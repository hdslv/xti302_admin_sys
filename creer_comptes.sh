#!/bin/bash

set -euo pipefail

REPERTOIRE_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPERTOIRE_SCRIPT
readonly REPERTOIRE_CLES="$REPERTOIRE_SCRIPT/config/cles"
readonly ENTETE_ATTENDUE="login;nom;groupe_principal;groupes_secondaires"
readonly MOTIF_NOM='^[a-z_][a-z0-9_-]{0,31}$'
readonly GROUPES_METIER=(comptables rh direction stagiaire)

FICHIER_CSV="$REPERTOIRE_SCRIPT/comptes.csv"
ADMINS=()
COMPTES_SSH=()

info()   { echo "[INFO] $*"; }
alerte() { echo "[ATTENTION] $*" >&2; }
erreur() { echo "[ERREUR] $1" >&2; exit "${2:-1}"; }

usage() {
    cat <<EOF
Usage : sudo $0 [fichier_csv]
Crée les groupes, les comptes, les répertoires de /srv (droits + ACL)
et installe les clés SSH, à partir de comptes.csv (format imposé :
$ENTETE_ATTENDUE).
EOF
}

verifier_prerequis() {
    [[ $EUID -eq 0 ]] || erreur "ce script doit être lancé en root (sudo $0)" 1
    [[ -r $FICHIER_CSV ]] || erreur "fichier introuvable ou illisible : $FICHIER_CSV" 1
    local commande
    for commande in useradd usermod groupadd setfacl ssh-keygen passwd chage; do
        command -v "$commande" >/dev/null \
            || erreur "commande manquante : $commande (installez le paquet acl ?)" 3
    done
}

contient() {
    local valeur=$1 element
    shift
    for element in "$@"; do
        [[ $element == "$valeur" ]] && return 0
    done
    return 1
}

creer_groupe() {
    local groupe=$1
    getent group "$groupe" >/dev/null && return 0
    groupadd "$groupe"
    info "groupe créé : $groupe"
}

traiter_compte() {
    local login=$1 nom=$2 primaire=$3 secondaires=$4 numero=$5
    local groupe maison
    local -a liste=()

    [[ $login =~ $MOTIF_NOM ]] || erreur "ligne $numero : login invalide « $login »" 2
    [[ $primaire =~ $MOTIF_NOM ]] || erreur "ligne $numero : groupe principal invalide « $primaire »" 2
    [[ $nom != *:* ]] || erreur "ligne $numero : le nom ne doit pas contenir « : »" 2
    if [[ -n $secondaires ]]; then
        IFS=',' read -r -a liste <<< "$secondaires"
    fi
    for groupe in "${liste[@]}"; do
        [[ $groupe =~ $MOTIF_NOM ]] \
            || erreur "ligne $numero : groupe secondaire invalide « $groupe »" 2
    done

    creer_groupe "$primaire"
    for groupe in "${liste[@]}"; do
        creer_groupe "$groupe"
    done

    if id -u "$login" >/dev/null 2>&1; then
        usermod -g "$primaire" -G "$secondaires" -c "$nom" "$login"
        info "compte mis à jour : $login"
    else
        if [[ -n $secondaires ]]; then
            useradd -m -s /bin/bash -g "$primaire" -G "$secondaires" -c "$nom" "$login"
        else
            useradd -m -s /bin/bash -g "$primaire" -c "$nom" "$login"
        fi
        info "compte créé : $login"
    fi

    maison=$(getent passwd "$login" | cut -d: -f6)
    if [[ -d $maison ]]; then
        chmod 0700 "$maison"
    fi

    if [[ $primaire == admins ]] || contient admins "${liste[@]}"; then
        ADMINS+=("$login")
    fi
    if [[ $primaire == acces_ssh ]] || contient acces_ssh "${liste[@]}"; then
        COMPTES_SSH+=("$login")
    fi
}

lire_csv() {
    local numero=0 ligne login nom primaire secondaires reste
    while IFS= read -r ligne || [[ -n $ligne ]]; do
        numero=$((numero + 1))
        ligne=${ligne%$'\r'}
        if [[ $numero -eq 1 ]]; then
            ligne=${ligne#$'\xef\xbb\xbf'}
            [[ $ligne == "$ENTETE_ATTENDUE" ]] \
                || erreur "en-tête invalide : « $ligne » (attendu : $ENTETE_ATTENDUE)" 2
            continue
        fi
        [[ -z ${ligne//[[:space:]]/} ]] && continue
        IFS=';' read -r login nom primaire secondaires reste <<< "$ligne"
        [[ -z ${reste:-} ]] || erreur "ligne $numero : trop de champs" 2
        [[ -n $login && -n $primaire ]] || erreur "ligne $numero : login ou groupe principal vide" 2
        traiter_compte "$login" "$nom" "$primaire" "${secondaires:-}" "$numero"
    done < "$FICHIER_CSV"
}

controler_groupes_metier() {
    local groupe gid nombre
    for groupe in "${GROUPES_METIER[@]}"; do
        gid=$(getent group "$groupe" | cut -d: -f3)
        nombre=$({ getent group "$groupe" | cut -d: -f4 | tr ',' '\n'
                   awk -F: -v gid="$gid" '$4 == gid {print $1}' /etc/passwd
                 } | sed '/^$/d' | sort -u | wc -l)
        if [[ $nombre -lt 2 ]]; then
            alerte "le groupe métier $groupe ne compte que $nombre utilisateur(s) (2 minimum)"
        fi
    done
}

appliquer_droits() {
    local repertoire=$1 mode=$2 acl=$3 acl_defaut=$4
    mkdir -p "$repertoire"
    chown root:root "$repertoire"
    setfacl --set "$acl" "$repertoire"
    setfacl -d --set "$acl_defaut" "$repertoire"
    chmod "$mode" "$repertoire"
}

creer_repertoires() {
    local groupe
    for groupe in "${GROUPES_METIER[@]}"; do
        creer_groupe "$groupe"
    done

    chown root:root /srv
    chmod 0755 /srv

    appliquer_droits /srv/dossiers_clients 0770 \
        "u::rwx,g::---,o::---,g:comptables:rwx,g:direction:r-x,m::rwx" \
        "u::rwx,g::---,o::---,g:comptables:rwx,g:direction:r-x,m::rwx"

    appliquer_droits /srv/rh 0770 \
        "u::rwx,g::---,o::---,g:rh:rwx,g:direction:r-x,m::rwx" \
        "u::rwx,g::---,o::---,g:rh:rwx,g:direction:r-x,m::rwx"

    appliquer_droits /srv/commun 0770 \
        "u::rwx,g::---,o::---,g:comptables:rwx,g:rh:rwx,g:direction:rwx,g:stagiaire:r-x,m::rwx" \
        "u::rwx,g::---,o::---,g:comptables:rwx,g:rh:rwx,g:direction:rwx,g:stagiaire:r-x,m::rwx"

    appliquer_droits /srv/commun/depot 1770 \
        "u::rwx,g::---,o::---,g:comptables:rwx,g:rh:rwx,g:direction:rwx,g:stagiaire:-wx,m::rwx" \
        "u::rwx,g::---,o::---,g:comptables:rwx,g:rh:rwx,g:direction:rwx,m::rwx"

    info "répertoires de /srv créés avec leurs ACL"
}

installer_cles() {
    local login cle maison groupe
    for login in "${COMPTES_SSH[@]}"; do
        cle="$REPERTOIRE_CLES/$login.pub"
        if [[ ! -f $cle ]]; then
            alerte "pas de clé publique pour $login ($cle) : connexion SSH impossible pour ce compte"
            continue
        fi
        if ! ssh-keygen -l -f "$cle" >/dev/null 2>&1; then
            alerte "clé publique invalide : $cle (ignorée)"
            continue
        fi
        maison=$(getent passwd "$login" | cut -d: -f6)
        groupe=$(id -gn "$login")
        install -d -m 0700 -o "$login" -g "$groupe" "$maison/.ssh"
        install -m 0600 -o "$login" -g "$groupe" "$cle" "$maison/.ssh/authorized_keys"
        info "clé SSH installée pour $login"
    done
}

mots_de_passe_admins() {
    local login etat
    for login in "${ADMINS[@]}"; do
        etat=$(passwd -S "$login" | awk '{print $2}')
        [[ $etat == P ]] && continue
        if [[ -t 0 ]]; then
            echo
            echo ">>> $login n'a pas encore de mot de passe (nécessaire pour sudo)."
            echo "    Choisissez un mot de passe provisoire : il devra être changé"
            echo "    à la première connexion."
            until passwd "$login"; do
                echo "Nouvel essai..."
            done
            chage -d 0 "$login"
        else
            alerte "$login n'a pas de mot de passe : lancez « passwd $login » puis « chage -d 0 $login »"
        fi
    done
}

main() {
    if [[ ${1:-} == -h || ${1:-} == --help ]]; then
        usage
        exit 0
    fi
    [[ $# -le 1 ]] || { usage >&2; exit 1; }
    if [[ -n ${1:-} ]]; then
        FICHIER_CSV=$1
    fi

    verifier_prerequis
    lire_csv
    controler_groupes_metier
    creer_repertoires
    installer_cles
    mots_de_passe_admins
    info "creer_comptes.sh terminé"
}

main "$@"
