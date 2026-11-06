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
