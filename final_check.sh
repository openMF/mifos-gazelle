#!/usr/bin/env bash
source src/utils/logger.sh

log_banner "MIFOS GAZELLE HYBRID LOGGING TEST"
log_section "Phase 1: UI Elements"
log_step "Testing step with success..."
log_ok
log_step "Testing step with failure..."
log_failed "Optional error detail here"

log_section "Phase 2: Level Filtering"
log_error "This is a visible error"
GAZELLE_LOG_LEVEL="ERROR" log_step "This step should be SILENT in terminal/file"
