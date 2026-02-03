#!/usr/bin/env python3
"""
Register beneficiaries with identity-account-mapper.
Fetches clients from Mifos and registers them as beneficiaries.
"""

import sys
import requests
import configparser
import argparse
from pathlib import Path
import urllib3

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# ----------------------------------------------------------------------
# Configuration
# ----------------------------------------------------------------------
def load_config(config_path):
    """Load configuration from config.ini file."""
    config = configparser.ConfigParser()
    config.read(config_path)
    return config

def get_gazelle_domain(config):
    """Extract Gazelle domain from config."""
    try:
        return config['general']['GAZELLE_DOMAIN']
    except KeyError:
        return 'mifos.gazelle.localhost'

def get_tenants(config):
    """Extract tenants from config."""
    try:
        return [t.strip() for t in config['gazelle']['tenants'].split(',')]
    except KeyError:
        return ['greenbank', 'bluebank']

# ----------------------------------------------------------------------
# Mifos Client Fetching
# ----------------------------------------------------------------------
def fetch_clients_from_mifos(domain, tenant):
    """Fetch all clients with mobile numbers from Mifos for a tenant."""
    # Fineract is at mifos.mifos.gazelle.localhost not fineract.mifos.gazelle.localhost
    url = f"https://mifos.{domain}/fineract-provider/api/v1/clients"

    headers = {
        "Fineract-Platform-TenantId": tenant,
        "Authorization": "Basic bWlmb3M6cGFzc3dvcmQ="  # mifos:password
    }

    try:
        response = requests.get(url, headers=headers, verify=False, timeout=30)
        response.raise_for_status()

        clients_data = response.json()
        clients = []

        for client in clients_data.get('pageItems', []):
            mobile = client.get('mobileNo')
            if not mobile:
                continue

            # Get client accounts
            client_id = client['id']
            accounts_url = f"https://mifos.{domain}/fineract-provider/api/v1/clients/{client_id}/accounts"
            accounts_response = requests.get(accounts_url, headers=headers, verify=False, timeout=30)
            accounts_response.raise_for_status()
            accounts_data = accounts_response.json()

            # Get first savings account
            savings_accounts = accounts_data.get('savingsAccounts', [])
            if savings_accounts:
                account_id = savings_accounts[0]['id']

                clients.append({
                    'name': client.get('displayName', 'Unknown'),
                    'mobile': mobile,
                    'account_id': account_id,
                    'tenant': tenant
                })

        return clients

    except Exception as e:
        print(f"Error fetching clients from {tenant}: {e}", file=sys.stderr)
        return []

def fetch_all_clients_from_mifos(domain, tenants, payer_tenant):
    """
    Fetch clients from all tenants EXCEPT the payer tenant.

    Args:
        domain: Gazelle domain
        tenants: List of all tenants
        payer_tenant: Tenant to exclude (payer, not a beneficiary)

    Returns:
        List of client dictionaries (beneficiaries only)
    """
    all_clients = []

    for tenant in tenants:
        if tenant == payer_tenant:
            print(f"Skipping {tenant} (payer tenant, not a beneficiary)", file=sys.stderr)
            continue

        print(f"Querying {tenant} for beneficiaries...", file=sys.stderr)
        clients = fetch_clients_from_mifos(domain, tenant)

        for client in clients:
            print(f"  Found: {client['name']} (MSISDN: {client['mobile']}, Account: {client['account_id']})", file=sys.stderr)
            all_clients.append(client)

    return all_clients

# ----------------------------------------------------------------------
# Identity Mapper Registration
# ----------------------------------------------------------------------
def register_with_identity_mapper(domain, client, registering_institution):
    """
    Register a client as a beneficiary with identity-account-mapper.

    Args:
        domain: Gazelle domain
        client: Client dictionary with mobile, account_id, tenant
        registering_institution: Institution ID registering the beneficiary (e.g., 'greenbank')
    """
    url = f"https://identity-mapper.{domain}/beneficiary"

    # Generate simple request ID (12 chars)
    import uuid
    request_id = str(uuid.uuid4()).replace('-', '')[:12]

    beneficiary = {
        "payeeIdentity": client['mobile'],
        "paymentModality": "01",
        "financialAddress": str(client['account_id']).zfill(9),  # Pad to 9 digits
        "bankingInstitutionCode": client['tenant']
    }

    payload = {
        "requestID": request_id,
        "beneficiaries": [beneficiary]
    }

    headers = {
        "X-CallbackURL": "http://ph-ee-connector-mock-payment-schema:8080/beneficiary/registration/callback",
        "X-Registering-Institution-ID": registering_institution,
        "Content-Type": "application/json",
        "Accept": "application/json"
    }

    try:
        response = requests.post(url, json=payload, headers=headers, verify=False, timeout=30)

        # Check if we got a structured response
        try:
            response_data = response.json()
            response_message = response_data.get('message', response.text)
        except:
            response_message = response.text

        if response.status_code in [200, 201, 202]:
            print(f"✓ Registered {client['name']} ({client['mobile']}) → account {client['account_id']} @ {client['tenant']}", file=sys.stderr)
            print(f"   Response: {response_message}", file=sys.stderr)
            return True
        else:
            print(f"✗ Failed to register {client['name']} ({client['mobile']})", file=sys.stderr)
            print(f"   Status: {response.status_code}", file=sys.stderr)
            print(f"   Response: {response_message}", file=sys.stderr)
            return False

    except Exception as e:
        print(f"✗ Error registering {client['name']}: {e}", file=sys.stderr)
        return False

# ----------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------
def main():
    # Setup argument parser
    script_path = Path(__file__).absolute()
    base_dir = script_path.parent.parent.parent.parent
    default_config = base_dir / "config" / "config.ini"

    parser = argparse.ArgumentParser(
        description="Register beneficiaries with identity-account-mapper",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Register all beneficiaries (excluding greenbank payer)
  ./register-beneficiaries.py

  # Use custom config
  ./register-beneficiaries.py --config ~/myconfig.ini

  # Use different payer tenant
  ./register-beneficiaries.py --payer-tenant bluebank

  # Register with specific institution
  ./register-beneficiaries.py --registering-institution ministry

How it works:
  - Fetches clients from all Mifos tenants
  - Excludes clients from payer tenant (they are payers, not beneficiaries)
  - Registers remaining clients as beneficiaries with identity-account-mapper
  - Uses registering institution ID (defaults to payer-tenant)
        """
    )

    parser.add_argument('--config', '-c', type=Path, default=default_config,
                       help=f'Path to config.ini (default: {default_config})')
    parser.add_argument('--payer-tenant', '-p', type=str, default='greenbank',
                       help='Payer tenant to exclude from beneficiary registration (default: greenbank)')
    parser.add_argument('--registering-institution', '-i', type=str,
                       help='Registering institution ID (defaults to payer-tenant)')

    args = parser.parse_args()

    # Default registering institution to payer tenant if not specified
    if not args.registering_institution:
        args.registering_institution = args.payer_tenant

    print("=== Identity Mapper Beneficiary Registration ===\n", file=sys.stderr)

    # Load config
    cfg = load_config(args.config)
    domain = get_gazelle_domain(cfg)
    tenants = get_tenants(cfg)

    print(f"Domain: {domain}", file=sys.stderr)
    print(f"All tenants: {', '.join(tenants)}", file=sys.stderr)
    print(f"Payer tenant (excluded): {args.payer_tenant}", file=sys.stderr)
    print(f"Registering institution: {args.registering_institution}\n", file=sys.stderr)

    # Fetch beneficiaries (all clients except payer tenant)
    print("Fetching beneficiaries from Mifos...", file=sys.stderr)
    beneficiaries = fetch_all_clients_from_mifos(domain, tenants, args.payer_tenant)

    if not beneficiaries:
        print("\nNo beneficiaries found in Mifos", file=sys.stderr)
        sys.exit(1)

    print(f"\nFound {len(beneficiaries)} beneficiaries\n", file=sys.stderr)

    # Register each beneficiary with identity-account-mapper
    print("Registering beneficiaries with identity-account-mapper...", file=sys.stderr)
    success_count = 0
    for beneficiary in beneficiaries:
        if register_with_identity_mapper(domain, beneficiary, args.registering_institution):
            success_count += 1

    print(f"\n✓ Registered {success_count}/{len(beneficiaries)} beneficiaries", file=sys.stderr)

    if success_count == len(beneficiaries):
        print("\n✓ All beneficiaries registered successfully!", file=sys.stderr)
        sys.exit(0)
    else:
        print(f"\n⚠ {len(beneficiaries) - success_count} beneficiaries failed to register", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()
