#!/usr/bin/env python3

import requests
import json
import datetime
import uuid
import sys
import base64 # Needed to decode the Authorization header if you want to see the credentials
import urllib3 # Import urllib3
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning) # Disable InsecureRequestWarning

# --- Configuration ---
NUMBER_OF_CLIENTS = 1  # Reduced for brevity during testing
API_BASE_URL = "https://mifos.mifos.gazelle.test/fineract-provider/api/v1"
CLIENTS_API_URL = f"{API_BASE_URL}/clients"
SAVINGS_API_URL = f"{API_BASE_URL}/savingsaccounts"
SAVINGS_PRODUCTS_API_URL = f"{API_BASE_URL}/savingsproducts"
INTEROP_PARTIES_API_URL = f"{API_BASE_URL}/interoperation/parties/MSISDN"

TENANT_ID = "bluebank"
# It's better practice to store credentials securely, e.g., in environment variables
# For demonstration, we'll decode the provided Basic auth header
AUTH_HEADER_VALUE = "Basic bWlmb3M6cGFzc3dvcmQ="
# Optional: Decode and print credentials (DO NOT do this in production logs!)
# try:
#     decoded_credentials = base64.b64decode(AUTH_HEADER_VALUE.split(' ')[1]).decode('utf-8')
#     print(f"Warning: Using hardcoded credentials: {decoded_credentials}", file=sys.stderr)
# except Exception as e:
#     print(f"Warning: Could not decode Authorization header: {e}", file=sys.stderr)


HEADERS = {
    "Fineract-Platform-TenantId": TENANT_ID,
    "Authorization": AUTH_HEADER_VALUE,
    "Content-Type": "application/json"
}

# Date format for API requests - Reverted to dd MMMMYYYY
# This format produces strings like "16 May 2025"
DATE_FORMAT = "%d %B %Y"
LOCALE = "en" # Define LOCALE globally

# Product details for creation
PRODUCT_CURRENCY_CODE = "USD"  # <-- Change this to your desired currency
PRODUCT_INTEREST_RATE = 5.0    # <-- Annual interest rate (float)
PRODUCT_SHORTNAME = "savb"     # Using the shortname from your last attempt
PRODUCT_NAME = f"{TENANT_ID}-savings" # Derived as requested
PRODUCT_DESCRIPTION = f"Savings product for {TENANT_ID} demo"

# --- Helper Function for API Calls ---
# Reverted JSON decoding logic to match your original posted code's behavior
def make_api_request(method, url, headers, json_data=None, params=None):
    """
    Makes an API request and handles basic error checking.
    Returns the JSON response body on success, None on failure.
    """
    try:
        # Disable SSL verification (-k in curl) - use with caution in production
        response = requests.request(
            method,
            url,
            headers=headers,
            json=json_data,
            params=params,
            verify=False # Equivalent to curl -k
        )

        # Raise an HTTPError for bad responses (4xx or 5xx)
        response.raise_for_status()

        # Attempt to parse JSON response - Reverted to original logic
        try:
            return response.json()
        except json.JSONDecodeError:
            print(f"Warning: Could not decode JSON response from {url}", file=sys.stderr)
            print(f"Response body: {response.text}", file=sys.stderr)
            return None # Return None on decode error, as in your original code

    except requests.exceptions.RequestException as e:
        print(f"API Request Error ({method} {url}): {e}", file=sys.stderr)
        if hasattr(e, 'response') and e.response is not None:
             print(f"Response Status Code: {e.response.status_code}", file=sys.stderr)
             print(f"Response Body: {e.response.text}", file=sys.stderr)
        return None
    except Exception as e:
        print(f"An unexpected error occurred during API request ({method} {url}): {e}", file=sys.stderr)
        return None

# --- Function to create a savings product ---
def create_savings_product(headers):
    """
    Creates a savings product in Fineract.
    Returns the product ID on success, None on failure.
    Handles potential 409 Conflict by trying to find the existing product.
    """
    print(f"Creating savings product: '{PRODUCT_NAME}' with short name '{PRODUCT_SHORTNAME}'...", file=sys.stderr)

    product_payload = {
        "name": PRODUCT_NAME,
        "shortName": PRODUCT_SHORTNAME,
        "currencyCode": PRODUCT_CURRENCY_CODE,
        "digitsAfterDecimal": 2,
        "inMultiplesOf": 1,
        "locale": "en", # Hardcoding locale as 'en' in payload as per common examples
        "nominalAnnualInterestRate": PRODUCT_INTEREST_RATE,
        "interestCompoundingPeriodType": 1,
        "interestPostingPeriodType": 4,
        "interestCalculationType": 1,
        "interestCalculationDaysInYearType": 365,
        "accountingRule": 1
    }
    # print(f"Product payload: {json.dumps(product_payload, indent=2)}", file=sys.stderr) # Debugging payload

    response_data = make_api_request("POST", SAVINGS_PRODUCTS_API_URL, headers, json_data=product_payload)

    if response_data:
        product_id = response_data.get('resourceId')
        if product_id is not None:
            print(f"Savings product creation successful. Product ID: {product_id}", file=sys.stderr)
            return product_id
        else:
            print(f"Error: 'resourceId' not found in successful product creation response.", file=sys.stderr)
            return None
    else:
        # Check if the error was a 409 Conflict (product already exists)
        # We need to re-check the status code from the underlying response object
        # This is a bit more complex with the helper, but we can add specific handling
        # A simpler approach for 409 is to just try to find it if the POST fails
        print(f"Attempting to find existing product with short name '{PRODUCT_SHORTNAME}' after creation failure...", file=sys.stderr)
        existing_product_id = get_product_id_by_shortname(headers, PRODUCT_SHORTNAME)
        if existing_product_id is not None:
            print(f"Found existing product with ID: {existing_product_id}", file=sys.stderr)
            return existing_product_id
        else:
            print("Could not create or find existing product.", file=sys.stderr)
            return None


# --- Helper function to get product ID by short name ---
def get_product_id_by_shortname(headers, shortname):
    """
    Fetches savings products and finds the ID by short name.
    Returns the product ID if found, None otherwise.
    """
    print(f"Attempting to find product ID for short name '{shortname}'...", file=sys.stderr)

    # Fineract API often uses query parameters for filtering, or you fetch all and filter locally
    # Fetching all and filtering locally is simpler here.
    response_data = make_api_request("GET", SAVINGS_PRODUCTS_API_URL, headers)

    if response_data and isinstance(response_data, list):
        for product in response_data:
            if product.get('shortName') == shortname:
                product_id = product.get('id')
                if product_id is not None:
                    print(f"Found product ID {product_id} for short name '{shortname}'", file=sys.stderr)
                    return product_id
        print(f"Product with short name '{shortname}' not found in the list.", file=sys.stderr)
        return None
    else:
        print("Could not fetch savings products list.", file=sys.stderr)
        return None


# --- Function to create a client ---
# Added locale as an argument
def create_client(headers, locale):
    """
    Creates a client in Fineract.
    Returns the client ID on success, None on failure.
    """
    firstname = f"John{datetime.datetime.now().timestamp()}".replace('.', '')
    lastname = "Wick"
    # Use the updated DATE_FORMAT (e.g., "16 May 2025")
    submitted_date = datetime.datetime.now().strftime(DATE_FORMAT)
    activation_date = submitted_date
    # Generate a plausible mobile number format
    mobile_number = f"04{str(int(datetime.datetime.now().timestamp()))[-8:]}"

    print(f"Creating client for <{TENANT_ID}>: {firstname} {lastname} with Mobile Number: {mobile_number} ...", file=sys.stderr)

    client_payload = {
        "officeId": 1, # Assuming officeId 1 exists
        "legalFormId": 1, # Assuming legalFormId 1 exists (e.g., Individual)
        "firstname": firstname,
        "lastname": lastname,
        "submittedOnDate": submitted_date,
        # CORRECTED: Use "dd MMMM YYYY" to match DATE_FORMAT
        "dateFormat": "dd MMMM yyyy",
        "locale": locale, # Use the passed locale argument
        "active": True,
        "activationDate": activation_date,
        "mobileNo": mobile_number
    }
    # print(f"Client payload: {json.dumps(client_payload, indent=2)}", file=sys.stderr) # Debugging payload

    response_data = make_api_request("POST", CLIENTS_API_URL, headers, json_data=client_payload)

    if response_data:
        client_id = response_data.get('clientId')
        if client_id is not None:
            print(f"Client creation successful. Client ID: {client_id}", file=sys.stderr)
            return client_id, mobile_number # Return both ID and mobile number
        else:
            print(f"Error: 'clientId' not found in successful client creation response.", file=sys.stderr)
            return None, None
    else:
        print("Client creation failed.", file=sys.stderr)
        return None, None


# --- Function to create a savings account ---
# Added locale as an argument
def create_savings_account(headers, client_id, product_id, locale):
    """
    Creates a savings account for a client.
    Returns a tuple of (accountId, externalId) on success, (None, None) on failure.
    """
    external_id = str(uuid.uuid4())
    # Use the updated DATE_FORMAT (e.g., "16 May 2025")
    submitted_date = datetime.datetime.now().strftime(DATE_FORMAT)

    print(f"Creating savings account for Client ID: {client_id} using Product ID: {product_id} with External ID: {external_id} ...", file=sys.stderr)

    savings_payload = {
        "clientId": client_id,
        "productId": product_id,
        "externalId": external_id,
        "locale": locale, # Use the passed locale argument
        # CORRECTED: Use "dd MMMM YYYY" to match DATE_FORMAT
        "dateFormat": "dd MMMM yyyy",
        "submittedOnDate": submitted_date
    }
    #print(f"Savings account payload: {json.dumps(savings_payload, indent=2)}", file=sys.stderr) # Debugging payload
    response_data = make_api_request("POST", SAVINGS_API_URL, headers, json_data=savings_payload)
    #print(f"Savings account response data: {response_data}", file=sys.stderr) # Debugging response

    if response_data:
        savings_id = response_data.get('savingsId')
        if savings_id is not None:
            print(f"Savings account creation successful. Account ID: {savings_id} External ID {external_id}", file=sys.stderr)
            return savings_id, external_id
        else:
            print(f"Error: 'savingsId' not found in successful savings account creation response.", file=sys.stderr)
            return None, None
    else:
        print("Savings account creation failed.", file=sys.stderr)
        return None ,None


# --- Function to approve a savings account ---
# Using API_BASE_URL and existing headers
def approve_savings_account(api_base_url, headers, account_id, approved_on_date_str="16 May 2025"):
    """
    Approves a savings account in Mifos Fineract.

    Args:
        api_base_url (str): The base URL for the API endpoints (e.g., ".../fineract-provider/api/v1").
        headers (dict): Dictionary containing the necessary headers (TenantId, Authorization, Content-Type).
        account_id (int or str): The ID of the savings account to approve.
        approved_on_date_str (str): The date the account was approved on in "dd MMMM YYYY" format.
                                     Defaults to "16 May 2025" as per your example.

    Returns:
        dict or None: The JSON response body on success, or None on failure.
    """
    # Construct the URL using the standard API_BASE_URL
    url = f"{api_base_url}/savingsaccounts/{account_id}?command=approve"

    # Construct the request body
    # The approval endpoint explicitly requires "dd MMMM YYYY" format for the date
    # And "dd MMMM YYYY" for the dateFormat string literal
    body = {
        "dateFormat": "dd MMMM yyyy", # Use the specific format string literal
        "locale": "en", # Use the locale 'en' as in the example
        "approvedOnDate": approved_on_date_str # Use the passed date string
    }

    print(f"Attempting to approve savings account ID: {account_id} with date {approved_on_date_str}...", file=sys.stderr)

    # Use the existing make_api_request helper
    response_data = make_api_request("POST", url, headers, json_data=body)

    # make_api_request returns None on failure, or the response dict on success
    if response_data is not None:
        print(f"Approval request for account ID {account_id} completed.", file=sys.stderr)
        return response_data
    else:
        print(f"Approval request for account ID {account_id} failed.", file=sys.stderr)
        return None


# --- Function to register interoperation party ---
# (This function doesn't use the LOCALE variable, so no change needed)
def register_interop_party(headers, client_id, account_external_id, mobile_number):
    """
    Registers an interoperation party using the client's mobile number and account's external ID.
    Returns True on success, False on failure.
    """
    if not mobile_number:
        print(f"Warning: Mobile number not available for Client ID: {client_id}. Skipping interoperation registration.", file=sys.stderr)
        return False

    interop_url = f"{INTEROP_PARTIES_API_URL}/{mobile_number}"
    print(f"Registering interoperation party for Client ID: {client_id} with External Account ID: {account_external_id} and MSISDN: {mobile_number} at URL: {interop_url} ...", file=sys.stderr)

    interop_payload = {
        "accountId": account_external_id
    }

    # Interop registration might return 204 No Content on success, or JSON
    response_data = make_api_request("POST", interop_url, headers, json_data=interop_payload)

    # make_api_request returns None on failure, or the response dict/{} on success
    if response_data is not None:
        print("Interoperation party registration successful.", file=sys.stderr)
        return True
    else:
        print("Interoperation party registration failed.", file=sys.stderr)
        return False


# --- Main Execution ---
if __name__ == "__main__":
    print("Attempting to create or find savings product...", file=sys.stderr)
    savings_product_id = create_savings_product(HEADERS)

    if savings_product_id is None:
        print("Fatal error: Could not create or find savings product. Exiting.", file=sys.stderr)
        sys.exit(1) # Exit the script if product creation/lookup fails
    else:
        print(f"Using Savings Product ID: {savings_product_id} for account creation.", file=sys.stderr)
        print("", file=sys.stderr) # Blank line for separation

    print(f"Starting loop to create {NUMBER_OF_CLIENTS} clients and associated accounts...", file=sys.stderr)

    # Define the approval date string - using the fixed date from your example and required format
    APPROVAL_DATE_STR = "16 May 2025"
    # If you need today's date dynamically in the correct format:
    # APPROVAL_DATE_STR = datetime.datetime.now().strftime("%d %B %Y")


    for i in range(1, NUMBER_OF_CLIENTS + 1):
        print(f"--- Processing client number {i} ---", file=sys.stderr)

        # Create Client - Pass LOCALE
        client_result = create_client(HEADERS, LOCALE)
        client_id, mobile_number = client_result if client_result else (None, None)

        if client_id is None:
            print(f"Skipping savings account, approval, and interoperation registration due to client creation failure for iteration {i}.", file=sys.stderr)
            continue # Skip to the next iteration

        # Create Savings Account - Pass LOCALE
        savings_account_result  = create_savings_account(HEADERS, client_id, savings_product_id, LOCALE)
        savings_account_id, external_id = savings_account_result if savings_account_result else (None, None)

        if savings_account_id is None:
            print(f"Skipping approval and interoperation registration due to savings account creation failure for Client ID: {client_id}.", file=sys.stderr)
            continue # Skip to the next iteration

        # --- NEW: Approve Savings Account ---
        print(f"Attempting to approve savings account ID: {savings_account_id}", file=sys.stderr)
        # Call the new approval function
        approval_response_data = approve_savings_account(
            API_BASE_URL, # Use the standard API_BASE_URL
            HEADERS,
            savings_account_id,
            APPROVAL_DATE_STR # Use the defined approval date string
        )

        # Check if the approval was successful (make_api_request returns None on failure)
        if approval_response_data is not None:
             print(f"Savings account {savings_account_id} approval step completed.", file=sys.stderr)
             # You can optionally add checks here if the approval API returns specific data on success
        else:
             print(f"Savings account {savings_account_id} approval failed. Skipping interoperation registration.", file=sys.stderr)
             continue # Skip interop if approval failed


        # Register Interoperation Party
        # We now have the mobile_number from the create_client step and the external_id from create_savings_account
        register_interop_party(HEADERS, client_id, external_id, mobile_number)

        print(f"--- Finished processing client number {i} ---", file=sys.stderr)
        print("", file=sys.stderr) # Add a blank line between iterations

    print("Loop finished.", file=sys.stderr)