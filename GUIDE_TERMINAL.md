# Guide terminal — construire le projet XTI302-CYB (contexte B) dans ta session SSH

> Cabinet comptable *Chiffres & Co*. Tu es connecte en SSH sur la VM en tant que `hugo`.

> Tu vas creer chaque fichier avec `nano`, coller son contenu, puis lancer les scripts.

## Comment utiliser ce guide avec `nano`

Pour **chaque** fichier ci-dessous :

1. Lance la commande `nano -w <chemin>` indiquee (l'option `-w` empeche nano de couper les lignes longues).
2. **Colle** le contenu : clic droit dans le terminal, ou **Ctrl+Maj+V**.
3. Enregistre : **Ctrl+O** puis **Entree**.
4. Quitte : **Ctrl+X**.

Si un script se comporte mal ensuite, c'est presque toujours un colle rate : rouvre le fichier et recommence.

> Astuce : garde une **deuxieme** session SSH ouverte en parallele. Si tu te bloques en durcissant SSH, tu gardes un acces.

## Etape 0 — devenir administrateur et creer le dossier de travail

Tout se fait en root. Ouvre un shell root (tape le mot de passe root) :

```bash
su -
```

Puis cree l'arborescence du projet et places-y toi :

```bash
mkdir -p ~/projet-xti302-cyb/config/ssh/sshd_config.d \
         ~/projet-xti302-cyb/config/profile.d \
         ~/projet-xti302-cyb/config/sudoers.d \
         ~/projet-xti302-cyb/config/systemd/nftables.service.d \
         ~/projet-xti302-cyb/config/fail2ban/jail.d \
         ~/projet-xti302-cyb/config/journald \
         ~/projet-xti302-cyb/config/apt \
         ~/projet-xti302-cyb/config/cles
cd ~/projet-xti302-cyb
```

> On construit dans `/root/projet-xti302-cyb`. `installer.sh` copiera ensuite les fichiers aux bons endroits du systeme.

## Etape 1 — creer les fichiers

Chaque fichier se cree depuis `~/projet-xti302-cyb` (ou tu es apres l'etape 0).

### Fichier 1 : `comptes.csv`
*la liste des comptes et groupes (format impose, aucun mot de passe)*

```bash
nano -w comptes.csv
```

Contenu a coller :

```text
login;nom;groupe_principal;groupes_secondaires
hugo;Hugo;admins;acces_ssh
membre2;Membre 2 (a remplacer);admins;acces_ssh
membre3;Membre 3 (a remplacer);admins;acces_ssh
support;Compte support;support;acces_ssh
pmartin;Paul Martin;comptables;
clefevre;Claire Lefèvre;comptables;
sbernard;Sophie Bernard;rh;
tmoreau;Thomas Moreau;rh;
jdurand;Jean Durand;direction;
mpetit;Marie Petit;direction;
lroux;Léa Roux;stagiaire;
ngarcia;Nathan Garcia;stagiaire;
```

Enregistre (**Ctrl+O**, **Entree**) et quitte (**Ctrl+X**).

### Fichier 2 : `creer_comptes.sh`
*cree comptes, groupes, repertoires /srv + ACL, installe les cles (C1, C2, C4)*

```bash
nano -w creer_comptes.sh
```

Contenu a coller :

```bash
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
```

Enregistre (**Ctrl+O**, **Entree**) et quitte (**Ctrl+X**).

### Fichier 3 : `analyse_logs.sh`
*rapport des connexions SSH, code de sortie exploitable (J4)*

```bash
nano -w analyse_logs.sh
```

Contenu a coller :

```bash
#!/bin/bash
#
# analyse_logs.sh — Projet XTI302-CYB, exigence J4
#
# Rapport des connexions SSH lu dans le journal systemd :
#   - nombre d'échecs par adresse IP,
#   - comptes visés par ces échecs,
#   - connexions réussies,
# puis code de sortie exploitable par un autre programme :
#   0 : aucune adresse IP n'a atteint le seuil d'alerte
#   1 : ALERTE, au moins une adresse IP a atteint le seuil
#   2 : erreur (option invalide, pas root, journal illisible)
#
# Usage : sudo analyse_logs.sh [-s SEUIL] [-p PERIODE] [-h]
#   -s SEUIL    échecs d'une même IP qui déclenchent l'alerte (défaut : 10)
#   -p PERIODE  période analysée : <n>h, <n>d, today ou yesterday (défaut : 24h)
#
# Où sont les journaux SSH ? Une Debian 13 minimale n'a pas rsyslog, donc
# pas de /var/log/auth.log : tout est dans le journal systemd. On filtre sur
# le nom du processus (_COMM) : « sshd » (le service qui écoute) et
# « sshd-session » / « sshd-auth » (OpenSSH 10 de Debian 13), qui écrivent
# les messages d'authentification.
#
# Le compte support lance ce script en root via sudo. Il appartient donc à
# root et n'est modifiable que par lui (/usr/local/sbin, 0755) ; ses
# arguments sont strictement validés et le PATH est fixé.

set -euo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C

SEUIL=10
PERIODE=24h

usage() {
    cat <<EOF
Usage : sudo $0 [-s SEUIL] [-p PERIODE] [-h]
  -s SEUIL    nombre d'échecs d'une même IP déclenchant l'alerte (1 à 999999, défaut 10)
  -p PERIODE  période analysée : <n>h, <n>d, today, yesterday (défaut 24h)
Codes de sortie : 0 = normal, 1 = seuil dépassé (alerte), 2 = erreur
EOF
}

erreur() {
    echo "analyse_logs.sh : $*" >&2
    exit 2
}

lire_options() {
    local option
    while getopts ":s:p:h" option; do
        case $option in
            s) [[ $OPTARG =~ ^[1-9][0-9]{0,5}$ ]] \
                   || erreur "seuil invalide « $OPTARG » (entier de 1 à 999999)"
               SEUIL=$OPTARG ;;
            p) [[ $OPTARG =~ ^([1-9][0-9]{0,3}[hd]|today|yesterday)$ ]] \
                   || erreur "période invalide « $OPTARG » (ex. 24h, 7d, today)"
               PERIODE=$OPTARG ;;
            h) usage; exit 0 ;;
            :) erreur "l'option -$OPTARG attend une valeur" ;;
            *) erreur "option inconnue -$OPTARG (voir -h)" ;;
        esac
    done
    shift $((OPTIND - 1))
    [[ $# -eq 0 ]] || erreur "argument inattendu : $1"
}

# Traduit la période en date de début compréhensible par journalctl
date_de_debut() {
    case $PERIODE in
        today | yesterday) echo "$PERIODE" ;;
        *h) echo "-${PERIODE%h}h" ;;
        *d) echo "-${PERIODE%d}d" ;;
    esac
}

lire_journal() {
    journalctl --no-pager --quiet -o short-iso --since="$(date_de_debut)" \
        _COMM=sshd _COMM=sshd-session _COMM=sshd-auth
}

# Transforme chaque ligne utile du journal en un « événement » normalisé :
#   SUCCES <date> <compte> <ip> <méthode>
#   ECHEC  <ip> <compte>
# Format d'une ligne (short-iso) :
#   2026-11-05T19:12:03+01:00 srv-xti sshd-session[1234]: <message>
# Après chaque substitution réussie, « t » passe à la ligne suivante : une
# ligne ne produit donc qu'un seul événement.
extraire_evenements() {
    sed -nE \
        -e 's/^([^ ]+) [^ ]+ [^ ]+ Accepted ([^ ]+) for ([^ ]+) from ([0-9A-Fa-f:.]+) port .*/SUCCES \1 \3 \4 \2/p' -e t \
        -e 's/^[^ ]+ [^ ]+ [^ ]+ Failed [^ ]+ for invalid user ([^ ]*) from ([0-9A-Fa-f:.]+) port .*/ECHEC \2 \1/p' -e t \
        -e 's/^[^ ]+ [^ ]+ [^ ]+ Failed [^ ]+ for ([^ ]+) from ([0-9A-Fa-f:.]+) port .*/ECHEC \2 \1/p' -e t \
        -e 's/^[^ ]+ [^ ]+ [^ ]+ Invalid user ([^ ]*) from ([0-9A-Fa-f:.]+) port .*/ECHEC \2 \1/p' -e t \
        -e 's/^[^ ]+ [^ ]+ [^ ]+ User ([^ ]+) from ([0-9A-Fa-f:.]+) not allowed because .*/ECHEC \2 \1/p' -e t \
        -e 's/^[^ ]+ [^ ]+ [^ ]+ ROOT LOGIN REFUSED FROM ([0-9A-Fa-f:.]+).*/ECHEC \1 root/p' -e t \
        -e 's/^[^ ]+ [^ ]+ [^ ]+ (Connection closed by|Disconnected from) authenticating user ([^ ]+) ([0-9A-Fa-f:.]+) port .*/ECHEC \3 \2/p' -e t
}

# Les tentatives depuis la machine elle-même (127.0.0.1, ::1), par exemple
# celles de verifier.sh, ne sont pas des attaques : on les écarte des échecs.
ecarter_boucle_locale() {
    awk '$1 == "ECHEC" && ($2 ~ /^127\./ || $2 == "::1") {next} {print}'
}

# Affiche « (aucun) » si une section du rapport est vide
afficher_section() {
    local titre=$1 contenu=$2
    echo "== $titre =="
    if [[ -n $contenu ]]; then
        echo "$contenu"
    else
        echo "  (aucun)"
    fi
    echo
}

main() {
    lire_options "$@"
    [[ $EUID -eq 0 ]] || erreur "à lancer en root : sudo $0"

    local journal evenements total par_ip comptes succes alertes
    journalctl --quiet -n 1 >/dev/null 2>&1 || erreur "impossible de lire le journal systemd"
    # « || true » : une période sans aucune ligne SSH n'est pas une erreur
    journal=$(lire_journal 2>/dev/null) || true
    evenements=$(extraire_evenements <<< "$journal" | ecarter_boucle_locale)

    total=$(awk '$1 == "ECHEC"' <<< "$evenements" | wc -l)
    par_ip=$(awk '$1 == "ECHEC" {print $2}' <<< "$evenements" \
             | sort | uniq -c | sort -rn | awk '{printf "  %6d  %s\n", $1, $2}')
    comptes=$(awk '$1 == "ECHEC" {print ($3 == "" ? "(vide)" : $3)}' <<< "$evenements" \
              | sort | uniq -c | sort -rn | awk '{printf "  %6d  %s\n", $1, $2}')
    succes=$(awk '$1 == "SUCCES" {printf "  %s  %-12s depuis %-15s (%s)\n", $2, $3, $4, $5}' <<< "$evenements")
    alertes=$(awk '$1 == "ECHEC" {print $2}' <<< "$evenements" \
              | sort | uniq -c | awk -v seuil="$SEUIL" '$1 >= seuil {printf "  %s : %d échecs\n", $2, $1}')

    echo "Rapport des connexions SSH — $(hostname) — $(date '+%d/%m/%Y %H:%M')"
    echo "Période analysée : $PERIODE — seuil d'alerte : $SEUIL échecs par adresse IP"
    echo "Total des échecs (hors boucle locale) : $total"
    echo
    afficher_section "Échecs par adresse IP" "$par_ip"
    afficher_section "Comptes visés" "$comptes"
    afficher_section "Connexions réussies" "$succes"

    if [[ -n $alertes ]]; then
        afficher_section "ALERTE : seuil de $SEUIL échecs atteint" "$alertes"
        logger -t analyse_logs -p auth.warning "ALERTE SSH : $(tr -s ' \n' ' ' <<< "$alertes")"
        exit 1
    fi
    echo "Aucune adresse IP n'atteint le seuil d'alerte."
    exit 0
}

main "$@"
```

Enregistre (**Ctrl+O**, **Entree**) et quitte (**Ctrl+X**).

### Fichier 4 : `sauvegarde.sh`
*sauvegarde incrementale versionnee de /srv et /etc (B1)*

```bash
nano -w sauvegarde.sh
```

Contenu a coller :

```bash
#!/bin/bash
#
# sauvegarde.sh — Projet XTI302-CYB, exigences B1 et B2
#
# Sauvegarde /srv et /etc sur le second disque (monté sur /sauvegardes) :
#  - chaque exécution crée une VERSION DATÉE : /sauvegardes/versions/AAAA-MM-JJ_HHMMSS
#  - sauvegarde INCRÉMENTALE : rsync --link-dest fait de chaque fichier
#    inchangé depuis la version précédente un lien physique vers celle-ci ;
#    il n'est pas recopié et n'occupe pas de place en plus, mais chaque
#    version reste une copie complète, restaurable seule ;
#  - droits, propriétaires, ACL et attributs étendus conservés (-a -A -X) ;
#  - seules les CONSERVATION dernières versions sont gardées (au moins 7) ;
#  - chaque exécution est journalisée (/var/log/sauvegarde.log + journal).
#
# Usage  : sudo sauvegarde.sh [-k NOMBRE_DE_VERSIONS] [-h]
# Sortie : 0 succès ; 1 erreur d'utilisation ; 3 disque non monté ;
#          4 sauvegarde déjà en cours ; 5 version déjà existante ; 6 échec de rsync.

set -euo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C

readonly POINT_MONTAGE=/sauvegardes
readonly DESTINATION=$POINT_MONTAGE/versions
readonly SOURCES=(/srv /etc)
readonly JOURNAL=/var/log/sauvegarde.log
readonly VERROU=/run/sauvegarde.lock
readonly MOTIF_VERSION='[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_[0-9][0-9][0-9][0-9][0-9][0-9]'
# 14 versions quotidiennes = 2 semaines d'historique (exigence : au moins 7)
CONSERVATION=14

journaliser() {
    local message="$*"
    printf '%s %s\n' "$(date '+%F %T')" "$message" >> "$JOURNAL"
    echo "$message"    # sous systemd, la sortie standard va dans le journal
}

erreur() {
    journaliser "ERREUR : $1"
    exit "${2:-1}"
}

usage() {
    echo "Usage : sudo $0 [-k NOMBRE_DE_VERSIONS (au moins 7, défaut $CONSERVATION)] [-h]"
}

lire_options() {
    local option
    while getopts ":k:h" option; do
        case $option in
            k) [[ $OPTARG =~ ^[0-9]{1,4}$ ]] && (( OPTARG >= 7 )) \
                   || { echo "nombre de versions invalide : $OPTARG (au moins 7)" >&2; exit 1; }
               CONSERVATION=$OPTARG ;;
            h) usage; exit 0 ;;
            *) usage >&2; exit 1 ;;
        esac
    done
}

# Liste les versions complètes, de la plus ancienne à la plus récente
lister_versions() {
    find "$DESTINATION" -mindepth 1 -maxdepth 1 -type d -name "$MOTIF_VERSION" -printf '%f\n' | sort
}

# Supprime les versions les plus anciennes au-delà de CONSERVATION
supprimer_anciennes_versions() {
    local -a versions
    local nombre i
    mapfile -t versions < <(lister_versions)
    nombre=${#versions[@]}
    (( nombre > CONSERVATION )) || return 0
    for (( i = 0; i < nombre - CONSERVATION; i++ )); do
        rm -rf -- "${DESTINATION:?}/${versions[i]}"
        journaliser "rotation : version ${versions[i]} supprimée"
    done
}

main() {
    lire_options "$@"
    [[ $EUID -eq 0 ]] || { echo "à lancer en root : sudo $0" >&2; exit 1; }

    # Sans le second disque monté, on écrirait dans /sauvegardes sur le disque
    # système : on refuse.
    mountpoint -q "$POINT_MONTAGE" \
        || erreur "$POINT_MONTAGE n'est pas monté : sauvegarde annulée" 3

    # Une seule exécution à la fois (timer et lancement manuel simultanés)
    exec 9> "$VERROU"
    flock -n 9 || erreur "une sauvegarde est déjà en cours" 4

    mkdir -p "$DESTINATION"
    chmod 0750 "$DESTINATION"
    if getent group admins >/dev/null; then
        chgrp admins "$DESTINATION"
    fi
    # Restes d'une exécution interrompue
    find "$DESTINATION" -mindepth 1 -maxdepth 1 -name '*.encours' -exec rm -rf {} +

    local horodatage nouvelle precedente code=0 statistiques
    local -a options=(-aAXH --numeric-ids --stats)
    horodatage=$(date +%Y-%m-%d_%H%M%S)
    nouvelle="$DESTINATION/$horodatage"
    [[ ! -e $nouvelle ]] || erreur "la version $horodatage existe déjà" 5

    precedente=$(lister_versions | tail -n 1)
    if [[ -n $precedente ]]; then
        options+=("--link-dest=$DESTINATION/$precedente")
    fi

    journaliser "début : ${SOURCES[*]} -> $nouvelle (référence : ${precedente:-aucune})"
    # On écrit d'abord dans « .encours » : une version interrompue n'est
    # jamais prise pour une version complète.
    statistiques=$(rsync "${options[@]}" "${SOURCES[@]}" "$nouvelle.encours/" 2>&1) || code=$?
    # Code 24 : des fichiers ont disparu pendant la copie (normal sur un
    # système en marche), la sauvegarde reste valable.
    if [[ $code -ne 0 && $code -ne 24 ]]; then
        rm -rf -- "$nouvelle.encours"
        erreur "rsync a échoué (code $code) : $(tail -n 3 <<< "$statistiques" | tr '\n' ' ')" 6
    fi
    mv -- "$nouvelle.encours" "$nouvelle"
    ln -sfn "$horodatage" "$DESTINATION/derniere"

    journaliser "fichiers copiés : $(sed -n 's/^Number of regular files transferred: //p' <<< "$statistiques")" \
                "(les autres sont des liens vers la version précédente)"
    supprimer_anciennes_versions
    journaliser "terminée : $horodatage ($(lister_versions | wc -l) versions conservées, maximum $CONSERVATION)"
}

main "$@"
```

Enregistre (**Ctrl+O**, **Entree**) et quitte (**Ctrl+X**).

### Fichier 5 : `installer.sh`
*reconstruit toute la configuration sur la VM (orchestre tout)*

```bash
nano -w installer.sh
```

Contenu a coller :

```bash
#!/bin/bash
#
# installer.sh — Projet XTI302-CYB, contexte B (cabinet Chiffres & Co)
#
# Reconstruit TOUTE la configuration sur la VM vierge (snapshot « vierge ») :
# paquets, comptes et droits, sudo, SSH, pare-feu, fail2ban, journal,
# mises à jour automatiques, disque et planification des sauvegardes.
# Le script peut être relancé sans danger (idempotent) : en particulier, il ne
# formate JAMAIS un disque qui contient déjà quelque chose.
#
# Usage  : sudo ./installer.sh [--forcer-ssh] [-h]
#   --forcer-ssh  applique le durcissement SSH même si aucun administrateur
#                 n'a de clé installée (risque de perdre l'accès SSH)
# Sortie : 0 succès ; 1 erreur.
#
# Variable facultative : DISQUE_SAUVEGARDE (défaut /dev/sdb)

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

# Copie un fichier de config/ en lui donnant root comme propriétaire
copier() {
    local source=$1 destination=$2 mode=$3
    install -D -o root -g root -m "$mode" "$CONFIG/$source" "$destination"
}

# Membres d'un groupe : groupe secondaire OU groupe principal
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
    # Les scripts lancés par root doivent appartenir à root et n'être
    # modifiables que par lui.
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

    # C4 : les futurs répertoires personnels seront aussi en 0700
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

    # Une Debian fraîche a souvent un compte dans le groupe « sudo » (créé si
    # aucun mot de passe root n'a été saisi à l'installation) : on le vide,
    # seuls admins et support (fichier ci-dessus) gardent sudo.
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

# B1 : prépare le second disque UNE SEULE FOIS. S'il porte déjà un système de
# fichiers « SAUVEGARDES », on ne touche à rien : les sauvegardes existantes
# survivent à une nouvelle exécution d'installer.sh.
preparer_disque() {
    etape "B1 : disque de sauvegarde"
    local partition
    partition=$(blkid -L "$ETIQUETTE" 2>/dev/null || true)
    if [[ -n $partition ]]; then
        info "système de fichiers $ETIQUETTE déjà présent sur $partition : aucun formatage"
    else
        [[ -b $DISQUE_SAUVEGARDE ]] \
            || erreur "disque $DISQUE_SAUVEGARDE introuvable : ajoutez un second disque à la VM"
        # Garde-fous : jamais le disque système, jamais un disque non vierge
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
    # Montage permanent, par étiquette. nofail : la VM démarre même sans ce
    # disque ; nodev,nosuid,noexec : rien ne peut être exécuté depuis les
    # sauvegardes.
    if ! grep -qE "^LABEL=$ETIQUETTE[[:space:]]" /etc/fstab; then
        echo "LABEL=$ETIQUETTE $POINT_MONTAGE ext4 defaults,nodev,nosuid,noexec,nofail 0 2" >> /etc/fstab
        systemctl daemon-reload
        info "montage ajouté dans /etc/fstab"
    fi
    mountpoint -q "$POINT_MONTAGE" || mount "$POINT_MONTAGE"

    # B3 : accessible uniquement aux administrateurs
    chown root:admins "$POINT_MONTAGE"
    chmod 0750 "$POINT_MONTAGE"
}

configurer_sauvegarde() {
    etape "B2 : planification de la sauvegarde (timer systemd)"
    copier systemd/sauvegarde.service /etc/systemd/system/sauvegarde.service 0644
    copier systemd/sauvegarde.timer /etc/systemd/system/sauvegarde.timer 0644
    systemctl daemon-reload
    systemctl enable --now sauvegarde.timer
    info "première sauvegarde..."
    systemctl start sauvegarde.service
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
    # reload (et non restart) : recharge nos règles sans toucher à celles de
    # fail2ban. Les connexions SSH établies restent autorisées.
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

# Vrai si au moins un administrateur pourra se connecter par clé
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
    # Piège classique : passer en « clé uniquement » sans clé installée =
    # plus aucun accès SSH. On refuse, sauf demande explicite.
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
    # S5 : on valide la configuration AVANT de recharger le service
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

# C4 : root verrouillé, en DERNIER, et seulement si un administrateur peut
# encore prendre la main (mot de passe défini + sudo valide). Sinon on se
# retrouverait sans aucun accès administrateur, même en console.
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

    etape "Installation terminée"
    echo "Vérifiez maintenant la conformité : ./verifier.sh"
    echo "Conseil : redémarrez une fois la VM puis relancez ./verifier.sh (J2, J3)."
}

main "$@"
```

Enregistre (**Ctrl+O**, **Entree**) et quitte (**Ctrl+X**).

### Fichier 6 : `verifier.sh`
*verifie automatiquement chaque exigence (la piece centrale)*

```bash
nano -w verifier.sh
```

Contenu a coller :

```bash
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
```

Enregistre (**Ctrl+O**, **Entree**) et quitte (**Ctrl+X**).

### Fichier 7 : `config/ssh/sshd_config.d/01-durcissement.conf`
*durcissement SSH (S1 a S5)*

```bash
nano -w config/ssh/sshd_config.d/01-durcissement.conf
```

Contenu a coller :

```text
# Projet XTI302-CYB — durcissement du serveur SSH (exigences S1 à S5)
# Copié par installer.sh dans /etc/ssh/sshd_config.d/, puis validé par
# « sshd -t » AVANT le rechargement du service (S5).
#
# Pour sshd, c'est la PREMIÈRE valeur rencontrée d'une option qui s'applique.
# Le préfixe « 01- » fait lire ce fichier avant tout autre fichier du
# répertoire (inclus en tête de /etc/ssh/sshd_config).

# --- S1 : connexion par clé uniquement, mot de passe refusé
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
AuthenticationMethods publickey

# --- S2 : connexion directe de root interdite
PermitRootLogin no

# --- S3 : seuls les membres du groupe acces_ssh peuvent se connecter
AllowGroups acces_ssh

# --- S4 : au plus 4 essais par connexion, sessions inactives fermées
# 3 essais : une personne légitime qui a une seule clé n'en a besoin que d'un.
MaxAuthTries 3
# 30 s pour s'authentifier, sinon la connexion est coupée
LoginGraceTime 30
# Toutes les 300 s, sshd vérifie que le client répond ; après 2 absences de
# réponse (10 min), la session est fermée. Les shells inactifs mais dont le
# client répond sont, eux, fermés par TMOUT (/etc/profile.d/tmout.sh).
ClientAliveInterval 300
ClientAliveCountMax 2

# --- Réduction de la surface d'attaque (fonctions inutiles ici)
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
PermitTunnel no
```

Enregistre (**Ctrl+O**, **Entree**) et quitte (**Ctrl+X**).

### Fichier 8 : `config/profile.d/tmout.sh`
*ferme les shells inactifs (S4)*

```bash
nano -w config/profile.d/tmout.sh
```

Contenu a coller :

```bash
# Projet XTI302-CYB — exigence S4 (complément)
# Copié par installer.sh dans /etc/profile.d/tmout.sh
#
# Un shell interactif sans aucune frappe pendant 600 s (10 min) est fermé
# automatiquement. readonly empêche l'utilisateur de désactiver ce délai.
# Le test évite l'erreur « readonly variable » si le fichier est relu.
if [ "${TMOUT:-}" != "600" ]; then
    TMOUT=600
    readonly TMOUT
    export TMOUT
fi
```

Enregistre (**Ctrl+O**, **Entree**) et quitte (**Ctrl+X**).

### Fichier 9 : `config/sudoers.d/projet`
*droits sudo : admins + support seulement (C3)*

```bash
nano -w config/sudoers.d/projet
```

Contenu a coller :

```text
# Projet XTI302-CYB — exigence C3
# Copié par installer.sh dans /etc/sudoers.d/projet (0440 root:root),
# après validation par « visudo -cf ».

# Chaque commande lancée avec sudo est journalisée, dans un pseudo-terminal
# séparé (un programme lancé via sudo ne peut pas injecter de frappes dans
# le terminal de l'utilisateur).
Defaults        use_pty
Defaults        logfile="/var/log/sudo.log"

# Administrateurs nominatifs : tous les droits, après saisie de LEUR propre
# mot de passe. Chaque action d'administration est donc imputable à une
# personne (pas de compte root partagé).
%admins         ALL=(ALL:ALL) ALL

# Compte support : UNIQUEMENT ce script, en root.
#  - NOPASSWD : support se connecte par clé et n'a pas de mot de passe ;
#  - le script appartient à root et n'est modifiable que par lui (0755) :
#    sinon support pourrait y écrire n'importe quelle commande et la lancer
#    en root ;
#  - le script valide strictement ses arguments (seuil et période).
support         ALL=(root) NOPASSWD: /usr/local/sbin/analyse_logs.sh
```

Enregistre (**Ctrl+O**, **Entree**) et quitte (**Ctrl+X**).

### Fichier 10 : `config/nftables.conf`
*pare-feu : tout refuse sauf SSH (J2)*

```bash
nano -w config/nftables.conf
```

Contenu a coller :

```bash
#!/usr/sbin/nft -f
#
# Projet XTI302-CYB — exigence J2 : pare-feu nftables
# Copié par installer.sh dans /etc/nftables.conf, chargé au démarrage par
# le service nftables (activé) : la règle survit à un redémarrage.
#
# Pas de « flush ruleset » : cette commande effacerait aussi la table de
# fail2ban (inet f2b-table) et les adresses bannies à chaque rechargement.
# On ne vide et ne recrée que NOTRE table :
#   1. « table inet filtre »        crée la table si elle n'existe pas,
#   2. « delete table inet filtre » la supprime (avec ses anciennes règles),
#   3. le bloc suivant la recrée.
# Les trois étapes sont appliquées d'un coup (transaction atomique).

table inet filtre
delete table inet filtre

table inet filtre {

    chain entree {
        # Tout ce qui entre est refusé par défaut
        type filter hook input priority filter; policy drop;

        # Trafic local de la machine (boucle locale)
        iif "lo" accept

        # Réponses aux connexions déjà établies (et messages ICMP liés)
        ct state established,related accept
        ct state invalid drop

        # IPv6 : la découverte de voisins (l'équivalent d'ARP) est
        # indispensable au fonctionnement d'IPv6 sur le réseau local
        icmpv6 type { nd-neighbor-solicit, nd-neighbor-advert, nd-router-advert } accept

        # Seul service ouvert : SSH (nouvelles connexions)
        tcp dport 22 ct state new accept
    }

    chain transfert {
        # Le serveur n'est pas un routeur : rien ne le traverse
        type filter hook forward priority filter; policy drop;
    }

    chain sortie {
        # Le serveur peut initier des connexions (mises à jour, DNS, NTP)
        type filter hook output priority filter; policy accept;
    }
}
```

Enregistre (**Ctrl+O**, **Entree**) et quitte (**Ctrl+X**).

### Fichier 11 : `config/systemd/nftables.service.d/projet.conf`
*garde les regles fail2ban apres rechargement (J1, J2)*

```bash
nano -w config/systemd/nftables.service.d/projet.conf
```

Contenu a coller :

```text
# Projet XTI302-CYB — cohabitation nftables / fail2ban (J1, J2)
# Copié par installer.sh dans /etc/systemd/system/nftables.service.d/
#
# Le service nftables de Debian exécute « nft flush ruleset » à l'arrêt :
# un « systemctl restart nftables » effacerait donc aussi les bannissements
# de fail2ban. On remplace cette action : à l'arrêt, on ne supprime que
# notre table. Le « - » ignore l'erreur si la table n'existe pas.
[Service]
ExecStop=
ExecStop=-/usr/sbin/nft delete table inet filtre
```

Enregistre (**Ctrl+O**, **Entree**) et quitte (**Ctrl+X**).

### Fichier 12 : `config/fail2ban/jail.d/projet-sshd.conf`
*fail2ban protege SSH (J1)*

```bash
nano -w config/fail2ban/jail.d/projet-sshd.conf
```

Contenu a coller :

```text
# Projet XTI302-CYB — exigence J1 : fail2ban protège SSH
# Copié par installer.sh dans /etc/fail2ban/jail.d/projet-sshd.conf
# (lu après defaults-debian.conf : ses valeurs l'emportent).

[DEFAULT]
# Jamais de bannissement de la boucle locale (tests de verifier.sh sur
# 127.0.0.1). L'hôte n'est PAS exclu : il doit pouvoir être banni (démo).
ignoreip = 127.0.0.1/8 ::1
# Les bannissements sont posés par fail2ban dans sa propre table nftables
banaction = nftables
banaction_allports = nftables[type=allports]

[sshd]
enabled  = true
port     = ssh
# Debian 13 n'a pas /var/log/auth.log : fail2ban lit le journal systemd
backend  = systemd
# 3 échecs en 10 minutes => adresse bannie 15 minutes
maxretry = 3
findtime = 10m
bantime  = 15m
```

Enregistre (**Ctrl+O**, **Entree**) et quitte (**Ctrl+X**).

### Fichier 13 : `config/journald/persistant.conf`
*journal conserve apres redemarrage (J3)*

```bash
nano -w config/journald/persistant.conf
```

Contenu a coller :

```text
# Projet XTI302-CYB — exigence J3 : journal persistant
# Copié par installer.sh dans /etc/systemd/journald.conf.d/persistant.conf
#
# Storage=persistent : le journal est écrit sur disque (/var/log/journal) et
# conservé après un redémarrage (sinon il peut rester en mémoire, /run).
[Journal]
Storage=persistent
# Garde-fous : 300 Mo au plus sur le disque système de 20 Go, et 6 mois
# d'historique, assez pour enquêter après un incident.
SystemMaxUse=300M
MaxRetentionSec=180d
```

Enregistre (**Ctrl+O**, **Entree**) et quitte (**Ctrl+X**).

### Fichier 14 : `config/apt/20auto-upgrades`
*mises a jour de securite automatiques (D1)*

```bash
nano -w config/apt/20auto-upgrades
```

Contenu a coller :

```text
// Projet XTI302-CYB — exigence D1 : mises à jour de sécurité automatiques
// Copié par installer.sh dans /etc/apt/apt.conf.d/20auto-upgrades
//
// Chaque jour (timers apt-daily et apt-daily-upgrade) : mise à jour de la
// liste des paquets, puis installation automatique par unattended-upgrades.
// Les dépôts concernés sont ceux de /etc/apt/apt.conf.d/50unattended-upgrades
// (par défaut sous Debian : les mises à jour de sécurité « Debian-Security »).
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
```

Enregistre (**Ctrl+O**, **Entree**) et quitte (**Ctrl+X**).

### Fichier 15 : `config/systemd/sauvegarde.service`
*execution de la sauvegarde (B2)*

```bash
nano -w config/systemd/sauvegarde.service
```

Contenu a coller :

```text
# Projet XTI302-CYB — exigence B2 : exécution de la sauvegarde
# Copié par installer.sh dans /etc/systemd/system/sauvegarde.service
# Déclenché par sauvegarde.timer. Les messages du script vont dans le
# journal (journalctl -u sauvegarde.service) et dans /var/log/sauvegarde.log.
[Unit]
Description=Sauvegarde incrementale versionnee de /srv et /etc
RequiresMountsFor=/sauvegardes

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/sauvegarde.sh
# La sauvegarde passe après les autres programmes (processeur et disque)
Nice=10
IOSchedulingClass=idle
```

Enregistre (**Ctrl+O**, **Entree**) et quitte (**Ctrl+X**).

### Fichier 16 : `config/systemd/sauvegarde.timer`
*planification quotidienne de la sauvegarde (B2)*

```bash
nano -w config/systemd/sauvegarde.timer
```

Contenu a coller :

```text
# Projet XTI302-CYB — exigence B2 : planification de la sauvegarde
# Copié par installer.sh dans /etc/systemd/system/sauvegarde.timer
[Unit]
Description=Sauvegarde quotidienne de /srv et /etc

[Timer]
# Tous les jours à 2 h, hors des heures de travail du cabinet
OnCalendar=*-*-* 02:00:00
# Si la machine était éteinte à 2 h, la sauvegarde est lancée au démarrage
Persistent=true
RandomizedDelaySec=15min

[Install]
WantedBy=timers.target
```

Enregistre (**Ctrl+O**, **Entree**) et quitte (**Ctrl+X**).

### Fichier 17 : `config/suid_attendus.txt`
*liste des fichiers SUID attendus (D3)*

```bash
nano -w config/suid_attendus.txt
```

Contenu a coller :

```text
# Projet XTI302-CYB — exigence D3 : fichiers SUID attendus
# verifier.sh compare la liste réelle (find / -xdev -type f -perm -4000)
# à ce fichier. Tout SUID absent d'ici est signalé [KO].
# Chaque entrée est expliquée dans DOSSIER.md (section D3).
# À AJUSTER après un premier « find / -xdev -type f -perm -4000 » sur la VM.
/usr/bin/chfn
/usr/bin/chsh
/usr/bin/gpasswd
/usr/bin/mount
/usr/bin/newgrp
/usr/bin/passwd
/usr/bin/su
/usr/bin/sudo
/usr/bin/umount
/usr/lib/dbus-1.0/dbus-daemon-launch-helper
/usr/lib/openssh/ssh-keysign
```

Enregistre (**Ctrl+O**, **Entree**) et quitte (**Ctrl+X**).

### Fichiers 18 et 19 : les cles publiques SSH
Les comptes autorises en SSH (les 3 administrateurs + `support`) ont besoin de leur **cle publique** dans `config/cles/<login>.pub`.

Pour toi (`hugo`) et pour `support`, les cles ont deja ete generees sur ton PC Windows. Affiche-les sur ton PC (PowerShell) :

```powershell
type $HOME\.ssh\projet_xti302.pub
type $HOME\.ssh\projet_support.pub
```

Puis, dans la VM, cree les deux fichiers et colle la ligne correspondante :

```bash
nano -w config/cles/hugo.pub
```

```bash
nano -w config/cles/support.pub
```

Tes deux camarades feront pareil sur leur PC :

```bash
ssh-keygen -t ed25519 -C "prenom.nom@projet-xti302"
```

puis t'enverront **uniquement** leur fichier `.pub`, que tu colleras dans `config/cles/membre2.pub` et `config/cles/membre3.pub`.

> Ne mets **jamais** de cle privee (le fichier **sans** `.pub`) dans le projet.

## Etape 2 — ajuster `comptes.csv` a ton groupe

Ouvre `comptes.csv` et remplace `membre2` et `membre3` (et leurs noms) par les vrais logins de tes camarades. `hugo` est deja le tien.

```bash
nano -w comptes.csv
```

## Etape 3 — rendre les scripts executables

```bash
chmod +x creer_comptes.sh analyse_logs.sh sauvegarde.sh installer.sh verifier.sh
```

## Etape 4 — lancer l'installation

Depuis `~/projet-xti302-cyb`, toujours en root :

```bash
./installer.sh
```

Pendant l'execution, il demande un **mot de passe provisoire** pour chaque administrateur qui n'en a pas (membre2, membre3). Mets ce que tu veux : il devra etre change a la premiere connexion.

`installer.sh` installe les paquets, cree les comptes et les droits, copie toutes les configurations, prepare le second disque, planifie les sauvegardes, durcit SSH, puis verrouille `root` en dernier.

> Il ne verrouille `root` et ne passe SSH en "cle seulement" que si au moins un administrateur a une cle installee et un mot de passe : sinon tu perdrais l'acces.

## Etape 5 — prouver que tout est conforme

```bash
./verifier.sh
```

Tu obtiens une ligne par exigence, puis un total (`--- N / N tests reussis`). Code de sortie 0 si tout est conforme.

Redemarre ensuite la VM une fois, puis relance `./verifier.sh` : cela prouve que le pare-feu (J2) et le journal (J3) survivent au redemarrage.

## Etape 6 — tester depuis ton PC (PowerShell)

Recupere l'IP de la VM (dans la VM : `ip a`, interface `enp0s3`), puis depuis ton PC :

```bash
ssh -i $HOME\.ssh\projet_xti302 hugo@<IP_VM>        # par cle, doit marcher
ssh root@<IP_VM>                                   # doit etre REFUSE (S2)
ssh -o PubkeyAuthentication=no hugo@<IP_VM>        # mot de passe REFUSE (S1)
```

Demonstration fail2ban : lance `ssh faux@<IP_VM>` trois fois (compte inexistant), ton PC est banni. Pour te debannir, sur la VM :

```bash
sudo fail2ban-client set sshd unbanip <IP_de_ton_PC>
```

## Depannage

- **Un script refuse de demarrer** (message avec `\r` ou `command not found`) : le colle a ajoute des retours chariot Windows. Corrige : `sed -i 's/\r$//' *.sh`.
- **`setfacl: command not found`** : le paquet `acl` n'est pas installe. `installer.sh` l'installe ; sinon `apt install acl`.
- **Bloque hors de la VM apres le durcissement SSH** : reconnecte-toi par ta cle, ou via la console VirtualBox avec `hugo` + son mot de passe, puis `su -`.
- **Un test `[KO]` dans verifier.sh** : il affiche la raison. Corrige le fichier concerne (souvent un colle incomplet) et relance.
