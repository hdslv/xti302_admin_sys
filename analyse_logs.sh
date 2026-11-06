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
