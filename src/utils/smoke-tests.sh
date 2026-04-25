#!/usr/bin/env bash
# smoke-tests.sh -- Optional Gazelle smoke-test runner.

RUN_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/../.." && pwd )"
export RUN_DIR

source "$RUN_DIR/src/commandline/commandline.sh" || {
  echo "FATAL: Could not source commandline.sh. Check RUN_DIR: $RUN_DIR"
  exit 1
}

STRICT_MODE="false"
APPS_TO_TEST="mifosx"

function show_smoke_usage() {
  cat <<EOF
Usage: sudo ./src/utils/smoke-tests.sh [-f <config.ini>] [-u <user>] [-a <apps>] [-s true|false] [-d true|false]

Examples:
  sudo ./src/utils/smoke-tests.sh -u \$USER
  sudo ./src/utils/smoke-tests.sh -u \$USER -a mifosx -s true
EOF
}

while getopts "f:u:a:s:d:hH" OPTION; do
  case "${OPTION}" in
    f) CONFIG_FILE_PATH="${OPTARG}" ;;
    u) k8s_user="${OPTARG}" ;;
    a) APPS_TO_TEST="$(echo "${OPTARG}" | tr ',' ' ')" ;;
    s) STRICT_MODE="${OPTARG}" ;;
    d) debug="${OPTARG}" ;;
    h|H)
      show_smoke_usage
      exit 0
      ;;
    *)
      show_smoke_usage
      exit 1
      ;;
  esac
done

check_sudo
install_crudini

CONFIG_FILE_PATH="${CONFIG_FILE_PATH:-$DEFAULT_CONFIG_FILE}"
loadConfigFromFile "$CONFIG_FILE_PATH"

if [[ -z "${k8s_user:-}" ]]; then
  k8s_user="$(resolve_invoker_user)"
fi

if [[ "$STRICT_MODE" != "true" && "$STRICT_MODE" != "false" ]]; then
  log_error "Invalid strict mode '$STRICT_MODE'. Use true or false."
  exit 1
fi

if [[ "${debug:-false}" != "true" && "${debug:-false}" != "false" ]]; then
  log_error "Invalid debug value '${debug:-false}'. Use true or false."
  exit 1
fi

if [[ -z "${kubeconfig_path:-}" ]]; then
  k8s_user_home=$(eval echo "~$k8s_user")
  kubeconfig_path="$k8s_user_home/.kube/config"
fi

export KUBECONFIG="$kubeconfig_path"

run_smoke_tests "$APPS_TO_TEST" "$STRICT_MODE"
exit $?
