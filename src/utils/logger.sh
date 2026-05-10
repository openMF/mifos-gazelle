#!/usr/bin/env bash

# Text color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# Log levels (used by log_with_level / log_with_verbose_check)
DEBUG="debug"
INFO="info"
WARNING="warning"
ERROR="error"

# Default minimum log level — overridden by config.ini log_level or -d flag.
# Numeric mapping: debug=0  info=1  warning=2  error=3
GAZELLE_LOG_LEVEL="${GAZELLE_LOG_LEVEL:-info}"

#------------------------------------------------------------------------------
# Internal: convert a level name to its numeric priority.
#------------------------------------------------------------------------------
_log_level_num() {
  case "$1" in
    debug)   echo 0 ;;
    info)    echo 1 ;;
    warning) echo 2 ;;
    error)   echo 3 ;;
    *)       echo 1 ;;  # unknown → treat as info
  esac
}

#------------------------------------------------------------------------------
# Internal: return an ISO-8601 timestamp (second precision, no TZ).
#------------------------------------------------------------------------------
_log_ts() {
  date '+%Y-%m-%dT%H:%M:%S'
}

#------------------------------------------------------------------------------
# Low-level levelled logger — used internally and by convenience wrappers.
# Respects GAZELLE_LOG_LEVEL: messages below the threshold are suppressed.
#------------------------------------------------------------------------------
log_with_level() {
  local logLevel=$1
  shift

  if [ -z "$logLevel" ] || [ -z "$1" ]; then
    echo "Usage: log_with_level <log_level> <log_message>"
    return 1
  fi

  # Level-gate: skip if message level is below the configured threshold
  local msg_num min_num
  msg_num=$(_log_level_num "$logLevel")
  min_num=$(_log_level_num "$GAZELLE_LOG_LEVEL")
  [[ $msg_num -lt $min_num ]] && return 0

  local logMessage="$*"
  local ts
  ts=$(_log_ts)

  case "$logLevel" in
    "$DEBUG")
        echo -e "${CYAN}${ts} DEBUG${RESET}  $logMessage"
        ;;
    "$INFO")
        echo -e "${BLUE}${ts} INFO${RESET}   $logMessage"
        ;;
    "$WARNING")
        echo -e "${YELLOW}${ts} WARN${RESET}   $logMessage"
        ;;
    "$ERROR")
        echo -e "${RED}${ts} ERROR${RESET}  $logMessage"
        ;;
    *)
        echo "${ts} $logMessage"
        ;;
  esac
}

#------------------------------------------------------------------------------
# Verbose-gated logger — only prints when isVerbose=true.
# Also respects GAZELLE_LOG_LEVEL for consistency.
#------------------------------------------------------------------------------
log_with_verbose_check() {
  local isVerbose=$1
  local logLevel=$2
  shift && shift

  if [ -z "$isVerbose" ] || [ -z "$logLevel" ] || [ -z "$1" ]; then
    echo "Usage: log_with_verbose_check <verbose_flag> <log_level> <log_message>"
    return 1
  fi

  if [ "$isVerbose" = true ]; then
    log_with_level "$logLevel" "$*"
  fi
}

#------------------------------------------------------------------------------
# Convenience wrappers — short names for the most common patterns.
# These always go through level-filtering; no verbose gate needed.
#------------------------------------------------------------------------------
log_debug() { log_with_level "$DEBUG"   "$@"; }
log_info()  { log_with_level "$INFO"    "$@"; }

#------------------------------------------------------------------------------
# Function-entry/exit tracing — automatically captures the calling function
# name via FUNCNAME.  Pass optional context as arguments.
#   log_func_start           → "→ deploy_vnext()"
#   log_func_start "ns=phee" → "→ deploy_ph() ns=phee"
#   log_func_end             → "← deploy_vnext()"
#------------------------------------------------------------------------------
log_func_start() {
  log_debug "→ ${FUNCNAME[1]}() $*"
}

log_func_end() {
  log_debug "← ${FUNCNAME[1]}()"
}

#------------------------------------------------------------------------------
# Elapsed-time helper — call at the start of a timed section to capture
# the start epoch.  Then call log_elapsed to print how long it took.
#   local t0; t0=$(log_timer_start)
#   … work …
#   log_elapsed "$t0" "Helm install"
#------------------------------------------------------------------------------
log_timer_start() {
  date +%s
}

log_elapsed() {
  local start="$1"; shift
  local label="$*"
  local elapsed=$(( $(date +%s) - start ))
  log_debug "$label completed in ${elapsed}s"
}

#------------------------------------------------------------------------------
# Structured output helpers — use these in deployer scripts
#------------------------------------------------------------------------------

# Major section header: ==> Title
log_section() {
  local ts
  ts=$(_log_ts)
  echo -e "\n${BLUE}${BOLD}${ts} ==> $*${RESET}"
}

# Step in progress (no newline — caller must follow with log_ok or log_failed)
# Pads to column 55 so status tags align regardless of message length.
log_step() {
  printf "%-55s" "    $*"
}

# Success status — appended on same line as log_step
log_ok() {
  echo -e "${GREEN}[  ok  ]${RESET}"
}

# Skipped status — appended on same line as log_step
log_skipped() {
  echo -e "${YELLOW}[skipping]${RESET}"
}

# Failure status — appended on same line as log_step, optional detail on next line
log_failed() {
  echo -e "${RED}[FAILED]${RESET}"
  if [ -n "$1" ]; then
    echo -e "         ${RED}$*${RESET}"
  fi
}

# Warning message (non-fatal)
log_warn() {
  local ts
  ts=$(_log_ts)
  echo -e "${YELLOW}${ts} WARN${RESET}   $*"
}

# Error message (fatal — caller should exit after)
log_error() {
  local ts
  ts=$(_log_ts)
  echo -e "${RED}${ts} ERROR${RESET}  $*"
}

# Success banner — green box with fixed 34-char rule
log_banner() {
  echo -e "\n${GREEN}==================================${RESET}"
  echo -e "${GREEN} $*${RESET}"
  echo -e "${GREEN}==================================${RESET}"
}
