#!/bin/bash

# --- Configuration ---
NUMBER_OF_CLIENTS=2 # Reduced for brevity during testing
API_BASE_URL="https://mifos.mifos.gazelle.test/fineract-provider/api/v1"
CLIENTS_API_URL="$API_BASE_URL/clients"
SAVINGS_API_URL="$API_BASE_URL/savingsaccounts"
INTEROP_PARTIES_API_URL="$API_BASE_URL/interoperation/parties/MSISDN"

TENANT_ID="bluebank"
AUTHORIZATION="Basic bWlmb3M6cGFzc3dvcmQ="
CONTENT_TYPE="application/json"
LOCALE="en"
DATE_FORMAT="dd MMMM yy"

# --- Function to create a client ---
create_client() {
  local firstname="John$(date +%s%N)"
  local lastname="Wick"
  local submitted_date=$(date +"%d %B %y")
  local activation_date="$submitted_date"

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
    "activationDate": "$activation_date"
}
EOF
)

  echo "Creating client for <$TENANT_ID>: $firstname $lastname ..."
  local client_response=$(curl -k -s -X POST \
                               -H "Fineract-Platform-TenantId: $TENANT_ID" \
                               -H "Authorization: $AUTHORIZATION" \
                               -H "Content-Type: $CONTENT_TYPE" \
                               -d "$client_payload" \
                               "$CLIENTS_API_URL")

  if echo "$client_response" | jq -e '.clientId'; then
    echo "Client creation successful."
    jq -r '.clientId' <<< "$client_response"
  else
    echo "Error creating client:"
    echo "$client_response"
    return 1
  fi
}

# --- Function to create a savings account ---
create_savings_account() {
  local client_id="$1"
  local external_id=$(uuidgen)
  local submitted_date=$(date +"%d %B %y")
  local product_id=5

  local savings_payload=$(cat <<EOF
{
    "clientId": $client_id,
    "productId": $product_id,
    "externalId": "$external_id",
    "locale": "$LOCALE",
    "dateFormat": "$DATE_FORMAT",
    "submittedOnDate": "$submitted_date"
}
EOF
)

  echo "Creating savings account for Client ID: $client_id with External ID: $external_id ..."
  local savings_response=$(curl -k -s -X POST \
                                -H "Fineract-Platform-TenantId: $TENANT_ID" \
                                -H "Authorization: $AUTHORIZATION" \
                                -H "Content-Type: $CONTENT_TYPE" \
                                -d "$savings_payload" \
                                "$SAVINGS_API_URL")

  echo "Savings account creation response:"
  echo "$savings_response"
  echo "$external_id" # Still echo for now, might adjust later
  echo "$external_id" # Ensure ONLY the external ID is on the last line
}

# --- Function to register interoperation party ---
register_interop_party() {
  local client_id="$1"
  local account_id="$2"
  local interop_url="$INTEROP_PARTIES_API_URL/$client_id"

  local interop_payload=$(cat <<EOF
{
    "accountId": "$account_id"
}
EOF
)

  echo "Registering interoperation party for Client ID: $client_id with Account ID: $account_id at URL: $interop_url ..."
  local interop_response=$(curl -k -s -X POST \
                                -H "Fineract-Platform-TenantId: $TENANT_ID" \
                                -H "Authorization: $AUTHORIZATION" \
                                -H "Content-Type: $CONTENT_TYPE" \
                                -d "$interop_payload" \
                                "$interop_url")

  echo "Interoperation party registration response:"
  echo "$interop_response"
}

# --- Main loop ---
echo "Starting loop to create $NUMBER_OF_CLIENTS clients and associated accounts..."
for i in $(seq 1 "$NUMBER_OF_CLIENTS"); do
  echo "--- Processing client number $i ---"

  client_id=$(create_client)
  if [ -n "$client_id" ]; then
    external_id=$(create_savings_account "$client_id" | tail -n 1) # Capture only the last line (external ID)
    if [ -n "$external_id" ]; then
      echo "Savings account created successfully with External ID: $external_id for Client ID: $client_id"
      register_interop_party "$client_id" "$external_id"
    else
      echo "Skipping interoperation registration due to savings account creation failure."
    fi
  else
    echo "Skipping savings account and interoperation registration due to client creation failure."
  fi
  echo ""
done

echo "Loop finished."