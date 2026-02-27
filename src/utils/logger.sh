#!/usr/bin/env bash

# Text color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RESET='\033[0m'

# Log levels
DEBUG="debug"
INFO="info"
WARNING="warning"
ERROR="error"

# Numeric priority (higher = more severe). Used for GAZELLE_LOG_LEVEL filtering.
# DEBUG=0, INFO=1, WARNING=2, ERROR=3
_log_level_priority() {
  case "$1" in
    "$DEBUG")   echo 0 ;;
    "$INFO")    echo 1 ;;
    "$WARNING") echo 2 ;;
    "$ERROR")   echo 3 ;;
    *)          echo 1 ;;  # Unknown: treat as INFO
  esac
}

# Strip ANSI escape sequences for plain-text log file output.
# We strip both:
# - real ANSI CSI sequences (ESC [ ... letter)
# - literal sequences embedded as text (e.g., "\033[0;31m", "\x1b[31m", "\e[31m")
_strip_ansi() {
  local esc
  esc=$'\033'

  # Real escape sequences (contain the ESC control char)
  # plus common literal forms sometimes embedded in strings.
  sed \
    -e "s/${esc}\\[[0-9;]*[[:alpha:]]//g" \
    -e 's/\\033\[[0-9;]*[[:alpha:]]//g' \
    -e 's/\\x1[bB]\[[0-9;]*[[:alpha:]]//g' \
    -e 's/\\e\[[0-9;]*[[:alpha:]]//g'
}

# Append message to GAZELLE_LOG_FILE (plain text, no ANSI codes).
_log_to_file() {
  if [ -n "${GAZELLE_LOG_FILE:-}" ] && [ -n "$1" ]; then
    local clean_msg
    clean_msg="$(printf '%s' "$1" | _strip_ansi)"
    printf '%s\n' "$clean_msg" >> "$GAZELLE_LOG_FILE"
  fi
}

# Check if message should be output based on GAZELLE_LOG_LEVEL.
# Returns 0 (success) if we should log, 1 if we should skip.
_should_log() {
  local msg_level="$1"
  if [ -z "${GAZELLE_LOG_LEVEL:-}" ]; then
    return 0  # No filter: always log
  fi
  local msg_pri
  local cfg_pri
  msg_pri=$(_log_level_priority "$msg_level")
  cfg_pri=$(_log_level_priority "$(echo "${GAZELLE_LOG_LEVEL}" | tr '[:upper:]' '[:lower:]')")
  [ "$msg_pri" -ge "$cfg_pri" ]
}

function logWithLevel() {
  local logLevel=$1
  shift

  # Check if required arguments are provided
  if [ -z "$logLevel" ] || [ -z "$1" ]; then
    echo "Usage: logWithLevel <log_level> <log_message>"
    return 1
  fi

  local logMessage=$@

  # Filter by GAZELLE_LOG_LEVEL if set
  if ! _should_log "$logLevel"; then
    return 0
  fi

  local output
  case "$logLevel" in
    "$DEBUG")
        output="${BLUE}DEBUG${RESET} $logMessage"
        ;;
    "$INFO")
        output="${BLUE}INFO${RESET} $logMessage"
        ;;
    "$WARNING")
        output="${YELLOW}WARNING${RESET} $logMessage"
        ;;
    "$ERROR")
        output="${RED}ERROR${RESET} $logMessage"
        ;;
    *) # Default case
        output="$logMessage"
        ;;
  esac

  echo -e "$output"
  _log_to_file "$output"
}

function logWithVerboseCheck() {
  local isVerbose=$1
  local logLevel=$2
  shift && shift

  # Check if required arguments are provided
  if [ -z "$isVerbose" ] || [ -z "$logLevel" ] || [ -z "$1" ]; then
    echo "Usage: logWithVerboseCheck <verbose_flag> <log_level> <log_message>"
    return 1
  fi

  local message=$@

  if [ "$isVerbose" = true ]; then
    logWithLevel "$logLevel" "$message"
  fi
}

# Usage examples:
# logWithLevel "$DEBUG" "This is a debug message"
# logWithVerboseCheck true "$DEBUG" "Verbose debug message"
# GAZELLE_LOG_FILE=/tmp/gazelle.log GAZELLE_LOG_LEVEL=INFO ./run.sh
