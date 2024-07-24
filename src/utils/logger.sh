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

function logWithLevel() {
  local logLevel=$1
  shift

  # Check if required arguments are provided
  if [ -z "$logLevel" ] || [ -z "$1" ]; then
    echo "Usage: logWithLevel <log_level> <log_message>"
    return 1
  fi

  local logMessage=$@

  case "$logLevel" in
    "$DEBUG")
        echo -e "${BLUE}DEBUG${RESET} $logMessage"
        ;;
    "$INFO")
        echo -e "${BLUE}INFO${RESET} $logMessage"
        ;;
    "$WARNING")
        echo -e "${YELLOW}WARNING${RESET} $logMessage"
        ;;
    "$ERROR")
        echo -e "${RED}ERROR${RESET} $logMessage"
        ;;
    *) # Default case
        echo "$logMessage"
        ;;
  esac
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
