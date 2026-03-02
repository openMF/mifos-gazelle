#!/usr/bin/env python3
"""
Submit batch CSV file to Payment Hub bulk-processor.
"""

import requests
import sys
import configparser
import json
import uuid
from pathlib import Path
import argparse
import urllib3
import subprocess

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# Default secret key
DEFAULT_SECRET_KEY = "MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC07fxdEQlsvWvggBgrork401cdyZ9MqV6FF/RgX6+Om23gP/rME5sE5//OoG61KU3dEj9phcHH845TuyNEyc4Vhqxe1gzl4VIZkOj+/2qxYvCsP1Sv3twTs+fDfFv5NA1ZXqiswTlgjR2Lpf1tevFQEOzB9WYvH/Bu9kgr2AlHMPV6+b7gcJij/7W1hndiCk2ahbi7oXjjODF4yEU9yNAhopibe4zzMX+FO4eFYpUmrjS5wvv6aAanfoeIMTwhF81Gj9V3rHf4UsD3VEx773q7GPuXlZSLyiNrUCdvxITh+dW8Y9ICuCTy3bFbp1/HzoPdzkkUlzPNKLlLiV2w4EcxAgMBAAECggEAMjqHfwbFyQxlMHQfQa3xIdd6LejVcqDqfqSB0Wd/A2YfAMyCQbmHpbsKh0B+u4h191OjixX5EBuLfa9MQUKNFejHXaSq+/6rnjFenbwm0IwZKJiEWDbUfhvJ0blqhypuMktXJG6YETfb5fL1AjnJWGL6d3Y7IgYJ56QzsQhOuxZidSqw468xc4sIF0CoTeJdrSC2yDCVuVlLNifm/2SXBJD8mgc1WCz0rkJhvvpW4k5G9rRSkS5f0013ZNfsfiDXoqiKkafoYNEbk7TZQNInqSuONm/UECn5GLm6IXdXSGfm1O2Lt0Kk7uxW/3W00mIPeZD+hiOObheRm/2HoOEKiQKBgQDreVFQihXAEDviIB2s6fphvPcMw/IonE8tX565i3303ubQMDIyZmsi3apN5pqSjm1TKq1KIgY2D4vYTu6vO5x9MhEO2CCZWNwC+awrIYa32FwiT8D8eZ9g+DJ4/IwXyz1fG38RCz/eIsJ0NsS9z8RKBIbfMmM+WnXRez3Fq+cbRwKBgQDEs35qXThbbFUYo1QkO0vIo85iczu9NllRxo1nAqQkfu1oTYQQobxcGk/aZk0B02r9kt2eob8zfG+X3LadIhQ0/LalnGNKI9jWLkdW4dxi7xMU99MYc3NRXmR49xGxgOVkLzKyGMisUvkTnE5v/S1nhu5uFr3JPkWcCScLOTjVxwKBgHNWsDq3+GFkUkC3pHF/BhJ7wbLyA5pavfmmnZOavO6FhB8zjFLdkdq5IuMXcl0ZAHm9LLZkJhCy2rfwKb+RflxgerR/rrAOM24Np4RU3q0MgEyaLhg85pFT4T0bzu8UsRH14O6TSQxgkEjmTsX+j9IFl56aCryPCKi8Kgy53/CfAoGAdV2kUFLPDb3WCJ1r1zKKRW1398ZKHtwO73xJYu1wg1Y40cNuyX23pj0M6IOh7zT24dZ/5ecc7tuQukw3qgprhDJFyQtHMzWwbBuw9WZO2blM6XX1vuEkLajkykihhggi12RSG3IuSqQ3ejwJkUi/jsYz/fwTwcAmSLQtV8UM5IECgYEAh4h1EkMx3NXzVFmLsb4QLMXw8+Rnn9oG+NGObldQ+nmknUPu7iz5kl9lTJy+jWtqHlHL8ZtV1cZZSZnFxX5WQH5/lcz/UD+GqWoSlWuTU34PPTJqLKSYgkoOJQDEZVMVphLySS9tuo+K/h10lRS1r9KDm3RZASa1JnnWopBZIz4="

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
# Tenant Validation
# ----------------------------------------------------------------------
def get_valid_tenants(namespace='paymenthub', pod='operationsmysql-0'):
    """
    Query the operationsmysql pod to get list of valid tenant names from
    tenant_server_connections table.

    Returns:
        list: List of valid tenant names (schema_name values)
        None: If query fails (e.g., kubectl not available, pod not found)
    """
    try:
        # First get the mysql root password from secret
        password_cmd = [
            'kubectl', 'get', 'secret', '-n', namespace, 'operationsmysql',
            '-o', "jsonpath={.data.mysql-root-password}"
        ]
        password_result = subprocess.run(
            password_cmd,
            capture_output=True,
            text=False,
            timeout=10
        )

        if password_result.returncode != 0:
            print(f"Warning: Could not retrieve mysql password from secret", file=sys.stderr)
            return None

        # Decode base64 password
        import base64
        password = base64.b64decode(password_result.stdout).decode('utf-8').strip()

        # Query tenants database
        query_cmd = [
            'kubectl', 'exec', '-n', namespace, pod, '--',
            'mysql', '-uroot', f'-p{password}', 'tenants',
            '-e', 'SELECT schema_name FROM tenant_server_connections',
            '--batch', '--skip-column-names'
        ]

        result = subprocess.run(
            query_cmd,
            capture_output=True,
            text=True,
            timeout=10
        )

        if result.returncode != 0:
            print(f"Warning: Could not query tenants database", file=sys.stderr)
            return None

        # Parse output - each line is a tenant name
        tenants = [line.strip() for line in result.stdout.split('\n') if line.strip() and not line.startswith('mysql:')]
        return tenants

    except subprocess.TimeoutExpired:
        print("Warning: Tenant validation query timed out", file=sys.stderr)
        return None
    except FileNotFoundError:
        print("Warning: kubectl not found - skipping tenant validation", file=sys.stderr)
        return None
    except Exception as e:
        print(f"Warning: Tenant validation failed: {e}", file=sys.stderr)
        return None

def validate_tenant(tenant, namespace='paymenthub'):
    """
    Validate that the specified tenant exists in the database.

    Args:
        tenant: Tenant name to validate
        namespace: Kubernetes namespace (default: paymenthub)

    Returns:
        bool: True if tenant is valid, False otherwise
    """
    valid_tenants = get_valid_tenants(namespace=namespace)

    if valid_tenants is None:
        # Could not query database - warn but allow to proceed
        print(f"⚠️  Warning: Could not validate tenant '{tenant}' - proceeding anyway", file=sys.stderr)
        return True

    if tenant not in valid_tenants:
        print(f"\n❌ ERROR: Tenant '{tenant}' does not exist!", file=sys.stderr)
        print(f"\nValid tenants are: {', '.join(valid_tenants)}", file=sys.stderr)
        print(f"\nTenants are configured in the tenant_server_connections table", file=sys.stderr)
        print(f"in the 'tenants' database on the operationsmysql pod.", file=sys.stderr)
        return False

    print(f"✓ Tenant '{tenant}' validated", file=sys.stderr)
    return True

# ----------------------------------------------------------------------
# GovStack Pre-flight Check
# ----------------------------------------------------------------------
def check_identity_mapper(registering_institution, debug=False):
    """
    Check if identity-account-mapper has entries for the given institution.

    Returns:
        int: Count of beneficiary entries, or None if the check could not run.
    """
    if debug:
        print(f"\nPre-flight: checking identity mapper for '{registering_institution}'...", file=sys.stderr)

    try:
        query_cmd = [
            'kubectl', 'exec', '-n', 'infra', 'mysql-0', '--',
            'mysql', '-umifos', '-ppassword', 'identity_account_mapper',
            '-e', (
                f"SELECT COUNT(*) FROM identity_details "
                f"WHERE registering_institution_id = '{registering_institution}'"
            ),
            '--batch', '--skip-column-names'
        ]
        result = subprocess.run(query_cmd, capture_output=True, text=True, timeout=10)

        if result.returncode != 0:
            return None

        lines = [l for l in result.stdout.split('\n')
                 if l.strip() and not l.startswith('mysql:')]
        return int(lines[0].strip()) if lines else None

    except subprocess.TimeoutExpired:
        print("Warning: Identity mapper check timed out", file=sys.stderr)
        return None
    except FileNotFoundError:
        print("Warning: kubectl not found — skipping identity mapper check", file=sys.stderr)
        return None
    except Exception as e:
        if debug:
            print(f"Warning: Identity mapper check failed: {e}", file=sys.stderr)
        return None


def get_payment_modes_from_csv(csv_file_path):
    """Return the set of unique payment_mode values found in the CSV."""
    import csv as csv_module
    try:
        modes = set()
        with open(csv_file_path, 'r') as f:
            reader = csv_module.DictReader(f)
            for row in reader:
                key = next((k for k in row if k.lower() == 'payment_mode'), None)
                if key and row[key]:
                    modes.add(row[key].strip().upper())
        return modes
    except Exception:
        return set()


def get_payee_identifiers_from_csv(csv_file_path):
    """Return list of payee_identifier values (MSISDNs) from the CSV."""
    import csv as csv_module
    try:
        payees = []
        with open(csv_file_path, 'r') as f:
            reader = csv_module.DictReader(f)
            for row in reader:
                key = next((k for k in row if k.lower() == 'payee_identifier'), None)
                if key and row[key]:
                    payees.append(row[key].strip())
        return payees
    except Exception:
        return []


def detect_registering_institution(payee_identifiers, debug=False):
    """
    Query identity_details to find which registering_institution_id(s) the
    payee MSISDNs from the CSV belong to.

    Returns:
        (str or None, dict): (best_institution, {institution: match_count})
        best_institution is None if no matches found or query failed.
    """
    if not payee_identifiers:
        return None, {}

    if debug:
        print(f"\nAuto-detecting registering institution from "
              f"{len(payee_identifiers)} payee identifiers...", file=sys.stderr)

    # MSISDNs are digits — safe to embed in IN clause
    in_clause = "', '".join(payee_identifiers)

    try:
        query_cmd = [
            'kubectl', 'exec', '-n', 'infra', 'mysql-0', '--',
            'mysql', '-umifos', '-ppassword', 'identity_account_mapper',
            '-e', (
                f"SELECT registering_institution_id, COUNT(*) as cnt "
                f"FROM identity_details "
                f"WHERE payee_identity IN ('{in_clause}') "
                f"GROUP BY registering_institution_id "
                f"ORDER BY cnt DESC"
            ),
            '--batch', '--skip-column-names'
        ]
        result = subprocess.run(query_cmd, capture_output=True, text=True, timeout=10)

        if result.returncode != 0:
            return None, {}

        counts = {}
        for line in result.stdout.split('\n'):
            if line.strip() and not line.startswith('mysql:'):
                parts = line.strip().split('\t')
                if len(parts) == 2:
                    try:
                        counts[parts[0]] = int(parts[1])
                    except ValueError:
                        pass

        if not counts:
            return None, {}

        best = max(counts, key=counts.get)
        return best, counts

    except subprocess.TimeoutExpired:
        print("Warning: Institution detection query timed out", file=sys.stderr)
        return None, {}
    except FileNotFoundError:
        return None, {}
    except Exception as e:
        if debug:
            print(f"Warning: Institution detection failed: {e}", file=sys.stderr)
        return None, {}


def print_workflow_info(tenant, govstack, csv_file_path):
    """Print BPMN workflow details. Called only in --debug mode."""
    bulk_workflow = (
        f"bulk_processor_account_lookup-{tenant}" if govstack
        else f"bulk_processor-{tenant}"
    )
    payment_modes = get_payment_modes_from_csv(csv_file_path)
    mode_desc = (
        "GovStack — identity validation + de-bulking by payee FSP"
        if govstack else
        "Standard — no identity validation, payer from CSV"
    )

    print(f"\nWORKFLOW DETAILS", file=sys.stderr)
    print(f"{'─' * 50}", file=sys.stderr)
    print(f"  Bulk-processor workflow : {bulk_workflow}", file=sys.stderr)
    if payment_modes:
        print(f"  Payment mode(s) in CSV  : {', '.join(sorted(payment_modes))}", file=sys.stderr)
    print(f"  Submission mode         : {mode_desc}", file=sys.stderr)
    print(f"{'─' * 50}", file=sys.stderr)


# ----------------------------------------------------------------------
# Signature Generation
# ----------------------------------------------------------------------
def generate_signature(domain, csv_file_path, private_key, tenant='greenbank', correlation_id=None):
    """Generate X-Signature using ops service."""
    url = f"https://ops.{domain}/api/v1/util/x-signature"

    if correlation_id is None:
        correlation_id = str(uuid.uuid4())

    headers = {
        "X-CorrelationID": correlation_id,
        "Platform-TenantId": tenant,
        "privateKey": private_key
    }

    try:
        with open(csv_file_path, 'rb') as f:
            files = {'data': (csv_file_path.name, f, 'text/csv')}

            print(f"Generating signature...", file=sys.stderr)

            response = requests.post(
                url,
                headers=headers,
                files=files,
                verify=False,
                timeout=30
            )

            if response.status_code != 200:
                print(f"Error from ops service: {response.status_code}", file=sys.stderr)
                print(f"Response: {response.text}", file=sys.stderr)
                response.raise_for_status()

            signature = response.text.strip()
            print(f"✓ Signature generated", file=sys.stderr)
            return signature, correlation_id

    except Exception as e:
        print(f"Error generating signature: {e}", file=sys.stderr)
        raise

# ----------------------------------------------------------------------
# Batch Submission
# ----------------------------------------------------------------------
def submit_batch(domain, csv_file_path, signature, tenant='greenbank',
                correlation_id=None, govstack=False, registering_institution=None, program=None):
    """
    Submit batch to bulk-processor endpoint.

    Args:
        domain: Gazelle domain
        csv_file_path: Path to CSV file
        signature: X-Signature for authentication
        tenant: Tenant ID (default: greenbank)
        correlation_id: Request correlation ID
        govstack: Boolean - if True, send X-Registering-Institution-ID header (triggers GovStack workflow)
        registering_institution: Institution ID (used when govstack=True, defaults to tenant)
        program: Program ID (optional, for GovStack mode)
    """
    url = f"https://bulk-processor.{domain}/batchtransactions"

    if correlation_id is None:
        correlation_id = str(uuid.uuid4())

    headers = {
        "X-Signature": signature,
        "X-CorrelationID": correlation_id,
        "Platform-TenantId": tenant,
        "type": "csv",
        "filename": csv_file_path.name,
        "X-CallbackURL": f"http://ph-ee-connector-mock-payment-schema:8080/batches/{correlation_id}/callback",
        "Purpose": "Batch payment"
    }

    # Add GovStack headers if govstack mode is enabled
    if govstack:
        # Use registering_institution if provided, otherwise default to tenant
        institution_id = registering_institution or tenant
        headers['X-Registering-Institution-ID'] = institution_id

        if program:
            headers['X-Program-ID'] = program

    print(f"\n" + "="*80, file=sys.stderr)
    print(f"SUBMITTING BATCH", file=sys.stderr)
    print("="*80, file=sys.stderr)
    print(f"URL: {url}", file=sys.stderr)
    print(f"File: {csv_file_path.name}", file=sys.stderr)
    print(f"Tenant: {tenant}", file=sys.stderr)
    print(f"Mode: {'GovStack' if govstack else 'Non-GovStack'}", file=sys.stderr)
    if govstack:
        print(f"Registering Institution: {institution_id}", file=sys.stderr)
        if program:
            print(f"Program: {program}", file=sys.stderr)
    print("="*80, file=sys.stderr)

    try:
        with open(csv_file_path, 'rb') as f:
            files = {'data': (csv_file_path.name, f, 'text/csv')}

            response = requests.post(
                url,
                headers=headers,
                files=files,
                verify=False,
                timeout=60
            )

        print(f"\nResponse Status: {response.status_code}", file=sys.stderr)

        try:
            response_data = response.json()
            print(f"\nResponse Body:", file=sys.stderr)
            print(json.dumps(response_data, indent=2), file=sys.stderr)

            if response.status_code >= 200 and response.status_code < 300:
                return response_data
            else:
                return None
        except:
            print(f"\nResponse Body (text):", file=sys.stderr)
            print(response.text, file=sys.stderr)

            if response.status_code >= 200 and response.status_code < 300:
                return {"status": "success"}
            else:
                return None

    except Exception as e:
        print(f"\nError submitting batch: {e}", file=sys.stderr)
        return None

# ----------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------
def main():
    script_path = Path(__file__).absolute()
    base_dir = script_path.parent.parent.parent.parent
    default_config = base_dir / "config" / "config.ini"

    parser = argparse.ArgumentParser(
        description="Submit batch CSV file to Payment Hub bulk-processor",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
WHEN TO USE --govstack:
  --govstack enables GovStack G2P mode (Government-to-Person disbursement):
    * Sends X-Registering-Institution-ID header to bulk-processor
    * Triggers bulk_processor_account_lookup-{tenant} workflow
      (instead of the standard bulk_processor-{tenant})
    * Validates every beneficiary via the identity-account-mapper service
    * De-bulks the batch by payee FSP (creates one sub-batch per destination bank)
    * --registering-institution is auto-detected from CSV payees via identity-account-mapper
      (override with --registering-institution if needed)
    * Prerequisite: identity-account-mapper DB must have entries
      (run generate-mifos-vnext-data.py --regenerate if empty)

  Without --govstack (standard mode):
    * Triggers bulk_processor-{tenant} workflow
    * No beneficiary validation — payer/payee taken directly from CSV
    * Faster; suitable for testing where beneficiaries are already known

NOTE: --govstack and payment_mode (CLOSEDLOOP vs MOJALOOP) are independent:
  CLOSEDLOOP  — direct call to connector-channel, no Mojaloop switch involved
  MOJALOOP    — routes via Mojaloop vNext switch for multi-FSP transfers
  Both modes work with or without --govstack.

DECISION TABLE:
  Use case                        | --tenant  | --govstack | CSV payment_mode
  --------------------------------|-----------|------------|------------------
  Simple internal test            | redbank   | NO         | CLOSEDLOOP
  Multi-FSP via Mojaloop switch   | greenbank | NO         | MOJALOOP
  G2P bulk disbursement (switch)  | greenbank | YES        | MOJALOOP  ← recommended
  G2P closedloop (same PH only)   | redbank   | YES        | CLOSEDLOOP

EXAMPLES:
  # Standard closedloop — redbank payer, no identity validation
  ./submit-batch.py -f bulk-gazelle-closedloop-4.csv --tenant redbank

  # Standard Mojaloop — greenbank payer, no identity validation
  ./submit-batch.py -f bulk-gazelle-mojaloop-4.csv --tenant greenbank

  # GovStack G2P via Mojaloop switch — registering institution auto-detected from CSV
  ./submit-batch.py -f bulk-gazelle-mojaloop-4.csv --tenant greenbank --govstack

  # Same as above with debug output (shows workflow, detected institution, payment modes)
  ./submit-batch.py -f bulk-gazelle-mojaloop-4.csv --tenant greenbank --govstack --debug

  # Override auto-detection if needed
  ./submit-batch.py -f bulk-gazelle-mojaloop-4.csv --tenant greenbank \\
    --govstack --registering-institution greenbank
        """
    )

    parser.add_argument('--csv-file', '-f', type=Path, required=True,
                       help='CSV file to submit (required)')
    parser.add_argument('--config', '-c', type=Path, default=default_config,
                       help=f'Path to config.ini (default: {default_config})')
    parser.add_argument('--tenant', '-t', type=str, default='greenbank',
                       help='Tenant ID (default: greenbank) - will be validated against tenant_server_connections table')
    parser.add_argument('--govstack', '-g', action='store_true',
                       help='Enable GovStack mode (sends X-Registering-Institution-ID header)')
    parser.add_argument('--registering-institution', '-i', type=str, default=None,
                       help='Registering institution ID for GovStack mode. '
                            'Auto-detected from CSV payees via identity-account-mapper if not specified.')
    parser.add_argument('--program', '-p', type=str,
                       help='Program ID (optional, for GovStack mode with X-Program-ID header)')
    parser.add_argument('--secret-key', '-k', type=str, default=DEFAULT_SECRET_KEY,
                       help='Secret key for signing (default: built-in key)')
    parser.add_argument('--debug', '-d', action='store_true',
                       help='Show workflow details (BPMN workflow name, payment modes) before submitting')

    args = parser.parse_args()

    # Validate CSV file exists
    if not args.csv_file.exists():
        print(f"Error: CSV file not found: {args.csv_file}", file=sys.stderr)
        sys.exit(1)

    # Load config
    cfg = load_config(args.config)
    domain = get_gazelle_domain(cfg)

    print("="*80, file=sys.stderr)
    print(f"PAYMENT HUB BATCH TOOL - {domain}", file=sys.stderr)
    print("="*80, file=sys.stderr)
    print(f"Using CSV: {args.csv_file}", file=sys.stderr)

    # Validate tenant exists
    if not validate_tenant(args.tenant):
        sys.exit(1)

    # Resolve registering institution for GovStack mode
    registering_institution = args.registering_institution
    if args.govstack:
        if registering_institution is None:
            # Auto-detect from CSV payees via identity-account-mapper DB
            payees = get_payee_identifiers_from_csv(args.csv_file)
            if payees:
                best, counts = detect_registering_institution(payees, debug=args.debug)
                if best:
                    total = len(payees)
                    matched = counts[best]
                    if len(counts) == 1:
                        print(f"✓ Auto-detected registering institution: '{best}' "
                              f"({matched}/{total} payees matched)", file=sys.stderr)
                    else:
                        others = ', '.join(
                            f"'{k}'({v})" for k, v in counts.items() if k != best
                        )
                        print(f"⚠️  Multiple institutions found: '{best}'({matched}) "
                              f"[most], {others}", file=sys.stderr)
                        print(f"   Using '{best}'. Pass --registering-institution to override.",
                              file=sys.stderr)
                    registering_institution = best
                else:
                    print(f"\n⚠️  WARNING: Could not auto-detect registering institution.",
                          file=sys.stderr)
                    print(f"   Payees from CSV not found in identity-account-mapper.",
                          file=sys.stderr)
                    print(f"   Fix: run generate-mifos-vnext-data.py --regenerate",
                          file=sys.stderr)
                    print(f"   Or:  pass --registering-institution explicitly",
                          file=sys.stderr)
            else:
                print(f"⚠️  No payee_identifier column found in CSV — "
                      f"cannot auto-detect institution", file=sys.stderr)
        else:
            # User specified institution explicitly — run pre-flight count check
            count = check_identity_mapper(registering_institution, debug=args.debug)
            if count is not None:
                if count == 0:
                    print(f"\n⚠️  WARNING: Identity mapper has 0 entries for "
                          f"institution '{registering_institution}'", file=sys.stderr)
                    print(f"   --govstack mode will likely produce empty results.",
                          file=sys.stderr)
                    print(f"   Fix: run generate-mifos-vnext-data.py --regenerate",
                          file=sys.stderr)
                    print(f"   Or: resubmit without --govstack for standard mode.",
                          file=sys.stderr)
                else:
                    n = count
                    print(f"✓ Identity mapper: {n} beneficiar{'ies' if n != 1 else 'y'} "
                          f"found for '{registering_institution}'", file=sys.stderr)

    # Debug: show which workflow will be triggered before submitting
    if args.debug:
        print_workflow_info(args.tenant, args.govstack, args.csv_file)

    # Generate correlation ID
    correlation_id = str(uuid.uuid4())

    # Generate signature
    signature, correlation_id = generate_signature(
        domain,
        args.csv_file,
        args.secret_key,
        tenant=args.tenant,
        correlation_id=correlation_id
    )

    # Submit batch
    result = submit_batch(
        domain,
        args.csv_file,
        signature,
        tenant=args.tenant,
        correlation_id=correlation_id,
        govstack=args.govstack,
        registering_institution=registering_institution,
        program=args.program
    )

    if result:
        print("\n✓ Batch submitted successfully!", file=sys.stderr)
        sys.exit(0)
    else:
        print("\n✗ Batch submission failed", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()
