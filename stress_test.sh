#!/usr/bin/env bash
source src/utils/logger.sh

export GAZELLE_LOG_FILE="./stress.log"
rm -f $GAZELLE_LOG_FILE # partiamo puliti

log_error "\033[1;31mERRORE CRITICO\033[0m: \033[4;33mDatabase in fiamme\033[0m"
log_ok

echo -e "\n=== ECCO COSA VEDRÀ UN UTENTE WINDOWS NEL FILE ==="
cat stress.log
