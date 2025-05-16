#!/bin/bash

# --- Configuration ---
NUMBER_OF_CLIENTS=1 # Reduced for brevity during testing
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
  local mobile_number="04$(date +%s | cut -c -8)" # Example generated mobile number

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

  echo "Creating client for <$TENANT_ID>: $firstname $lastname with Mobile Number: $mobile_number ..."
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

  echo "\nTOMD Inside create_savings_account - Received client_id: $client_id"

  local savings_payload='{'
  savings_payload+="\"clientId\":${client_id},"
  savings_payload+="\"productId\":${product_id},"
  savings_payload+="\"externalId\":\"${external_id}\","
  savings_payload+="\"locale\":\"${LOCALE}\","
  savings_payload+="\"dateFormat\":\"${DATE_FORMAT}\","
  savings_payload+="\"submittedOnDate\":\"${submitted_date}\""
  savings_payload+='}'

  echo "TOMD Savings account payload: $savings_payload"

  local savings_response=$(curl -k -s -X POST \
                                -H "Fineract-Platform-TenantId: $TENANT_ID" \
                                -H "Authorization: $AUTHORIZATION" \
                                -H "Content-Type: $CONTENT_TYPE" \
                                -d "$savings_payload" \
                                "$SAVINGS_API_URL")

  echo "Savings account creation response:"
  echo "$savings_response"

  if echo "$client_response" | jq -e '.clientId'; then
    echo "Client creation successful."
    jq -r '.clientId' <<< "$client_response"
  else
    echo "Error creating client:"
    echo "$client_response" # Log the full error response
    return 1
  fi
}
# --- Function to register interoperation party ---
register_interop_party() {
  local client_id="$1"
  local account_id="$2" # This will now be the externalId
  local client_details_url="$CLIENTS_API_URL/$client_id"

  echo "\nTOMD Inside register_interop_party - Client ID: $client_id, External Account ID: $account_id"

  # Fetch client details to get the mobile number (assuming it exists)
  local client_details=$(curl -k -s -X GET \
                                 -H "Fineract-Platform-TenantId: $TENANT_ID" \
                                 -H "Authorization: $AUTHORIZATION" \
                                 "$client_details_url")

  local mobile_number=$(echo "$client_details" | jq -r '.mobileNo')
  echo "TOMD Inside register_interop_party - Mobile Number: $mobile_number"

  if [ -n "$mobile_number" ]; then
    local interop_url="$INTEROP_PARTIES_API_URL/$mobile_number"
    echo "TOMD Inside register_interop_party - Interop URL: $interop_url"

    local interop_payload=$(cat <<EOF
{
    "accountId": "$account_id"
}
EOF
)
    echo "TOMD Inside register_interop_party - Interop Payload: $interop_payload"

    echo "Registering interoperation party for Client ID: $client_id with External Account ID: $account_id and MSISDN: $mobile_number at URL: $interop_url ..."
    local interop_response=$(curl -k -s -X POST \
                                  -H "Fineract-Platform-TenantId: $TENANT_ID" \
                                  -H "Authorization: $AUTHORIZATION" \
                                  -H "Content-Type: $CONTENT_TYPE" \
                                  -d "$interop_payload" \
                                  "$interop_url")

    echo "Interoperation party registration response:"
    echo "$interop_response"
  else
    echo "Warning: Mobile number not found for Client ID: $client_id. Skipping interoperation registration."
  fi
}

# --- Main loop ---
echo "Starting loop to create $NUMBER_OF_CLIENTS clients and associated accounts..."
for i in $(seq 1 "$NUMBER_OF_CLIENTS"); do
  echo "--- Processing client number $i ---"

  client_id=$(create_client | tail -n 1)
  if [ -n "$client_id" ]; then
    echo "Client ID obtained: $client_id"
    create_savings_output=$(create_savings_account "$client_id")
    #echo "TOMD create_savings_output: $create_savings_output"
    savings_account_id=$(echo "$create_savings_output" | head -n 1)
    echo "TOMD savings_account_id: $savings_account_id"
    external_id=$(echo "$create_savings_output" | tail -n 1)
    echo "TOMD external_id: $external_id"
    if [ -n "$savings_account_id" ] && [ -n "$external_id" ]; then
      echo "Savings Account ID obtained: $savings_account_id, External ID: $external_id"
      register_interop_party "$client_id" "$external_id" # Pass the externalId
    else
      echo "Skipping interoperation registration due to savings account creation failure."
    fi
  else
    echo "Skipping savings account and interoperation registration due to client creation failure."
  fi
  echo ""
done

echo "Loop finished."