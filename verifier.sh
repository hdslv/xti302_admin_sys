#!/bin/bash
#
# verifier.sh — Projet XTI302-CYB « Durcir un serveur Linux et le prouver »
# Contexte B : cabinet comptable Chiffres & Co
#
# Teste automatiquement chaque exigence du cahier des charges et affiche un
# résultat par test :
#     [OK] S2  connexion root refusée
#     [KO] J2  politique par défaut du pare-feu : accept (attendu : drop)
#     --- 27 / 28 tests réussis
#
# Usage  : sudo ./verifier.sh        (depuis la racine du dépôt)
# Sortie : 0 si tout est conforme, 1 si au moins un test échoue,
#          2 en cas d'erreur d'utilisation (pas root, option inconnue).
#
# Ce script ne modifie JAMAIS le système : il ne crée que des fichiers de test
# temporaires, supprimés à la fin (fonction nettoyer, appelée par trap EXIT).
#
# Pourquoi seulement « set -u » et pas « set -euo pipefail » ?
#   -e       : ce script lance EXPRÈS des commandes qui doivent échouer (ex.
#              « un stagiaire ne peut pas lister depot ») ; avec -e, le premier
#              refus arrêterait toute la vérification.
#   pipefail : dans « commande | grep -q motif », grep s'arrête à la première
#              ligne trouvée ; la commande reçoit SIGPIPE et, avec pipefail, le
#              pipeline serait faux alors que le motif est bien présent.
#   -u       : conservé : une faute de frappe dans un nom de variable est une
#              erreur et non une chaîne vide silencieuse.
#
# Pour tester un droit à la place d'un utilisateur, on utilise runuser (le
# « sudo -u » de root) : il ne dépend pas de la configuration sudo, que le
# jury peut justement avoir modifiée.
set -u

# Messages des commandes en anglais (stables pour les comparaisons), PATH sûr
export LC_ALL=C
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

REP="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REP
readonly CSV="$REP/comptes.csv"
readonly CONFIG="$REP/config"
readonly ENTETE="login;nom;groupe_principal;groupes_secondaires"
readonly GROUPES_METIER=(comptables rh direction stagiaire)

readonly CONF_SSH=/etc/ssh/sshd_config.d/01-durcissement.conf
readonly CONF_TMOUT=/etc/profile.d/tmout.sh
readonly CONF_SUDO=/etc/sudoers.d/projet
readonly CONF_F2B=/etc/fail2ban/jail.d/projet-sshd.conf
readonly CONF_NFT=/etc/nftables.conf
readonly CONF_NFT_SERVICE=/etc/systemd/system/nftables.service.d/projet.conf
readonly CONF_JOURNAL=/etc/systemd/journald.conf.d/persistant.conf
readonly CONF_APT=/etc/apt/apt.conf.d/20auto-upgrades
readonly SCRIPT_ANALYSE=/usr/local/sbin/analyse_logs.sh
readonly SCRIPT_SAUVEGARDE=/usr/local/sbin/sauvegarde.sh
readonly SAUVEGARDES=/sauvegardes
readonly VERSIONS=$SAUVEGARDES/versions
readonly ETIQUETTE_DISQUE=SAUVEGARDES

# C2 : tableau du contexte B, une ligne par case : répertoire|groupe|droit
#   rw = lecture/écriture   r = lecture   - = aucun accès   depot = dépôt seul
readonly DROITS_ATTENDUS=(
    "/srv/dossiers_clients|comptables|rw"
    "/srv/dossiers_clients|rh|-"
    "/srv/dossiers_clients|direction|r"
    "/srv/dossiers_clients|stagiaire|-"
    "/srv/rh|comptables|-"
    "/srv/rh|rh|rw"
    "/srv/rh|direction|r"
    "/srv/rh|stagiaire|-"
    "/srv/commun|comptables|rw"
    "/srv/commun|rh|rw"
    "/srv/commun|direction|rw"
    "/srv/commun|stagiaire|r"
    "/srv/commun/depot|comptables|rw"
    "/srv/commun/depot|rh|rw"
    "/srv/commun/depot|direction|rw"
    "/srv/commun/depot|stagiaire|depot"
)
readonly REPERTOIRES_SRV=(/srv/dossiers_clients /srv/rh /srv/commun /srv/commun/depot)

NB_OK=0
NB_KO=0
CSV_VALIDE=0
LOGINS=()
declare -A PRIMAIRE=()
declare -A SECONDAIRES=()
A_SUPPRIMER=()
SSHD_T=""

if [[ -t 1 ]]; then
    VERT=$'\e[32m' ROUGE=$'\e[31m' GRIS=$'\e[90m' GRAS=$'\e[1m' NORMAL=$'\e[0m'
else
    VERT="" ROUGE="" GRIS="" GRAS="" NORMAL=""
fi

# ---------------------------------------------------------------------------
# Outils
# ---------------------------------------------------------------------------

ok()    { NB_OK=$((NB_OK + 1)); printf '%s[OK]%s %-3s %s\n' "$VERT" "$NORMAL" "$1" "$2"; }
ko()    { NB_KO=$((NB_KO + 1)); printf '%s[KO]%s %-3s %s\n' "$ROUGE" "$NORMAL" "$1" "$2"; }
note()  { printf '%s[--]%s %-3s %s\n' "$GRIS" "$NORMAL" "$1" "$2"; }   # information, non comptée
titre() { printf '\n%s%s%s\n' "$GRAS" "$*" "$NORMAL"; }

# controle ID "message si OK" "message si KO" commande [arguments...]
controle() {
    local id=$1 message_ok=$2 message_ko=$3
    shift 3
    if "$@" >/dev/null 2>&1; then ok "$id" "$message_ok"; else ko "$id" "$message_ko"; fi
}

nettoyer() {
    local element
    for element in "${A_SUPPRIMER[@]}"; do
        rm -rf -- "$element"
    done
}

# en_tant_que COMPTE commande... : lance la commande avec l'identité du compte
en_tant_que() { runuser -u "$1" -- "${@:2}" >/dev/null 2>&1; }
# peut COMPTE -r|-w|-x CHEMIN : test d'accès réel (respecte les ACL)
peut() { runuser -u "$1" -- test "$2" "$3" 2>/dev/null; }

identique() { [[ -f $1 && -f $2 ]] && cmp -s "$1" "$2"; }

# Fichier appartenant à root et non modifiable par le groupe ni les autres
protege() {
    [[ -f $1 ]] || return 1
    [[ $(stat -c %U "$1") == root ]] || return 1
    (( (8#$(stat -c %a "$1") & 8#022) == 0 ))
}

droits_autres() { echo $(( 8#$(stat -c %a "$1") & 7 )); }

# Comptes humains (UID 1000 à 59999)
comptes_humains() { awk -F: '$3 >= 1000 && $3 < 60000 {print $1}' /etc/passwd; }

# Groupe principal ou secondaire, d'après comptes.csv
dans_groupe_csv() {
    local login=$1 groupe=$2
    [[ ${PRIMAIRE[$login]} == "$groupe" || ",${SECONDAIRES[$login]}," == *",$groupe,"* ]]
}

# membre GROUPE [RANG] : le RANG-ième compte du groupe dans comptes.csv
membre() {
    local groupe=$1 rang=${2:-1} login n=0
    for login in "${LOGINS[@]}"; do
        if dans_groupe_csv "$login" "$groupe"; then
            n=$((n + 1))
            if [[ $n -eq $rang ]]; then echo "$login"; return 0; fi
        fi
    done
    return 1
}

membres() {
    local groupe=$1 login
    for login in "${LOGINS[@]}"; do
        if dans_groupe_csv "$login" "$groupe"; then echo "$login"; fi
    done
}

# Valeur effective d'une option sshd (sshd -T affiche les noms en minuscules)
valeur_sshd() {
    awk -v cle="$1" '$1 == cle { $1 = ""; sub(/^ /, ""); print; exit }' <<< "$SSHD_T"
}

# Tentative de connexion SSH locale par mot de passe, sans clé ni saisie
ssh_par_mot_de_passe() {
    timeout 15 ssh -o BatchMode=yes -o ConnectTimeout=5 \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        -o PubkeyAuthentication=no -o PreferredAuthentications=password,keyboard-interactive \
        "$1@127.0.0.1" true 2>&1
}

lire_csv() {
    [[ -r $CSV ]] || return 1
    local numero=0 ligne login nom primaire secondaires reste
    while IFS= read -r ligne || [[ -n $ligne ]]; do
        numero=$((numero + 1))
        ligne=${ligne%$'\r'}
        if [[ $numero -eq 1 ]]; then
            ligne=${ligne#$'\xef\xbb\xbf'}
            [[ $ligne == "$ENTETE" ]] || return 1
            continue
        fi
        [[ -z ${ligne//[[:space:]]/} ]] && continue
        IFS=';' read -r login nom primaire secondaires reste <<< "$ligne"
        [[ -n $login && -n $primaire && -z ${reste:-} ]] || return 1
        LOGINS+=("$login")
        PRIMAIRE[$login]=$primaire
        SECONDAIRES[$login]=${secondaires:-}
    done < "$CSV"
    CSV_VALIDE=1
}

derniere_version() {
    find "$VERSIONS" -mindepth 1 -maxdepth 1 -type d -name '[0-9]*-[0-9]*_[0-9]*' -printf '%f\n' 2>/dev/null \
        | sort | tail -n 1
}

nombre_versions() {
    find "$VERSIONS" -mindepth 1 -maxdepth 1 -type d -name '[0-9]*-[0-9]*_[0-9]*' 2>/dev/null | wc -l
}

# ---------------------------------------------------------------------------
# C1 à C4 : comptes et droits
# ---------------------------------------------------------------------------

test_C1_csv() {
    if lire_csv; then
        ok C1 "comptes.csv lisible et au format imposé (${#LOGINS[@]} comptes)"
    else
        ko C1 "comptes.csv absent ou mal formé (en-tête attendu : $ENTETE)"
    fi
}

test_C1_comptes() {
    [[ $CSV_VALIDE -eq 1 ]] || return 0
    local login groupe manque
    for login in "${LOGINS[@]}"; do
        if ! id -u "$login" >/dev/null 2>&1; then
            ko C1 "le compte $login prévu dans comptes.csv n'existe pas"
            continue
        fi
        manque=""
        [[ $(id -gn "$login") == "${PRIMAIRE[$login]}" ]] || manque+=" ${PRIMAIRE[$login]}(principal)"
        local -a secondaires=()
        IFS=',' read -r -a secondaires <<< "${SECONDAIRES[$login]}"
        for groupe in "${secondaires[@]}"; do
            id -Gn "$login" | tr ' ' '\n' | grep -qx "$groupe" || manque+=" $groupe"
        done
        if [[ -z $manque ]]; then
            ok C1 "compte $login présent, groupes conformes à comptes.csv"
        else
            ko C1 "compte $login : groupe(s) incorrect(s) :$manque"
        fi
    done
}

test_C1_groupes_metier() {
    local groupe gid nombre
    for groupe in "${GROUPES_METIER[@]}"; do
        gid=$(getent group "$groupe" | cut -d: -f3)
        if [[ -z $gid ]]; then
            ko C1 "le groupe métier $groupe n'existe pas"
            continue
        fi
        nombre=$({ getent group "$groupe" | cut -d: -f4 | tr ',' '\n'
                   awk -F: -v gid="$gid" '$4 == gid {print $1}' /etc/passwd
                 } | sed '/^$/d' | sort -u | wc -l)
        if [[ $nombre -ge 2 ]]; then
            ok C1 "groupe métier $groupe : $nombre utilisateurs (2 minimum)"
        else
            ko C1 "groupe métier $groupe : $nombre utilisateur(s), 2 minimum"
        fi
    done
}

test_C1_doublons() {
    local doublons
    doublons=$( { cut -d: -f1 /etc/passwd | sort | uniq -d
                  cut -d: -f3 /etc/passwd | sort | uniq -d | sed 's/^/uid /'
                  cut -d: -f1 /etc/group | sort | uniq -d | sed 's/^/groupe /'
                } | tr '\n' ' ')
    if [[ -z ${doublons// /} ]]; then
        ok C1 "aucun doublon de compte, d'UID ou de groupe (idempotence de creer_comptes.sh)"
    else
        ko C1 "doublons trouvés : $doublons"
    fi
}

test_C1_hors_csv() {
    [[ $CSV_VALIDE -eq 1 ]] || return 0
    local compte inconnus=""
    for compte in $(comptes_humains); do
        [[ -v PRIMAIRE[$compte] ]] || inconnus+=" $compte"
    done
    if [[ -z $inconnus ]]; then
        ok C1 "aucun compte humain en dehors de comptes.csv"
    else
        ko C1 "compte(s) absent(s) de comptes.csv :$inconnus (à ajouter au CSV ou à supprimer)"
    fi
}

test_C2_structure() {
    local rep
    for rep in "${REPERTOIRES_SRV[@]}"; do
        if [[ ! -d $rep ]]; then
            ko C2 "$rep n'existe pas"
        elif [[ $(stat -c %U:%G "$rep") != root:root ]]; then
            ko C2 "$rep n'appartient pas à root:root"
        elif [[ $(droits_autres "$rep") -ne 0 ]]; then
            ko C2 "$rep donne des droits à « other » (attendu : aucun)"
        elif ! getfacl -p "$rep" 2>/dev/null | grep -q '^default:'; then
            ko C2 "$rep n'a pas d'ACL par défaut"
        else
            ok C2 "$rep : root:root, aucun droit pour « other », ACL par défaut présente"
        fi
    done
    controle C2 "/srv/commun/depot a le sticky bit (seul l'auteur supprime son fichier)" \
                "/srv/commun/depot n'a pas le sticky bit" \
                test -k /srv/commun/depot
}

test_C2_droits() {
    [[ $CSV_VALIDE -eq 1 ]] || return 0
    local entree rep groupe droit compte r w x conforme libelle
    for entree in "${DROITS_ATTENDUS[@]}"; do
        IFS='|' read -r rep groupe droit <<< "$entree"
        compte=$(membre "$groupe" 1)
        if [[ -z $compte ]] || ! id -u "$compte" >/dev/null 2>&1; then
            ko C2 "aucun compte existant du groupe $groupe pour tester $rep"
            continue
        fi
        peut "$compte" -r "$rep"; r=$?
        peut "$compte" -w "$rep"; w=$?
        peut "$compte" -x "$rep"; x=$?
        conforme=1
        case $droit in
            rw)    libelle="lecture/écriture"; [[ $r -eq 0 && $w -eq 0 && $x -eq 0 ]] || conforme=0 ;;
            r)     libelle="lecture seule";    [[ $r -eq 0 && $x -eq 0 && $w -ne 0 ]] || conforme=0 ;;
            -)     libelle="aucun accès";      [[ $r -ne 0 && $w -ne 0 && $x -ne 0 ]] || conforme=0 ;;
            depot) libelle="dépôt seul";       [[ $r -ne 0 && $w -eq 0 && $x -eq 0 ]] || conforme=0 ;;
        esac
        if [[ $conforme -eq 1 ]]; then
            ok C2 "$groupe sur $rep : $libelle (testé avec $compte)"
        else
            ko C2 "$groupe sur $rep : attendu $libelle, obtenu r=$((r == 0)) w=$((w == 0)) x=$((x == 0)) ($compte)"
        fi
    done
}

# Un fichier créé PLUS TARD doit hériter des bons droits (ACL par défaut)
heritage() {
    local rep=$1 groupe_auteur=$2
    local auteur fichier entree rep2 groupe droit compte r w erreurs=""
    auteur=$(membre "$groupe_auteur" 1) || { ko C2 "aucun compte $groupe_auteur pour tester $rep"; return; }
    fichier="$rep/.verifier_$$_$RANDOM"
    if ! en_tant_que "$auteur" touch "$fichier"; then
        ko C2 "$auteur ($groupe_auteur) ne peut pas créer de fichier dans $rep"
        return
    fi
    A_SUPPRIMER+=("$fichier")
    for entree in "${DROITS_ATTENDUS[@]}"; do
        IFS='|' read -r rep2 groupe droit <<< "$entree"
        [[ $rep2 == "$rep" ]] || continue
        # 2e membre du groupe : différent de l'auteur pour son propre groupe
        compte=$(membre "$groupe" 2) || compte=$(membre "$groupe" 1)
        peut "$compte" -r "$fichier"; r=$?
        peut "$compte" -w "$fichier"; w=$?
        case $droit in
            rw)      [[ $r -eq 0 && $w -eq 0 ]] || erreurs+=" $groupe" ;;
            r)       [[ $r -eq 0 && $w -ne 0 ]] || erreurs+=" $groupe" ;;
            - | depot) [[ $r -ne 0 && $w -ne 0 ]] || erreurs+=" $groupe" ;;
        esac
    done
    rm -f -- "$fichier"
    if [[ -z $erreurs ]]; then
        ok C2 "ACL par défaut : un fichier créé par $auteur dans $rep hérite des bons droits"
    else
        ko C2 "ACL par défaut : droits incorrects sur un nouveau fichier de $rep pour :$erreurs"
    fi
}

test_C2_heritage() {
    [[ $CSV_VALIDE -eq 1 ]] || return 0
    heritage /srv/dossiers_clients comptables
    heritage /srv/rh rh
    heritage /srv/commun direction
    heritage /srv/commun/depot rh
}

test_C2_depot() {
    [[ $CSV_VALIDE -eq 1 ]] || return 0
    local stagiaire1 stagiaire2 comptable fichier
    stagiaire1=$(membre stagiaire 1)
    stagiaire2=$(membre stagiaire 2)
    comptable=$(membre comptables 1)
    if [[ -z $stagiaire1 || -z $stagiaire2 || -z $comptable ]]; then
        ko C2 "il faut 2 stagiaires et 1 comptable dans comptes.csv pour tester depot"
        return
    fi
    fichier="/srv/commun/depot/.verifier_depot_$$"
    if printf 'rapport de stage\n' | runuser -u "$stagiaire1" -- tee "$fichier" >/dev/null 2>&1; then
        ok C2 "le stagiaire $stagiaire1 peut déposer un fichier dans depot"
        A_SUPPRIMER+=("$fichier")
    else
        ko C2 "le stagiaire $stagiaire1 ne peut pas déposer de fichier dans depot"
        return
    fi
    if en_tant_que "$stagiaire1" ls /srv/commun/depot; then
        ko C2 "un stagiaire peut lister le contenu de depot"
    else
        ok C2 "un stagiaire ne peut pas lister le contenu de depot"
    fi
    if peut "$stagiaire2" -r "$fichier"; then
        ko C2 "le stagiaire $stagiaire2 peut lire le dépôt de $stagiaire1"
    else
        ok C2 "le stagiaire $stagiaire2 ne peut pas lire le dépôt de $stagiaire1"
    fi
    controle C2 "le comptable $comptable peut lire le fichier déposé par $stagiaire1" \
                "le comptable $comptable ne peut pas lire le fichier déposé" \
                peut "$comptable" -r "$fichier"
    if en_tant_que "$stagiaire2" rm -f "$fichier" && [[ ! -e $fichier ]]; then
        ko C2 "le stagiaire $stagiaire2 a pu supprimer le dépôt de $stagiaire1"
    else
        ok C2 "le stagiaire $stagiaire2 ne peut pas supprimer le dépôt de $stagiaire1"
    fi
    rm -f -- "$fichier"
}

test_C3_fichier() {
    if identique "$CONF_SUDO" "$CONFIG/sudoers.d/projet" \
       && [[ $(stat -c %a:%U "$CONF_SUDO") == 440:root ]] && visudo -c >/dev/null 2>&1; then
        ok C3 "$CONF_SUDO installé (0440 root), identique au dépôt, visudo -c valide"
    else
        ko C3 "$CONF_SUDO absent, modifié, mal protégé ou configuration sudo invalide"
    fi
}

test_C3_admins() {
    [[ $CSV_VALIDE -eq 1 ]] || return 0
    local admin
    for admin in $(membres admins); do
        controle C3 "l'administrateur $admin peut tout lancer avec sudo" \
                    "l'administrateur $admin n'a pas sudo" \
                    sudo -n -l -U "$admin" /usr/bin/id
    done
}

test_C3_support() {
    if sudo -n -l -U support "$SCRIPT_ANALYSE" >/dev/null 2>&1 \
       && ! sudo -n -l -U support /usr/bin/id >/dev/null 2>&1 \
       && ! sudo -n -l -U support /bin/bash >/dev/null 2>&1; then
        ok C3 "le compte support ne peut lancer que analyse_logs.sh avec sudo"
    else
        ko C3 "droits sudo du compte support incorrects (attendu : analyse_logs.sh seulement)"
    fi
}

test_C3_personne_d_autre() {
    local compte membres_sudo abusifs=""
    membres_sudo=$(getent group sudo | cut -d: -f4)
    for compte in $(comptes_humains); do
        [[ $compte == support ]] && continue
        id -Gn "$compte" | tr ' ' '\n' | grep -qx admins && continue
        if sudo -n -l -U "$compte" /usr/bin/id >/dev/null 2>&1; then
            abusifs+=" $compte"
        fi
    done
    if [[ -z $membres_sudo && -z $abusifs ]]; then
        ok C3 "aucun autre compte n'a sudo (groupe sudo vide)"
    else
        ko C3 "comptes ayant sudo à tort :${abusifs} ${membres_sudo:+(groupe sudo : $membres_sudo)}"
    fi
}

test_C4_root() {
    local etat
    etat=$(passwd -S root 2>/dev/null | awk '{print $2}')
    if [[ $etat == L ]]; then
        ok C4 "le compte root est verrouillé"
    else
        ko C4 "le compte root n'est pas verrouillé (état : ${etat:-inconnu})"
    fi
}

test_C4_maisons() {
    local compte maison mauvais=""
    for compte in $(comptes_humains); do
        maison=$(getent passwd "$compte" | cut -d: -f6)
        [[ -d $maison && $maison == /home/* ]] || continue
        (( (8#$(stat -c %a "$maison") & 8#077) == 0 )) || mauvais+=" $maison($(stat -c %a "$maison"))"
    done
    if [[ -z $mauvais ]]; then
        ok C4 "répertoires personnels en 0700 (illisibles par les autres)"
    else
        ko C4 "répertoires personnels lisibles par d'autres :$mauvais"
    fi
}

test_C4_lecture() {
    [[ $CSV_VALIDE -eq 1 ]] || return 0
    local a b maison
    a=$(membre comptables 1); b=$(membre comptables 2)
    [[ -n $a && -n $b ]] || return 0
    maison=$(getent passwd "$b" | cut -d: -f6)
    if peut "$a" -r "$maison" || peut "$a" -x "$maison"; then
        ko C4 "$a peut accéder au répertoire personnel de $b"
    else
        ok C4 "$a ne peut pas lire le répertoire personnel de $b (pourtant même groupe)"
    fi
}

# ---------------------------------------------------------------------------
# S1 à S5 : accès SSH
# ---------------------------------------------------------------------------

test_S1() {
    if [[ $(valeur_sshd passwordauthentication) == no \
          && $(valeur_sshd kbdinteractiveauthentication) == no \
          && $(valeur_sshd pubkeyauthentication) == yes ]]; then
        ok S1 "sshd : clé uniquement (PasswordAuthentication et KbdInteractiveAuthentication à no)"
    else
        ko S1 "sshd accepte encore les mots de passe (sshd -T)"
    fi
    local sortie
    sortie=$(ssh_par_mot_de_passe support)
    if [[ $sortie == *"Permission denied (publickey)"* ]]; then
        ok S1 "connexion par mot de passe refusée : le serveur ne propose que « publickey »"
    else
        ko S1 "test de connexion par mot de passe inattendu : $(tail -n 1 <<< "$sortie")"
    fi
}

test_S2() {
    local sortie
    sortie=$(ssh_par_mot_de_passe root)
    if [[ $(valeur_sshd permitrootlogin) == no && $sortie == *"Permission denied"* ]]; then
        ok S2 "connexion root refusée (PermitRootLogin no)"
    else
        ko S2 "PermitRootLogin n'est pas à « no » ($(valeur_sshd permitrootlogin))"
    fi
}

test_S3() {
    local groupes
    groupes=$(valeur_sshd allowgroups)
    if [[ $groupes == acces_ssh ]]; then
        ok S3 "seul le groupe acces_ssh peut se connecter (AllowGroups)"
    else
        ko S3 "AllowGroups vaut « ${groupes:-non défini} » (attendu : acces_ssh)"
    fi
}

test_S3_cles() {
    [[ $CSV_VALIDE -eq 1 ]] || return 0
    local compte maison cle
    for compte in $(membres acces_ssh); do
        maison=$(getent passwd "$compte" | cut -d: -f6)
        cle="$CONFIG/cles/$compte.pub"
        if [[ ! -f $cle ]]; then
            ko S3 "clé publique de $compte absente du dépôt ($cle)"
        elif identique "$maison/.ssh/authorized_keys" "$cle" \
             && [[ $(stat -c %U:%a "$maison/.ssh/authorized_keys") == "$compte:600" ]]; then
            ok S3 "clé publique de $compte installée (authorized_keys 0600, identique au dépôt)"
        else
            ko S3 "authorized_keys de $compte absent, différent du dépôt ou mal protégé"
        fi
    done
}

test_S4() {
    local essais intervalle nombre
    essais=$(valeur_sshd maxauthtries)
    intervalle=$(valeur_sshd clientaliveinterval)
    nombre=$(valeur_sshd clientalivecountmax)
    if [[ $essais =~ ^[0-9]+$ ]] && (( essais >= 1 && essais <= 4 )); then
        ok S4 "au plus 4 essais d'authentification (MaxAuthTries $essais)"
    else
        ko S4 "MaxAuthTries vaut ${essais:-?} (attendu : 4 au plus)"
    fi
    if [[ $intervalle =~ ^[0-9]+$ && $nombre =~ ^[0-9]+$ ]] \
       && (( intervalle > 0 && intervalle * nombre <= 900 )); then
        ok S4 "session sans réponse fermée après $((intervalle * nombre)) s (ClientAlive, 15 min max)"
    else
        ko S4 "ClientAliveInterval × ClientAliveCountMax = ${intervalle:-?} × ${nombre:-?} (attendu : 1 à 900 s)"
    fi
    local delai
    delai=$(sed -n 's/^[[:space:]]*TMOUT=\([0-9]*\).*/\1/p' "$CONF_TMOUT" 2>/dev/null | head -n 1)
    if [[ -n $delai ]] && (( delai > 0 && delai <= 900 )); then
        ok S4 "shell inactif fermé après $delai s (TMOUT en lecture seule)"
    else
        ko S4 "TMOUT absent ou supérieur à 900 s ($CONF_TMOUT)"
    fi
}

test_S5() {
    if identique "$CONF_SSH" "$CONFIG/ssh/sshd_config.d/01-durcissement.conf"; then
        ok S5 "configuration dans /etc/ssh/sshd_config.d/, identique au dépôt"
    else
        ko S5 "$CONF_SSH absent ou différent du dépôt"
    fi
    controle S5 "sshd -t valide la configuration" "sshd -t signale une erreur de configuration" \
                sshd -t
    controle S5 "sshd_config inclut bien sshd_config.d/*.conf" \
                "sshd_config n'inclut pas sshd_config.d/*.conf" \
                grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config.d/\*\.conf' /etc/ssh/sshd_config
}

# ---------------------------------------------------------------------------
# J1 à J4 : journaux et défense
# ---------------------------------------------------------------------------

test_J1() {
    if systemctl is-active --quiet fail2ban && systemctl is-enabled --quiet fail2ban \
       && fail2ban-client status sshd >/dev/null 2>&1; then
        ok J1 "fail2ban actif au démarrage, prison sshd en service"
    else
        ko J1 "fail2ban inactif ou prison sshd absente"
        return
    fi
    local essais duree
    essais=$(fail2ban-client get sshd maxretry 2>/dev/null)
    duree=$(fail2ban-client get sshd bantime 2>/dev/null)
    if [[ $essais =~ ^[0-9]+$ && $duree =~ ^[0-9]+$ ]] && (( essais <= 5 && duree >= 60 )); then
        ok J1 "bannissement après $essais échecs, pendant $duree s"
    else
        ko J1 "paramètres fail2ban inattendus (maxretry=${essais:-?}, bantime=${duree:-?})"
    fi
    controle J1 "fail2ban bannit via nftables" "fail2ban n'utilise pas l'action nftables" \
                bash -c 'fail2ban-client get sshd actions | grep -q nftables'
    controle J1 "$CONF_F2B identique au dépôt" "$CONF_F2B absent ou différent du dépôt" \
                identique "$CONF_F2B" "$CONFIG/fail2ban/jail.d/projet-sshd.conf"
}

test_J1_J2_cohabitation() {
    if [[ -f $CONF_NFT ]] && ! grep -Eq '^[[:space:]]*flush[[:space:]]+ruleset' "$CONF_NFT" \
       && [[ -f $CONF_NFT_SERVICE ]]; then
        ok J2 "recharger nftables n'efface pas les règles de fail2ban (pas de flush ruleset)"
    else
        ko J2 "un rechargement de nftables effacerait les bannissements de fail2ban"
    fi
}

test_J2() {
    local entree
    entree=$(nft list chain inet filtre entree 2>/dev/null)
    if [[ -z $entree ]]; then
        ko J2 "table inet filtre / chaîne entree absente (pare-feu non chargé)"
        return
    fi
    if grep -q 'policy drop' <<< "$entree"; then
        ok J2 "politique par défaut du pare-feu en entrée : drop"
    else
        ko J2 "politique par défaut du pare-feu : $(grep -o 'policy [a-z]*' <<< "$entree") (attendu : drop)"
    fi
    controle J2 "SSH (tcp/22) autorisé en entrée" "aucune règle n'autorise SSH" \
                grep -Eq 'tcp dport (22|ssh) .*accept' <<< "$entree"
    controle J2 "trafic des connexions établies autorisé" "règle « ct state established » absente" \
                grep -q 'ct state established,related accept' <<< "$entree"
    local autres
    autres=$(grep -E 'dport' <<< "$entree" | grep -vE 'dport (22|ssh) ' | grep accept)
    if [[ -z $autres ]]; then
        ok J2 "aucun autre port ouvert en entrée"
    else
        ko J2 "autre(s) port(s) ouvert(s) : $(tr -s ' \n' ' ' <<< "$autres")"
    fi
    controle J2 "transit (forward) refusé par défaut" "politique forward différente de drop" \
                bash -c 'nft list chain inet filtre transfert | grep -q "policy drop"'
    if systemctl is-enabled --quiet nftables && identique "$CONF_NFT" "$CONFIG/nftables.conf"; then
        ok J2 "service nftables activé au démarrage avec /etc/nftables.conf du dépôt (survit au redémarrage)"
    else
        ko J2 "nftables non activé au démarrage ou /etc/nftables.conf différent du dépôt"
    fi
}

test_J3() {
    local stockage
    stockage=$(systemd-analyze cat-config systemd/journald.conf 2>/dev/null \
               | sed -n 's/^[[:space:]]*Storage=//p' | tail -n 1)
    if [[ $stockage == persistent ]] && identique "$CONF_JOURNAL" "$CONFIG/journald/persistant.conf"; then
        ok J3 "journal configuré en Storage=persistent ($CONF_JOURNAL)"
    else
        ko J3 "Storage vaut « ${stockage:-auto (défaut)} » (attendu : persistent)"
    fi
    controle J3 "le journal est écrit sur disque (/var/log/journal)" \
                "aucun fichier de journal dans /var/log/journal" \
                bash -c 'find /var/log/journal -name "*.journal" | grep -q .'
    local demarrages
    demarrages=$(journalctl --list-boots --no-pager 2>/dev/null | grep -cE '^[[:space:]]*-?[0-9]+ ')
    if [[ $demarrages -ge 2 ]]; then
        note J3 "le journal contient $demarrages démarrages : il a bien survécu à un redémarrage"
    else
        note J3 "un seul démarrage dans le journal : redémarrez la VM pour prouver la persistance"
    fi
}

test_J4() {
    if protege "$SCRIPT_ANALYSE" && [[ -x $SCRIPT_ANALYSE ]] && identique "$SCRIPT_ANALYSE" "$REP/analyse_logs.sh"; then
        ok J4 "analyse_logs.sh installé, appartient à root, modifiable par root seul"
    else
        ko J4 "$SCRIPT_ANALYSE absent, différent du dépôt ou modifiable par d'autres que root"
        return
    fi
    local sortie code total
    sortie=$("$SCRIPT_ANALYSE" -s 999999 2>&1); code=$?
    if [[ $code -eq 0 && $sortie == *"Échecs par adresse IP"* && $sortie == *"Comptes visés"* \
          && $sortie == *"Connexions réussies"* ]]; then
        ok J4 "rapport produit : échecs par IP, comptes visés, connexions réussies"
    else
        ko J4 "rapport incomplet ou code de sortie inattendu ($code)"
    fi
    sortie=$("$SCRIPT_ANALYSE" -s 1 2>&1); code=$?
    total=$(sed -n 's/^Total des échecs[^:]*: *\([0-9]*\).*/\1/p' <<< "$sortie")
    if [[ -z $total ]]; then
        ko J4 "impossible de lire le total des échecs dans le rapport"
    elif (( total > 0 )) && [[ $code -eq 1 ]]; then
        ok J4 "seuil dépassé (seuil 1, $total échecs) : code de sortie 1"
    elif (( total == 0 )) && [[ $code -eq 0 ]]; then
        ok J4 "aucun échec enregistré, code 0 (faites des échecs depuis l'hôte pour tester l'alerte)"
    else
        ko J4 "code de sortie $code incohérent avec $total échec(s) pour un seuil de 1"
    fi
    "$SCRIPT_ANALYSE" -s abc >/dev/null 2>&1; code=$?
    if [[ $code -eq 2 ]]; then
        ok J4 "argument invalide refusé (code 2)"
    else
        ko J4 "argument invalide non refusé (code $code, attendu 2)"
    fi
}

# ---------------------------------------------------------------------------
# B1 à B4 : sauvegarde
# ---------------------------------------------------------------------------

test_B1_disque() {
    if mountpoint -q "$SAUVEGARDES" \
       && [[ $(findmnt -no LABEL "$SAUVEGARDES") == "$ETIQUETTE_DISQUE" ]] \
       && [[ $(findmnt -no SOURCE "$SAUVEGARDES") != "$(findmnt -no SOURCE /)" ]] \
       && grep -Eq "^LABEL=$ETIQUETTE_DISQUE[[:space:]]+$SAUVEGARDES[[:space:]]" /etc/fstab; then
        ok B1 "second disque monté sur $SAUVEGARDES ($(findmnt -no SOURCE "$SAUVEGARDES")), montage permanent (fstab)"
    else
        ko B1 "$SAUVEGARDES n'est pas le second disque monté (étiquette $ETIQUETTE_DISQUE, /etc/fstab)"
    fi
}

test_B1_versions() {
    if protege "$SCRIPT_SAUVEGARDE" && identique "$SCRIPT_SAUVEGARDE" "$REP/sauvegarde.sh"; then
        ok B1 "sauvegarde.sh installé, appartient à root, identique au dépôt"
    else
        ko B1 "$SCRIPT_SAUVEGARDE absent, différent du dépôt ou modifiable par d'autres"
    fi
    local derniere
    derniere=$(derniere_version)
    if [[ -n $derniere && -d $VERSIONS/$derniere/srv && -d $VERSIONS/$derniere/etc ]]; then
        ok B1 "version datée présente ($derniere) contenant srv et etc"
    else
        ko B1 "aucune version complète de /srv et /etc dans $VERSIONS"
        return
    fi
    local -a deux
    mapfile -t deux < <(find "$VERSIONS" -mindepth 1 -maxdepth 1 -type d -name '[0-9]*-[0-9]*_[0-9]*' -printf '%f\n' | sort | tail -n 2)
    if [[ ${#deux[@]} -lt 2 ]]; then
        note B1 "une seule version : relancez sauvegarde.sh pour vérifier l'incrémental"
    elif [[ $(stat -c %i "$VERSIONS/${deux[0]}/etc/debian_version") == $(stat -c %i "$VERSIONS/${deux[1]}/etc/debian_version") ]]; then
        ok B1 "sauvegarde incrémentale : un fichier inchangé est un lien vers la version précédente"
    else
        ko B1 "les fichiers inchangés sont recopiés (pas de --link-dest ?)"
    fi
    if diff <(getfacl -p --omit-header /srv/commun/depot 2>/dev/null) \
            <(getfacl -p --omit-header "$VERSIONS/$derniere/srv/commun/depot" 2>/dev/null) >/dev/null \
       && [[ $(stat -c %a "/srv/commun/depot") == $(stat -c %a "$VERSIONS/$derniere/srv/commun/depot") ]]; then
        ok B1 "droits et ACL conservés dans la sauvegarde (/srv/commun/depot)"
    else
        ko B1 "droits ou ACL différents entre /srv/commun/depot et sa sauvegarde"
    fi
    local conservation nombre
    conservation=$(sed -n 's/^CONSERVATION=\([0-9]*\).*/\1/p' "$SCRIPT_SAUVEGARDE" 2>/dev/null)
    nombre=$(nombre_versions)
    if [[ -n $conservation ]] && (( conservation >= 7 && nombre <= conservation )); then
        ok B1 "rotation : $nombre version(s), $conservation au maximum (au moins 7 gardées)"
    else
        ko B1 "rotation incorrecte : $nombre versions pour CONSERVATION=${conservation:-?} (au moins 7)"
    fi
}

test_B2() {
    if systemctl is-enabled --quiet sauvegarde.timer && systemctl is-active --quiet sauvegarde.timer; then
        ok B2 "sauvegarde planifiée (sauvegarde.timer actif, prochain passage : $(systemctl show -p NextElapseUSecRealtime --value sauvegarde.timer))"
    else
        ko B2 "sauvegarde.timer non activé ou inactif"
    fi
    if grep -q 'terminée' /var/log/sauvegarde.log 2>/dev/null \
       && journalctl -u sauvegarde.service --no-pager -q 2>/dev/null | grep -q 'terminée'; then
        ok B2 "exécutions journalisées (/var/log/sauvegarde.log et journalctl -u sauvegarde)"
    else
        ko B2 "aucune exécution terminée trouvée dans les journaux de sauvegarde"
    fi
}

test_B3() {
    if [[ -d $SAUVEGARDES && $(stat -c %U:%G "$SAUVEGARDES") == root:admins && $(droits_autres "$SAUVEGARDES") -eq 0 ]]; then
        ok B3 "$SAUVEGARDES : root:admins, aucun droit pour les autres ($(stat -c %a "$SAUVEGARDES"))"
    else
        ko B3 "$SAUVEGARDES n'est pas réservé aux administrateurs (attendu root:admins, 0750)"
    fi
    [[ $CSV_VALIDE -eq 1 ]] || return 0
    local admin employe
    admin=$(membre admins 1); employe=$(membre direction 1)
    if [[ -n $admin && -n $employe ]] && peut "$admin" -x "$SAUVEGARDES" && ! peut "$employe" -x "$SAUVEGARDES"; then
        ok B3 "l'administrateur $admin accède aux sauvegardes, $employe (direction) non"
    else
        ko B3 "accès aux sauvegardes incorrect (test avec ${admin:-?} et ${employe:-?})"
    fi
}

test_B4() {
    local derniere temporaire
    derniere=$(derniere_version)
    if [[ -z $derniere || ! -d $VERSIONS/$derniere/srv/commun ]]; then
        ko B4 "aucune version à restaurer"
        return
    fi
    temporaire=$(mktemp -d /tmp/verifier_restauration.XXXXXX)
    A_SUPPRIMER+=("$temporaire")
    # Même procédure que dans DOSSIER.md, mais vers un répertoire temporaire
    if rsync -aAX "$VERSIONS/$derniere/srv/commun/" "$temporaire/commun/" \
       && diff -r "$VERSIONS/$derniere/srv/commun" "$temporaire/commun" >/dev/null \
       && diff <(cd "$VERSIONS/$derniere/srv/commun" && getfacl -R -p . 2>/dev/null) \
               <(cd "$temporaire/commun" && getfacl -R -p . 2>/dev/null) >/dev/null; then
        ok B4 "restauration testée : /srv/commun de la version $derniere restauré (contenu, droits, ACL identiques)"
    else
        ko B4 "la restauration de /srv/commun depuis $derniere ne redonne pas les mêmes fichiers ou ACL"
    fi
    controle B4 "procédure de restauration documentée dans DOSSIER.md" \
                "DOSSIER.md ne décrit pas la procédure de restauration" \
                grep -qi 'restauration' "$REP/DOSSIER.md"
}

# ---------------------------------------------------------------------------
# D1 à D3 : système
# ---------------------------------------------------------------------------

test_D1() {
    local configuration
    configuration=$(apt-config dump 2>/dev/null)
    if [[ $(dpkg-query -W -f='${Status}' unattended-upgrades 2>/dev/null) == "install ok installed" ]] \
       && grep -q '^APT::Periodic::Unattended-Upgrade "1";' <<< "$configuration" \
       && grep -q '^APT::Periodic::Update-Package-Lists "1";' <<< "$configuration"; then
        ok D1 "unattended-upgrades installé et activé chaque jour"
    else
        ko D1 "unattended-upgrades absent ou non activé (APT::Periodic)"
    fi
    if grep -i 'Origins-Pattern' <<< "$configuration" | grep -qi 'security' \
       && systemctl is-enabled --quiet apt-daily-upgrade.timer; then
        ok D1 "mises à jour de sécurité Debian incluses, timer apt-daily-upgrade activé"
    else
        ko D1 "origine Debian-Security absente ou timer apt-daily-upgrade désactivé"
    fi
}

test_D2() {
    local netid etat rq sq locale distante processus adresse port nom inattendus="" vus=""
    while read -r netid etat rq sq locale distante processus; do
        port=${locale##*:}
        adresse=${locale%:*}
        adresse=${adresse%%%*}            # retire « %interface »
        adresse=${adresse#\[}; adresse=${adresse%\]}   # retire les crochets IPv6
        nom=$(sed -n 's/.*(("\([^"]*\)".*/\1/p' <<< "${processus:-}")
        # Écoute limitée à la machine elle-même : pas joignable depuis le réseau
        [[ $adresse == 127.* || $adresse == ::1 || $adresse == localhost ]] && continue
        vus+=" $netid/$port($nom)"
        if [[ $netid == tcp && $port == 22 && $nom == sshd ]]; then continue; fi
        # Client DHCP (IPv4 port 68, IPv6 port 546) : expliqué dans le dossier
        if [[ $netid == udp && ( $port == 68 || $port == 546 ) && $nom =~ ^(dhclient|dhcpcd|systemd-network)$ ]]; then continue; fi
        inattendus+=" $netid/$port($nom)"
    done < <(ss -Htulpn 2>/dev/null)
    if [[ -z $inattendus ]]; then
        ok D2 "seul SSH est joignable depuis le réseau (ss -tulpn :${vus:- rien})"
    else
        ko D2 "service(s) joignable(s) autre(s) que SSH :$inattendus"
    fi
}

test_D3() {
    local -a racines=(/)
    mountpoint -q "$SAUVEGARDES" && racines+=("$SAUVEGARDES")
    local modifiables
    # -xdev : ne pas descendre dans /proc, /sys, /dev, /run (systèmes de
    # fichiers virtuels). -type f / -type d : les liens symboliques (toujours
    # en 777) ne sont pas comptés.
    modifiables=$(find "${racines[@]}" -xdev \
                    \( -path /tmp -o -path /var/tmp -o -path /dev/shm \) -prune -o \
                    \( -type f -perm -0002 -print \) -o \
                    \( -type d -perm -0002 ! -perm -1000 -print \) 2>/dev/null | head -n 20)
    if [[ -z $modifiables ]]; then
        ok D3 "aucun fichier modifiable par tous hors des répertoires temporaires"
    else
        ko D3 "fichier(s) modifiable(s) par tous : $(tr '\n' ' ' <<< "$modifiables")"
    fi
    local attendus inattendus
    attendus=$(grep -vE '^[[:space:]]*(#|$)' "$CONFIG/suid_attendus.txt" 2>/dev/null)
    inattendus=$(find / -xdev -type f -perm -4000 2>/dev/null | sort | grep -vxF -f <(echo "$attendus"))
    if [[ -z $inattendus ]]; then
        ok D3 "fichiers SUID : tous listés et expliqués (config/suid_attendus.txt)"
    else
        ko D3 "SUID non répertorié(s) : $(tr '\n' ' ' <<< "$inattendus")"
    fi
}

# ---------------------------------------------------------------------------

usage() {
    echo "Usage : sudo $0     (vérifie toutes les exigences, ne modifie rien)"
}

main() {
    if [[ $# -gt 0 ]]; then
        case $1 in
            -h | --help) usage; exit 0 ;;
            *) echo "option inconnue : $1" >&2; usage >&2; exit 2 ;;
        esac
    fi
    if [[ $EUID -ne 0 ]]; then
        echo "verifier.sh doit être lancé en root : sudo $0" >&2
        exit 2
    fi
    trap nettoyer EXIT
    SSHD_T=$(sshd -T 2>/dev/null)

    echo "Vérification de $(hostname) — $(date '+%d/%m/%Y %H:%M') — contexte B (Chiffres & Co)"

    titre "Comptes et droits"
    test_C1_csv
    test_C1_comptes
    test_C1_groupes_metier
    test_C1_doublons
    test_C1_hors_csv
    test_C2_structure
    test_C2_droits
    test_C2_heritage
    test_C2_depot
    test_C3_fichier
    test_C3_admins
    test_C3_support
    test_C3_personne_d_autre
    test_C4_root
    test_C4_maisons
    test_C4_lecture

    titre "Accès SSH"
    test_S1
    test_S2
    test_S3
    test_S3_cles
    test_S4
    test_S5

    titre "Journaux et défense"
    test_J1
    test_J1_J2_cohabitation
    test_J2
    test_J3
    test_J4

    titre "Sauvegarde"
    test_B1_disque
    test_B1_versions
    test_B2
    test_B3
    test_B4

    titre "Système"
    test_D1
    test_D2
    test_D3

    local total=$((NB_OK + NB_KO))
    echo
    if [[ $NB_KO -eq 0 ]]; then
        printf '%s--- %d / %d tests réussis%s\n' "$VERT" "$NB_OK" "$total" "$NORMAL"
        return 0
    fi
    printf '%s--- %d / %d tests réussis%s\n' "$ROUGE" "$NB_OK" "$total" "$NORMAL"
    return 1
}

main "$@"
