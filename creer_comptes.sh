#!/bin/bash
#
# creer_comptes.sh — Projet XTI302-CYB, contexte B (cabinet Chiffres & Co)
#
# C1 : crée les groupes et les comptes décrits dans comptes.csv.
#      Le script est idempotent : le relancer met les comptes en conformité
#      avec le fichier, sans créer de doublon et sans erreur.
# C2 : crée les répertoires de /srv avec leurs permissions et leurs ACL,
#      y compris les ACL par défaut (héritées par les fichiers créés plus tard).
# C4 : répertoires personnels en 0700 (illisibles par les autres).
#      Installe les clés publiques (config/cles/<login>.pub) des comptes
#      du groupe acces_ssh.
#
# Usage  : sudo ./creer_comptes.sh [fichier_csv]     (défaut : ./comptes.csv)
# Sortie : 0 succès ; 1 erreur d'utilisation ; 2 erreur dans le CSV ;
#          3 commande manquante.

set -euo pipefail

REPERTOIRE_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPERTOIRE_SCRIPT
readonly REPERTOIRE_CLES="$REPERTOIRE_SCRIPT/config/cles"
readonly ENTETE_ATTENDUE="login;nom;groupe_principal;groupes_secondaires"
# Noms de comptes et de groupes acceptés (règle classique de useradd)
readonly MOTIF_NOM='^[a-z_][a-z0-9_-]{0,31}$'
# Groupes métier du contexte B (colonnes du tableau)
readonly GROUPES_METIER=(comptables rh direction stagiaire)

FICHIER_CSV="$REPERTOIRE_SCRIPT/comptes.csv"
ADMINS=()        # comptes membres de admins (mot de passe initial)
COMPTES_SSH=()   # comptes membres de acces_ssh (installation des clés)

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

# contient VALEUR ELEMENT... : vrai si VALEUR fait partie de la liste
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

# Crée ou met à jour UN compte (appelée pour chaque ligne du CSV)
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

    # Les groupes doivent exister avant le compte
    creer_groupe "$primaire"
    for groupe in "${liste[@]}"; do
        creer_groupe "$groupe"
    done

    if id -u "$login" >/dev/null 2>&1; then
        # Compte existant : on le remet en conformité avec le CSV.
        # -G sans -a fixe la liste EXACTE des groupes secondaires : un compte
        # ajouté à la main dans « sudo » en est donc retiré (C3).
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

    # C4 : répertoire personnel illisible par les autres. 0700 et non 0750,
    # car le groupe principal est partagé (ex. tous les comptables).
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

# Lit comptes.csv ligne par ligne et vérifie le format imposé
lire_csv() {
    local numero=0 ligne login nom primaire secondaires reste
    while IFS= read -r ligne || [[ -n $ligne ]]; do
        numero=$((numero + 1))
        ligne=${ligne%$'\r'}                    # fichier édité sous Windows
        if [[ $numero -eq 1 ]]; then
            ligne=${ligne#$'\xef\xbb\xbf'}      # marque BOM éventuelle
            [[ $ligne == "$ENTETE_ATTENDUE" ]] \
                || erreur "en-tête invalide : « $ligne » (attendu : $ENTETE_ATTENDUE)" 2
            continue
        fi
        [[ -z ${ligne//[[:space:]]/} ]] && continue   # ligne vide
        IFS=';' read -r login nom primaire secondaires reste <<< "$ligne"
        [[ -z ${reste:-} ]] || erreur "ligne $numero : trop de champs" 2
        [[ -n $login && -n $primaire ]] || erreur "ligne $numero : login ou groupe principal vide" 2
        traiter_compte "$login" "$nom" "$primaire" "${secondaires:-}" "$numero"
    done < "$FICHIER_CSV"
}

# Chaque groupe métier doit compter au moins 2 utilisateurs
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

# Applique propriétaire, mode, ACL et ACL par défaut à un répertoire.
# setfacl --set REMPLACE toute l'ACL : relancer le script donne le même résultat.
appliquer_droits() {
    local repertoire=$1 mode=$2 acl=$3 acl_defaut=$4
    mkdir -p "$repertoire"
    chown root:root "$repertoire"
    setfacl --set "$acl" "$repertoire"
    setfacl -d --set "$acl_defaut" "$repertoire"
    # chmod en dernier : il fixe le sticky bit et « other ». Sur un fichier
    # avec ACL, les bits « groupe » de chmod règlent le masque (ici rwx).
    chmod "$mode" "$repertoire"
}

# C2 : répertoires et droits du contexte B
#   g::--- (groupe propriétaire) : un fichier appartient au groupe principal
#   de son créateur ; on ne donne AUCUN droit via ce groupe, seulement via
#   les entrées nommées. Indispensable pour depot : un fichier déposé par un
#   stagiaire appartient au groupe stagiaire, les autres stagiaires ne
#   doivent pas pouvoir le lire.
creer_repertoires() {
    local groupe
    for groupe in "${GROUPES_METIER[@]}"; do
        creer_groupe "$groupe"
    done

    # /srv : traversable par tous, modifiable par root seul
    chown root:root /srv
    chmod 0755 /srv

    # comptables : lecture/écriture ; direction : lecture ; rh, stagiaire : rien
    appliquer_droits /srv/dossiers_clients 0770 \
        "u::rwx,g::---,o::---,g:comptables:rwx,g:direction:r-x,m::rwx" \
        "u::rwx,g::---,o::---,g:comptables:rwx,g:direction:r-x,m::rwx"

    # rh : lecture/écriture ; direction : lecture ; comptables, stagiaire : rien
    appliquer_droits /srv/rh 0770 \
        "u::rwx,g::---,o::---,g:rh:rwx,g:direction:r-x,m::rwx" \
        "u::rwx,g::---,o::---,g:rh:rwx,g:direction:r-x,m::rwx"

    # comptables, rh, direction : lecture/écriture ; stagiaire : lecture
    appliquer_droits /srv/commun 0770 \
        "u::rwx,g::---,o::---,g:comptables:rwx,g:rh:rwx,g:direction:rwx,g:stagiaire:r-x,m::rwx" \
        "u::rwx,g::---,o::---,g:comptables:rwx,g:rh:rwx,g:direction:rwx,g:stagiaire:r-x,m::rwx"

    # depot : stagiaire = « dépôt seul » :
    #   -wx sur le répertoire : peut créer un fichier (w) et y accéder (x),
    #       mais pas lister le contenu (pas de r) ;
    #   aucune entrée stagiaire dans l'ACL par défaut : les fichiers déposés
    #       ne sont lisibles que par leur auteur et par les trois autres groupes ;
    #   sticky bit (1770) : seul l'auteur d'un fichier peut le supprimer ou le
    #       renommer (un stagiaire ne peut pas effacer le dépôt d'un autre).
    appliquer_droits /srv/commun/depot 1770 \
        "u::rwx,g::---,o::---,g:comptables:rwx,g:rh:rwx,g:direction:rwx,g:stagiaire:-wx,m::rwx" \
        "u::rwx,g::---,o::---,g:comptables:rwx,g:rh:rwx,g:direction:rwx,m::rwx"

    info "répertoires de /srv créés avec leurs ACL"
}

# Installe la clé publique du dépôt pour chaque compte de acces_ssh.
# Le dépôt est la référence : authorized_keys est réécrit à chaque exécution.
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

# Les administrateurs ont besoin d'un mot de passe : pour sudo, et pour la
# console de secours une fois root verrouillé. Aucun mot de passe n'est stocké
# dans le dépôt : on le demande ici, puis on force son changement à la
# première connexion (chage -d 0).
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
