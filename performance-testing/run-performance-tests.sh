#!/bin/bash

# Performance Testing Automation Script for Mojafos
# This script automates running JMeter tests and collecting results

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="${SCRIPT_DIR}/results/$(date +%Y%m%d_%H%M%S)"
JMETER_PATH="jmeter" # Assumes JMeter is in PATH, modify if needed

# Function to display help message
display_help() {
  echo "Usage: $0 [options]"
  echo ""
  echo "Options:"
  echo "  -t, --test-plan FILE       JMeter test plan file (default: paymentHubEE.jmx)"
  echo "  -u, --users NUM            Number of users/threads (default: 10)"
  echo "  -r, --ramp-up NUM          Ramp-up period in seconds (default: 5)"
  echo "  -d, --duration NUM         Test duration in seconds (default: 60)"
  echo "  -h, --host STRING          Host to test (default: paymenthub.local)"
  echo "  -p, --protocol STRING      Protocol [http|https] (default: https)"
  echo "  --help                     Display this help message"
  echo ""
}

# Default values
TEST_PLAN="${SCRIPT_DIR}/paymentHubEE.jmx"
USERS=10
RAMP_UP=5
DURATION=60
HOST="paymenthub.local"
PROTOCOL="https"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--test-plan)
      TEST_PLAN="$2"
      shift 2
      ;;
    -u|--users)
      USERS="$2"
      shift 2
      ;;
    -r|--ramp-up)
      RAMP_UP="$2"
      shift 2
      ;;
    -d|--duration)
      DURATION="$2"
      shift 2
      ;;
    -h|--host)
      HOST="$2"
      shift 2
      ;;
    -p|--protocol)
      PROTOCOL="$2"
      shift 2
      ;;
    --help)
      display_help
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      display_help
      exit 1
      ;;
  esac
done

# Create results directory
mkdir -p "${RESULTS_DIR}"
echo "Results will be saved to: ${RESULTS_DIR}"

# Run JMeter test
echo "Starting JMeter test with ${USERS} users, ${RAMP_UP}s ramp-up, ${DURATION}s duration"
${JMETER_PATH} -n -t "${TEST_PLAN}" \
  -l "${RESULTS_DIR}/results.jtl" \
  -j "${RESULTS_DIR}/jmeter.log" \
  -Jhost="${HOST}" \
  -Jscheme="${PROTOCOL}" \
  -Jthreads="${USERS}" \
  -Jrampup="${RAMP_UP}" \
  -Jduration="${DURATION}"

# Generate HTML report
echo "Generating HTML report..."
${JMETER_PATH} -g "${RESULTS_DIR}/results.jtl" -o "${RESULTS_DIR}/html-report"

echo "Performance test completed. Results available at ${RESULTS_DIR}"
echo "HTML report: ${RESULTS_DIR}/html-report/index.html"

# Generate TCO estimation
echo "Generating TCO estimation..."
${SCRIPT_DIR}/estimate-tco.sh -r "${RESULTS_DIR}/results.jtl" -o "${RESULTS_DIR}/tco-estimate.json"

echo "All tasks completed successfully." 