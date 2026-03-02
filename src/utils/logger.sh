#!/usr/bin/env bash

# Text color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# Log levels (used by logWithLevel / logWithVerboseCheck)
DEBUG="debug"
INFO="info"
WARNING="warning"
ERROR="error"

#------------------------------------------------------------------------------
# Low-level levelled logger — used internally and by logWithVerboseCheck
#------------------------------------------------------------------------------
function logWithLevel() {
  local logLevel=$1
  shift

  if [ -z "$logLevel" ] || [ -z "$1" ]; then
    echo "Usage: logWithLevel <log_level> <log_message>"
    return 1
  fi

  local logMessage="$*"

  case "$logLevel" in
    "$DEBUG")
        echo -e "${CYAN}DEBUG${RESET}  $logMessage"
        ;;
    "$INFO")
        echo -e "${BLUE}INFO${RESET}   $logMessage"
        ;;
    "$WARNING")
        echo -e "${YELLOW}WARN${RESET}   $logMessage"
        ;;
    "$ERROR")
        echo -e "${RED}ERROR${RESET}  $logMessage"
        ;;
    *)
        echo "$logMessage"
        ;;
  esac
}

#------------------------------------------------------------------------------
# Verbose-gated logger — only prints when isVerbose=true
#------------------------------------------------------------------------------
function logWithVerboseCheck() {
  local isVerbose=$1
  local logLevel=$2
  shift && shift

  if [ -z "$isVerbose" ] || [ -z "$logLevel" ] || [ -z "$1" ]; then
    echo "Usage: logWithVerboseCheck <verbose_flag> <log_level> <log_message>"
    return 1
  fi

  if [ "$isVerbose" = true ]; then
    logWithLevel "$logLevel" "$*"
  fi
}

#------------------------------------------------------------------------------
# Structured output helpers — use these in deployer scripts
#------------------------------------------------------------------------------

# Major section header: ==> Title
function log_section() {
  echo -e "\n${BLUE}${BOLD}==> $*${RESET}"
}

# Step in progress (no newline — caller must follow with log_ok or log_failed)
function log_step() {
  printf "    %s " "$*"
}

# Success status — appended on same line as log_step
function log_ok() {
  echo -e "${GREEN}[  ok  ]${RESET}"
}

# Failure status — appended on same line as log_step, optional detail on next line
function log_failed() {
  echo -e "${RED}[FAILED]${RESET}"
  if [ -n "$1" ]; then
    echo -e "         ${RED}$*${RESET}"
  fi
}

# Warning message (non-fatal)
function log_warn() {
  echo -e "${YELLOW}WARN${RESET}   $*"
}

# Error message (fatal — caller should exit after)
function log_error() {
  echo -e "${RED}ERROR${RESET}  $*"
}

# Success banner — green box with fixed 34-char rule
function log_banner() {
  echo -e "\n${GREEN}==================================${RESET}"
  echo -e "${GREEN} $*${RESET}"
  echo -e "${GREEN}==================================${RESET}"
}
