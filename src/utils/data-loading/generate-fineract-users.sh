#!/bin/bash

# --- Configuration ---
NUMBER_OF_CLIENTS=1 # Reduced for brevity during testing
API_BASE_URL="https://mifos.mifos.gazelle.test/fineract-provider/api/v1"
CLIENTS_API_URL="$API_BASE_URL/clients"
SAVINGS_API_URL="$API_BASE_URL/savingsaccounts"
SAVINGS_PRODUCTS_API_URL="$API_BASE_URL/savingsproducts" # New endpoint for savings products
INTEROP_PARTIES_API_URL="$API_BASE_URL/interoperation/parties/MSISDN"

TENANT_ID="bluebank"
AUTHORIZATION="Basic bWlmb3M6cGFzc3dvcmQ=" # Use environment variables or secrets management for production
CONTENT_TYPE="application/json"
LOCALE="en"
DATE_FORMAT="dd MMMM yy"

# Product details for creation
PRODUCT_CURRENCY_CODE="USD" # <-- Change this to your desired currency
PRODUCT_INTEREST_RATE="5.0" # <-- Annual interest rate
PRODUCT_SHORTNAME="savb"
PRODUCT_NAME="${TENANT_ID}-savings" # Derived as requested
PRODUCT_DESCRIPTION="Savings product for ${TENANT_ID} demo"

# Enable strict mode: exit on error, treat unset variables as errors, etc.
set -euo pipefail

# --- Function to create a savings product ---
# On success, prints the product ID to stdout. On failure, prints error to stderr.
create_savings_product() {
  echo "Creating savings product: '$PRODUCT_NAME' with short name '$PRODUCT_SHORTNAME'..." >&2

  local product_payload=$(cat <<EOF
{
    "name": "$PRODUCT_NAME",
    "shortName": "$PRODUCT_SHORTNAME",
    "currencyCode": "USD",
    "digitsAfterDecimal": 2,
    "inMultiplesOf": 1,
    "locale": "$LOCALE",
    "nominalAnnualInterestRate": $PRODUCT_INTEREST_RATE,
    "interestCompoundingPeriodType": 1,
    "interestPostingPeriodType": 4,
    "interestCalculationType": 1,
    "interestCalculationDaysInYearType": 365,
    "accountingRule": 1
}
EOF
)
echo "Product payload: $product_payload" >&2 # Debugging output

  # *** CHANGE: Use --data-raw instead of -d ***
  # The --data-raw option is used to send the payload as-is without any processing.
  # This is useful for JSON payloads to ensure they are sent correctly.
  # Note: Ensure that jq is installed and available in your environment for JSON parsing.
 # Note: This is a minimal payload. You might need to add more fields
 # depending on your Fineract configuration or requirements (e.g., lockinPeriodFrequency, charges, etc.)

  local product_response
  # *** CHANGE: Use --data-raw instead of -d ***
  product_response=$(curl -k -s -w "%{http_code}" -X POST \
                          -H "Fineract-Platform-TenantId: $TENANT_ID" \
                          -H "Authorization: $AUTHORIZATION" \
                          -H "Content-Type: $CONTENT_TYPE" \
                          -d "$product_payload" \
                          "$SAVINGS_PRODUCTS_API_URL")

  local http_code="${product_response: -3}"
  local response_body="${product_response: 0: -3}"

  if [[ "$http_code" -ge 200 && "$http_code" -lt 300 ]]; then
      local product_id=$(echo "$response_body" | jq -r '.resourceId')
      if [ "$product_id" != "null" ] && [ -n "$product_id" ]; then
          echo "$product_id" # Output only the product ID to stdout on success
          echo "Savings product creation successful. Product ID: $product_id" >&2
          return 0 # Success
      else
          echo "Error parsing product ID from response: $response_body" >&2
          return 1 # Failure
      fi
  # Handle the case where the product might already exist (e.g., HTTP 409 Conflict)
  # The exact error structure for conflict might vary, check your Fineract logs if needed.
  # This is a basic attempt based on common API patterns.
  elif [[ "$http_code" -eq 409 ]]; then
      echo "Warning: Savings product with short name '$PRODUCT_SHORTNAME' might already exist. Skipping creation." >&2
      # Attempt to find the existing product's ID by short name
      local existing_product_id=$(get_product_id_by_shortname "$PRODUCT_SHORTNAME")
      if [ -n "$existing_product_id" ]; then
          echo "$existing_product_id" # Return the ID of the existing product
          echo "Found existing product with ID: $existing_product_id" >&2
          return 0 # Consider this step successful as we got an ID
      else
          echo "Could not find existing product ID after 409 error." >&2
          return 1 # Failure
      fi
  else
      echo "Error creating savings product (HTTP $http_code):" >&2
      echo "$response_body" >&2 # Log the full error response to stderr
      return 1 # Failure
  fi
}

# --- Helper function to get product ID by short name ---
# Returns the product ID if found, empty string otherwise. Prints errors to stderr.
# *** Correction: Added quotes around the URL to handle potential query params correctly ***
get_product_id_by_shortname() {
    local shortname="$1"
    echo "Attempting to find product ID for short name '$shortname'..." >&2
    local response
    # Using --data-raw here is unnecessary as it's a GET request with no body
    response=$(curl -k -s -w "%{http_code}" -X GET \
                    -H "Fineract-Platform-TenantId: $TENANT_ID" \
                    -H "Authorization: $AUTHORIZATION" \
                    "$SAVINGS_PRODUCTS_API_URL?tenantIdentifier=$TENANT_ID") # Use tenantIdentifier query param as an alternative to header if needed, relying on header mainly

    local http_code="${response: -3}"
    local response_body="${response: 0: -3}"

    if [[ "$http_code" -ge 200 && "$http_code" -lt 300 ]]; then
        # Find the product with the matching shortName and extract its 'id'
        local product_id=$(echo "$response_body" | jq -r ".[] | select(.shortName == \"$shortname\") | .id")
        if [ -n "$product_id" ]; then
            echo "$product_id" # Output ID to stdout
            return 0
        else
             echo "Product with short name '$shortname' not found in the list." >&2
             return 1
        fi
    else
        echo "Error fetching savings products list (HTTP $http_code):" >&2
        echo "$response_body" >&2
        return 1
    fi
}


# --- Function to create a client ---
# (Keep this function the same)
create_client() {
  local firstname="John$(date +%s%N)"
  local lastname="Wick"
  local submitted_date=$(date +"%d %B %y")
  local activation_date="$submitted_date"
  local mobile_number="04$(date +%s | cut -c 3-10)" # Generate a plausible mobile number

  local client_payload=$(cat <<EOF
{
    "officeId": 1,
    "legalFormId": 1,
    "firstname": "$firstname",
    "lastname": "$lastname",
    "submittedOnDate": "$submitted_date",
    "dateFormat": "$DATE_FORMAT",
    "locale": "$LOCALE",
    "active": true,
    "activationDate": "$activation_date",
    "mobileNo": "$mobile_number"
}
EOF
)

  echo "Creating client for <$TENANT_ID>: $firstname $lastname with Mobile Number: $mobile_number ..." >&2

  local client_response
  client_response=$(curl -k -s -w "%{http_code}" -X POST \
                         -H "Fineract-Platform-TenantId: $TENANT_ID" \
                         -H "Authorization: $AUTHORIZATION" \
                         -H "Content-Type: $CONTENT_TYPE" \
                         --data-raw "$client_payload" \ # Also use --data-raw here for consistency
                         "$CLIENTS_API_URL")

  local http_code="${client_response: -3}"
  local response_body="${client_response: 0: -3}"

  if [[ "$http_code" -ge 200 && "$http_code" -lt 300 ]]; then
      local client_id=$(echo "$response_body" | jq -r '.clientId')
      if [ "$client_id" != "null" ] && [ -n "$client_id" ]; then
          echo "$client_id" # Output only the client ID to stdout on success
          echo "Client creation successful. Client ID: $client_id" >&2
          return 0 # Success
      else
          echo "Error parsing client ID from response: $response_body" >&2
          return 1 # Failure
      fi
  else
      echo "Error creating client (HTTP $http_code):" >&2
      echo "$response_body" >&2 # Log the full error response to stderr
      return 1 # Failure
  fi
}

# --- Function to create a savings account ---
# (Keep this function the same, ensures --data-raw is used here too)
create_savings_account() {
  local client_id="$1"
  local external_id=$(uuidgen)
  local submitted_date=$(date +"%d %B %y")
  # Use the product ID created earlier
  local product_id=${SAVINGS_PRODUCT_ID:-} # Use default empty if not set, though set -u prevents this

  if [ -z "$product_id" ]; then
      echo "Error: SAVINGS_PRODUCT_ID is not set. Cannot create savings account." >&2
      return 1
  fi

  echo "Creating savings account for Client ID: $client_id using Product ID: $product_id with External ID: $external_id ..." >&2

  local savings_payload=$(cat <<EOF
{
    "clientId": ${client_id},
    "productId": ${product_id},
    "externalId": "${external_id}",
    "locale": "${LOCALE}",
    "dateFormat": "${DATE_FORMAT}",
    "submittedOnDate": "${submitted_date}"
}
EOF
)

  local savings_response
  # *** CHANGE: Use --data-raw instead of -d ***
  savings_response=$(curl -k -s -w "%{http_code}" -X POST \
                           -H "Fineract-Platform-TenantId: $TENANT_ID" \
                           -H "Authorization: $AUTHORIZATION" \
                           -H "Content-Type: $CONTENT_TYPE" \
                           --data-raw "$savings_payload" \ # <-- Changed here
                           "$SAVINGS_API_URL")

  local http_code="${savings_response: -3}"
  local response_body="${savings_response: 0: -3}"

  if [[ "$http_code" -ge 200 && "$http_code" -lt 300 ]]; then
      local account_id=$(echo "$response_body" | jq -r '.accountId')
      local returned_external_id=$(echo "$response_body" | jq -r '.externalId') # Capture externalId from response
      if [ "$account_id" != "null" ] && [ -n "$account_id" ] && [ "$returned_external_id" != "null" ] && [ -n "$returned_external_id" ]; then
          echo "$account_id $returned_external_id" # Output account ID and external ID space-separated to stdout
          echo "Savings account creation successful. Account ID: $account_id, External ID: $returned_external_id" >&2
          return 0 # Success
      else
          echo "Error parsing account ID or external ID from response: $response_body" >&2
          return 1 # Failure
      fi
  else
      echo "Error creating savings account (HTTP $http_code):" >&2
      echo "$response_body" >&2 # Log the full error response to stderr
      return 1 # Failure
  fi
}

# --- Function to register interoperation party ---
# (Keep this function the same, ensures --data-raw is used here too if it has a body)
register_interop_party() {
  local client_id="$1"
  local account_external_id="$2" # Variable name clarifies this is the external ID

  echo "Fetching mobile number for Client ID: $client_id ..." >&2

  local client_details_url="$CLIENTS_API_URL/$client_id"
  local client_details
  client_details=$(curl -k -s -w "%{http_code}" -X GET \
                          -H "Fineract-Platform-TenantId: $TENANT_ID" \
                          -H "Authorization: $AUTHORIZATION" \
                          "$client_details_url") # GET requests don't have bodies or need --data-raw

  local http_code="${client_details: -3}"
  local response_body="${client_details: 0: -3}"

  if [[ "$http_code" -ge 200 && "$http_code" -lt 300 ]]; then
      local mobile_number=$(echo "$response_body" | jq -r '.mobileNo')

      if [ "$mobile_number" != "null" ] && [ -n "$mobile_number" ]; then
          local interop_url="$INTEROP_PARTIES_API_URL/$mobile_number"
          echo "Mobile Number found: $mobile_number" >&2
          echo "Registering interoperation party with External Account ID: $account_external_id and MSISDN: $mobile_number at URL: $interop_url ..." >&2

          local interop_payload=$(cat <<EOF
{
    "accountId": "$account_external_id"
}
EOF
          )

          local interop_response
          # *** CHANGE: Use --data-raw instead of -d ***
          interop_response=$(curl -k -s -w "%{http_code}" -X POST \
                                  -H "Fineract-Platform-TenantId: $TENANT_ID" \
                                  -H "Authorization: $AUTHORIZATION" \
                                  -H "Content-Type: $CONTENT_TYPE" \
                                  --data-raw "$interop_payload" \ # <-- Changed here
                                  "$interop_url")

          local interop_http_code="${interop_response: -3}"
          local interop_response_body="${interop_response: 0: -3}"

          if [[ "$interop_http_code" -ge 200 && "$interop_http_code" -lt 300 ]]; then
              echo "Interoperation party registration successful." >&2
              # Optionally print response body for debugging success: echo "$interop_response_body" >&2
              return 0 # Success
          else
              echo "Error registering interoperation party (HTTP $interop_http_code):" >&2
              echo "$interop_response_body" >&2
              return 1 # Failure
          fi
      else
          echo "Warning: Mobile number not found or is null for Client ID: $client_id. Skipping interoperation registration." >&2
          return 1 # Consider this a failure for this step
      fi
  else
      echo "Error fetching client details for ID: $client_id (HTTP $http_code):" >&2
      echo "$response_body" >&2
      return 1 # Failure
  fi
}

# --- Main Execution ---

# 1. Create the savings product first
SAVINGS_PRODUCT_ID=""
echo "Attempting to create or find savings product..." >&2
if ! SAVINGS_PRODUCT_ID=$(create_savings_product); then
    echo "Fatal error: Could not create or find savings product. Exiting." >&2
    exit 1 # Exit the script if product creation/lookup fails
fi
echo "Using Savings Product ID: $SAVINGS_PRODUCT_ID for account creation." >&2
echo "" >&2 # Blank line for separation

# 2. Proceed with the main loop to create clients and accounts
echo "Starting loop to create $NUMBER_OF_CLIENTS clients and associated accounts..." >&2

# Loop NUMBER_OF_CLIENTS times
for ((i=1; i<=NUMBER_OF_CLIENTS; i++)); do
  echo "--- Processing client number $i ---" >&2

  client_id=""
  # Capture stdout of create_client and check exit status
  if ! client_id=$(create_client); then
    echo "Skipping savings account and interoperation registration due to client creation failure for iteration $i." >&2
    continue # Skip to the next iteration
  fi

  savings_output=""
  savings_account_id=""
  external_id=""

  # Capture stdout of create_savings_account and check exit status
  # read splits the line by default whitespace into variables
  if savings_output=$(create_savings_account "$client_id"); then
      read savings_account_id external_id <<< "$savings_output"

      if [ -n "$savings_account_id" ] && [ -n "$external_id" ]; then
        echo "Savings Account ID obtained: $savings_account_id, External ID obtained: $external_id" >&2
        # Call interop registration, checking its status
        if ! register_interop_party "$client_id" "$external_id"; then
            echo "Interoperation registration failed for Client ID: $client_id, External ID: $external_id." >&2
            # Continue loop or exit based on desired behavior on interop failure
        fi
      else
        echo "Error: Savings account creation succeeded, but account ID or external ID could not be parsed from output: '$savings_output'" >&2
      fi
  else
    echo "Skipping interoperation registration due to savings account creation failure for Client ID: $client_id." >&2
  fi

  echo "--- Finished processing client number $i ---" >&2
  echo "" >&2 # Add a blank line between iterations
done

echo "Loop finished." >&2