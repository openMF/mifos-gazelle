#!/bin/bash

# vNext Performance Tools Integration Script
# This script integrates with Mojaloop vNext performance tools
# as described in the project requirements

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="${SCRIPT_DIR}/results/vnext/$(date +%Y%m%d_%H%M%S)"
NDOGO_LOOP_REPO="https://github.com/tdaly61/ndogo-loop.git"
NDOGO_LOOP_BRANCH="dev"
VNEXT_TOOLS_REPO="https://github.com/mojaloop/platform-shared-tools.git"
VNEXT_TOOLS_BRANCH="main"

# Function to display help message
display_help() {
  echo "Usage: $0 [options]"
  echo ""
  echo "Options:"
  echo "  -r, --results-dir DIR       Directory to store results (default: auto-generated)"
  echo "  -n, --ndogo-branch BRANCH   ndogo-loop branch (default: dev)"
  echo "  -v, --vnext-branch BRANCH   vNext tools branch (default: main)"
  echo "  -u, --users NUM             Number of users/threads (default: 10)"
  echo "  -d, --duration NUM          Test duration in seconds (default: 60)"
  echo "  --help                      Display this help message"
  echo ""
}

# Default values
USERS=10
DURATION=60
TMP_DIR="/tmp/vnext-perf-$(date +%s)"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    -r|--results-dir)
      RESULTS_DIR="$2"
      shift 2
      ;;
    -n|--ndogo-branch)
      NDOGO_LOOP_BRANCH="$2"
      shift 2
      ;;
    -v|--vnext-branch)
      VNEXT_TOOLS_BRANCH="$2"
      shift 2
      ;;
    -u|--users)
      USERS="$2"
      shift 2
      ;;
    -d|--duration)
      DURATION="$2"
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

# Create temporary directory for cloning repositories
mkdir -p "${TMP_DIR}"
cd "${TMP_DIR}"

# Function to check if a command exists
command_exists() {
  command -v "$1" >/dev/null 2>&1
}

# Check prerequisites
echo "Checking prerequisites..."
for cmd in git curl jq docker kubectl; do
  if ! command_exists "$cmd"; then
    echo "Error: Required command '$cmd' not found"
    exit 1
  fi
done

# Clone repositories
echo "Cloning ndogo-loop repository..."
git clone --branch "${NDOGO_LOOP_BRANCH}" "${NDOGO_LOOP_REPO}" ndogo-loop

echo "Cloning vNext tools repository..."
git clone --branch "${VNEXT_TOOLS_BRANCH}" "${VNEXT_TOOLS_REPO}" vnext-tools

# Check if Mojaloop vNext is deployed
echo "Checking if Mojaloop vNext is deployed..."
if ! kubectl get namespace mojaloop >/dev/null 2>&1; then
  echo "Warning: Mojaloop vNext namespace not found. Make sure vNext is deployed."
fi

# Run vNext performance tests
echo "Running vNext performance tests with ${USERS} users for ${DURATION} seconds..."

# Get vNext service endpoints
VNEXT_ADMIN_URL=$(kubectl get ingress -n mojaloop vnextadmin-ing -o jsonpath='{.spec.rules[0].host}' 2>/dev/null || echo "vnextadmin.mifos.gazelle.test")
FSPIOP_URL=$(kubectl get ingress -n mojaloop fspiop-ing -o jsonpath='{.spec.rules[0].host}' 2>/dev/null || echo "fspiop.mifos.gazelle.test")

echo "Using vNext endpoints:"
echo "- Admin UI: ${VNEXT_ADMIN_URL}"
echo "- FSPIOP API: ${FSPIOP_URL}"

# Get vNext native performance tools from ndogo-loop
if [ -f "${TMP_DIR}/ndogo-loop/perf/run-perf-tests.sh" ]; then
  echo "Running native vNext performance tests..."
  cd "${TMP_DIR}/ndogo-loop/perf"
  
  # Modify configuration for our scenario
  if [ -f "config.json" ]; then
    jq '.concurrency = '${USERS}' | .duration = '${DURATION}'' config.json > config.json.tmp
    mv config.json.tmp config.json
  fi
  
  # Execute the performance tests and redirect output to our results directory
  ./run-perf-tests.sh > "${RESULTS_DIR}/vnext-native-perf.log" 2>&1 || echo "Warning: vNext native performance tests exited with non-zero code"
  
  # Copy the results to our results directory
  if [ -d "results" ]; then
    cp -r results/* "${RESULTS_DIR}/"
  fi
else
  echo "Warning: Native vNext performance tests not found in ndogo-loop repository"
  echo "Using alternative approach with JMeter and the vNext API..."
  
  # Create a basic JMeter test plan for vNext
  cat > "${RESULTS_DIR}/vnext-basic.jmx" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<jmeterTestPlan version="1.2" properties="5.0" jmeter="5.6.3">
  <hashTree>
    <TestPlan guiclass="TestPlanGui" testclass="TestPlan" testname="vNext Test Plan">
      <elementProp name="TestPlan.user_defined_variables" elementType="Arguments" guiclass="ArgumentsPanel" testclass="Arguments" testname="User Defined Variables">
        <collectionProp name="Arguments.arguments"/>
      </elementProp>
    </TestPlan>
    <hashTree>
      <ThreadGroup guiclass="ThreadGroupGui" testclass="ThreadGroup" testname="vNext APIs">
        <intProp name="ThreadGroup.num_threads">${USERS}</intProp>
        <intProp name="ThreadGroup.ramp_time">5</intProp>
        <boolProp name="ThreadGroup.same_user_on_next_iteration">true</boolProp>
        <stringProp name="ThreadGroup.on_sample_error">continue</stringProp>
        <elementProp name="ThreadGroup.main_controller" elementType="LoopController" guiclass="LoopControlPanel" testclass="LoopController" testname="Loop Controller">
          <stringProp name="LoopController.loops">1</stringProp>
          <boolProp name="LoopController.continue_forever">false</boolProp>
        </elementProp>
      </ThreadGroup>
      <hashTree>
        <HTTPSamplerProxy guiclass="HttpTestSampleGui" testclass="HTTPSamplerProxy" testname="Health Check">
          <stringProp name="HTTPSampler.domain">${FSPIOP_URL}</stringProp>
          <stringProp name="HTTPSampler.protocol">http</stringProp>
          <stringProp name="HTTPSampler.path">/health</stringProp>
          <stringProp name="HTTPSampler.method">GET</stringProp>
          <boolProp name="HTTPSampler.follow_redirects">true</boolProp>
          <boolProp name="HTTPSampler.use_keepalive">true</boolProp>
        </HTTPSamplerProxy>
        <hashTree/>
      </hashTree>
    </hashTree>
  </hashTree>
</jmeterTestPlan>
EOF

  # Run JMeter with the basic vNext test plan if JMeter is available
  if command_exists jmeter; then
    echo "Running JMeter with basic vNext test plan..."
    jmeter -n -t "${RESULTS_DIR}/vnext-basic.jmx" -l "${RESULTS_DIR}/vnext-results.jtl" -j "${RESULTS_DIR}/jmeter.log"
  else
    echo "Warning: JMeter not found. Cannot run basic vNext performance tests."
  fi
fi

# Generate a simple report with metrics from both systems
echo "Generating integrated performance report..."
cat > "${RESULTS_DIR}/integrated-report.md" << EOF
# Integrated Performance Test Report

## Test Configuration
- Date: $(date)
- Users: ${USERS}
- Duration: ${DURATION} seconds
- vNext URL: ${FSPIOP_URL}
- PaymentHub URL: paymenthub.local

## Test Results
EOF

if [ -f "${RESULTS_DIR}/vnext-native-perf.log" ]; then
  echo "vNext native test results found. Adding to report..."
  echo "
### vNext Native Performance Results
\`\`\`
$(grep -A 20 "Results:" "${RESULTS_DIR}/vnext-native-perf.log" || echo "No results found in log")
\`\`\`
" >> "${RESULTS_DIR}/integrated-report.md"
fi

if [ -f "${RESULTS_DIR}/vnext-results.jtl" ]; then
  echo "vNext JMeter results found. Adding to report..."
  echo "
### vNext JMeter Performance Results
\`\`\`
$(head -n 20 "${RESULTS_DIR}/vnext-results.jtl")
\`\`\`
" >> "${RESULTS_DIR}/integrated-report.md"
fi

# Cleanup
echo "Cleaning up temporary files..."
rm -rf "${TMP_DIR}"

echo "vNext performance integration completed. Results available at: ${RESULTS_DIR}"
echo "Integrated report: ${RESULTS_DIR}/integrated-report.md" 