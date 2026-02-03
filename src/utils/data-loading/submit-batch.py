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
Examples:
  # Submit CSV in non-GovStack mode (uses payer from CSV, partyLookup workflow)
  ./submit-batch.py --csv-file tom-bulk4.csv

  # Submit CSV in GovStack mode (uses payer from config, batchAccountLookup workflow)
  ./submit-batch.py --csv-file bulk-govstack.csv --govstack --program SocialWelfare

  # Submit with custom tenant
  ./submit-batch.py --csv-file bulk.csv --tenant bluebank

  # Submit GovStack with custom institution
  ./submit-batch.py --csv-file bulk.csv --govstack \\
    --registering-institution greenbank --program ChildBenefit

Notes:
  - Use generate-example-csv-files.py to create CSV files
  - GovStack mode (--govstack) triggers different BPMN workflow:
    * Sends X-Registering-Institution-ID header
    * Uses bulk_processor_account_lookup-{tenant} workflow
    * Payer account from application.yml config
    * CSV payer columns are ignored
  - Non-GovStack mode (default):
    * No X-Registering-Institution-ID header
    * Uses bulk_processor-{tenant} workflow
    * Payer account from CSV
    * Supports closedloop or mojaloop payment_mode
        """
    )

    parser.add_argument('--csv-file', '-f', type=Path, required=True,
                       help='CSV file to submit (required)')
    parser.add_argument('--config', '-c', type=Path, default=default_config,
                       help=f'Path to config.ini (default: {default_config})')
    parser.add_argument('--tenant', '-t', type=str, default='greenbank',
                       help='Tenant ID (default: greenbank)')
    parser.add_argument('--govstack', '-g', action='store_true',
                       help='Enable GovStack mode (sends X-Registering-Institution-ID header)')
    parser.add_argument('--registering-institution', '-i', type=str, default='greenbank',
                       help='Registering institution ID (default: greenbank, used when --govstack is set)')
    parser.add_argument('--program', '-p', type=str,
                       help='Program ID (optional, for GovStack mode with X-Program-ID header)')
    parser.add_argument('--secret-key', '-k', type=str, default=DEFAULT_SECRET_KEY,
                       help='Secret key for signing (default: built-in key)')

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
        registering_institution=args.registering_institution,
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
