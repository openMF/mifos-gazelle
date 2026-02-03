#!/usr/bin/env python3
"""
Generate example bulk payment CSV files for Payment Hub testing.
Creates CSV files with test data from Mifos clients.
"""

import sys
import csv
import uuid
import argparse
import configparser
import requests
import urllib3
from pathlib import Path

# Disable SSL warnings for local development
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# ----------------------------------------------------------------------
# Mifos Client Query Functions
# ----------------------------------------------------------------------
def get_mifos_host(config=None):
    """Get Mifos hostname from config or use default."""
    if config:
        try:
            domain = config.get('general', 'GAZELLE_DOMAIN')
            return f"http://mifos.{domain}"
        except:
            pass
    return "http://mifos.mifos.gazelle.localhost"

def query_mifos_clients(tenant, limit=10, username="mifos", password="password", mifos_host=None):
    """
    Query Mifos for clients in a specific tenant.

    Args:
        tenant: Tenant identifier (e.g., 'greenbank', 'redbank', 'bluebank')
        limit: Maximum number of clients to fetch
        username: Mifos username
        password: Mifos password
        mifos_host: Mifos API host URL

    Returns:
        List of client dictionaries with 'id', 'name', 'msisdn', 'account' keys
    """
    if mifos_host is None:
        mifos_host = get_mifos_host()

    url = f"{mifos_host}/fineract-provider/api/v1/clients"
    headers = {"Fineract-Platform-TenantId": tenant}
    params = {"limit": limit}

    try:
        print(f"Querying Mifos for {tenant} clients...", file=sys.stderr)
        response = requests.get(
            url,
            headers=headers,
            params=params,
            auth=(username, password),
            verify=False,
            timeout=10
        )
        response.raise_for_status()

        data = response.json()
        clients = []

        for item in data.get('pageItems', []):
            client = {
                'id': str(item['id']),
                'name': item.get('displayName', 'Unknown'),
                'msisdn': item.get('mobileNo', ''),
                'account': item.get('accountNo', str(item['id']))
            }
            if client['msisdn']:  # Only include clients with phone numbers
                clients.append(client)

        print(f"✓ Found {len(clients)} clients in {tenant}", file=sys.stderr)
        return clients

    except Exception as e:
        print(f"Warning: Could not query Mifos for {tenant}: {e}", file=sys.stderr)
        return []

# ----------------------------------------------------------------------
# Utility Functions
# ----------------------------------------------------------------------
def load_config(config_path):
    """Load configuration from config.ini file."""
    config = configparser.ConfigParser()
    config.read(config_path)
    return config

def get_gazelle_domain(config):
    """Extract Gazelle domain from config."""
    try:
        return config.get('general', 'GAZELLE_DOMAIN')
    except:
        return 'mifos.gazelle.localhost'

def get_clients_from_mifos(config=None):
    """
    Query Mifos for payer and payee clients.

    Returns:
        Tuple of (payer_closedloop, payer_mojaloop, payees_list)
    """
    mifos_host = get_mifos_host(config)

    # Get redbank payer (first client with MSISDN)
    redbank_clients = query_mifos_clients('redbank', limit=1, mifos_host=mifos_host)
    payer_closedloop = redbank_clients[0]['msisdn'] if redbank_clients else None

    # Get greenbank payer (first client with MSISDN)
    greenbank_clients = query_mifos_clients('greenbank', limit=1, mifos_host=mifos_host)
    payer_mojaloop = greenbank_clients[0]['msisdn'] if greenbank_clients else None

    # Get bluebank payees (multiple clients)
    bluebank_clients = query_mifos_clients('bluebank', limit=20, mifos_host=mifos_host)
    payees = []
    for client in bluebank_clients:
        payees.append({
            'msisdn': client['msisdn'],
            'name': client['name'],
            'account': client['account'],
            'amounts': [10.00, 16.00]  # Standard test amounts
        })

    return payer_closedloop, payer_mojaloop, payees

# ----------------------------------------------------------------------
# CSV Generation
# ----------------------------------------------------------------------
def generate_csv_data(mode='CLOSEDLOOP', payer_msisdn=None, payees=None, num_rows=None):
    """
    Generate CSV test data for bulk transactions.

    Args:
        mode: 'CLOSEDLOOP' or 'MOJALOOP'
        payer_msisdn: Payer phone number (defaults to DEFAULT_PAYER_MSISDN)
        payees: List of payee dictionaries (defaults to DEFAULT_PAYEES)
        num_rows: Number of rows to generate (defaults to all payees * all amounts)

    Returns:
        List of transaction dictionaries
    """
    if payer_msisdn is None:
        payer_msisdn = DEFAULT_PAYER_MSISDN
    if payees is None:
        payees = DEFAULT_PAYEES

    transactions = []
    txn_id = 0
    row_count = 0

    for payee in payees:
        for amount in payee['amounts']:
            if num_rows is not None and row_count >= num_rows:
                break

            transaction = {
                'id': txn_id,
                'request_id': str(uuid.uuid4()),
                'payment_mode': mode,
                'payer_identifier_type': 'MSISDN',
                'payer_identifier': payer_msisdn,
                'payee_identifier_type': 'MSISDN',
                'payee_identifier': payee['msisdn'],
                'amount': int(amount),
                'currency': 'USD',
                'note': f"Payment to {payee['name']}"
            }

            transactions.append(transaction)
            txn_id += 1
            row_count += 1

        if num_rows is not None and row_count >= num_rows:
            break

    return transactions

def generate_govstack_csv_data(payees=None, num_rows=None):
    """
    Generate CSV test data for GovStack mode (no payer columns).

    Args:
        payees: List of payee dictionaries (defaults to DEFAULT_PAYEES)
        num_rows: Number of rows to generate (defaults to all payees * all amounts)

    Returns:
        List of transaction dictionaries
    """
    if payees is None:
        payees = DEFAULT_PAYEES

    transactions = []
    txn_id = 0
    row_count = 0

    for payee in payees:
        for amount in payee['amounts']:
            if num_rows is not None and row_count >= num_rows:
                break

            transaction = {
                'id': txn_id,
                'request_id': str(uuid.uuid4()),
                'payment_mode': 'CLOSEDLOOP',  # GovStack uses CLOSEDLOOP
                'payee_identifier_type': 'MSISDN',
                'payee_identifier': payee['msisdn'],
                'amount': int(amount),
                'currency': 'USD',
                'note': f"Payment to {payee['name']}",
                'account_number': payee['account']
            }

            transactions.append(transaction)
            txn_id += 1
            row_count += 1

        if num_rows is not None and row_count >= num_rows:
            break

    return transactions

def write_csv_file(csv_path, transactions, govstack_mode=False):
    """Write transactions to CSV file."""
    # Define column order based on mode
    if govstack_mode:
        fieldnames = [
            'id', 'request_id', 'payment_mode',
            'payee_identifier_type', 'payee_identifier',
            'amount', 'currency', 'note', 'account_number'
        ]
    else:
        fieldnames = [
            'id', 'request_id', 'payment_mode',
            'payer_identifier_type', 'payer_identifier',
            'payee_identifier_type', 'payee_identifier',
            'amount', 'currency', 'note'
        ]

    with open(csv_path, 'w', newline='') as csvfile:
        writer = csv.DictWriter(csvfile, fieldnames=fieldnames)
        writer.writeheader()
        for txn in transactions:
            writer.writerow(txn)

    return csv_path

def generate_csv_files(output_dir=None, payer_msisdn_closedloop=None, payer_msisdn_mojaloop=None, payees=None, num_rows=None):
    """
    Generate all example CSV files.

    Args:
        output_dir: Directory to write CSV files (defaults to script directory)
        payer_msisdn_closedloop: Payer phone number for CLOSEDLOOP (redbank)
        payer_msisdn_mojaloop: Payer phone number for MOJALOOP (greenbank)
        payees: List of payee dictionaries
        num_rows: Number of rows to generate per file

    Returns:
        Dictionary of generated file paths with payer info
    """
    if output_dir is None:
        output_dir = Path(__file__).parent
    else:
        output_dir = Path(output_dir)

    output_dir.mkdir(parents=True, exist_ok=True)

    # Use defaults if not provided
    if payer_msisdn_closedloop is None:
        payer_msisdn_closedloop = DEFAULT_PAYER_MSISDN_REDBANK
    if payer_msisdn_mojaloop is None:
        payer_msisdn_mojaloop = DEFAULT_PAYER_MSISDN_GREENBANK

    files = {}

    # Determine filename suffix based on num_rows
    suffix = f"-{num_rows}" if num_rows else "-4"

    # Generate closedloop CSV with redbank payer
    closedloop_data = generate_csv_data('CLOSEDLOOP', payer_msisdn_closedloop, payees, num_rows)
    closedloop_path = output_dir / f'bulk-gazelle-closedloop{suffix}.csv'
    write_csv_file(closedloop_path, closedloop_data, govstack_mode=False)
    files['closedloop'] = {'path': closedloop_path, 'payer': payer_msisdn_closedloop, 'tenant': 'redbank', 'rows': len(closedloop_data)}
    print(f"✓ Generated {closedloop_path} ({len(closedloop_data)} rows, payer: {payer_msisdn_closedloop}, tenant: redbank)", file=sys.stderr)

    # Generate mojaloop CSV with greenbank payer
    mojaloop_data = generate_csv_data('MOJALOOP', payer_msisdn_mojaloop, payees, num_rows)
    mojaloop_path = output_dir / f'bulk-gazelle-mojaloop{suffix}.csv'
    write_csv_file(mojaloop_path, mojaloop_data, govstack_mode=False)
    files['mojaloop'] = {'path': mojaloop_path, 'payer': payer_msisdn_mojaloop, 'tenant': 'greenbank', 'rows': len(mojaloop_data)}
    print(f"✓ Generated {mojaloop_path} ({len(mojaloop_data)} rows, payer: {payer_msisdn_mojaloop}, tenant: greenbank)", file=sys.stderr)

    # Generate GovStack CSV (no payer columns)
    govstack_data = generate_govstack_csv_data(payees, num_rows)
    govstack_path = output_dir / f'bulk-gazelle-govstack{suffix}.csv'
    write_csv_file(govstack_path, govstack_data, govstack_mode=True)
    files['govstack'] = {'path': govstack_path, 'payer': 'N/A (uses registeringInstitutionId)', 'tenant': 'greenbank/redbank', 'rows': len(govstack_data)}
    print(f"✓ Generated {govstack_path} ({len(govstack_data)} rows, GovStack mode)", file=sys.stderr)

    return files

# ----------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------
def main():
    # Setup argument parser
    script_path = Path(__file__).absolute()
    base_dir = script_path.parent.parent.parent.parent
    default_config = base_dir / "config" / "config.ini"
    default_output = script_path.parent

    parser = argparse.ArgumentParser(
        description="Generate example bulk payment CSV files",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Generate all CSV files with defaults (queries Mifos for payers/payees)
  ./generate-example-csv-files.py

  # Generate with 10 rows per file
  ./generate-example-csv-files.py --num-rows 10

  # Generate 100 rows for mojaloop mode only
  ./generate-example-csv-files.py --mode mojaloop --num-rows 100

  # Generate with custom config
  ./generate-example-csv-files.py --config ~/myconfig.ini

  # Generate to specific directory
  ./generate-example-csv-files.py --output-dir /tmp/csv-files

  # Generate with custom payer MSISDNs for each tenant
  ./generate-example-csv-files.py --payer-msisdn-closedloop 0987654321 --payer-msisdn-mojaloop 0413356886

Generated files (suffix indicates row count):
  - bulk-gazelle-closedloop-N.csv (CLOSEDLOOP mode, redbank payer)
  - bulk-gazelle-mojaloop-N.csv (MOJALOOP mode, greenbank payer)
  - bulk-gazelle-govstack-N.csv (GovStack mode, no payer columns)

Tenant/Mode mapping:
  - CLOSEDLOOP → redbank tenant (payer), bluebank tenant (payees)
    * Uses minimal_mock_fund_transfer workflow
    * Direct transfers within same Payment Hub instance
    * For testing: ./submit-batch.py --csv-file bulk-gazelle-closedloop-N.csv --tenant redbank

  - MOJALOOP → greenbank tenant (payer), bluebank tenant (payees via switch)
    * Uses PayerFundTransfer workflow with Mojaloop vNext switch
    * Cross-FSP transfers with party lookup, quotes, and switch routing
    * For testing: ./submit-batch.py --csv-file bulk-gazelle-mojaloop-N.csv --tenant greenbank

  - GOVSTACK → Can use either redbank or greenbank as payer (specify with --registering-institution)
    * Enables identity validation via identity-account-mapper
    * Batch de-bulking by payee FSP (bankingInstitutionCode)
    * For testing with redbank: ./submit-batch.py --csv-file bulk-gazelle-govstack-N.csv --tenant redbank --govstack --registering-institution redbank
    * For testing with greenbank: ./submit-batch.py --csv-file bulk-gazelle-govstack-N.csv --tenant greenbank --govstack --registering-institution greenbank

Notes:
  - Payees are always from bluebank tenant (beneficiary FSP)
  - Redbank is default payer for CLOSEDLOOP mode (direct transfers)
  - Greenbank is default payer for MOJALOOP mode (via switch)
  - GovStack mode requires beneficiaries registered with matching registeringInstitutionId
    (use ./register-beneficiaries.py --payer-tenant <redbank|greenbank> first)
        """
    )

    parser.add_argument('--config', '-c', type=Path, default=default_config,
                       help=f'Path to config.ini (default: {default_config})')
    parser.add_argument('--output-dir', '-o', type=Path, default=default_output,
                       help=f'Output directory for CSV files (default: {default_output})')
    parser.add_argument('--mode', '-m', choices=['closedloop', 'mojaloop', 'govstack', 'all'],
                       default='all',
                       help='Generate specific mode only, or all (default: all)')
    parser.add_argument('--num-rows', '-n', type=int, default=None,
                       help='Number of transaction rows to generate per file (default: all available payees)')
    parser.add_argument('--payer-msisdn-closedloop', type=str, default=None,
                       help='Payer MSISDN for CLOSEDLOOP/redbank (default: query from Mifos redbank)')
    parser.add_argument('--payer-msisdn-mojaloop', type=str, default=None,
                       help='Payer MSISDN for MOJALOOP/greenbank (default: query from Mifos greenbank)')
    # Legacy parameter for backward compatibility
    parser.add_argument('--payer-msisdn', '-p', type=str, default=None,
                       help='Legacy: sets both closedloop and mojaloop payer (overrides Mifos query)')
    parser.add_argument('--no-mifos-query', action='store_true',
                       help='Skip Mifos query and require MSISDNs to be provided via command line')

    args = parser.parse_args()

    print("=== CSV File Generation ===\n", file=sys.stderr)
    print(f"Output directory: {args.output_dir}\n", file=sys.stderr)

    # Prepare output directory
    args.output_dir.mkdir(parents=True, exist_ok=True)

    # Load config
    config = None
    if args.config.exists():
        config = load_config(args.config)

    # Query Mifos for client data (unless --no-mifos-query is set)
    payees = []
    if not args.no_mifos_query:
        try:
            payer_closedloop_mifos, payer_mojaloop_mifos, payees_mifos = get_clients_from_mifos(config)

            # Use Mifos-queried values as defaults if not provided via command line
            if args.payer_msisdn_closedloop is None:
                args.payer_msisdn_closedloop = payer_closedloop_mifos
            if args.payer_msisdn_mojaloop is None:
                args.payer_msisdn_mojaloop = payer_mojaloop_mifos
            if payees_mifos:
                payees = payees_mifos

            print(f"\n✓ Queried Mifos successfully", file=sys.stderr)
        except Exception as e:
            print(f"\nWarning: Could not query Mifos: {e}", file=sys.stderr)
            print(f"Please provide MSISDNs via command line arguments\n", file=sys.stderr)

    # Handle legacy --payer-msisdn parameter (overrides Mifos query)
    if args.payer_msisdn:
        args.payer_msisdn_closedloop = args.payer_msisdn
        args.payer_msisdn_mojaloop = args.payer_msisdn

    # Validate we have required data
    if not args.payer_msisdn_closedloop or not args.payer_msisdn_mojaloop:
        print("Error: Could not determine payer MSISDNs. Please provide via command line:", file=sys.stderr)
        print("  --payer-msisdn-closedloop <msisdn>", file=sys.stderr)
        print("  --payer-msisdn-mojaloop <msisdn>", file=sys.stderr)
        sys.exit(1)

    if not payees:
        print("Error: Could not determine payee MSISDNs. Mifos query failed.", file=sys.stderr)
        sys.exit(1)

    # Generate requested CSV files
    if args.mode == 'all':
        files = generate_csv_files(args.output_dir, args.payer_msisdn_closedloop, args.payer_msisdn_mojaloop, payees, args.num_rows)
        print(f"\n✓ Generated {len(files)} CSV files", file=sys.stderr)
    else:
        # Generate single mode
        suffix = f"-{args.num_rows}" if args.num_rows else "-4"
        if args.mode == 'govstack':
            data = generate_govstack_csv_data(payees, args.num_rows)
            csv_path = args.output_dir / f'bulk-gazelle-{args.mode}{suffix}.csv'
            write_csv_file(csv_path, data, govstack_mode=True)
            print(f"✓ Generated {csv_path} ({len(data)} rows, GovStack mode)", file=sys.stderr)
        elif args.mode == 'closedloop':
            data = generate_csv_data('CLOSEDLOOP', args.payer_msisdn_closedloop, payees, args.num_rows)
            csv_path = args.output_dir / f'bulk-gazelle-{args.mode}{suffix}.csv'
            write_csv_file(csv_path, data, govstack_mode=False)
            print(f"✓ Generated {csv_path} ({len(data)} rows, payer: {args.payer_msisdn_closedloop}, tenant: redbank)", file=sys.stderr)
        elif args.mode == 'mojaloop':
            data = generate_csv_data('MOJALOOP', args.payer_msisdn_mojaloop, payees, args.num_rows)
            csv_path = args.output_dir / f'bulk-gazelle-{args.mode}{suffix}.csv'
            write_csv_file(csv_path, data, govstack_mode=False)
            print(f"✓ Generated {csv_path} ({len(data)} rows, payer: {args.payer_msisdn_mojaloop}, tenant: greenbank)", file=sys.stderr)

    print("\n============================================================", file=sys.stderr)
    total_txns = len(payees) * len(payees[0]['amounts']) if payees else 0
    print(f"CSV files created with {total_txns} transactions:", file=sys.stderr)
    if args.mode == 'all' or args.mode == 'closedloop':
        print(f"  CLOSEDLOOP payer: {args.payer_msisdn_closedloop} (redbank)", file=sys.stderr)
    if args.mode == 'all' or args.mode == 'mojaloop':
        print(f"  MOJALOOP payer: {args.payer_msisdn_mojaloop} (greenbank)", file=sys.stderr)
    for payee in payees[:5]:  # Show first 5 payees
        print(f"  Payee: {payee['name']} ({payee['msisdn']}) - account {payee['account']}", file=sys.stderr)
    if len(payees) > 5:
        print(f"  ... and {len(payees) - 5} more payees", file=sys.stderr)
    print("============================================================\n", file=sys.stderr)

if __name__ == "__main__":
    main()
