#!/bin/bash

# Master Performance Testing Script for Mojafos
# This script orchestrates all performance testing components

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="${SCRIPT_DIR}/results/$(date +%Y%m%d_%H%M%S)"
REPORT_DIR="${RESULTS_DIR}/reports"

# Function to display help message
display_help() {
  echo "Mojafos Performance Testing and TCO Estimation Suite"
  echo "Usage: $0 [options]"
  echo ""
  echo "Options:"
  echo "  --phee                       Test PaymentHub EE APIs (default: enabled)"
  echo "  --vnext                      Test Mojaloop vNext (default: enabled)"
  echo "  --tco                        Generate TCO estimation (default: enabled)"
  echo "  --no-phee                    Disable PaymentHub EE testing"
  echo "  --no-vnext                   Disable vNext testing"
  echo "  --no-tco                     Disable TCO estimation"
  echo "  -u, --users NUM              Number of users/threads (default: 10)"
  echo "  -d, --duration NUM           Test duration in seconds (default: 60)"
  echo "  -r, --results-dir DIR        Results directory (default: auto-generated)"
  echo "  -h, --help                   Display this help message"
  echo ""
  echo "Examples:"
  echo "  $0 --users 50 --duration 120"
  echo "  $0 --no-vnext"
  echo "  $0 --no-tco --users 100"
}

# Default values
USERS=10
DURATION=60
TEST_PHEE=true
TEST_VNEXT=true
GENERATE_TCO=true

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --phee)
      TEST_PHEE=true
      shift
      ;;
    --vnext)
      TEST_VNEXT=true
      shift
      ;;
    --tco)
      GENERATE_TCO=true
      shift
      ;;
    --no-phee)
      TEST_PHEE=false
      shift
      ;;
    --no-vnext)
      TEST_VNEXT=false
      shift
      ;;
    --no-tco)
      GENERATE_TCO=false
      shift
      ;;
    -u|--users)
      USERS="$2"
      shift 2
      ;;
    -d|--duration)
      DURATION="$2"
      shift 2
      ;;
    -r|--results-dir)
      RESULTS_DIR="$2"
      shift 2
      ;;
    -h|--help)
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

# Create directories
mkdir -p "${RESULTS_DIR}"
mkdir -p "${REPORT_DIR}"

echo "=========================================================="
echo "Mojafos Performance Testing and TCO Estimation"
echo "=========================================================="
echo "Date: $(date)"
echo "Configuration:"
echo "- Users: ${USERS}"
echo "- Duration: ${DURATION} seconds"
echo "- Results directory: ${RESULTS_DIR}"
echo "- Testing PaymentHub EE: ${TEST_PHEE}"
echo "- Testing vNext: ${TEST_VNEXT}"
echo "- Generating TCO estimate: ${GENERATE_TCO}"
echo "=========================================================="

# Run PaymentHub EE tests if enabled
if [[ "${TEST_PHEE}" == "true" ]]; then
  echo "Running PaymentHub EE performance tests..."
  "${SCRIPT_DIR}/run-performance-tests.sh" \
    --users "${USERS}" \
    --duration "${DURATION}" \
    --test-plan "${SCRIPT_DIR}/paymentHubEE.jmx" \
    --results-dir "${RESULTS_DIR}/phee"
  echo "PaymentHub EE tests completed."
fi

# Run vNext tests if enabled
if [[ "${TEST_VNEXT}" == "true" ]]; then
  echo "Running vNext performance tests..."
  "${SCRIPT_DIR}/vnext-performance-integration.sh" \
    --users "${USERS}" \
    --duration "${DURATION}" \
    --results-dir "${RESULTS_DIR}/vnext"
  echo "vNext tests completed."
fi

# Generate TCO estimation if enabled
if [[ "${GENERATE_TCO}" == "true" ]]; then
  echo "Generating TCO estimation..."
  
  if [[ "${TEST_PHEE}" == "true" && -f "${RESULTS_DIR}/phee/results.jtl" ]]; then
    "${SCRIPT_DIR}/estimate-tco.sh" \
      --results "${RESULTS_DIR}/phee/results.jtl" \
      --output "${REPORT_DIR}/phee-tco-estimate.json"
  fi
  
  if [[ "${TEST_VNEXT}" == "true" && -f "${RESULTS_DIR}/vnext/vnext-results.jtl" ]]; then
    "${SCRIPT_DIR}/estimate-tco.sh" \
      --results "${RESULTS_DIR}/vnext/vnext-results.jtl" \
      --output "${REPORT_DIR}/vnext-tco-estimate.json"
  fi
  
  echo "TCO estimation completed."
fi

# Generate combined report
echo "Generating final report..."
cat > "${REPORT_DIR}/combined-report.md" << EOF
# Mojafos Performance Testing and TCO Estimation Report

## Test Configuration
- Date: $(date)
- Users: ${USERS}
- Duration: ${DURATION} seconds

## Summary

EOF

if [[ "${TEST_PHEE}" == "true" ]]; then
  echo "### PaymentHub EE Results" >> "${REPORT_DIR}/combined-report.md"
  echo "- [Detailed JMeter Results](../phee/html-report/index.html)" >> "${REPORT_DIR}/combined-report.md"
  
  if [[ "${GENERATE_TCO}" == "true" && -f "${REPORT_DIR}/phee-tco-estimate.json" ]]; then
    echo "- [TCO Estimation](phee-tco-estimate.json)" >> "${REPORT_DIR}/combined-report.md"
    
    # Extract key TCO metrics
    if command -v jq &> /dev/null; then
      PHEE_MONTHLY=$(jq -r '.costs.instanceMonthlyCost' "${REPORT_DIR}/phee-tco-estimate.json")
      PHEE_ANNUAL=$(jq -r '.recommendations.estimatedAnnualCost' "${REPORT_DIR}/phee-tco-estimate.json")
      
      echo "  - Monthly Cost: \$${PHEE_MONTHLY}" >> "${REPORT_DIR}/combined-report.md"
      echo "  - Annual Cost: \$${PHEE_ANNUAL}" >> "${REPORT_DIR}/combined-report.md"
    fi
  fi
fi

if [[ "${TEST_VNEXT}" == "true" ]]; then
  echo "### vNext Results" >> "${REPORT_DIR}/combined-report.md"
  echo "- [Detailed Report](../vnext/integrated-report.md)" >> "${REPORT_DIR}/combined-report.md"
  
  if [[ "${GENERATE_TCO}" == "true" && -f "${REPORT_DIR}/vnext-tco-estimate.json" ]]; then
    echo "- [TCO Estimation](vnext-tco-estimate.json)" >> "${REPORT_DIR}/combined-report.md"
    
    # Extract key TCO metrics
    if command -v jq &> /dev/null; then
      VNEXT_MONTHLY=$(jq -r '.costs.instanceMonthlyCost' "${REPORT_DIR}/vnext-tco-estimate.json")
      VNEXT_ANNUAL=$(jq -r '.recommendations.estimatedAnnualCost' "${REPORT_DIR}/vnext-tco-estimate.json")
      
      echo "  - Monthly Cost: \$${VNEXT_MONTHLY}" >> "${REPORT_DIR}/combined-report.md"
      echo "  - Annual Cost: \$${VNEXT_ANNUAL}" >> "${REPORT_DIR}/combined-report.md"
    fi
  fi
fi

if [[ "${GENERATE_TCO}" == "true" ]]; then
  echo "### Combined TCO Estimation" >> "${REPORT_DIR}/combined-report.md"
  
  if command -v jq &> /dev/null && [[ -f "${REPORT_DIR}/phee-tco-estimate.json" ]] && [[ -f "${REPORT_DIR}/vnext-tco-estimate.json" ]]; then
    PHEE_MONTHLY=$(jq -r '.costs.instanceMonthlyCost' "${REPORT_DIR}/phee-tco-estimate.json")
    VNEXT_MONTHLY=$(jq -r '.costs.instanceMonthlyCost' "${REPORT_DIR}/vnext-tco-estimate.json")
    COMBINED_MONTHLY=$(echo "$PHEE_MONTHLY + $VNEXT_MONTHLY" | bc)
    COMBINED_ANNUAL=$(echo "$COMBINED_MONTHLY * 12" | bc)
    
    echo "- Monthly Cost: \$${COMBINED_MONTHLY}" >> "${REPORT_DIR}/combined-report.md"
    echo "- Annual Cost: \$${COMBINED_ANNUAL}" >> "${REPORT_DIR}/combined-report.md"
    echo "- 3-Year Cost: \$$(echo "$COMBINED_ANNUAL * 3" | bc)" >> "${REPORT_DIR}/combined-report.md"
  else
    echo "- TCO data not complete for both systems." >> "${REPORT_DIR}/combined-report.md"
  fi
fi

echo "## Recommendations" >> "${REPORT_DIR}/combined-report.md"
echo "
Based on the performance tests and TCO estimation, consider the following recommendations:

1. **Resource Allocation**: Adjust instance types based on the performance metrics
2. **Scaling Strategy**: Implement auto-scaling for handling peak loads
3. **Optimization**: Review the response time patterns to identify potential bottlenecks
4. **Cost Reduction**: Consider reserved instances for long-term deployments
" >> "${REPORT_DIR}/combined-report.md"

echo "=========================================================="
echo "Performance testing and TCO estimation completed."
echo "Results and reports available at: ${RESULTS_DIR}"
echo "Combined report: ${REPORT_DIR}/combined-report.md"
echo "==========================================================" 