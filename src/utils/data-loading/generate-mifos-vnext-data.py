#!/usr/bin/env python3
# generates demo data for Fineract and registers it with built-in Oracle in vNext
# * deterministic by default (same data every run)
# * use --random for non-deterministic data
# * retries on transient errors (503, connection, timeout, 5xx)
import requests
import random
import hashlib
import json
import datetime
import uuid
import sys
import time
from pathlib import Path
import configparser
import argparse
import urllib3

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# ----------------------------------------------------------------------
# Global configuration
# ----------------------------------------------------------------------
_deterministic_mode = True          # default: deterministic
# Notionally greenbank = payer (a few accounts), bluebank = payee (a good but
# not large number of account holders), redbank = a second payer. Counts and
# MSISDNs are kept deterministic so the generated demo data — and the seed dump
# taken from it — are reproducible run to run.
TENANTS = {
    "bluebank": 12,
    "greenbank": 3,
    "redbank": 1
}
# The FIRST 6 bluebank MSISDNs are the OpenG2P beneficiaries registered with the
# identity-account-mapper (do NOT remove or reorder them — downstream OpenG2P demo
# data depends on these exact numbers). Entries after them are report-only holders.
DEMO_MSISDNS = {
    "greenbank": ["0413356886", "0413356887", "0413356888"],
    "bluebank":  ["0495822412", "0424942603", "0445271476",
                  "0450258089", "0498660918", "0472794194",
                  "0495100001", "0495100002", "0495100003",
                  "0495100004", "0495100005", "0495100006"],
    "redbank":   ["0423810475"],
}
# Only register payee tenants with identity-account-mapper (beneficiaries)
# Payer tenants (greenbank, redbank) don't need identity-account-mapper registration
IDENTITY_MAPPER_TENANTS = {"bluebank"}
# Payer/government institutions that register beneficiaries for G2P programs
# Beneficiaries will be registered under ALL of these institutions
REGISTERING_INSTITUTIONS = ["greenbank", "redbank"]
FIRST_NAMES = [
    "Alice", "Bob", "Charlie", "Diana", "Ethan",
    "Fiona", "George", "Hannah", "Isaac", "Julia",
    "Liam", "Mia", "Noah", "Olivia", "Aiden",
    "Zara", "Elijah", "Sophia", "Lucas", "Amelia",
    "Mason", "Chloe", "Logan", "Ava", "James",
    "Emily", "Benjamin", "Grace", "Jack", "Lily",
    "Henry", "Ella", "Samuel", "Scarlett", "Owen",
    "Aria", "Daniel", "Layla", "Leo", "Sofia",
    "Nathan", "Ruby", "Gabriel", "Isla", "Sebastian",
    "Evie", "Caleb", "Zoe", "Finn", "Nora"
]
LAST_NAMES = [
    "Smith", "Johnson", "Williams", "Brown", "Jones",
    "Garcia", "Miller", "Davis", "Rodriguez", "Martinez",
    "Hernandez", "Lopez", "Gonzalez", "Wilson", "Anderson",
    "Thomas", "Taylor", "Moore", "Jackson", "Martin",
    "Lee", "Perez", "Thompson", "White", "Harris",
    "Sanchez", "Clark", "Ramirez", "Lewis", "Robinson",
    "Walker", "Young", "Allen", "King", "Wright",
    "Scott", "Torres", "Nguyen", "Hill", "Flores",
    "Green", "Adams", "Nelson", "Baker", "Hall",
    "Rivera", "Campbell", "Mitchell", "Carter", "Roberts"
]

tenant_client_counter = {}
created_clients = []  # Track all created clients for CSV generation

# ----------------------------------------------------------------------
# Global URLs (filled in later)
# ----------------------------------------------------------------------
API_BASE_URL = None
CLIENTS_API_URL = None
SAVINGS_API_URL = None
SAVINGS_PRODUCTS_API_URL = None
INTEROP_PARTIES_API_URL = None
VNEXT_BASE_URL = None
IDENTITY_MAPPER_URL = None

AUTH_HEADER_VALUE = "Basic bWlmb3M6cGFzc3dvcmQ="   # mifos:password
HEADERS = {
    "Fineract-Platform-TenantId": " ",
    "Authorization": AUTH_HEADER_VALUE,
    "Content-Type": "application/json",
    "Accept": "*/*"
}

DATE_FORMAT = "%d %B %Y"
LOCALE = "en"
PRODUCT_CURRENCY_CODE = "USD"
PRODUCT_INTEREST_RATE = 5.0
PRODUCT_SHORTNAME = "savb"  # Max 4 chars, shared across tenants
DEFAULT_DEPOSIT_AMOUNT = 5000.0
DEFAULT_PAYMENT_TYPE_ID = 1
PAYLOAD_DATE_FORMAT_LITERAL = "dd MMMM yyyy"

# Transaction history: open accounts in the past and post a series of
# deposits/withdrawals so the transaction & savings reports show a real timeline
# (rather than a single same-day deposit). All deterministic per account.
ACCOUNT_OPENING_DAYS_AGO = 120
TXN_MIN_COUNT = 4
TXN_MAX_COUNT = 8

# Accounting: create the savings product with CASH accounting mapped to a minimal
# chart of accounts, so every deposit/withdrawal posts GL journal entries. Without
# this the accounting reports (Trial Balance, Balance Sheet, Income Statement) are
# empty. GL accounts are per-tenant; the map is (re)built per tenant, keyed by glCode.
ENABLE_ACCOUNTING = True
# glCode -> (name, type_id, role)  where type_id: 1=ASSET 2=LIABILITY 3=EQUITY 4=INCOME 5=EXPENSE
GL_ACCOUNTS = {
    "110000": ("Savings Reference (Cash)",     1, "savingsReferenceAccountId"),
    "120000": ("Overdraft Portfolio Control",  1, "overdraftPortfolioControlId"),
    "210000": ("Savings Control",              2, "savingsControlAccountId"),
    "220000": ("Transfers In Suspense",        2, "transfersInSuspenseAccountId"),
    "310000": ("Income from Fees",             4, "incomeFromFeeAccountId"),
    "320000": ("Income from Penalties",        4, "incomeFromPenaltyAccountId"),
    "330000": ("Income from Interest",         4, "incomeFromInterestId"),
    "410000": ("Interest on Savings",          5, "interestOnSavingsAccountId"),
    "420000": ("Losses Written Off",           5, "writeOffAccountId"),
}

# ----------------------------------------------------------------------
# Helper – resilient API request
# ----------------------------------------------------------------------
def make_api_request(
    method, url, headers, json_data=None, params=None,
    max_retries=5, backoff_factor=2, timeout=30
):
    """Retry on transient errors (5xx, connection, timeout)."""
    for attempt in range(max_retries):
        response = None
        try:
            response = requests.request(
                method, url, headers=headers, json=json_data,
                params=params, verify=False, timeout=timeout
            )
            response.raise_for_status()

            # ---- success path ----
            try:
                data = response.json()
                if data is None or (isinstance(data, (dict, list)) and not data):
                    return {}
                return data
            except json.JSONDecodeError:
                print("Warning: 2xx but non-JSON body", file=sys.stderr)
                return {}

        # -------------------------------------------------
        # 1. Connection / timeout → retry
        # -------------------------------------------------
        except (requests.exceptions.ConnectionError,
                requests.exceptions.Timeout) as e:
            print(f"Transient connection/timeout error: {e} – attempt {attempt+1}/{max_retries}",
                  file=sys.stderr)

        # -------------------------------------------------
        # 2. ANY 5xx (including 503) → retry
        # -------------------------------------------------
        except requests.exceptions.HTTPError as e:
            if e.response is not None and 500 <= e.response.status_code < 600:
                print(f"Transient 5xx error {e.response.status_code} – attempt {attempt+1}/{max_retries}",
                      file=sys.stderr)
            else:
                # 4xx or other non-retryable
                print(f"Non-retryable HTTP error: {e}", file=sys.stderr)
                if e.response is not None:
                    try:
                        error_detail = e.response.json()
                        print(f"Error details: {json.dumps(error_detail, indent=2)}", file=sys.stderr)
                    except:
                        print(f"Error response text: {e.response.text}", file=sys.stderr)
                return None

        # -------------------------------------------------
        # 3. Unexpected → give up
        # -------------------------------------------------
        except Exception as e:
            print(f"Unexpected error: {type(e).__name__}: {e}", file=sys.stderr)
            return None

        # ---- back-off ----
        if attempt < max_retries - 1:
            sleep = backoff_factor * (2 ** attempt)
            print(f"Retrying in {sleep}s...", file=sys.stderr)
            time.sleep(sleep)

    print("Failed after all retries", file=sys.stderr)
    return None

# ----------------------------------------------------------------------
# Savings product helpers
# ----------------------------------------------------------------------
def get_product_id_by_shortname(headers, shortname):
    data = make_api_request("GET", SAVINGS_PRODUCTS_API_URL, headers)
    if data is None:
        print(f"WARNING: Failed to retrieve products list", file=sys.stderr)
        return None
    if not isinstance(data, list):
        print(f"WARNING: Unexpected response type: {type(data)}", file=sys.stderr)
        return None
    for p in data:
        if p.get("shortName") == shortname:
            return p.get("id")
    return None

def ensure_gl_accounts(headers):
    """Ensure the minimal chart of accounts exists for the current tenant and
    return a mapping of savings-product accounting role -> GL account id. Idempotent:
    an account is created only if its glCode is not already present."""
    gl_url = f"{API_BASE_URL}/glaccounts"
    existing = make_api_request("GET", gl_url, headers) or []
    by_code = {a.get("glCode"): a.get("id") for a in existing if isinstance(a, dict)}
    role_to_id = {}
    for gl_code, (name, type_id, role) in GL_ACCOUNTS.items():
        acct_id = by_code.get(gl_code)
        if acct_id is None:
            payload = {
                "name": name,
                "glCode": gl_code,
                "type": type_id,
                "usage": 1,               # DETAIL
                "manualEntriesAllowed": True,
                "description": f"Demo account for savings CASH accounting ({name})",
            }
            resp = make_api_request("POST", gl_url, headers, json_data=payload)
            acct_id = resp.get("resourceId") if resp else None
            if acct_id is None:
                print(f"ERROR: failed to create GL account {gl_code} ({name})", file=sys.stderr)
                return None
            print(f"Created GL account {gl_code} ({name}) -> id {acct_id}", file=sys.stderr)
        role_to_id[role] = acct_id
    return role_to_id

def create_savings_product(headers, product_name):
    print(f"Finding/creating product '{PRODUCT_SHORTNAME}' for {product_name}...", file=sys.stderr)
    pid = get_product_id_by_shortname(headers, PRODUCT_SHORTNAME)
    if pid:
        print(f"Using existing product ID {pid}", file=sys.stderr)
        return pid

    payload = {
        "name": product_name,
        "shortName": PRODUCT_SHORTNAME,
        "currencyCode": PRODUCT_CURRENCY_CODE,
        "digitsAfterDecimal": 2,
        "inMultiplesOf": 1,
        "locale": "en",
        "nominalAnnualInterestRate": PRODUCT_INTEREST_RATE,
        "interestCompoundingPeriodType": 1,
        "interestPostingPeriodType": 4,
        "interestCalculationType": 1,
        "interestCalculationDaysInYearType": 365,
        "accountingRule": 1
    }

    # CASH accounting so deposits/withdrawals post GL journal entries (feeds the
    # Trial Balance / Balance Sheet / Income Statement reports).
    if ENABLE_ACCOUNTING:
        role_to_id = ensure_gl_accounts(headers)
        if role_to_id:
            payload["accountingRule"] = 2   # CASH
            payload.update(role_to_id)
        else:
            print("WARNING: GL setup failed; falling back to NONE accounting", file=sys.stderr)

    resp = make_api_request("POST", SAVINGS_PRODUCTS_API_URL, headers, json_data=payload)
    if resp:
        pid = resp.get("resourceId")
        if pid:
            print(f"Created product ID {pid}", file=sys.stderr)
            return pid
    print(f"ERROR: Failed to create product for {product_name}", file=sys.stderr)
    return None

# ----------------------------------------------------------------------
# Query existing clients (for --regenerate mode)
# ----------------------------------------------------------------------
def get_clients_from_mifos(headers, tenant):
    """Query Mifos to get all clients for a tenant."""
    url = f"{CLIENTS_API_URL}"

    data = make_api_request("GET", url, headers)

    clients = []
    if data and 'pageItems' in data:
        for client in data['pageItems']:
            clients.append({
                'client_id': client.get('id'),
                'name': client.get('displayName'),
                'mobile': client.get('mobileNo'),
                'tenant': tenant
            })

    return clients

def check_client_exists_by_mobile(headers, mobile_number):
    """Check if a client with this mobile number already exists.

    Fineract's GET /clients?mobileNo= filter is not applied server-side (it returns
    the first client regardless of the value), so match on mobileNo client-side —
    otherwise every new MSISDN false-matches the first client and only one client
    is ever created per tenant."""
    data = make_api_request("GET", CLIENTS_API_URL, headers)

    if data and 'pageItems' in data:
        for client in data['pageItems']:
            if client.get('mobileNo') == mobile_number:
                return {
                    'client_id': client.get('id'),
                    'name': client.get('displayName'),
                    'mobile': client.get('mobileNo')
                }
    return None

def get_savings_accounts_for_client(headers, client_id):
    """Get savings accounts for a specific client."""
    url = f"{API_BASE_URL}/clients/{client_id}/accounts"

    data = make_api_request("GET", url, headers)

    if data:
        # Get savings accounts
        savings = data.get('savingsAccounts', [])
        if savings:
            # Return the first active savings account
            for acct in savings:
                if acct.get('status', {}).get('active'):
                    return acct.get('id')
            # If no active, return first one
            return savings[0].get('id')

    return None

def fetch_all_clients_from_mifos(tenants):
    """Fetch all clients with their savings accounts from Mifos."""
    all_clients = []

    for tenant in tenants:
        print(f"Querying {tenant} for existing clients...", file=sys.stderr)
        tenant_headers = HEADERS.copy()
        tenant_headers["Fineract-Platform-TenantId"] = tenant

        clients = get_clients_from_mifos(tenant_headers, tenant)

        for client in clients:
            if not client['mobile']:
                print(f"  Skipping {client['name']} - no mobile number", file=sys.stderr)
                continue

            # Get savings account
            account_id = get_savings_accounts_for_client(tenant_headers, client['client_id'])
            if not account_id:
                print(f"  Skipping {client['name']} - no savings account", file=sys.stderr)
                continue

            client['account_id'] = account_id
            all_clients.append(client)
            print(f"  Found: {client['name']} (MSISDN: {client['mobile']}, Account: {account_id})", file=sys.stderr)

    return all_clients

# ----------------------------------------------------------------------
# Client creation
# ----------------------------------------------------------------------
def create_client(headers, locale, tenant_id, mobile_number, submitted_date_str=None):
    count = tenant_client_counter.get(tenant_id, 0)
    tenant_client_counter[tenant_id] = count + 1

    # Name generation – deterministic when _deterministic_mode=True
    global _deterministic_mode
    if _deterministic_mode:
        seed_str = f"{tenant_id}-{count}"
        seed = int(hashlib.sha256(seed_str.encode()).hexdigest(), 16) % (10 ** 8)
        rng = random.Random(seed)
        # Use deterministic indices based on seed to ensure unique names
        firstname_idx = seed % len(FIRST_NAMES)
        lastname_idx = (seed // len(FIRST_NAMES)) % len(LAST_NAMES)
        firstname = FIRST_NAMES[firstname_idx]
        lastname = LAST_NAMES[lastname_idx]
    else:
        rng = random.Random()
        firstname = rng.choice(FIRST_NAMES)
        lastname = rng.choice(LAST_NAMES)

    full_name = f"{firstname} {lastname}"

    submitted_date = submitted_date_str or datetime.datetime.now().strftime(DATE_FORMAT)

    print(f"Creating client {full_name} ({mobile_number}) for {tenant_id}", file=sys.stderr)

    payload = {
        "officeId": 1,
        "legalFormId": 1,
        "firstname": firstname,
        "lastname": lastname,
        "submittedOnDate": submitted_date,
        "dateFormat": PAYLOAD_DATE_FORMAT_LITERAL,
        "locale": locale,
        "active": True,
        "activationDate": submitted_date,
        "mobileNo": mobile_number
    }
    resp = make_api_request("POST", CLIENTS_API_URL, headers, json_data=payload)
    if resp:
        cid = resp.get("clientId")
        if cid:
            print(f"Client ID {cid}", file=sys.stderr)
            return cid, mobile_number, full_name
    print("Client creation failed", file=sys.stderr)
    return None, None, None

# ----------------------------------------------------------------------
# Savings account helpers
# ----------------------------------------------------------------------
def create_savings_account(headers, client_id, product_id, locale, submitted_date_str=None):
    external_id = str(uuid.uuid4())
    submitted_date = submitted_date_str or datetime.datetime.now().strftime(DATE_FORMAT)
    payload = {
        "clientId": client_id,
        "productId": product_id,
        "externalId": external_id,
        "locale": locale,
        "dateFormat": PAYLOAD_DATE_FORMAT_LITERAL,
        "submittedOnDate": submitted_date
    }
    resp = make_api_request("POST", SAVINGS_API_URL, headers, json_data=payload)
    if resp:
        sid = resp.get("savingsId")
        if sid:
            print(f"Savings account {sid} (ext {external_id})", file=sys.stderr)
            return sid, external_id
    print("Savings account creation failed", file=sys.stderr)
    return None, None

def approve_savings_account(api_base_url, headers, account_id, date_str):
    url = f"{api_base_url}/savingsaccounts/{account_id}?command=approve"
    body = {"dateFormat": PAYLOAD_DATE_FORMAT_LITERAL, "locale": "en", "approvedOnDate": date_str}
    return make_api_request("POST", url, headers, json_data=body)

def activate_savings_account(api_base_url, headers, account_id, date_str):
    url = f"{api_base_url}/savingsaccounts/{account_id}?command=activate"
    body = {"dateFormat": PAYLOAD_DATE_FORMAT_LITERAL, "locale": "en", "activatedOnDate": date_str}
    return make_api_request("POST", url, headers, json_data=body)

def make_deposit(api_base_url, headers, account_id, amount, date_str, payment_type_id=DEFAULT_PAYMENT_TYPE_ID):
    url = f"{api_base_url}/savingsaccounts/{account_id}/transactions?command=deposit"
    body = {
        "locale": "en",
        "dateFormat": PAYLOAD_DATE_FORMAT_LITERAL,
        "transactionDate": date_str,
        "transactionAmount": amount,
        "paymentTypeId": payment_type_id
    }
    return make_api_request("POST", url, headers, json_data=body)

def make_withdrawal(api_base_url, headers, account_id, amount, date_str, payment_type_id=DEFAULT_PAYMENT_TYPE_ID):
    url = f"{api_base_url}/savingsaccounts/{account_id}/transactions?command=withdrawal"
    body = {
        "locale": "en",
        "dateFormat": PAYLOAD_DATE_FORMAT_LITERAL,
        "transactionDate": date_str,
        "transactionAmount": amount,
        "paymentTypeId": payment_type_id
    }
    return make_api_request("POST", url, headers, json_data=body)

def generate_transaction_history(api_base_url, headers, account_id, opening_date, seed):
    """Post a deterministic series of deposits/withdrawals from opening_date to today
    so savings/transaction reports show a real timeline. Keeps the running balance
    positive. Returns the number of transactions posted."""
    rng = random.Random(seed)
    now = datetime.datetime.now()
    span_days = max((now - opening_date).days, 1)
    n_txns = rng.randint(TXN_MIN_COUNT, TXN_MAX_COUNT)

    # Spread transaction dates across the account's lifetime (first = opening day).
    offsets = sorted(rng.sample(range(0, span_days + 1), min(n_txns, span_days + 1)))
    if offsets and offsets[0] != 0:
        offsets[0] = 0  # ensure the opening deposit lands on the opening date

    balance = 0.0
    posted = 0
    for idx, off in enumerate(offsets):
        txn_date = (opening_date + datetime.timedelta(days=off)).strftime(DATE_FORMAT)
        if idx == 0:
            # opening deposit
            amount = float(rng.choice([2000, 3000, 5000, 8000, 10000]))
            if make_deposit(api_base_url, headers, account_id, amount, txn_date):
                balance += amount
                posted += 1
            continue
        # Withdraw only if there's a sensible balance, otherwise deposit.
        if balance > 500 and rng.random() < 0.4:
            amount = float(round(rng.uniform(100, balance * 0.5) / 50) * 50) or 100.0
            if make_withdrawal(api_base_url, headers, account_id, amount, txn_date):
                balance -= amount
                posted += 1
        else:
            amount = float(rng.choice([500, 1000, 1500, 2500, 4000]))
            if make_deposit(api_base_url, headers, account_id, amount, txn_date):
                balance += amount
                posted += 1
    print(f"Posted {posted} transactions (balance {balance:.2f})", file=sys.stderr)
    return posted

# ----------------------------------------------------------------------
# Interop / vNext
# ----------------------------------------------------------------------
def register_interop_party(headers, client_id, account_external_id, mobile_number):
    if not mobile_number:
        return False
    url = f"{INTEROP_PARTIES_API_URL}/{mobile_number}"
    payload = {"accountId": account_external_id}
    resp = make_api_request("POST", url, headers, json_data=payload)
    if resp is not None:
        print("Interop party registered", file=sys.stderr)
        return True
    return False

def register_client_with_vnext(headers, tenant_id, mobile_number, currency="USD"):
    url = f"{VNEXT_BASE_URL}{mobile_number}"
    payload = {"fspId": tenant_id, "currency": currency}
    vnext_headers = {
        "fspiop-source": tenant_id,
        "Date": datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        "Accept": "application/json",
        "Content-Type": "application/json"
    }
    try:
        resp = requests.post(url, headers=vnext_headers, json=payload, verify=False, timeout=30)
        if 200 <= resp.status_code < 300:
            print(f"vNext registration OK for {mobile_number}", file=sys.stderr)
            return True
        # 500 usually means duplicate association — verify with GET
        if resp.status_code == 500:
            get_resp = requests.get(url, headers={"Accept": "application/json"}, verify=False, timeout=30)
            if get_resp.status_code == 200:
                existing = get_resp.json()
                if existing.get("fspId") == tenant_id:
                    print(f"vNext already registered for {mobile_number} (skipping duplicate)", file=sys.stderr)
                    return True
                # Wrong FSP — delete and re-register
                requests.delete(url, headers=vnext_headers, verify=False, timeout=30)
                resp2 = requests.post(url, headers=vnext_headers, json=payload, verify=False, timeout=30)
                if 200 <= resp2.status_code < 300:
                    print(f"vNext re-registered {mobile_number} (was {existing.get('fspId')}, now {tenant_id})", file=sys.stderr)
                    return True
        print(f"✗ vNext registration failed for {mobile_number}: HTTP {resp.status_code}", file=sys.stderr)
    except Exception as e:
        print(f"✗ vNext registration failed for {mobile_number}: {e}", file=sys.stderr)
    return False

def register_beneficiary_with_identity_mapper(tenant_id, mobile_number, account_id, registering_institution):
    """Register beneficiary with identity-account-mapper.

    Args:
        tenant_id: The payee FSP where beneficiary has an account (e.g., 'bluebank')
        mobile_number: Beneficiary MSISDN
        account_id: Beneficiary account number at the payee FSP
        registering_institution: The payer/government institution (e.g., 'greenbank', 'redbank')
    """
    if not mobile_number or not account_id:
        return False

    url = f"{IDENTITY_MAPPER_URL}/beneficiary"
    # Request ID must be exactly 12 characters (matching register-and-generate-csv.py)
    request_id = str(uuid.uuid4()).replace('-', '')[:12]

    beneficiary = {
        "payeeIdentity": mobile_number,
        "paymentModality": "00",  # MSISDN payment modality
        "financialAddress": str(account_id),
        "bankingInstitutionCode": tenant_id  # Payee FSP
    }

    payload = {
        "requestID": request_id,  # Note: capital ID required
        "sourceBBID": registering_institution,  # Payer/government institution
        "beneficiaries": [beneficiary]
    }

    mapper_headers = {
        "X-CallbackURL": "https://localhost/callback",  # Dummy callback URL
        "X-Registering-Institution-ID": registering_institution,  # Payer/government institution
        "Content-Type": "application/json",
        "Accept": "application/json"
    }

    try:
        # Use raw requests here to handle 500 responses with structured data
        response = requests.post(url, json=payload, headers=mapper_headers, verify=False, timeout=30)

        # Check if we got a structured response (even if HTTP status is 500)
        # responseCode "01" means the identity mapper processed it
        # (callback failure is expected with fake callback URL)
        try:
            resp_json = response.json()
            if 'responseCode' in resp_json:
                print(f"✓ Registered {mobile_number} → account {account_id} @ {tenant_id} (payer: {registering_institution})", file=sys.stderr)
                return True
        except:
            pass

        # If 2xx status, consider it success
        if 200 <= response.status_code < 300:
            print(f"✓ Registered {mobile_number} → account {account_id} @ {tenant_id} (payer: {registering_institution})", file=sys.stderr)
            return True

        # Otherwise report error
        print(f"✗ Failed to register {mobile_number}: HTTP {response.status_code}", file=sys.stderr)
        print(f"   Response: {response.text}", file=sys.stderr)
        return False

    except Exception as e:
        print(f"✗ Failed to register {mobile_number}: {e}", file=sys.stderr)
        return False

# ----------------------------------------------------------------------
# Config / URL setup
# ----------------------------------------------------------------------
def load_config(config_file):
    cfg = configparser.ConfigParser()
    if not cfg.read(config_file):
        print(f"Cannot read config {config_file}", file=sys.stderr)
        sys.exit(1)
    return cfg

def get_gazelle_domain(cfg):
    try:
        return cfg.get('general', 'GAZELLE_DOMAIN')
    except (configparser.NoSectionError, configparser.NoOptionError) as e:
        print(f"Config error: {e}", file=sys.stderr)
        sys.exit(1)

def set_global_urls(domain):
    global API_BASE_URL, CLIENTS_API_URL, SAVINGS_API_URL, SAVINGS_PRODUCTS_API_URL
    global INTEROP_PARTIES_API_URL, VNEXT_BASE_URL, IDENTITY_MAPPER_URL
    API_BASE_URL = f"https://mifos.{domain}/fineract-provider/api/v1"
    CLIENTS_API_URL = f"{API_BASE_URL}/clients"
    SAVINGS_API_URL = f"{API_BASE_URL}/savingsaccounts"
    SAVINGS_PRODUCTS_API_URL = f"{API_BASE_URL}/savingsproducts"
    INTEROP_PARTIES_API_URL = f"{API_BASE_URL}/interoperation/parties/MSISDN"
    VNEXT_BASE_URL = f"http://vnextadmin.{domain}/_interop/participants/MSISDN/"
    IDENTITY_MAPPER_URL = f"https://identity-mapper.{domain}"


# ----------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------
if __name__ == "__main__":
    script_path = Path(__file__).absolute()
    base_dir = script_path.parent.parent.parent.parent
    default_config = base_dir / "config" / "config.ini"

    parser = argparse.ArgumentParser(
        description="Generate demo data for Mifos + Mojaloop vNext"
    )
    parser.add_argument('--config', '-c', type=Path, default=default_config,
                        help=f'Path to config.ini (default: {default_config})')
    parser.add_argument('--random', action='store_true',
                        help='Generate random (non-deterministic) clients')
    parser.add_argument('--regenerate', action='store_true',
                        help='Query existing clients and regenerate CSVs (idempotent mode)')
    args = parser.parse_args()

    # ----- config & URLs -----
    cfg = load_config(args.config)
    domain = get_gazelle_domain(cfg)
    set_global_urls(domain)

    # ----- regenerate mode (query existing clients) -----
    if args.regenerate:
        print("\n=== REGENERATE MODE: Querying existing clients ===\n", file=sys.stderr)

        tenants_list = list(TENANTS.keys())
        all_clients = fetch_all_clients_from_mifos(tenants_list)

        if not all_clients:
            print("ERROR: No existing clients found in Mifos", file=sys.stderr)
            sys.exit(1)

        print(f"\nFound {len(all_clients)} clients total", file=sys.stderr)

        # Register clients with identity-account-mapper (payees only) and vNext (all)
        print("\nRegistering clients with identity-account-mapper and vNext...", file=sys.stderr)
        print(f"  Identity-mapper payee tenants: {', '.join(IDENTITY_MAPPER_TENANTS)}", file=sys.stderr)
        print(f"  Registering under payers: {', '.join(REGISTERING_INSTITUTIONS)}", file=sys.stderr)
        mapper_success_count = 0
        vnext_success_count = 0
        for client in all_clients:
            # Register with identity-account-mapper (only for payee tenants)
            # Register under ALL payer institutions (greenbank, redbank)
            if client['tenant'] in IDENTITY_MAPPER_TENANTS:
                for payer in REGISTERING_INSTITUTIONS:
                    if register_beneficiary_with_identity_mapper(client['tenant'], client['mobile'], client['account_id'], payer):
                        mapper_success_count += 1
            else:
                print(f"  Skipping identity-mapper for payer tenant: {client['tenant']} ({client['mobile']})", file=sys.stderr)

            # Register with vNext oracle (all tenants need this for party lookup)
            tenant_headers = HEADERS.copy()
            tenant_headers["Fineract-Platform-TenantId"] = client['tenant']
            if register_client_with_vnext(tenant_headers, client['tenant'], client['mobile']):
                vnext_success_count += 1

            # Add to created_clients for CSV generation
            created_clients.append(client)

        payee_count = sum(1 for c in all_clients if c['tenant'] in IDENTITY_MAPPER_TENANTS)
        print(f"\nRegistered {mapper_success_count}/{payee_count} payee clients with identity-account-mapper", file=sys.stderr)
        print(f"Registered {vnext_success_count}/{len(all_clients)} clients with vNext oracle", file=sys.stderr)

        print("\n✓ Regeneration complete!", file=sys.stderr)
        sys.exit(0)

    # ----- create mode (default) -----
    print("\n=== CREATE MODE: Generating new clients ===\n", file=sys.stderr)

    # ----- deterministic / random mode -----
    #global _deterministic_mode
    _deterministic_mode = not args.random
    if _deterministic_mode:
        # Use deterministic but unique MSISDNs per tenant
        # Generate MSISDNs with tenant-specific prefixes to ensure uniqueness
        unique_mobile_numbers = []
        tenant_prefixes = {
            'greenbank': '0413',  # 0413xxxxxx for greenbank
            'redbank': '0423',    # 0423xxxxxx for redbank
            'bluebank': '0495'    # 0495xxxxxx for bluebank
        }
        for tenant_id, num_clients in TENANTS.items():
            if tenant_id in DEMO_MSISDNS:
                unique_mobile_numbers.extend(DEMO_MSISDNS[tenant_id][:num_clients])
                continue
            prefix = tenant_prefixes.get(tenant_id, '0400')
            # Use tenant-specific seed for deterministic but unique numbers
            tenant_seed = int(hashlib.sha256(tenant_id.encode()).hexdigest(), 16) % (10 ** 8)
            tenant_rng = random.Random(tenant_seed)
            for i in range(num_clients):
                # Generate 6-digit suffix (000000-999999)
                suffix = tenant_rng.randint(100000, 999999)
                unique_mobile_numbers.append(f"{prefix}{suffix}")
    else:
        # Random mode - generate random MSISDNs
        random.seed()
        total_clients = sum(TENANTS.values())
        unique_mobile_numbers = [
            f"04{random.randint(10000000, 99999999)}" for _ in range(total_clients)
        ]
        random.shuffle(unique_mobile_numbers)

    # ----- process each tenant -----
    failed_tenants = []
    TENANT_MAX_RETRIES = 3
    TENANT_RETRY_DELAY = 30  # seconds between per-tenant retries

    for tenant_id, num_clients in TENANTS.items():
        print(f"\n=== Tenant: {tenant_id} ===", file=sys.stderr)
        HEADERS["Fineract-Platform-TenantId"] = tenant_id
        product_name = f"{tenant_id}-savings"

        # If the tenant already has clients, re-register them and skip creation.
        # This makes CREATE mode idempotent per-tenant, so re-running after a
        # partial failure (e.g. greenbank not ready during initial deploy) safely
        # picks up the missed tenant without duplicating the others.
        existing = [c for c in get_clients_from_mifos(HEADERS, tenant_id) if c.get('mobile')]
        if existing and len(existing) >= num_clients:
            print(f"  {tenant_id} already has {len(existing)}/{num_clients} client(s) - re-registering, skipping creation", file=sys.stderr)
            for client in existing:
                acct_id = get_savings_accounts_for_client(HEADERS, client['client_id'])
                if not acct_id:
                    print(f"  Skipping {client['name']} - no savings account", file=sys.stderr)
                    continue
                register_client_with_vnext(HEADERS, tenant_id, client['mobile'])
                if tenant_id in IDENTITY_MAPPER_TENANTS:
                    for payer in REGISTERING_INSTITUTIONS:
                        register_beneficiary_with_identity_mapper(tenant_id, client['mobile'], acct_id, payer)
                else:
                    print(f"  Skipping identity-mapper for payer tenant {tenant_id}", file=sys.stderr)
                created_clients.append({
                    'tenant': tenant_id,
                    'mobile': client['mobile'],
                    'account_id': acct_id,
                    'client_id': client['client_id'],
                    'name': client['name']
                })
            # Consume the pre-allocated MSISDNs to keep the flat list aligned
            for _ in range(num_clients):
                unique_mobile_numbers.pop(0)
            print(f"=== Finished tenant {tenant_id} (existing clients re-registered) ===\n", file=sys.stderr)
            continue

        # Extract this tenant's pre-allocated MSISDNs before the retry loop so
        # the same numbers can be reused on each attempt without consuming more
        # from the shared list.
        tenant_msisdns = [unique_mobile_numbers.pop(0) for _ in range(num_clients)]

        tenant_ok = False
        for attempt in range(1, TENANT_MAX_RETRIES + 1):
            if attempt > 1:
                print(f"  Retrying tenant {tenant_id} (attempt {attempt}/{TENANT_MAX_RETRIES}) "
                      f"after {TENANT_RETRY_DELAY}s — Fineract seed data may still be loading...",
                      file=sys.stderr)
                time.sleep(TENANT_RETRY_DELAY)
                # Another process or a previous partial attempt may have created clients
                existing = [c for c in get_clients_from_mifos(HEADERS, tenant_id) if c.get('mobile')]
                if existing:
                    print(f"  {tenant_id} now has clients — switching to re-register mode", file=sys.stderr)
                    for client in existing:
                        acct_id = get_savings_accounts_for_client(HEADERS, client['client_id'])
                        if not acct_id:
                            continue
                        register_client_with_vnext(HEADERS, tenant_id, client['mobile'])
                        if tenant_id in IDENTITY_MAPPER_TENANTS:
                            for payer in REGISTERING_INSTITUTIONS:
                                register_beneficiary_with_identity_mapper(tenant_id, client['mobile'], acct_id, payer)
                        created_clients.append({
                            'tenant': tenant_id,
                            'mobile': client['mobile'],
                            'account_id': acct_id,
                            'client_id': client['client_id'],
                            'name': client['name']
                        })
                    tenant_ok = True
                    break

            # product
            product_id = create_savings_product(HEADERS, product_name)
            if not product_id:
                print(f"  ERROR: Failed to create/find product for tenant {tenant_id} (attempt {attempt})", file=sys.stderr)
                continue  # retry

            process_date = datetime.datetime.now().strftime(DATE_FORMAT)
            # Open accounts in the past so transaction history spans a real period.
            opening_dt = datetime.datetime.now() - datetime.timedelta(days=ACCOUNT_OPENING_DAYS_AGO)
            opening_date_str = opening_dt.strftime(DATE_FORMAT)
            clients_created = 0

            for i, mobile in enumerate(tenant_msisdns, 1):
                print(f"\n--- Client {i}/{num_clients} for {tenant_id} (attempt {attempt}) ---", file=sys.stderr)

                # Check if client already exists with this mobile number
                existing_client = check_client_exists_by_mobile(HEADERS, mobile)
                if existing_client:
                    print(f"Client with mobile {mobile} already exists (ID: {existing_client['client_id']})", file=sys.stderr)
                    client_id = existing_client['client_id']
                    name = existing_client['name']

                    # Get existing savings account
                    acct_id = get_savings_accounts_for_client(HEADERS, client_id)
                    if not acct_id:
                        print(f"No savings account found for existing client {mobile}, skipping", file=sys.stderr)
                        continue

                    print(f"Using existing account {acct_id}", file=sys.stderr)

                    # Re-register with vNext and identity-account-mapper (idempotent)
                    register_client_with_vnext(HEADERS, tenant_id, mobile)

                    if tenant_id in IDENTITY_MAPPER_TENANTS:
                        for payer in REGISTERING_INSTITUTIONS:
                            register_beneficiary_with_identity_mapper(tenant_id, mobile, acct_id, payer)
                    else:
                        print(f"Skipping identity-mapper for payer tenant {tenant_id}", file=sys.stderr)

                    created_clients.append({
                        'tenant': tenant_id,
                        'mobile': mobile,
                        'account_id': acct_id,
                        'client_id': client_id,
                        'name': name
                    })

                    clients_created += 1
                    print(f"--- Re-registered existing client {i} ---", file=sys.stderr)
                    continue

                # Create new client (back-dated so it can hold historical txns)
                client_id, mobile, name = create_client(HEADERS, LOCALE, tenant_id, mobile, opening_date_str)
                if not client_id:
                    continue

                # savings account (back-dated)
                acct_id, ext_id = create_savings_account(HEADERS, client_id, product_id, LOCALE, opening_date_str)
                if not acct_id:
                    continue

                # approve (on opening date)
                if not approve_savings_account(API_BASE_URL, HEADERS, acct_id, opening_date_str):
                    continue

                # activate (on opening date)
                if not activate_savings_account(API_BASE_URL, HEADERS, acct_id, opening_date_str):
                    continue

                # transaction history: deterministic series of deposits/withdrawals
                # from the opening date to today (seeded per account for reproducibility)
                txn_seed = int(hashlib.sha256(f"{tenant_id}-{mobile}".encode()).hexdigest(), 16) % (10 ** 8)
                if not generate_transaction_history(API_BASE_URL, HEADERS, acct_id, opening_dt, txn_seed):
                    continue

                # interop & vNext
                register_interop_party(HEADERS, client_id, ext_id, mobile)
                register_client_with_vnext(HEADERS, tenant_id, mobile)

                # identity-account-mapper (only for payee tenants)
                if tenant_id in IDENTITY_MAPPER_TENANTS:
                    for payer in REGISTERING_INSTITUTIONS:
                        register_beneficiary_with_identity_mapper(tenant_id, mobile, acct_id, payer)
                else:
                    print(f"Skipping identity-mapper for payer tenant {tenant_id}", file=sys.stderr)

                created_clients.append({
                    'tenant': tenant_id,
                    'mobile': mobile,
                    'account_id': acct_id,
                    'client_id': client_id,
                    'name': name
                })

                clients_created += 1
                print(f"--- Finished client {i} ---", file=sys.stderr)

            # end of client loop — check if this attempt succeeded
            if clients_created == num_clients:
                tenant_ok = True
                break
            print(f"  Attempt {attempt}: only {clients_created}/{num_clients} clients created for {tenant_id}", file=sys.stderr)

        # end of retry loop
        if not tenant_ok:
            print(f"  ERROR: Could not fully process tenant {tenant_id} after {TENANT_MAX_RETRIES} attempts", file=sys.stderr)
            failed_tenants.append(tenant_id)

        print(f"=== Finished tenant {tenant_id} ===\n", file=sys.stderr)

    # ----- final status -----
    if failed_tenants:
        print(f"\n{'='*60}", file=sys.stderr)
        print(f"ERROR: Failed to process {len(failed_tenants)} tenant(s): {', '.join(failed_tenants)}", file=sys.stderr)
        print(f"{'='*60}", file=sys.stderr)
        sys.exit(1)

    print("\n✓ All tenants processed successfully.", file=sys.stderr)
