#!/bin/bash
# End-to-end Mastercard payment test and tracking

set -e

# Default values
CONFIG_FILE="$HOME/tomconfig.ini"
CSV_FILE=""
TENANT="greenbank"
WAIT_TIME=5

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -c|--config)
            CONFIG_FILE="$2"
            shift 2
            ;;
        -f|--file)
            CSV_FILE="$2"
            shift 2
            ;;
        -t|--tenant)
            TENANT="$2"
            shift 2
            ;;
        -w|--wait)
            WAIT_TIME="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  -c, --config FILE    Config file path (default: ~/tomconfig.ini)"
            echo "  -f, --file FILE      CSV file to submit (required)"
            echo "  -t, --tenant TENANT  Tenant name (default: greenbank)"
            echo "  -w, --wait SECONDS   Wait time after submission (default: 5)"
            echo "  -h, --help           Show this help message"
            echo ""
            echo "Example:"
            echo "  $0 -c ~/tomconfig.ini -f bulk-gazelle-mastercard-6.csv -t greenbank"
            exit 0
            ;;
        *)
            CSV_FILE="$1"
            shift
            ;;
    esac
done

echo "======================================================================"
echo "MASTERCARD END-TO-END PAYMENT TEST"
echo "======================================================================"
echo

# Validate inputs
if [ -z "$CSV_FILE" ]; then
    echo "❌ Error: CSV file not specified"
    echo "Usage: $0 -c <config-file> -f <csv-file>"
    echo "Run '$0 --help' for more information"
    exit 1
fi

if [ ! -f "$CSV_FILE" ]; then
    echo "❌ Error: CSV file '$CSV_FILE' not found"
    exit 1
fi

if [ ! -f "$CONFIG_FILE" ]; then
    echo "❌ Error: Config file '$CONFIG_FILE' not found"
    exit 1
fi

echo "📄 CSV File: $CSV_FILE"
echo "⚙️  Config File: $CONFIG_FILE"
echo "👤 Tenant: $TENANT"
echo "🚀 Submitting batch..."
echo

# Submit batch
./submit-batch.py -c "$CONFIG_FILE" -f "$CSV_FILE" --tenant "$TENANT" --govstack --registering-institution "$TENANT"

echo
echo "⏳ Waiting for processing ($WAIT_TIME seconds)..."
sleep "$WAIT_TIME"

echo
echo "📊 Tracking payments..."
echo

# Track payments
python3 ../mastercard-payment-tracker.py -c "$CONFIG_FILE" -f "$CSV_FILE" --minutes 1

echo
echo "======================================================================"
echo "✅ End-to-end test complete!"
echo "======================================================================"
echo
echo "To verify manually:"
echo "  • Connector logs:  kubectl logs -n mastercard-demo -l app=ph-ee-connector-mastercard-cbs --tail=50"
echo "  • Zeebe Operate:   http://zeebe-operate.mifos.gazelle.test (search: MastercardFundTransfer)"
echo ""
echo "To run again:"
echo "  $0 -c $CONFIG_FILE -f $CSV_FILE -t $TENANT"
echo
