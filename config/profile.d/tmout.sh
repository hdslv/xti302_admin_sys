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
