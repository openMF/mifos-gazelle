#!/usr/bin/env python3
"""
View transaction history for all Mifos clients across tenants.
Queries Mifos dynamically and displays transactions in a neat format.
"""

import requests
import sys
import configparser
from pathlib import Path
import argparse
import urllib3
from datetime import datetime

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# ----------------------------------------------------------------------
# Configuration
# ----------------------------------------------------------------------
def load_config(config_file):
    """Load configuration from config.ini."""
    cfg = configparser.ConfigParser()
    if not cfg.read(config_file):
        print(f"Cannot read config {config_file}", file=sys.stderr)
        sys.exit(1)
    return cfg

def get_gazelle_domain(cfg):
    """Extract GAZELLE_DOMAIN from config."""
    try:
        return cfg.get('general', 'GAZELLE_DOMAIN')
    except (configparser.NoSectionError, configparser.NoOptionError) as e:
        print(f"Config error: {e}", file=sys.stderr)
        sys.exit(1)

# ----------------------------------------------------------------------
# Mifos API
# ----------------------------------------------------------------------
AUTH_HEADER_VALUE = "Basic bWlmb3M6cGFzc3dvcmQ="  # mifos:password
TENANTS = ["bluebank", "greenbank", "redbank"]

def make_request(url, headers):
    """Make API request with error handling."""
    try:
        response = requests.get(url, headers=headers, verify=False, timeout=30)
        response.raise_for_status()
        return response.json()
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        return None

def get_clients(domain, tenant):
    """Get all clients for a tenant."""
    url = f"https://mifos.{domain}/fineract-provider/api/v1/clients"
    headers = {
        "Fineract-Platform-TenantId": tenant,
        "Authorization": AUTH_HEADER_VALUE,
        "Accept": "application/json"
    }

    data = make_request(url, headers)
    if data and 'pageItems' in data:
        return data['pageItems']
    return []

def get_client_accounts(domain, tenant, client_id):
    """Get all accounts for a client."""
    url = f"https://mifos.{domain}/fineract-provider/api/v1/clients/{client_id}/accounts"
    headers = {
        "Fineract-Platform-TenantId": tenant,
        "Authorization": AUTH_HEADER_VALUE,
        "Accept": "application/json"
    }

    data = make_request(url, headers)
    if data:
        return data.get('savingsAccounts', [])
    return []

def get_account_transactions(domain, tenant, account_id):
    """Get transaction history for a savings account."""
    # Get account details with transactions association
    url = f"https://mifos.{domain}/fineract-provider/api/v1/savingsaccounts/{account_id}?associations=transactions"
    headers = {
        "Fineract-Platform-TenantId": tenant,
        "Authorization": AUTH_HEADER_VALUE,
        "Accept": "application/json"
    }

    data = make_request(url, headers)
    if data:
        return data.get('transactions', [])
    return []

# ----------------------------------------------------------------------
# Formatting
# ----------------------------------------------------------------------
def format_currency(amount, currency="USD"):
    """Format currency amount."""
    return f"{currency} {amount:,.2f}"

def format_date(date_array):
    """Format date from Mifos array format [year, month, day]."""
    if date_array and len(date_array) >= 3:
        return f"{date_array[0]}-{date_array[1]:02d}-{date_array[2]:02d}"
    return "N/A"

def print_separator(char="=", length=80):
    """Print a separator line."""
    print(char * length)

def print_transaction(txn, indent=6):
    """Print a single transaction in compact format."""
    spaces = " " * indent
    txn_type = txn.get('transactionType', {}).get('value', 'Unknown')
    txn_date = format_date(txn.get('date'))
    txn_amount = txn.get('amount', 0)
    txn_balance = txn.get('runningBalance', 0)
    txn_id = txn.get('id', 'N/A')

    # Determine if credit or debit
    is_credit = txn.get('transactionType', {}).get('deposit', False)
    is_debit = txn.get('transactionType', {}).get('withdrawal', False)

    # Compact one-line format
    amount_str = f"Credit: {format_currency(txn_amount)}" if is_credit else f"Debit: {format_currency(txn_amount)}" if is_debit else f"Amount: {format_currency(txn_amount)}"
    print(f"{spaces}[{txn_id}] {txn_date} | {txn_type:20} | {amount_str:20} | Balance: {format_currency(txn_balance)}")

# ----------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------
def main():
    script_path = Path(__file__).absolute()
    base_dir = script_path.parent.parent.parent.parent
    default_config = base_dir / "config" / "config.ini"

    parser = argparse.ArgumentParser(
        description="View Mifos transaction history for all clients"
    )
    parser.add_argument('--config', '-c', type=Path, default=default_config,
                        help=f'Path to config.ini (default: {default_config})')
    parser.add_argument('--tenant', '-t', type=str,
                        help='Show only specific tenant (e.g., bluebank, greenbank)')
    parser.add_argument('--client-id', type=int,
                        help='Show only specific client ID')
    parser.add_argument('--balance', '-b', action='store_true',
                        help='Show condensed tenant/client/balance summary only')
    args = parser.parse_args()

    # Load config
    cfg = load_config(args.config)
    domain = get_gazelle_domain(cfg)

    if args.balance:
        print(f"MIFOS BALANCES - {domain}")
        print(f"{'Tenant':<12} {'Client':<30} {'Mobile':<15} {'Balance':>12}")
        print("-" * 72)
    else:
        print_separator()
        print(f"MIFOS TRANSACTION HISTORY - {domain}")
        print_separator()

    # Filter tenants if specified
    tenants_to_query = [args.tenant] if args.tenant else TENANTS

    total_clients = 0
    total_accounts = 0
    total_transactions = 0

    for tenant in tenants_to_query:
        if not args.balance:
            print(f"\n{'='*80}")
            print(f"TENANT: {tenant.upper()}")
            print(f"{'='*80}")

        clients = get_clients(domain, tenant)

        if not clients:
            if not args.balance:
                print(f"  No clients found in {tenant}")
            continue

        for client in clients:
            client_id = client.get('id')
            client_name = client.get('displayName', 'Unknown')
            client_mobile = client.get('mobileNo', 'N/A')

            # Filter by client ID if specified
            if args.client_id and client_id != args.client_id:
                continue

            total_clients += 1

            if not args.balance:
                print(f"  Client: {client_name} | Mobile: {client_mobile} | ID: {client_id}")

            accounts = get_client_accounts(domain, tenant, client_id)

            if not accounts:
                if not args.balance:
                    print(f"    No accounts found")
                continue

            for account in accounts:
                account_id = account.get('id')
                account_number = account.get('accountNo', 'N/A')
                account_status = account.get('status', {}).get('value', 'Unknown')
                account_balance = account.get('accountBalance', 0)

                total_accounts += 1

                if args.balance:
                    print(f"{tenant:<12} {client_name:<30} {client_mobile:<15} {format_currency(account_balance):>12}")
                else:
                    print(f"    Account #{account_number} (ID: {account_id}) | Status: {account_status} | Balance: {format_currency(account_balance)}")

                    transactions = get_account_transactions(domain, tenant, account_id)

                    if not transactions:
                        print(f"      No transactions")
                        continue

                    # Sort transactions by date (newest first)
                    transactions.sort(key=lambda x: x.get('date', [0, 0, 0]), reverse=True)

                    print(f"      Transactions ({len(transactions)}):")
                    for txn in transactions:
                        print_transaction(txn)
                        total_transactions += 1

    # Summary
    if args.balance:
        print("-" * 72)
        print(f"Tenants: {len(tenants_to_query)} | Clients: {total_clients} | Accounts: {total_accounts}")
    else:
        print(f"\n{'='*80}")
        print(f"SUMMARY: Tenants: {len(tenants_to_query)} | Clients: {total_clients} | Accounts: {total_accounts} | Transactions: {total_transactions}")
        print_separator()

if __name__ == "__main__":
    main()
