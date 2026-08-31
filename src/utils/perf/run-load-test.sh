#!/usr/bin/env bash
# run-load-test.sh -- Headless JMeter load test runner for Mifos Gazelle
#
# Wraps the existing performance-testing/paymentHubEE.jmx plan so it can be
# run from the command line without opening the JMeter GUI. Captures a
# resource snapshot before and after the test so you can see how load
# affects CPU/memory consumption.
#
# Usage:
#   ./src/utils/perf/run-load-test.sh [options]
#
# Options:
#   --threads   <n>      Number of concurrent virtual users (default: 10)
#   --duration  <s>      Test duration in seconds (default: 60)
#   --rampup    <s>      Ramp-up period in seconds (default: 10)
#   --host      <host>   PaymentHub EE host (default: ops.mifos.gazelle.test)
#   --port      <port>   PaymentHub EE port (default: 443)
#   --jmeter    <path>   Path to JMeter bin dir (default: auto-detect)
#   --out       <dir>    Output directory for reports (default: /tmp/gazelle-perf-<ts>)
#   --no-snapshot        Skip before/after resource snapshots
#   --mock               Dry-run: print what would be executed, don't run JMeter
#
# Output:
#   <out>/report/          JMeter HTML report
#   <out>/results.jtl      Raw JMeter results (CSV)
#   <out>/metrics-before.json  Resource snapshot before test
#   <out>/metrics-after.json   Resource snapshot after test
#   <out>/summary.txt      Human-readable summary

set -euo pipefail

# ── colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; RESET='\033[0m'

log_section() { echo -e "\n${BLUE}${BOLD}==> $*${RESET}"; }
log_step()    { printf "%-55s" "    $*"; }
log_ok()      { echo -e "${GREEN}[  ok  ]${RESET}"; }
log_warn()    { echo -e "${YELLOW}WARN${RESET}   $*"; }
log_error()   { echo -e "${RED}ERROR${RESET}  $*"; }
log_info()    { echo -e "${BLUE}INFO${RESET}   $*"; }

# ── defaults ──────────────────────────────────────────────────────────────────
THREADS=10
DURATION=60
RAMPUP=10
PH_HOST="ops.mifos.gazelle.test"
PH_PORT=443
JMETER_BIN=""
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUT_DIR="/tmp/gazelle-perf-${TIMESTAMP}"
TAKE_SNAPSHOTS=true
MOCK_MODE=false

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
JMX_FILE="$REPO_ROOT/performance-testing/paymentHubEE.jmx"
METRICS_SCRIPT="$SCRIPT_DIR/collect-metrics.sh"

# ── argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --threads)      THREADS="$2";      shift 2 ;;
    --duration)     DURATION="$2";     shift 2 ;;
    --rampup)       RAMPUP="$2";       shift 2 ;;
    --host)         PH_HOST="$2";      shift 2 ;;
    --port)         PH_PORT="$2";      shift 2 ;;
    --jmeter)       JMETER_BIN="$2";   shift 2 ;;
    --out)          OUT_DIR="$2";      shift 2 ;;
    --no-snapshot)  TAKE_SNAPSHOTS=false; shift ;;
    --mock)         MOCK_MODE=true;    shift ;;
    -h|--help)
      sed -n '2,30p' "$0" | grep '^#' | sed 's/^# \?//'
      exit 0 ;;
    *) log_error "Unknown option: $1"; exit 1 ;;
  esac
done

# ── locate JMeter ─────────────────────────────────────────────────────────────
find_jmeter() {
  # 1. Explicit --jmeter flag
  if [[ -n "$JMETER_BIN" ]]; then
    if [[ -x "$JMETER_BIN/jmeter" ]]; then
      echo "$JMETER_BIN/jmeter"
      return 0
    fi
    log_error "JMeter not found at: $JMETER_BIN/jmeter"
    return 1
  fi

  # 2. On PATH
  if command -v jmeter &>/dev/null; then
    command -v jmeter
    return 0
  fi

  # 3. Common install locations
  for candidate in \
    "$HOME/apache-jmeter/bin/jmeter" \
    "/opt/apache-jmeter/bin/jmeter" \
    "/usr/local/bin/jmeter" \
    "/usr/share/jmeter/bin/jmeter"
  do
    if [[ -x "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done

  return 1
}

# ── dependency checks ─────────────────────────────────────────────────────────
check_deps() {
  local missing=()

  if [[ "$MOCK_MODE" == "false" ]]; then
    if ! JMETER_CMD=$(find_jmeter); then
      missing+=("jmeter")
    fi
  fi

  if [[ ${#missing[@]} -gt 0 ]]; then
    log_error "Missing required tools: ${missing[*]}"
    echo ""
    echo "  Install JMeter:"
    echo "    wget https://downloads.apache.org/jmeter/binaries/apache-jmeter-5.6.3.tgz"
    echo "    tar -xzf apache-jmeter-5.6.3.tgz -C \$HOME"
    echo "    mv \$HOME/apache-jmeter-5.6.3 \$HOME/apache-jmeter"
    echo "    export PATH=\$HOME/apache-jmeter/bin:\$PATH"
    echo ""
    exit 1
  fi

  if [[ ! -f "$JMX_FILE" ]]; then
    log_error "JMeter test plan not found: $JMX_FILE"
    log_error "Expected at: performance-testing/paymentHubEE.jmx"
    exit 1
  fi
}

# ── take resource snapshot ────────────────────────────────────────────────────
take_snapshot() {
  local label="$1"   # "before" or "after"
  local out_file="$OUT_DIR/metrics-${label}.json"

  if [[ "$TAKE_SNAPSHOTS" == "false" ]]; then
    return 0
  fi

  if [[ ! -f "$METRICS_SCRIPT" ]]; then
    log_warn "collect-metrics.sh not found — skipping $label snapshot"
    return 0
  fi

  log_step "Resource snapshot ($label)"
  if bash "$METRICS_SCRIPT" --storage --out "$out_file" > /dev/null 2>&1; then
    log_ok
  else
    # Non-fatal: snapshot failure shouldn't abort the load test
    echo -e "${YELLOW}[skipped]${RESET}"
    log_warn "Could not collect $label snapshot (cluster may not be reachable)"
  fi
}

# ── run JMeter ────────────────────────────────────────────────────────────────
run_jmeter() {
  local results_file="$OUT_DIR/results.jtl"
  local report_dir="$OUT_DIR/report"
  local log_file="$OUT_DIR/jmeter.log"

  mkdir -p "$report_dir"

  # JMeter CLI flags:
  #   -n           non-GUI (headless) mode
  #   -t           test plan file
  #   -l           results log file (JTL/CSV)
  #   -e           generate HTML report after test
  #   -o           HTML report output directory
  #   -j           JMeter log file
  #   -J<prop>     override a JMeter property (maps to ${__P(prop)} in the JMX)
  local jmeter_cmd=(
    "$JMETER_CMD"
    -n
    -t "$JMX_FILE"
    -l "$results_file"
    -e -o "$report_dir"
    -j "$log_file"
    -Jthreads="$THREADS"
    -Jduration="$DURATION"
    -Jrampup="$RAMPUP"
    -Jhost="$PH_HOST"
    -Jport="$PH_PORT"
  )

  log_info "Running: ${jmeter_cmd[*]}"
  echo ""

  if "${jmeter_cmd[@]}"; then
    return 0
  else
    log_error "JMeter exited with errors. Check: $log_file"
    return 1
  fi
}

# ── parse JTL results ─────────────────────────────────────────────────────────
# JTL is a CSV with header: timeStamp,elapsed,label,responseCode,success,...
parse_jtl() {
  local jtl="$1"

  if [[ ! -f "$jtl" ]]; then
    echo "  No results file found."
    return
  fi

  awk -F',' '
    NR == 1 { next }   # skip header
    {
      elapsed=$2; success=$8
      total++
      if (success == "true") passed++
      else failed++
      sum_elapsed += elapsed
      if (elapsed > max_elapsed) max_elapsed = elapsed
      if (min_elapsed == 0 || elapsed < min_elapsed) min_elapsed = elapsed
    }
    END {
      if (total == 0) { print "  No samples recorded."; exit }
      avg = sum_elapsed / total
      error_pct = (failed / total) * 100
      printf "  Total requests:  %d\n",  total
      printf "  Passed:          %d\n",  passed
      printf "  Failed:          %d  (%.1f%%)\n", failed, error_pct
      printf "  Avg response:    %.0f ms\n", avg
      printf "  Min response:    %.0f ms\n", min_elapsed
      printf "  Max response:    %.0f ms\n", max_elapsed
    }
  ' "$jtl"
}

# ── compare before/after snapshots ───────────────────────────────────────────
compare_snapshots() {
  local before="$OUT_DIR/metrics-before.json"
  local after="$OUT_DIR/metrics-after.json"

  if [[ ! -f "$before" || ! -f "$after" ]]; then
    return
  fi

  if ! command -v jq &>/dev/null; then
    return
  fi

  local cpu_before cpu_after mem_before mem_after
  cpu_before=$(jq '.summary.total_cpu_cores'  "$before")
  cpu_after=$(jq  '.summary.total_cpu_cores'  "$after")
  mem_before=$(jq '.summary.total_memory_gib' "$before")
  mem_after=$(jq  '.summary.total_memory_gib' "$after")

  echo "  Resource delta (before → after load test):"
  printf "  CPU (cores):  %.2f  →  %.2f\n" "$cpu_before" "$cpu_after"
  printf "  Memory (GiB): %.2f  →  %.2f\n" "$mem_before" "$mem_after"
}

# ── write summary file ────────────────────────────────────────────────────────
write_summary() {
  local summary_file="$OUT_DIR/summary.txt"
  {
    echo "Mifos Gazelle Load Test Summary"
    echo "================================"
    echo "Date:       $(date)"
    echo "Host:       $PH_HOST:$PH_PORT"
    echo "Threads:    $THREADS"
    echo "Duration:   ${DURATION}s"
    echo "Ramp-up:    ${RAMPUP}s"
    echo ""
    echo "Results:"
    parse_jtl "$OUT_DIR/results.jtl"
    echo ""
    compare_snapshots
  } | tee "$summary_file"
}

# ── mock dry-run ──────────────────────────────────────────────────────────────
run_mock() {
  log_warn "MOCK mode — showing what would be executed (JMeter not invoked)"
  echo ""
  echo "  JMeter plan:  $JMX_FILE"
  echo "  Target host:  $PH_HOST:$PH_PORT"
  echo "  Threads:      $THREADS"
  echo "  Duration:     ${DURATION}s"
  echo "  Ramp-up:      ${RAMPUP}s"
  echo "  Output dir:   $OUT_DIR"
  echo ""
  echo "  JMeter command that would run:"
  echo "    jmeter -n -t $JMX_FILE \\"
  echo "      -l $OUT_DIR/results.jtl \\"
  echo "      -e -o $OUT_DIR/report \\"
  echo "      -Jthreads=$THREADS -Jduration=$DURATION -Jrampup=$RAMPUP \\"
  echo "      -Jhost=$PH_HOST -Jport=$PH_PORT"
  echo ""
  echo "  To run for real: remove --mock flag"
  echo "  To install JMeter: see --help"
}

# ── main ──────────────────────────────────────────────────────────────────────
main() {
  echo -e "${BLUE}${BOLD}"
  echo "  Mifos Gazelle — Load Test Runner"
  echo -e "${RESET}"

  if [[ "$MOCK_MODE" == "true" ]]; then
    run_mock
    exit 0
  fi

  check_deps

  mkdir -p "$OUT_DIR"

  log_section "Test configuration"
  log_info "Host:       $PH_HOST:$PH_PORT"
  log_info "Threads:    $THREADS concurrent users"
  log_info "Duration:   ${DURATION}s"
  log_info "Ramp-up:    ${RAMPUP}s"
  log_info "Output:     $OUT_DIR"
  echo ""

  # Snapshot before
  log_section "Pre-test resource snapshot"
  take_snapshot "before"

  # Run the test
  log_section "Running load test"
  if ! run_jmeter; then
    log_error "Load test failed. Check $OUT_DIR/jmeter.log"
    exit 1
  fi

  # Snapshot after
  log_section "Post-test resource snapshot"
  take_snapshot "after"

  # Summary
  log_section "Results"
  write_summary

  echo ""
  echo -e "${GREEN}  Load test complete.${RESET}"
  echo "  HTML report:  $OUT_DIR/report/index.html"
  echo "  Raw results:  $OUT_DIR/results.jtl"
  echo "  Summary:      $OUT_DIR/summary.txt"
  if [[ "$TAKE_SNAPSHOTS" == "true" ]]; then
    echo ""
    echo "  Run TCO estimate on post-test metrics:"
    echo "    python3 src/utils/perf/tco-estimate.py --metrics $OUT_DIR/metrics-after.json"
  fi
  echo ""
}

main "$@"
