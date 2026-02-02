#!/bin/bash
# GAZ-31: Stress test automation for memory leak detection
# Usage: ./stress_test_memory.sh [iterations] [delay]

ITERATIONS=${1:-100}
DELAY=${2:-2}
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"


PAYMENT_SCRIPT="$SCRIPT_DIR/../make-payment.sh"
DATA_LOADER="$SCRIPT_DIR/../data-loading/generate-mifos-vnext-data.py"

# ANSI Colors
BLUE='\033[0;34m'
GREEN='\033[0;32m'
RESET='\033[0m'

echo -e "${BLUE}Starting Gazelle Memory Stress Test (Target: $ITERATIONS cycles)${RESET}"

# Validate dependencies
if [ ! -f "$DATA_LOADER" ] || [ ! -f "$PAYMENT_SCRIPT" ]; then
    echo "Error: Required scripts not found."
    echo "Checked: $DATA_LOADER and $PAYMENT_SCRIPT"
    exit 1
fi

check_memory() {
    if command -v kubectl &> /dev/null; then
        echo "[Memory Usage]"
        kubectl top pods -n mifosx --no-headers 2>/dev/null || echo "  (Metrics not available)"
    fi
}

# Main loop
for ((i=1; i<=ITERATIONS; i++)); do
    echo -e "\n${GREEN}Cycle $i / $ITERATIONS${RESET}"
    
    echo "Running batch data generation..."
    if command -v python3 &> /dev/null; then
        python3 "$DATA_LOADER" --limit 5 > /dev/null 2>&1
    fi

    echo "Processing payments..."
    bash "$PAYMENT_SCRIPT" > /dev/null 2>&1

    check_memory
    sleep "$DELAY"
done

echo -e "\n${GREEN}Test complete.${RESET}"