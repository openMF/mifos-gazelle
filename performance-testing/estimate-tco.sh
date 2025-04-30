#!/bin/bash

# TCO (Total Cost of Ownership) Estimation Tool
# This script analyzes JMeter test results and estimates cloud infrastructure costs

set -e

# Default values
RESULTS_FILE=""
OUTPUT_FILE="tco-estimate.json"
INSTANCE_TYPE="t3.xlarge"
REGION="us-east-1"
DURATION_DAYS=30

# AWS estimated monthly costs for various instance types (in USD)
declare -A INSTANCE_COSTS
INSTANCE_COSTS["t3.medium"]=30.37
INSTANCE_COSTS["t3.large"]=60.74
INSTANCE_COSTS["t3.xlarge"]=121.47
INSTANCE_COSTS["t3.2xlarge"]=242.94
INSTANCE_COSTS["m5.xlarge"]=140.16
INSTANCE_COSTS["m5.2xlarge"]=280.32
INSTANCE_COSTS["c5.xlarge"]=134.14
INSTANCE_COSTS["c5.2xlarge"]=268.27

# Function to display help message
display_help() {
  echo "Usage: $0 [options]"
  echo ""
  echo "Options:"
  echo "  -r, --results FILE         JMeter results file (.jtl)"
  echo "  -o, --output FILE          Output file for TCO estimate (default: tco-estimate.json)"
  echo "  -i, --instance TYPE        Instance type (default: t3.xlarge)"
  echo "  -g, --region REGION        Cloud region (default: us-east-1)"
  echo "  -d, --days DAYS            Duration in days (default: 30)"
  echo "  --help                     Display this help message"
  echo ""
  echo "Available instance types:"
  for instance in "${!INSTANCE_COSTS[@]}"; do
    echo "  $instance: $${INSTANCE_COSTS[$instance]}/month"
  done
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    -r|--results)
      RESULTS_FILE="$2"
      shift 2
      ;;
    -o|--output)
      OUTPUT_FILE="$2"
      shift 2
      ;;
    -i|--instance)
      INSTANCE_TYPE="$2"
      shift 2
      ;;
    -g|--region)
      REGION="$2"
      shift 2
      ;;
    -d|--days)
      DURATION_DAYS="$2"
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

# Check if required parameters are provided
if [[ -z "$RESULTS_FILE" ]]; then
  echo "Error: JMeter results file is required."
  display_help
  exit 1
fi

if [[ ! -f "$RESULTS_FILE" ]]; then
  echo "Error: JMeter results file not found: $RESULTS_FILE"
  exit 1
fi

# Check if instance type is valid
if [[ -z "${INSTANCE_COSTS[$INSTANCE_TYPE]}" ]]; then
  echo "Error: Invalid instance type: $INSTANCE_TYPE"
  display_help
  exit 1
fi

# Calculate average response time and throughput from JMeter results
echo "Analyzing JMeter results: $RESULTS_FILE"

# Extract average response time (assuming column 1 is timestamp and column 2 is elapsed time)
AVG_RESPONSE_TIME=$(awk -F ',' 'NR>1 {sum+=$2; count++} END {print sum/count}' "$RESULTS_FILE")
AVG_RESPONSE_TIME=${AVG_RESPONSE_TIME:-0}

# Extract throughput (transactions per second)
START_TIME=$(awk -F ',' 'NR==2 {print $1}' "$RESULTS_FILE")
END_TIME=$(awk -F ',' 'END {print $1}' "$RESULTS_FILE")
TOTAL_TRANSACTIONS=$(wc -l < "$RESULTS_FILE")
TOTAL_TRANSACTIONS=$((TOTAL_TRANSACTIONS - 1)) # Subtract header line
TEST_DURATION=$((END_TIME - START_TIME))
TEST_DURATION=${TEST_DURATION:-1} # Avoid division by zero
THROUGHPUT=$(echo "scale=2; $TOTAL_TRANSACTIONS / ($TEST_DURATION / 1000)" | bc)
THROUGHPUT=${THROUGHPUT:-0}

# Calculate required instances based on performance metrics
# This is a simplified calculation - adjust according to your specific requirements
TARGET_THROUGHPUT_PER_INSTANCE=50
REQUIRED_INSTANCES=$(echo "scale=0; ($THROUGHPUT / $TARGET_THROUGHPUT_PER_INSTANCE) + 0.9" | bc | cut -d '.' -f 1)
REQUIRED_INSTANCES=$((REQUIRED_INSTANCES < 1 ? 1 : REQUIRED_INSTANCES))

# Calculate TCO
INSTANCE_MONTHLY_COST=${INSTANCE_COSTS[$INSTANCE_TYPE]}
DAILY_COST=$(echo "scale=2; $INSTANCE_MONTHLY_COST / 30" | bc)
MONTHLY_COST=$(echo "scale=2; $DAILY_COST * $REQUIRED_INSTANCES * 30" | bc)
TOTAL_COST=$(echo "scale=2; $DAILY_COST * $REQUIRED_INSTANCES * $DURATION_DAYS" | bc)

# Add storage, network, and other costs (simplified)
STORAGE_COST_PER_GB=0.10
ESTIMATED_DATA_GB=20
STORAGE_MONTHLY_COST=$(echo "scale=2; $STORAGE_COST_PER_GB * $ESTIMATED_DATA_GB" | bc)
STORAGE_TOTAL_COST=$(echo "scale=2; $STORAGE_MONTHLY_COST * $DURATION_DAYS / 30" | bc)

NETWORK_COST_PER_GB=0.09
ESTIMATED_NETWORK_GB=50
NETWORK_MONTHLY_COST=$(echo "scale=2; $NETWORK_COST_PER_GB * $ESTIMATED_NETWORK_GB" | bc)
NETWORK_TOTAL_COST=$(echo "scale=2; $NETWORK_MONTHLY_COST * $DURATION_DAYS / 30" | bc)

# Calculate grand total
GRAND_TOTAL=$(echo "scale=2; $TOTAL_COST + $STORAGE_TOTAL_COST + $NETWORK_TOTAL_COST" | bc)

# Generate output file
cat > "$OUTPUT_FILE" << EOF
{
  "performance": {
    "averageResponseTime": $AVG_RESPONSE_TIME,
    "throughput": $THROUGHPUT,
    "totalTransactions": $TOTAL_TRANSACTIONS
  },
  "infrastructure": {
    "instanceType": "$INSTANCE_TYPE",
    "region": "$REGION",
    "requiredInstances": $REQUIRED_INSTANCES,
    "durationDays": $DURATION_DAYS
  },
  "costs": {
    "instanceCostPerDay": $DAILY_COST,
    "instanceMonthlyCost": $MONTHLY_COST,
    "instanceTotalCost": $TOTAL_COST,
    "storageMonthlyCost": $STORAGE_MONTHLY_COST,
    "storageTotalCost": $STORAGE_TOTAL_COST,
    "networkMonthlyCost": $NETWORK_MONTHLY_COST,
    "networkTotalCost": $NETWORK_TOTAL_COST,
    "grandTotal": $GRAND_TOTAL
  },
  "recommendations": {
    "optimalInstanceType": "$INSTANCE_TYPE",
    "estimatedAnnualCost": $(echo "scale=2; $MONTHLY_COST * 12" | bc),
    "scalingRecommendation": "$([ $REQUIRED_INSTANCES -gt 1 ] && echo "Consider using auto-scaling groups" || echo "Single instance is sufficient")"
  }
}
EOF

echo "TCO estimation complete. Results saved to: $OUTPUT_FILE" 