if [ "${TMOUT:-}" != "600" ]; then
    TMOUT=600
    readonly TMOUT
    export TMOUT
fi
