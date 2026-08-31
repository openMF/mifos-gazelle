#!/usr/bin/env bash
# collect-metrics.sh -- Collect CPU/memory resource usage from a live Gazelle deployment
#
# Queries kubectl top for all Gazelle namespaces and writes a structured JSON
# report that the TCO calculator (tco-estimate.py) can consume.
# Also collects actual PVC storage usage when --storage flag is passed.
#
# Usage:
#   ./src/utils/perf/collect-metrics.sh [--kubeconfig <path>] [--out <file>] [--storage]
#   ./src/utils/perf/collect-metrics.sh --mock
#
# Output: JSON file at /tmp/gazelle-metrics-<timestamp>.json (or --out path)
#
# Requirements:
#   - kubectl installed and configured (skipped in --mock mode)
#   - metrics-server running in the cluster (k3s includes this by default)
#   - jq installed (for JSON formatting)

set -euo pipefail

# ── colour helpers (inline so this script is self-contained) ─────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; RESET='\033[0m'

log_section() { echo -e "\n${BLUE}${BOLD}==> $*${RESET}"; }
log_step()    { printf "%-55s" "    $*"; }
log_ok()      { echo -e "${GREEN}[  ok  ]${RESET}"; }
log_warn()    { echo -e "${YELLOW}WARN${RESET}   $*"; }
log_error()   { echo -e "${RED}ERROR${RESET}  $*"; }

# ── defaults ─────────────────────────────────────────────────────────────────
KUBECONFIG_PATH="${KUBECONFIG:-$HOME/.kube/config}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUT_FILE="/tmp/gazelle-metrics-${TIMESTAMP}.json"
MOCK_MODE=false
COLLECT_STORAGE=false

# Gazelle namespaces to measure
GAZELLE_NAMESPACES=("infra" "mifosx" "paymenthub" "vnext")

# ── argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig) KUBECONFIG_PATH="$2"; shift 2 ;;
    --out)        OUT_FILE="$2";        shift 2 ;;
    --mock)       MOCK_MODE=true;       shift   ;;
    --storage)    COLLECT_STORAGE=true; shift   ;;
    -h|--help)
      echo "Usage: $0 [--kubeconfig <path>] [--out <file>] [--mock] [--storage]"
      echo "  --storage  Also collect PVC sizes from the cluster (live mode only)"
      exit 0 ;;
    *) log_error "Unknown option: $1"; exit 1 ;;
  esac
done

export KUBECONFIG="$KUBECONFIG_PATH"

# ── dependency checks ─────────────────────────────────────────────────────────
check_deps() {
  local missing=()
  command -v jq &>/dev/null || missing+=("jq")
  if [[ "$MOCK_MODE" == "false" ]]; then
    command -v kubectl &>/dev/null || missing+=("kubectl")
  fi
  if [[ ${#missing[@]} -gt 0 ]]; then
    log_error "Missing required tools: ${missing[*]}"
    echo "  Install jq:      sudo apt-get install -y jq"
    echo "  Install kubectl: https://kubernetes.io/docs/tasks/tools/"
    exit 1
  fi
}

# ── kubectl top parser ────────────────────────────────────────────────────────
# kubectl top pods -n <ns> --no-headers outputs lines like:
#   fineract-server-xxx-yyy   245m   512Mi
# Parses into one JSON object per pod.
parse_top_output() {
  local ns="$1"
  local raw="$2"

  echo "$raw" | awk -v ns_name="$ns" '
    NF >= 3 {
      pod=$1; cpu=$2; mem=$3

      cpu_val = cpu
      if (sub(/m$/, "", cpu_val)) { cpu_m = cpu_val + 0 }
      else                        { cpu_m = cpu_val * 1000 }

      mem_val = mem
      if      (sub(/Gi$/, "", mem_val)) { mem_mib = mem_val * 1024 }
      else if (sub(/Mi$/, "", mem_val)) { mem_mib = mem_val + 0 }
      else if (sub(/Ki$/, "", mem_val)) { mem_mib = mem_val / 1024 }
      else                              { mem_mib = mem_val / 1048576 }

      printf "{\"namespace\":\"%s\",\"pod\":\"%s\",\"cpu_millicores\":%d,\"memory_mib\":%.1f}\n",
             ns_name, pod, cpu_m, mem_mib
    }
  '
}

# ── collect PVC storage from cluster ─────────────────────────────────────────
# Returns a JSON object: {namespace: requested_gib, ...}
collect_pvc_storage() {
  local pvc_json="{}"

  for ns in "${GAZELLE_NAMESPACES[@]}"; do
    if ! kubectl get namespace "$ns" &>/dev/null; then
      continue
    fi

    # Sum requested storage for all PVCs in this namespace
    local total_gib
    total_gib=$(kubectl get pvc -n "$ns" -o json 2>/dev/null | jq '
      [.items[].spec.resources.requests.storage // "0"] |
      map(
        if   test("Gi$") then gsub("Gi";"") | tonumber
        elif test("Mi$") then gsub("Mi";"") | tonumber / 1024
        elif test("Ti$") then gsub("Ti";"") | tonumber * 1024
        else 0
        end
      ) | add // 0
    ')

    pvc_json=$(echo "$pvc_json" | jq --arg ns "$ns" --argjson gib "$total_gib" \
      '. + {($ns): $gib}')
  done

  echo "$pvc_json"
}

# ── collect from live cluster ─────────────────────────────────────────────────
# Sets globals: PODS_JSON, NS_SUMMARIES_JSON
collect_live() {
  log_section "Collecting resource metrics from cluster"

  log_step "Cluster connectivity"
  if ! kubectl cluster-info &>/dev/null; then
    echo ""
    log_error "Cannot reach cluster. Check your kubeconfig: $KUBECONFIG_PATH"
    exit 1
  fi
  log_ok

  log_step "Metrics-server availability"
  if ! kubectl top nodes &>/dev/null 2>&1; then
    echo ""
    log_warn "metrics-server not responding. On k3s run:"
    log_warn "  kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml"
    log_warn "Then wait ~60s and retry."
    exit 1
  fi
  log_ok

  PODS_JSON="[]"
  NS_SUMMARIES_JSON="[]"

  for ns in "${GAZELLE_NAMESPACES[@]}"; do
    log_step "Namespace: $ns"

    if ! kubectl get namespace "$ns" &>/dev/null; then
      echo -e "${YELLOW}[not deployed]${RESET}"
      continue
    fi

    local raw
    raw=$(kubectl top pods -n "$ns" --no-headers 2>/dev/null || true)

    if [[ -z "$raw" ]]; then
      echo -e "${YELLOW}[no pods running]${RESET}"
      continue
    fi

    local pods_json
    pods_json=$(parse_top_output "$ns" "$raw")

    while IFS= read -r pod_obj; do
      [[ -z "$pod_obj" ]] && continue
      PODS_JSON=$(echo "$PODS_JSON" | jq --argjson p "$pod_obj" '. + [$p]')
    done <<< "$pods_json"

    local total_cpu total_mem pod_count
    total_cpu=$(echo "$pods_json" | jq -s '[.[].cpu_millicores] | add // 0')
    total_mem=$(echo "$pods_json" | jq -s '[.[].memory_mib]     | add // 0')
    pod_count=$(echo "$pods_json" | jq -s 'length')

    local ns_summary
    ns_summary=$(jq -n \
      --arg  ns    "$ns" \
      --argjson cpu   "$total_cpu" \
      --argjson mem   "$total_mem" \
      --argjson count "$pod_count" \
      '{namespace: $ns, pod_count: $count, total_cpu_millicores: $cpu, total_memory_mib: $mem}')

    NS_SUMMARIES_JSON=$(echo "$NS_SUMMARIES_JSON" | jq --argjson s "$ns_summary" '. + [$s]')
    log_ok
  done
}

# ── mock data (for testing without a cluster) ─────────────────────────────────
# Representative values from a typical single-node Gazelle deployment.
collect_mock() {
  log_warn "Running in MOCK mode — using representative sample data, not a live cluster."
  echo ""

  PODS_JSON='[
    {"namespace":"infra","pod":"mysql-0","cpu_millicores":45,"memory_mib":512.0},
    {"namespace":"infra","pod":"kafka-0","cpu_millicores":120,"memory_mib":768.0},
    {"namespace":"infra","pod":"redis-master-0","cpu_millicores":8,"memory_mib":32.0},
    {"namespace":"infra","pod":"mongodb-0","cpu_millicores":35,"memory_mib":256.0},
    {"namespace":"infra","pod":"elasticsearch-master-0","cpu_millicores":180,"memory_mib":1024.0},
    {"namespace":"infra","pod":"nginx-ingress-controller","cpu_millicores":12,"memory_mib":64.0},
    {"namespace":"mifosx","pod":"fineract-server-xxx","cpu_millicores":320,"memory_mib":1536.0},
    {"namespace":"mifosx","pod":"mifos-web-app-xxx","cpu_millicores":5,"memory_mib":48.0},
    {"namespace":"paymenthub","pod":"ph-ee-connector-channel-xxx","cpu_millicores":85,"memory_mib":384.0},
    {"namespace":"paymenthub","pod":"ph-ee-operations-app-xxx","cpu_millicores":60,"memory_mib":256.0},
    {"namespace":"paymenthub","pod":"ph-ee-bulk-processor-xxx","cpu_millicores":70,"memory_mib":320.0},
    {"namespace":"paymenthub","pod":"zeebe-gateway-xxx","cpu_millicores":95,"memory_mib":512.0},
    {"namespace":"paymenthub","pod":"zeebe-broker-0","cpu_millicores":140,"memory_mib":768.0},
    {"namespace":"vnext","pod":"account-lookup-svc-xxx","cpu_millicores":40,"memory_mib":192.0},
    {"namespace":"vnext","pod":"transfers-bc-xxx","cpu_millicores":55,"memory_mib":256.0},
    {"namespace":"vnext","pod":"quoting-bc-xxx","cpu_millicores":35,"memory_mib":192.0},
    {"namespace":"vnext","pod":"participants-bc-xxx","cpu_millicores":30,"memory_mib":160.0},
    {"namespace":"vnext","pod":"admin-ui-xxx","cpu_millicores":5,"memory_mib":64.0}
  ]'

  NS_SUMMARIES_JSON='[
    {"namespace":"infra","pod_count":6,"total_cpu_millicores":400,"total_memory_mib":2656.0},
    {"namespace":"mifosx","pod_count":2,"total_cpu_millicores":325,"total_memory_mib":1584.0},
    {"namespace":"paymenthub","pod_count":5,"total_cpu_millicores":450,"total_memory_mib":2240.0},
    {"namespace":"vnext","pod_count":5,"total_cpu_millicores":165,"total_memory_mib":864.0}
  ]'
}

# ── node metrics ──────────────────────────────────────────────────────────────
collect_node_metrics() {
  if [[ "$MOCK_MODE" == "true" ]]; then
    echo '{"node_count":1,"total_cpu_millicores":4000,"total_memory_mib":16384}'
    return
  fi

  local node_raw
  node_raw=$(kubectl top nodes --no-headers 2>/dev/null || true)

  if [[ -z "$node_raw" ]]; then
    echo '{"node_count":0,"total_cpu_millicores":0,"total_memory_mib":0}'
    return
  fi

  echo "$node_raw" | awk '
    NF >= 3 {
      cpu=$2; mem=$4
      cpu_val=cpu
      if (sub(/m$/, "", cpu_val)) cpu_m = cpu_val + 0
      else                        cpu_m = cpu_val * 1000
      mem_val=mem
      if      (sub(/Gi$/, "", mem_val)) mem_mib = mem_val * 1024
      else if (sub(/Mi$/, "", mem_val)) mem_mib = mem_val + 0
      else                              mem_mib = mem_val / 1048576
      total_cpu += cpu_m; total_mem += mem_mib; count++
    }
    END {
      printf "{\"node_count\":%d,\"total_cpu_millicores\":%d,\"total_memory_mib\":%.0f}\n",
             count, total_cpu, total_mem
    }
  '
}

# ── assemble final JSON report ────────────────────────────────────────────────
build_report() {
  local pods_json="$1"
  local ns_summaries_json="$2"
  local node_metrics="$3"
  local storage_json="$4"

  local grand_cpu grand_mem total_pods
  grand_cpu=$(echo "$pods_json"  | jq '[.[].cpu_millicores] | add // 0')
  grand_mem=$(echo "$pods_json"  | jq '[.[].memory_mib]     | add // 0')
  total_pods=$(echo "$pods_json" | jq 'length')

  jq -n \
    --arg  ts          "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg  mode        "$([[ "$MOCK_MODE" == "true" ]] && echo "mock" || echo "live")" \
    --argjson pods         "$pods_json" \
    --argjson ns_summaries "$ns_summaries_json" \
    --argjson nodes        "$node_metrics" \
    --argjson storage      "$storage_json" \
    --argjson grand_cpu    "$grand_cpu" \
    --argjson grand_mem    "$grand_mem" \
    --argjson total_pods   "$total_pods" \
    '{
      collected_at: $ts,
      mode: $mode,
      cluster: $nodes,
      summary: {
        total_pods: $total_pods,
        total_cpu_millicores: $grand_cpu,
        total_memory_mib: $grand_mem,
        total_cpu_cores: ($grand_cpu / 1000),
        total_memory_gib: ($grand_mem / 1024)
      },
      storage_gib: $storage,
      namespaces: $ns_summaries,
      pods: $pods
    }'
}

# ── print human-readable summary ─────────────────────────────────────────────
print_summary() {
  local report="$1"

  echo ""
  echo -e "${BLUE}${BOLD}  Resource Usage Summary${RESET}"
  echo    "  ─────────────────────────────────────────────────"
  printf  "  %-20s %10s %12s\n" "Namespace" "CPU (cores)" "Memory (GiB)"
  echo    "  ─────────────────────────────────────────────────"

  # Use a temp file to avoid subshell variable scoping issues with while+IFS
  local tmpfile
  tmpfile=$(mktemp)
  echo "$report" | jq -r '.namespaces[] | [.namespace, (.total_cpu_millicores/1000), (.total_memory_mib/1024)] | @tsv' > "$tmpfile"
  while IFS=$'\t' read -r ns cpu mem; do
    printf "  %-20s %10.2f %12.2f\n" "$ns" "$cpu" "$mem"
  done < "$tmpfile"
  rm -f "$tmpfile"

  echo    "  ─────────────────────────────────────────────────"
  local total_cpu total_mem
  total_cpu=$(echo "$report" | jq '.summary.total_cpu_cores')
  total_mem=$(echo "$report"  | jq '.summary.total_memory_gib')
  printf  "  %-20s %10.2f %12.2f\n" "TOTAL" "$total_cpu" "$total_mem"

  # Show measured storage if present
  local has_storage
  has_storage=$(echo "$report" | jq '.storage_gib | length > 0')
  if [[ "$has_storage" == "true" ]]; then
    echo ""
    echo -e "${BLUE}${BOLD}  Measured PVC Storage${RESET}"
    echo    "  ─────────────────────────────────────────────────"
    local stmpfile
    stmpfile=$(mktemp)
    echo "$report" | jq -r '.storage_gib | to_entries[] | [.key, .value] | @tsv' > "$stmpfile"
    while IFS=$'\t' read -r ns gib; do
      printf "  %-20s %10.1f GiB\n" "$ns" "$gib"
    done < "$stmpfile"
    rm -f "$stmpfile"
  fi

  echo ""
}

# ── globals set by collect_live / collect_mock ────────────────────────────────
PODS_JSON="[]"
NS_SUMMARIES_JSON="[]"

# ── main ──────────────────────────────────────────────────────────────────────
main() {
  check_deps

  echo -e "${BLUE}${BOLD}"
  echo "  Mifos Gazelle — Resource Metrics Collector"
  echo -e "${RESET}"

  if [[ "$MOCK_MODE" == "true" ]]; then
    collect_mock
  else
    collect_live
  fi

  log_step "Collecting node metrics"
  local node_metrics
  node_metrics=$(collect_node_metrics)
  log_ok

  # Storage: collect from cluster if --storage flag set, else empty object
  local storage_json="{}"
  if [[ "$COLLECT_STORAGE" == "true" && "$MOCK_MODE" == "false" ]]; then
    log_step "Collecting PVC storage"
    storage_json=$(collect_pvc_storage)
    log_ok
  elif [[ "$MOCK_MODE" == "true" ]]; then
    # Provide representative mock storage so tco-estimate.py can use real values
    storage_json='{"infra":45,"mifosx":8,"paymenthub":9,"vnext":7}'
  fi

  log_step "Building report"
  local report
  report=$(build_report "$PODS_JSON" "$NS_SUMMARIES_JSON" "$node_metrics" "$storage_json")
  log_ok

  log_step "Writing report to $OUT_FILE"
  echo "$report" | jq '.' > "$OUT_FILE"
  log_ok

  print_summary "$report"

  echo -e "${GREEN}  Report saved: $OUT_FILE${RESET}"
  echo -e "  Run TCO estimate: python3 src/utils/perf/tco-estimate.py --metrics $OUT_FILE"
  echo ""
}

main "$@"
