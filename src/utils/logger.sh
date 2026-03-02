#!/usr/bin/env bash

# Codici colore per il terminale
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# Livelli di log
DEBUG="debug"
INFO="info"
WARNING="warning"
ERROR="error"

# --- TUA LOGICA: Gestione File e ANSI (Essenziale per Windows) ---

_log_level_priority() {
  case "$1" in
    "$DEBUG")   echo 0 ;;
    "$INFO")    echo 1 ;;
    "$WARNING") echo 2 ;;
    "$ERROR")   echo 3 ;;
    *)          echo 1 ;;
  esac
}

_strip_ansi() {
  local esc=$'\033'
  sed -e "s/${esc}\\[[0-9;]*[[:alpha:]]//g" \
      -e 's/\\033\[[0-9;]*[[:alpha:]]//g' \
      -e 's/\\x1[bB]\[[0-9;]*[[:alpha:]]//g' \
      -e 's/\\e\[[0-9;]*[[:alpha:]]//g'
}

_log_to_file() {
  if [ -n "${GAZELLE_LOG_FILE:-}" ] && [ -n "$1" ]; then
    local clean_msg
    clean_msg="$(printf '%s' "$1" | _strip_ansi)"
    printf '%s\n' "$clean_msg" >> "$GAZELLE_LOG_FILE"
  fi
}

_should_log() {
  local msg_level="$1"
  if [ -z "${GAZELLE_LOG_LEVEL:-}" ]; then return 0; fi
  local msg_pri=$(_log_level_priority "$msg_level")
  local cfg_pri=$(_log_level_priority "$(echo "${GAZELLE_LOG_LEVEL}" | tr '[:upper:]' '[:lower:]')")
  [ "$msg_pri" -ge "$cfg_pri" ]
}

# --- LOGICA CLAUDE: Nuova Interfaccia (Integrata con file logging) ---

function logWithLevel() {
  local logLevel=$1
  shift
  if [ -z "$logLevel" ] || [ -z "$1" ]; then return 1; fi
  if ! _should_log "$logLevel"; then return 0; fi

  local logMessage="$*"
  local output
  case "$logLevel" in
    "$DEBUG")   output="${CYAN}DEBUG${RESET}  $logMessage" ;;
    "$INFO")    output="${BLUE}INFO${RESET}   $logMessage" ;;
    "$WARNING") output="${YELLOW}WARN${RESET}   $logMessage" ;;
    "$ERROR")   output="${RED}ERROR${RESET}  $logMessage" ;;
    *)          output="$logMessage" ;;
  esac

  echo -e "$output"
  _log_to_file "$output"
}

function log_section() {
  local msg="\n${BLUE}${BOLD}==> $*${RESET}"
  echo -e "$msg"
  _log_to_file "$msg"
}

function log_step() {
  printf "    %s " "$*"
  _log_to_file "    $* "
}

function log_ok() {
  echo -e "${GREEN}[  ok  ]${RESET}"
  _log_to_file "[  ok  ]"
}

function log_failed() {
  echo -e "${RED}[FAILED]${RESET}"
  _log_to_file "[FAILED]"
  if [ -n "$1" ]; then
    echo -e "         ${RED}$*${RESET}"
    _log_to_file "         $*"
  fi
}

function log_warn() {
  local msg="${YELLOW}WARN${RESET}   $*"
  echo -e "$msg"
  _log_to_file "$msg"
}

function log_error() {
  local msg="${RED}ERROR${RESET}  $*"
  if ! _should_log "$ERROR"; then return 0; fi
  echo -e "$msg"
  _log_to_file "$msg"
}

function log_banner() {
  local line="================================="
  echo -e "\n${GREEN}${line}${RESET}"
  echo -e "${GREEN}$*${RESET}"
  echo -e "${GREEN}${line}${RESET}"
  _log_to_file "\n${line}\n$*\n${line}"
}