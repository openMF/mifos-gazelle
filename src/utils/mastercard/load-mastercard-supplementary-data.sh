#!/bin/bash
#
# Load Mastercard CBS Supplementary Data
#
# Populates the mastercard_cbs_supplementary_data table with regulatory/compliance
# information needed for Mastercard CBS cross-border payments.
#
# Usage:
#     ./load-mastercard-supplementary-data.sh -c ~/tomconfig.ini [--regenerate]
#

set -e

# Source helpers from mifos-gazelle
HELPERS_PATH="$HOME/mifos-gazelle/src/utils/helpers.sh"
if [[ -f "$HELPERS_PATH" ]]; then
    source "$HELPERS_PATH"
else
    echo "Error: helpers.sh not found at $HELPERS_PATH"
    exit 1
fi

# Override run_as_user if we're already the k8s user
run_as_k8s_user() {
    local command="$1"
    if [[ "$(whoami)" == "$k8s_user" ]]; then
        # Already the right user, just run with KUBECONFIG
        KUBECONFIG="$kubeconfig_path" eval "$command"
    else
        # Use the helper function
        run_as_user "$command"
    fi
}

# Demo data arrays
COUNTRIES=("US" "GB" "ES" "IT" "FR" "DE" "JP" "CN" "SA" "IN")

# Banks by country index (name|swift|branch)
BANKS_US=("JPMorgan Chase Bank|CHASUS33|New York Main" "Bank of America|BOFAUS3N|Los Angeles" "Wells Fargo Bank|WFBIUS6S|San Francisco")
BANKS_GB=("Barclays Bank|BARCGB22|London Main" "HSBC Bank|HSBCGB2L|Canary Wharf" "Lloyds Bank|LOYDGB2L|City of London")
BANKS_ES=("Banco Santander|BSCHESMM|Madrid Central" "BBVA|BBVAESMM|Barcelona" "CaixaBank|CAIXESBB|Valencia")
BANKS_IT=("UniCredit Bank|UNCRITMM|Milan Main" "Intesa Sanpaolo|BCITITMM|Turin" "Banco BPM|BAPPIT21|Rome")
BANKS_FR=("BNP Paribas|BNPAFRPP|Paris La Defense" "Societe Generale|SOGEFRPP|Paris" "Credit Agricole|AGRIFRPP|Montpellier")
BANKS_DE=("Deutsche Bank|DEUTDEFF|Frankfurt Main" "Commerzbank|COBADEFF|Frankfurt" "DZ Bank|GENODEFF|Frankfurt")
BANKS_JP=("Mitsubishi UFJ Bank|BOTKJPJT|Tokyo Main" "Sumitomo Mitsui Banking Corp|SMBCJPJT|Tokyo" "Mizuho Bank|MHCBJPJT|Tokyo")
BANKS_CN=("Bank of China|BKCHCNBJ|Beijing Main" "Industrial and Commercial Bank|ICBKCNBJ|Shanghai" "China Construction Bank|PCBCCNBJ|Shenzhen")
BANKS_SA=("Al Rajhi Bank|RJHISARI|Riyadh Main" "Saudi National Bank|NCBKSAJE|Jeddah" "Riyad Bank|RIBLSARI|Riyadh")
BANKS_IN=("HDFC Bank|HDFCINBB|Mumbai Main" "ICICI Bank|ICICINBB|New Delhi" "State Bank of India|SBININBB|Bangalore")

# Names by country (first|last)
NAMES_US=("John|Doe" "Mary|Smith" "James|Johnson")
NAMES_GB=("William|Brown" "Emma|Wilson" "Oliver|Taylor")
NAMES_ES=("Carlos|Rodriguez" "Maria|Garcia" "Antonio|Martinez")
NAMES_IT=("Marco|Rossi" "Giulia|Romano" "Luca|Ferrari")
NAMES_FR=("Pierre|Dubois" "Marie|Leroy" "Jean|Moreau")
NAMES_DE=("Hans|Mueller" "Anna|Schmidt" "Klaus|Weber")
NAMES_JP=("Yuki|Tanaka" "Hiro|Sato" "Akiko|Suzuki")
NAMES_CN=("Li|Wei" "Wang|Ming" "Zhang|Hua")
NAMES_SA=("Ahmed|Hassan" "Fatima|Al-Saud" "Mohammed|Al-Rashid")
NAMES_IN=("Priya|Sharma" "Raj|Patel" "Deepa|Kumar")

# Cities by country
CITIES_US=("New York" "Los Angeles" "Chicago" "Houston")
CITIES_GB=("London" "Manchester" "Birmingham" "Edinburgh")
CITIES_ES=("Madrid" "Barcelona" "Valencia" "Seville")
CITIES_IT=("Rome" "Milan" "Naples" "Turin")
CITIES_FR=("Paris" "Marseille" "Lyon" "Toulouse")
CITIES_DE=("Berlin" "Hamburg" "Munich" "Frankfurt")
CITIES_JP=("Tokyo" "Osaka" "Kyoto" "Yokohama")
CITIES_CN=("Beijing" "Shanghai" "Guangzhou" "Shenzhen")
CITIES_SA=("Riyadh" "Jeddah" "Mecca" "Medina")
CITIES_IN=("Mumbai" "Delhi" "Bangalore" "Chennai")

# Streets by country
declare -A STREETS=(
    ["US"]="Main Street"
    ["GB"]="High Street"
    ["ES"]="Calle Mayor"
    ["IT"]="Via Roma"
    ["FR"]="Rue de la Paix"
    ["DE"]="Hauptstrasse"
    ["JP"]="Chuo-dori"
    ["CN"]="Nanjing Road"
    ["SA"]="King Fahd Road"
    ["IN"]="MG Road"
)

# Email domains by country
declare -A EMAIL_DOMAINS=(
    ["US"]="example.com"
    ["GB"]="example.co.uk"
    ["ES"]="example.es"
    ["IT"]="example.it"
    ["FR"]="example.fr"
    ["DE"]="example.de"
    ["JP"]="example.jp"
    ["CN"]="example.cn"
    ["SA"]="example.sa"
    ["IN"]="example.in"
)

CONFIG_FILE=""
REGENERATE=false
DROP_TABLE=false
NAMESPACE="paymenthub"
INFRA_NAMESPACE="infra"
MIFOS_MYSQL_POD="mysql-0"
DEBUG=false

usage() {
    echo "Usage: $0 -c <config_file> [OPTIONS]"
    echo ""
    echo "Required:"
    echo "  -c, --config     Path to config file (e.g., ~/tomconfig.ini)"
    echo ""
    echo "Options:"
    echo "  -n, --namespace  Kubernetes namespace (default: paymenthub)"
    echo "  -d, --debug      Enable debug output showing detailed operations"
    echo ""
    echo "Data Management:"
    echo "  --regenerate     Delete existing data and reload (keeps table structure)"
    echo "  --drop-table     Drop and recreate table with new schema (USE WITH CAUTION)"
    echo ""
    echo "Examples:"
    echo "  # Initial load (creates table if not exists, loads data)"
    echo "  $0 -c ~/tomconfig.ini"
    echo ""
    echo "  # Reload data only (keeps existing schema)"
    echo "  $0 -c ~/tomconfig.ini --regenerate"
    echo ""
    echo "  # Drop table and recreate with PHEE-351 schema (for schema upgrades)"
    echo "  $0 -c ~/tomconfig.ini --drop-table"
    echo ""
    echo "  # Debug mode to see all SQL operations"
    echo "  $0 -c ~/tomconfig.ini --drop-table -d"
    echo ""
    echo "Note: --drop-table will DELETE ALL DATA and recreate the table."
    echo "      Use this when upgrading from old schema to PHEE-351 compliant schema."
    exit 1
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -c|--config)
            CONFIG_FILE="$2"
            shift 2
            ;;
        -n|--namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        --regenerate)
            REGENERATE=true
            shift
            ;;
        --drop-table)
            DROP_TABLE=true
            shift
            ;;
        -d|--debug)
            DEBUG=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

if [[ -z "$CONFIG_FILE" ]]; then
    echo "Error: Config file required"
    usage
fi

# Expand tilde
CONFIG_FILE="${CONFIG_FILE/#\~/$HOME}"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Error: Config file not found: $CONFIG_FILE"
    exit 1
fi

# Parse INI file
get_ini_value() {
    local section=$1
    local key=$2
    local file=$3

    awk -F ' *= *' -v section="[$section]" -v key="$key" '
        $0 == section { in_section = 1; next }
        /^\[/ { in_section = 0 }
        in_section && $1 == key { print $2; exit }
    ' "$file"
}

# Get element from array using a deterministic hash of seed string
# Produces the same result for the same (array, seed) pair across runs
deterministic_element() {
    local -n arr=$1
    local seed=$2
    local hash
    hash=$(echo -n "$seed" | cksum | cut -d' ' -f1)
    local idx=$((hash % ${#arr[@]}))
    echo "${arr[$idx]}"
}

# Look up real client name from MifosX for a given MSISDN + institution.
# Returns "FirstName|LastName" if found, empty string if not found.
get_mifos_client_name() {
    local msisdn=$1
    local institution=$2
    local db="${institution,,}"  # institution code == MifosX database name

    local MIFOS_DB_PASS
    MIFOS_DB_PASS=$(run_as_k8s_user "kubectl exec -n $INFRA_NAMESPACE $MIFOS_MYSQL_POD -- printenv MYSQL_ROOT_PASSWORD" 2>/dev/null)
    if [[ -z "$MIFOS_DB_PASS" ]]; then
        return
    fi

    local result
    result=$(run_as_k8s_user "kubectl exec -n $INFRA_NAMESPACE $MIFOS_MYSQL_POD -- mysql -uroot -p'$MIFOS_DB_PASS' $db -N -s -e \"SELECT firstname, lastname FROM m_client WHERE mobile_no = '$msisdn' LIMIT 1\"" 2>/dev/null)
    if [[ -n "$result" ]]; then
        local fn ln
        fn=$(echo "$result" | cut -f1)
        ln=$(echo "$result" | cut -f2)
        echo "${fn}|${ln}"
    fi
}

# Map institution to country
map_institution_to_country() {
    local institution=$1
    local inst_lower=$(echo "$institution" | tr '[:upper:]' '[:lower:]')

    case "$inst_lower" in
        greenbank) echo "US" ;;
        redbank) echo "GB" ;;
        bluebank) echo "ES" ;;
        *)
            # Use hash for consistent assignment
            local hash=$(echo -n "$institution" | cksum | cut -d' ' -f1)
            local idx=$((hash % 10))
            echo "${COUNTRIES[$idx]}"
            ;;
    esac
}

# Generate IBAN-formatted account number for testing
# Format: CountryCode(2) + CheckDigits(2) + BankCode(4) + AccountNumber(14)
generate_test_iban() {
    local country=$1
    local msisdn=$2

    # Generate deterministic but unique account number from MSISDN
    local hash=$(echo -n "$msisdn" | cksum | cut -d' ' -f1)
    local account_num=$(printf "%014d" $((hash % 100000000000000)))

    # Generate check digits (simplified - just use last 2 digits of hash)
    local check_digits=$(printf "%02d" $((hash % 100)))

    # Bank code - use first 4 chars of country-specific pattern
    case "$country" in
        US) echo "US${check_digits}BANK${account_num}" ;;       # US format (not true IBAN but similar)
        GB) echo "GB${check_digits}BARC${account_num}" ;;       # UK IBAN
        ES) echo "ES${check_digits}2100${account_num}" ;;       # Spain IBAN
        IT) echo "IT${check_digits}X0542811101${account_num:0:12}" ;;  # Italy IBAN
        FR) echo "FR${check_digits}20041010050${account_num:0:11}" ;;  # France IBAN
        DE) echo "DE${check_digits}37040044${account_num:0:10}" ;;     # Germany IBAN
        JP) echo "JP${check_digits}MUFG${account_num}" ;;       # Japan format
        CN) echo "CN${check_digits}ICBC${account_num}" ;;       # China format
        SA) echo "SA${check_digits}80000${account_num:0:18}" ;;  # Saudi Arabia IBAN
        IN) echo "IN${check_digits}HDFC${account_num}" ;;       # India format
        *) echo "${country}${check_digits}BANK${account_num}" ;; # Generic format
    esac
}

# Get bank data for country — deterministic for a given MSISDN seed
get_bank_data() {
    local country=$1
    local seed=$2
    local var_name="BANKS_${country}[@]"
    local banks=("${!var_name}")
    deterministic_element banks "${seed}_bank"
}

# Get name data for country — deterministic for a given MSISDN seed
get_name_data() {
    local country=$1
    local seed=$2
    local var_name="NAMES_${country}[@]"
    local names=("${!var_name}")
    deterministic_element names "${seed}_name"
}

# Get city for country — deterministic for a given MSISDN seed
get_city() {
    local country=$1
    local seed=$2
    local var_name="CITIES_${country}[@]"
    local cities=("${!var_name}")
    deterministic_element cities "${seed}_city"
}

echo "======================================================================"
echo "Mastercard CBS Supplementary Data Loader"
echo "======================================================================"
echo ""

echo "Loading config from: $CONFIG_FILE"
echo "Namespace: $NAMESPACE"
if [[ "$DEBUG" == "true" ]]; then
    echo "Debug mode: ENABLED (showing detailed database operations)"
fi

# Load k8s config from INI
k8s_user=$(get_ini_value "kubernetes" "k8s_user" "$CONFIG_FILE")
kubeconfig_path=$(get_ini_value "kubernetes" "kubeconfig_path" "$CONFIG_FILE")

# Expand $USER if present
k8s_user="${k8s_user//\$USER/$USER}"
kubeconfig_path="${kubeconfig_path/#\~/$HOME}"

echo "Kubernetes user: $k8s_user"
echo "Kubeconfig: $kubeconfig_path"

# Get MySQL password from Kubernetes secret
echo "Getting MySQL credentials from Kubernetes..."
DB_PASS_B64=$(run_as_k8s_user "kubectl get secret operationsmysql -n $NAMESPACE -o jsonpath={.data.mysql-root-password}")
DB_PASS=$(echo "$DB_PASS_B64" | base64 -d)

if [[ -z "$DB_PASS" ]]; then
    echo "Error: Could not get MySQL password from secret operationsmysql in namespace $NAMESPACE"
    exit 1
fi

# Find MySQL pod
MYSQL_POD=$(run_as_k8s_user "kubectl get pods -n $NAMESPACE -l app.kubernetes.io/name=operationsmysql -o jsonpath={.items[0].metadata.name}" 2>/dev/null)
if [[ -z "$MYSQL_POD" ]]; then
    MYSQL_POD=$(run_as_k8s_user "kubectl get pods -n $NAMESPACE -o name" 2>/dev/null | grep -i mysql | head -1 | sed 's|pod/||')
fi

if [[ -z "$MYSQL_POD" ]]; then
    echo "Error: Could not find MySQL pod in namespace $NAMESPACE"
    exit 1
fi

echo "Using MySQL pod: $MYSQL_POD"

# MySQL command helper - runs via kubectl exec
mysql_cmd() {
    local db=$1
    shift
    run_as_k8s_user "kubectl exec -n $NAMESPACE $MYSQL_POD -- mysql -u root -p'$DB_PASS' $db -N -s -e \"$*\"" 2>/dev/null
}

# MySQL command for multi-line SQL via stdin
mysql_exec_sql() {
    local db=$1
    local sql=$2
    run_as_k8s_user "kubectl exec -n $NAMESPACE $MYSQL_POD -- mysql -u root -p'$DB_PASS' $db -N -s -e \"$sql\"" 2>/dev/null
}

# Create operations database if it doesn't exist
echo "Ensuring operations database exists..."
if [[ "$DEBUG" == "true" ]]; then
    echo "  → Executing: CREATE DATABASE IF NOT EXISTS operations"
fi
mysql_exec_sql "mysql" "CREATE DATABASE IF NOT EXISTS operations"

# Drop table if requested
if [[ "$DROP_TABLE" == "true" ]]; then
    echo ""
    echo "⚠️  WARNING: Dropping existing table (--drop-table flag detected)"
    echo "⚠️  All existing data will be lost!"
    echo ""

    if [[ "$DEBUG" == "true" ]]; then
        echo "┌────────────────────────────────────────────────────────────────────"
        echo "│ DATABASE: operations"
        echo "│ EXECUTING: DROP TABLE IF EXISTS mastercard_cbs_supplementary_data"
        echo "└────────────────────────────────────────────────────────────────────"
        echo ""
    fi

    mysql_exec_sql "operations" "DROP TABLE IF EXISTS mastercard_cbs_supplementary_data"
    echo "✓ Table dropped successfully"
    echo ""
fi

# Check if supplementary data table exists, create if not
if [[ "$DROP_TABLE" == "true" ]]; then
    echo "Creating new table with PHEE-351 compliant schema..."
else
    echo "Ensuring table exists..."
fi
CREATE_TABLE_SQL="CREATE TABLE IF NOT EXISTS mastercard_cbs_supplementary_data (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    payee_msisdn VARCHAR(20) NOT NULL,
    payee_account_number VARCHAR(50),
    -- Static fields (same for all lookups per PHEE-351)
    sender_organisation_name VARCHAR(255) NOT NULL DEFAULT 'GovStack Ministry of Social Welfare',
    sender_address_line1 VARCHAR(255) NOT NULL DEFAULT '123 Government Boulevard',
    sender_address_city VARCHAR(100) NOT NULL DEFAULT 'Capital City',
    sender_address_country VARCHAR(3) NOT NULL DEFAULT 'ZAF',
    payment_origination_country VARCHAR(3) NOT NULL DEFAULT 'ZAF',
    destination_country_iso3 VARCHAR(3) NOT NULL DEFAULT 'ZAF',
    beneficiary_currency VARCHAR(3) NOT NULL DEFAULT 'ZAR',
    beneficiary_currency_decimal_precision INT NOT NULL DEFAULT 2,
    destination_service_tag VARCHAR(20) NOT NULL DEFAULT 'ZAK-BK',
    payment_type VARCHAR(10) NOT NULL DEFAULT 'B2P',
    -- Variable fields based on account details (per PHEE-351)
    recipient_first_name VARCHAR(100),
    recipient_last_name VARCHAR(100),
    recipient_address_line1 VARCHAR(255),
    recipient_address_city VARCHAR(100),
    recipient_phone VARCHAR(20),
    recipient_email VARCHAR(255),
    recipient_address_country VARCHAR(3),
    -- Additional banking/routing fields for Mastercard CBS API
    bank_name VARCHAR(255),
    bank_swift_code VARCHAR(11),
    bank_branch_name VARCHAR(255),
    bank_country_code VARCHAR(3),
    purpose_of_payment VARCHAR(500),
    -- Metadata
    created_by VARCHAR(100),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    UNIQUE KEY uk_msisdn (payee_msisdn),
    INDEX idx_account (payee_account_number)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;"
if [[ "$DEBUG" == "true" ]]; then
    echo ""
    echo "┌────────────────────────────────────────────────────────────────────"
    echo "│ DATABASE: operations"
    echo "│ TABLE:    mastercard_cbs_supplementary_data"
    echo "├────────────────────────────────────────────────────────────────────"
    echo "│ CREATING TABLE WITH SCHEMA (PHEE-351 compliant):"
    echo "│ PRIMARY KEY:"
    echo "│   id                                  BIGINT AUTO_INCREMENT PRIMARY KEY"
    echo "│   payee_msisdn                        VARCHAR(20) NOT NULL UNIQUE"
    echo "│   payee_account_number                VARCHAR(50)"
    echo "│"
    echo "│ STATIC FIELDS (same for all lookups per PHEE-351):"
    echo "│   sender_organisation_name            VARCHAR(255) DEFAULT 'GovStack Ministry of Social Welfare'"
    echo "│   sender_address_line1                VARCHAR(255) DEFAULT '123 Government Boulevard'"
    echo "│   sender_address_city                 VARCHAR(100) DEFAULT 'Capital City'"
    echo "│   sender_address_country              VARCHAR(3)   DEFAULT 'ZAF'"
    echo "│   payment_origination_country         VARCHAR(3)   DEFAULT 'ZAF'"
    echo "│   destination_country_iso3            VARCHAR(3)   DEFAULT 'ZAF'"
    echo "│   beneficiary_currency                VARCHAR(3)   DEFAULT 'ZAR'"
    echo "│   beneficiary_currency_decimal_precision INT       DEFAULT 2"
    echo "│   destination_service_tag             VARCHAR(20)  DEFAULT 'ZAK-BK'"
    echo "│   payment_type                        VARCHAR(10)  DEFAULT 'B2P'"
    echo "│"
    echo "│ NOTE: All 9 static fields from PHEE-351 specification present"
    echo "│"
    echo "│ VARIABLE FIELDS (per beneficiary from PHEE-351):"
    echo "│   recipient_first_name                VARCHAR(100)"
    echo "│   recipient_last_name                 VARCHAR(100)"
    echo "│   recipient_address_line1             VARCHAR(255)"
    echo "│   recipient_address_city              VARCHAR(100)"
    echo "│   recipient_phone                     VARCHAR(20)"
    echo "│   recipient_email                     VARCHAR(255)"
    echo "│   recipient_address_country           VARCHAR(3)"
    echo "│"
    echo "│ NOTE: All 6 variable fields from PHEE-351 specification present"
    echo "│"
    echo "│ BANKING FIELDS (for Mastercard CBS API):"
    echo "│   bank_name                           VARCHAR(255)"
    echo "│   bank_swift_code                     VARCHAR(11)"
    echo "│   bank_branch_name                    VARCHAR(255)"
    echo "│   bank_country_code                   VARCHAR(3)"
    echo "│   purpose_of_payment                  VARCHAR(500)"
    echo "│"
    echo "│ METADATA:"
    echo "│   created_by                          VARCHAR(100)"
    echo "│   created_at                          TIMESTAMP DEFAULT CURRENT_TIMESTAMP"
    echo "└────────────────────────────────────────────────────────────────────"
    echo ""
fi
mysql_exec_sql "operations" "$CREATE_TABLE_SQL"

if [[ "$DROP_TABLE" == "true" ]]; then
    echo "✓ New table created with PHEE-351 compliant schema"
fi

# Check existing data (skip if we just dropped the table)
if [[ "$DROP_TABLE" != "true" ]]; then
    existing_count=$(mysql_cmd "operations" "SELECT COUNT(*) FROM mastercard_cbs_supplementary_data")

    if [[ "$existing_count" -gt 0 ]]; then
        if [[ "$REGENERATE" != "true" ]]; then
            echo "Supplementary data already exists ($existing_count records)"
            echo "Use --regenerate to replace existing data only (keeps schema)"
            echo "Use --drop-table to drop and recreate table with new schema"
            exit 0
        else
            echo "Regenerating data (deleting $existing_count existing records)..."
            if [[ "$DEBUG" == "true" ]]; then
                echo ""
                echo "┌────────────────────────────────────────────────────────────────────"
                echo "│ DATABASE: operations"
                echo "│ TABLE:    mastercard_cbs_supplementary_data"
                echo "├────────────────────────────────────────────────────────────────────"
                echo "│ EXECUTING: DELETE FROM mastercard_cbs_supplementary_data"
                echo "│ RECORDS TO DELETE: $existing_count"
                echo "└────────────────────────────────────────────────────────────────────"
                echo ""
            fi
            mysql_cmd "operations" "DELETE FROM mastercard_cbs_supplementary_data"
        fi
    fi
else
    echo ""
    echo "Table recreated from scratch - loading fresh data..."
fi

# Query beneficiaries from identity_account_mapper
echo ""
echo "Querying identity_account_mapper..."

if [[ "$DEBUG" == "true" ]]; then
    echo ""
    echo "┌────────────────────────────────────────────────────────────────────"
    echo "│ DATABASE: identity_account_mapper"
    echo "│ TABLES:   identity_details, payment_modality_details"
    echo "├────────────────────────────────────────────────────────────────────"
    echo "│ QUERY:"
    echo "│   SELECT DISTINCT"
    echo "│     id.payee_identity,"
    echo "│     pmd.destination_account,"
    echo "│     pmd.institution_code"
    echo "│   FROM identity_details id"
    echo "│   JOIN payment_modality_details pmd"
    echo "│     ON id.master_id = pmd.master_id"
    echo "│   WHERE pmd.destination_account IS NOT NULL"
    echo "│     AND pmd.institution_code IS NOT NULL"
    echo "│   ORDER BY id.payee_identity"
    echo "└────────────────────────────────────────────────────────────────────"
    echo ""
fi

beneficiaries=$(mysql_cmd "identity_account_mapper" "SELECT DISTINCT id.payee_identity, pmd.destination_account, pmd.institution_code FROM identity_details id JOIN payment_modality_details pmd ON id.master_id = pmd.master_id WHERE pmd.destination_account IS NOT NULL AND pmd.institution_code IS NOT NULL ORDER BY id.payee_identity")

if [[ -z "$beneficiaries" ]]; then
    echo ""
    echo "Warning: No beneficiaries found in identity_account_mapper"
    echo "Run generate-mifos-vnext-data.py first to populate identity mapper"
    exit 1
fi

count=$(echo "$beneficiaries" | wc -l)
echo "Found $count beneficiaries in identity_account_mapper"

if [[ "$DEBUG" == "true" ]]; then
    echo ""
    echo "First 3 records from query:"
    echo "$beneficiaries" | head -3 | while IFS=$'\t' read -r msisdn account institution; do
        echo "  → MSISDN: $msisdn | Account: $account | Institution: $institution"
    done
    echo ""
fi

echo ""
echo "Generating supplementary data..."

inserted=0

while IFS=$'\t' read -r msisdn account institution; do
    [[ -z "$msisdn" ]] && continue

    # Map institution to country
    country=$(map_institution_to_country "$institution")

    # Generate IBAN-formatted account number for Mastercard CBS API
    iban_account=$(generate_test_iban "$country" "$msisdn")

    # Get deterministic bank and city for this country (keyed on MSISDN so
    # the same MSISDN always gets the same bank/city across re-runs)
    bank_data=$(get_bank_data "$country" "$msisdn")
    bank_name=$(echo "$bank_data" | cut -d'|' -f1)
    bank_swift=$(echo "$bank_data" | cut -d'|' -f2)
    bank_branch=$(echo "$bank_data" | cut -d'|' -f3)

    city=$(get_city "$country" "$msisdn")

    # Prefer real client name from MifosX over generated country-based name
    mifos_name=$(get_mifos_client_name "$msisdn" "$institution")
    if [[ -n "$mifos_name" ]]; then
        first_name=$(echo "$mifos_name" | cut -d'|' -f1)
        last_name=$(echo "$mifos_name" | cut -d'|' -f2)
        if [[ "$DEBUG" == "true" ]]; then
            echo "  → MifosX name found: $first_name $last_name"
        fi
    else
        # Deterministic fallback: same MSISDN always gets same name across runs
        name_data=$(get_name_data "$country" "$msisdn")
        first_name=$(echo "$name_data" | cut -d'|' -f1)
        last_name=$(echo "$name_data" | cut -d'|' -f2)
        if [[ "$DEBUG" == "true" ]]; then
            echo "  → MifosX lookup failed, using deterministic fallback: $first_name $last_name"
        fi
    fi
    street="${STREETS[$country]}"
    street_hash=$(echo -n "${msisdn}_street" | cksum | cut -d' ' -f1)
    street_num=$(( (street_hash % 999) + 1 ))
    address="$street_num $street"

    email_domain="${EMAIL_DOMAINS[$country]}"
    email=$(echo "${first_name,,}.${last_name,,}@${email_domain}")

    purpose="Government social grant payment to $first_name $last_name"

    # Insert record (static fields use table defaults per PHEE-351)
    INSERT_SQL="INSERT INTO mastercard_cbs_supplementary_data (
        payee_msisdn,
        payee_account_number,
        recipient_first_name,
        recipient_last_name,
        recipient_address_line1,
        recipient_address_city,
        recipient_address_country,
        recipient_phone,
        recipient_email,
        bank_name,
        bank_swift_code,
        bank_branch_name,
        bank_country_code,
        purpose_of_payment,
        created_by
    ) VALUES (
        '$msisdn',
        '$iban_account',
        '$first_name',
        '$last_name',
        '$address',
        '$city',
        '$country',
        '$msisdn',
        '$email',
        '$bank_name',
        '$bank_swift',
        '$bank_branch',
        '$country',
        '$purpose',
        'load-mastercard-supplementary-data.sh'
    ) ON DUPLICATE KEY UPDATE
        payee_account_number = VALUES(payee_account_number),
        recipient_first_name = VALUES(recipient_first_name),
        recipient_last_name = VALUES(recipient_last_name)"

    if [[ "$DEBUG" == "true" ]]; then
        echo ""
        echo "┌────────────────────────────────────────────────────────────────────"
        echo "│ DATABASE: operations"
        echo "│ TABLE:    mastercard_cbs_supplementary_data"
        echo "├────────────────────────────────────────────────────────────────────"
        echo "│ INSERTING VALUES (PHEE-351 compliant):"
        echo "│"
        echo "│ STATIC FIELDS (using table defaults):"
        echo "│   sender_organisation_name        = (default: GovStack Ministry of Social Welfare)"
        echo "│   sender_address_line1            = (default: 123 Government Boulevard)"
        echo "│   sender_address_city             = (default: Capital City)"
        echo "│   sender_address_country          = (default: ZAF)"
        echo "│   payment_origination_country     = (default: ZAF)"
        echo "│   destination_country_iso3        = (default: ZAF)"
        echo "│   beneficiary_currency            = (default: ZAR)"
        echo "│   beneficiary_currency_decimal_precision = (default: 2)"
        echo "│   destination_service_tag         = (default: ZAK-BK)"
        echo "│   payment_type                    = (default: B2P)"
        echo "│"
        echo "│ VARIABLE FIELDS (per beneficiary):"
        echo "│   payee_msisdn                = $msisdn"
        echo "│   payee_account_number        = $iban_account (IBAN format)"
        echo "│   recipient_first_name        = $first_name"
        echo "│   recipient_last_name         = $last_name"
        echo "│   recipient_address_line1     = $address"
        echo "│   recipient_address_city      = $city"
        echo "│   recipient_address_country   = $country"
        echo "│   recipient_phone             = $msisdn"
        echo "│   recipient_email             = $email"
        echo "│"
        echo "│ BANKING FIELDS:"
        echo "│   bank_name                   = $bank_name"
        echo "│   bank_swift_code             = $bank_swift"
        echo "│   bank_branch_name            = $bank_branch"
        echo "│   bank_country_code           = $country"
        echo "│   purpose_of_payment          = $purpose"
        echo "│"
        echo "│ METADATA:"
        echo "│   created_by                  = load-mastercard-supplementary-data.sh"
        echo "└────────────────────────────────────────────────────────────────────"
    fi

    if mysql_exec_sql "operations" "$INSERT_SQL"; then
        if [[ "$DEBUG" == "true" ]]; then
            echo "  ✓ Successfully inserted record"
        else
            echo "  + $msisdn -> $first_name $last_name ($country - $bank_name)"
        fi
        inserted=$((inserted + 1))
    else
        echo "  ✗ Error inserting $msisdn"
    fi

done <<< "$beneficiaries"

echo ""
echo "======================================================================"
echo "Successfully loaded $inserted supplementary data records"
if [[ "$DROP_TABLE" == "true" ]]; then
    echo "Table was dropped and recreated with PHEE-351 compliant schema"
elif [[ "$REGENERATE" == "true" ]]; then
    echo "Data was regenerated (table schema preserved)"
fi
echo "======================================================================"
echo ""
echo "Next steps:"
echo "  1. Generate Mastercard CBS batch CSV:"
echo "     ./generate-mastercard-batch.sh -c ~/tomconfig.ini"
echo ""
echo "  2. Submit batch:"
echo "     ./submit-batch.py -c ~/tomconfig.ini \\"
echo "       -f bulk-mastercard-cbs.csv \\"
echo "       --tenant greenbank \\"
echo "       --payment-mode MASTERCARD_CBS"
echo ""
