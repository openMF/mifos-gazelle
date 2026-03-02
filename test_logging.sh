#!/usr/bin/env bash
# Carica il logger usando il percorso relativo corretto
source ./src/utils/logger.sh

export GAZELLE_LOG_FILE="./test_gazelle.log"
export GAZELLE_LOG_LEVEL="INFO"

log_banner "TESTING HYBRID LOGGING"
log_section "System Check"
log_step "Checking network..."
log_ok
log_step "Checking database..."
log_failed "Database not reachable"
log_warn "This is a non-fatal warning"
log_error "This is a fatal error"
