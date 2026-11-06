#!/bin/bash

set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

REP="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REP
readonly CONFIG="$REP/config"
readonly DISQUE_SAUVEGARDE="${DISQUE_SAUVEGARDE:-/dev/sdb}"
readonly ETIQUETTE=SAUVEGARDES
readonly POINT_MONTAGE=/sauvegardes
readonly PAQUETS=(sudo acl rsync fdisk nftables fail2ban python3-systemd
                  unattended-upgrades apt-listchanges)
FORCER_SSH=0

etape()  { echo; echo "=== $* ==="; }
info()   { echo "[INFO] $*"; }
alerte() { echo "[ATTENTION] $*" >&2; }
erreur() { echo "[ERREUR] $*" >&2; exit 1; }

usage() {
    sed -n '3,18p' "$0" | sed 's/^# \{0,1\}//'
}

copier() {
    local source=$1 destination=$2 mode=$3
    install -D -o root -g root -m "$mode" "$CONFIG/$source" "$destination"
}

membres_groupe() {
    local groupe=$1 gid
    gid=$(getent group "$groupe" | cut -d: -f3)
    [[ -n $gid ]] || return 0
    { getent group "$groupe" | cut -d: -f4 | tr ',' '\n'
      awk -F: -v gid="$gid" '$4 == gid {print $1}' /etc/passwd
    } | sed '/^$/d' | sort -u
}

verifier_prerequis() {
    [[ $EUID -eq 0 ]] || erreur "ce script doit être lancé en root (su - puis ./installer.sh)"
    [[ -f $REP/comptes.csv && -x $REP/creer_comptes.sh ]] \
        || erreur "lancez installer.sh depuis la racine du dépôt (comptes.csv, creer_comptes.sh)"
    if ! grep -q '^13' /etc/debian_version 2>/dev/null; then
        alerte "ce projet est prévu pour Debian 13 (version trouvée : $(cat /etc/debian_version 2>/dev/null))"
    fi
    if [[ $(stat -c %U "$REP") != root ]] || find "$REP" -perm /022 -type f -name '*.sh' | grep -q .; then
        alerte "le dépôt $REP devrait appartenir à root, sans écriture pour le groupe ni les autres"
        alerte "  correction : chown -R root:root $REP && chmod -R go-w $REP"
    fi
}

installer_paquets() {
    etape "Paquets (dépôts Debian officiels uniquement)"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -q
    apt-get install -y -q --no-install-recommends "${PAQUETS[@]}"
}

configurer_comptes() {
    etape "C1, C2, C4 : comptes, groupes, répertoires /srv et clés SSH"
    "$REP/creer_comptes.sh" "$REP/comptes.csv"

    if grep -qE '^[#[:space:]]*HOME_MODE' /etc/login.defs; then
        sed -i -E 's/^[#[:space:]]*HOME_MODE.*/HOME_MODE\t0700/' /etc/login.defs
    else
        printf 'HOME_MODE\t0700\n' >> /etc/login.defs
    fi
    if [[ -f /etc/adduser.conf ]]; then
        sed -i -E 's/^#?DIR_MODE=.*/DIR_MODE=0700/' /etc/adduser.conf
    fi
    find /home -mindepth 1 -maxdepth 1 -type d -exec chmod 0700 {} +
}

configurer_sudo() {
    etape "C3 : sudo"
    visudo -cf "$CONFIG/sudoers.d/projet" >/dev/null || erreur "config/sudoers.d/projet est invalide"
    copier sudoers.d/projet /etc/sudoers.d/projet 0440
    visudo -c >/dev/null || erreur "configuration sudo invalide après copie"

    local compte
    for compte in $(getent group sudo | cut -d: -f4 | tr ',' ' '); do
        gpasswd -d "$compte" sudo >/dev/null
        info "$compte retiré du groupe sudo"
    done
}

installer_scripts() {
    etape "Scripts d'administration (root:root 0755 dans /usr/local/sbin)"
    install -o root -g root -m 0755 "$REP/analyse_logs.sh" /usr/local/sbin/analyse_logs.sh
    install -o root -g root -m 0755 "$REP/sauvegarde.sh" /usr/local/sbin/sauvegarde.sh
}

preparer_disque() {
    etape "B1 : disque de sauvegarde"
    local partition
    partition=$(blkid -L "$ETIQUETTE" 2>/dev/null || true)
    if [[ -n $partition ]]; then
        info "système de fichiers $ETIQUETTE déjà présent sur $partition : aucun formatage"
    else
        [[ -b $DISQUE_SAUVEGARDE ]] \
            || erreur "disque $DISQUE_SAUVEGARDE introuvable : ajoutez un second disque à la VM"
        if lsblk -nro MOUNTPOINT "$DISQUE_SAUVEGARDE" | grep -q .; then
            erreur "$DISQUE_SAUVEGARDE contient une partition montée : refus de formater"
        fi
        if [[ $(lsblk -nro NAME "$DISQUE_SAUVEGARDE" | wc -l) -gt 1 ]] \
           || blkid -p "$DISQUE_SAUVEGARDE" >/dev/null 2>&1; then
            erreur "$DISQUE_SAUVEGARDE n'est pas vierge (voir lsblk -f) : refus de formater"
        fi
        info "partitionnement de $DISQUE_SAUVEGARDE : table GPT, une partition Linux"
        printf 'label: gpt\n,,L\n' | sfdisk --quiet "$DISQUE_SAUVEGARDE"
        udevadm settle
        partition=$(lsblk -nrpo NAME,TYPE "$DISQUE_SAUVEGARDE" | awk '$2 == "part" {print $1; exit}')
        [[ -n $partition ]] || erreur "partition introuvable après le partitionnement"
        mkfs.ext4 -q -L "$ETIQUETTE" "$partition"
        info "système de fichiers ext4 « $ETIQUETTE » créé sur $partition"
    fi

    mkdir -p "$POINT_MONTAGE"
    if ! grep -qE "^LABEL=$ETIQUETTE[[:space:]]" /etc/fstab; then
        echo "LABEL=$ETIQUETTE $POINT_MONTAGE ext4 defaults,nodev,nosuid,noexec,nofail 0 2" >> /etc/fstab
        systemctl daemon-reload
        info "montage ajouté dans /etc/fstab"
    fi
    mountpoint -q "$POINT_MONTAGE" || mount "$POINT_MONTAGE"

    chown root:admins "$POINT_MONTAGE"
    chmod 0750 "$POINT_MONTAGE"
}

configurer_sauvegarde() {
    etape "B2 : planification de la sauvegarde (timer systemd)"
    copier systemd/sauvegarde.service /etc/systemd/system/sauvegarde.service 0644
    copier systemd/sauvegarde.timer /etc/systemd/system/sauvegarde.timer 0644
    systemctl daemon-reload
    systemctl enable --now sauvegarde.timer
}

premiere_sauvegarde() {
    etape "B1 : première sauvegarde (après configuration complète)"
    systemctl start sauvegarde.service
    info "sauvegarde initiale effectuée dans $POINT_MONTAGE/versions"
}

configurer_journal() {
    etape "J3 : journal persistant"
    copier journald/persistant.conf /etc/systemd/journald.conf.d/persistant.conf 0644
    mkdir -p /var/log/journal
    systemd-tmpfiles --create --prefix /var/log/journal
    systemctl restart systemd-journald
    journalctl --flush
}

configurer_parefeu() {
    etape "J2 : pare-feu nftables"
    nft -c -f "$CONFIG/nftables.conf" || erreur "config/nftables.conf est invalide"
    copier nftables.conf /etc/nftables.conf 0755
    copier systemd/nftables.service.d/projet.conf /etc/systemd/system/nftables.service.d/projet.conf 0644
    systemctl daemon-reload
    systemctl enable nftables
    if systemctl is-active --quiet nftables; then
        systemctl reload nftables
    else
        systemctl start nftables
    fi
}

configurer_fail2ban() {
    etape "J1 : fail2ban"
    copier fail2ban/jail.d/projet-sshd.conf /etc/fail2ban/jail.d/projet-sshd.conf 0644
    systemctl enable fail2ban
    systemctl restart fail2ban
    sleep 2
    fail2ban-client status sshd >/dev/null || erreur "la prison sshd de fail2ban n'est pas active"
}

configurer_mises_a_jour() {
    etape "D1 : mises à jour de sécurité automatiques"
    copier apt/20auto-upgrades /etc/apt/apt.conf.d/20auto-upgrades 0644
    systemctl enable --now apt-daily.timer apt-daily-upgrade.timer
}

cle_admin_installee() {
    local compte maison
    for compte in $(membres_groupe admins); do
        id -Gn "$compte" | tr ' ' '\n' | grep -qx acces_ssh || continue
        maison=$(getent passwd "$compte" | cut -d: -f6)
        [[ -s $maison/.ssh/authorized_keys ]] && return 0
    done
    return 1
}

configurer_ssh() {
    etape "S1 à S5 : durcissement SSH"
    if ! cle_admin_installee && [[ $FORCER_SSH -eq 0 ]]; then
        alerte "aucun administrateur n'a de clé SSH installée (config/cles/<login>.pub)"
        alerte "durcissement SSH NON appliqué ; ajoutez les clés puis relancez (ou --forcer-ssh)"
        return 0
    fi
    copier profile.d/tmout.sh /etc/profile.d/tmout.sh 0644

    local cible=/etc/ssh/sshd_config.d/01-durcissement.conf sauvegarde=""
    if [[ -f $cible ]]; then
        sauvegarde=$(mktemp)
        cp -p "$cible" "$sauvegarde"
    fi
    copier ssh/sshd_config.d/01-durcissement.conf "$cible" 0644
    if sshd -t; then
        systemctl reload ssh
        info "configuration SSH validée (sshd -t) et rechargée"
        if [[ -n $sauvegarde ]]; then
            rm -f "$sauvegarde"
        fi
    else
        if [[ -n $sauvegarde ]]; then
            mv "$sauvegarde" "$cible"
        else
            rm -f "$cible"
        fi
        erreur "sshd -t a refusé la configuration : ancienne configuration remise, service non rechargé"
    fi
}

verrouiller_root() {
    etape "C4 : verrouillage du compte root"
    local compte possible=0
    for compte in $(membres_groupe admins); do
        if [[ $(passwd -S "$compte" | awk '{print $2}') == P ]]; then
            possible=1
        fi
    done
    if [[ $possible -eq 1 ]] && visudo -c >/dev/null 2>&1; then
        passwd -l root >/dev/null
        info "compte root verrouillé (connexion : un administrateur nominatif + sudo)"
    else
        alerte "root NON verrouillé : aucun administrateur n'a de mot de passe (accès de secours)"
    fi
}

main() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --forcer-ssh) FORCER_SSH=1 ;;
            -h | --help) usage; exit 0 ;;
            *) erreur "option inconnue : $1 (voir -h)" ;;
        esac
        shift
    done

    verifier_prerequis
    installer_paquets
    configurer_comptes
    configurer_sudo
    installer_scripts
    preparer_disque
    configurer_sauvegarde
    configurer_journal
    configurer_parefeu
    configurer_fail2ban
    configurer_mises_a_jour
    configurer_ssh
    verrouiller_root
    premiere_sauvegarde

    etape "Installation terminée"
    echo "Vérifiez maintenant la conformité : ./verifier.sh"
    echo "Conseil : redémarrez une fois la VM puis relancez ./verifier.sh (J2, J3)."
}

main "$@"
