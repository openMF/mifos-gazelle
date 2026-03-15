#!/usr/bin/env python3
"""
Submit batch CSV file to Payment Hub bulk-processor.
"""

import importlib.util
import json
import sys
import uuid
from pathlib import Path

import argparse
import requests
import urllib3

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# ---------------------------------------------------------------------------
# Load shared utilities from batch_utils.py (same directory)
# ---------------------------------------------------------------------------
_UTILS = Path(__file__).parent / "batch_utils.py"
_spec = importlib.util.spec_from_file_location("batch_utils", _UTILS)
_mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_mod)

load_config                   = _mod.load_config
get_gazelle_domain            = _mod.get_gazelle_domain
get_valid_tenants             = _mod.get_valid_tenants
FALLBACK_TENANTS              = _mod.FALLBACK_TENANTS
get_payment_modes_from_csv    = _mod.get_payment_modes_from_csv
get_payee_identifiers_from_csv = _mod.get_payee_identifiers_from_csv
detect_registering_institution = _mod.detect_registering_institution
check_identity_mapper          = _mod.check_identity_mapper
check_data_loaded              = _mod.check_data_loaded

# Default secret key
DEFAULT_SECRET_KEY = "MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC07fxdEQlsvWvggBgrork401cdyZ9MqV6FF/RgX6+Om23gP/rME5sE5//OoG61KU3dEj9phcHH845TuyNEyc4Vhqxe1gzl4VIZkOj+/2qxYvCsP1Sv3twTs+fDfFv5NA1ZXqiswTlgjR2Lpf1tevFQEOzB9WYvH/Bu9kgr2AlHMPV6+b7gcJij/7W1hndiCk2ahbi7oXjjODF4yEU9yNAhopibe4zzMX+FO4eFYpUmrjS5wvv6aAanfoeIMTwhF81Gj9V3rHf4UsD3VEx773q7GPuXlZSLyiNrUCdvxITh+dW8Y9ICuCTy3bFbp1/HzoPdzkkUlzPNKLlLiV2w4EcxAgMBAAECggEAMjqHfwbFyQxlMHQfQa3xIdd6LejVcqDqfqSB0Wd/A2YfAMyCQbmHpbsKh0B+u4h191OjixX5EBuLfa9MQUKNFejHXaSq+/6rnjFenbwm0IwZKJiEWDbUfhvJ0blqhypuMktXJG6YETfb5fL1AjnJWGL6d3Y7IgYJ56QzsQhOuxZidSqw468xc4sIF0CoTeJdrSC2yDCVuVlLNifm/2SXBJD8mgc1WCz0rkJhvvpW4k5G9rRSkS5f0013ZNfsfiDXoqiKkafoYNEbk7TZQNInqSuONm/UECn5GLm6IXdXSGfm1O2Lt0Kk7uxW/3W00mIPeZD+hiOObheRm/2HoOEKiQKBgQDreVFQihXAEDviIB2s6fphvPcMw/IonE8tX565i3303ubQMDIyZmsi3apN5pqSjm1TKq1KIgY2D4vYTu6vO5x9MhEO2CCZWNwC+awrIYa32FwiT8D8eZ9g+DJ4/IwXyz1fG38RCz/eIsJ0NsS9z8RKBIbfMmM+WnXRez3Fq+cbRwKBgQDEs35qXThbbFUYo1QkO0vIo85iczu9NllRxo1nAqQkfu1oTYQQobxcGk/aZk0B02r9kt2eob8zfG+X3LadIhQ0/LalnGNKI9jWLkdW4dxi7xMU99MYc3NRXmR49xGxgOVkLzKyGMisUvkTnE5v/S1nhu5uFr3JPkWcCScLOTjVxwKBgHNWsDq3+GFkUkC3pHF/BhJ7wbLyA5pavfmmnZOavO6FhB8zjFLdkdq5IuMXcl0ZAHm9LLZkJhCy2rfwKb+RflxgerR/rrAOM24Np4RU3q0MgEyaLhg85pFT4T0bzu8UsRH14O6TSQxgkEjmTsX+j9IFl56aCryPCKi8Kgy53/CfAoGAdV2kUFLPDb3WCJ1r1zKKRW1398ZKHtwO73xJYu1wg1Y40cNuyX23pj0M6IOh7zT24dZ/5ecc7tuQukw3qgprhDJFyQtHMzWwbBuw9WZO2blM6XX1vuEkLajkykihhggi12RSG3IuSqQ3ejwJkUi/jsYz/fwTwcAmSLQtV8UM5IECgYEAh4h1EkMx3NXzVFmLsb4QLMXw8+Rnn9oG+NGObldQ+nmknUPu7iz5kl9lTJy+jWtqHlHL8ZtV1cZZSZnFxX5WQH5/lcz/UD+GqWoSlWuTU34PPTJqLKSYgkoOJQDEZVMVphLySS9tuo+K/h10lRS1r9KDm3RZASa1JnnWopBZIz4="


# ---------------------------------------------------------------------------
# Tenant validation
# ---------------------------------------------------------------------------

def validate_tenant(tenant, namespace='paymenthub'):
    valid_tenants = get_valid_tenants(namespace=namespace)
    if valid_tenants is None:
        print(f"⚠️  Warning: Could not validate tenant '{tenant}' - proceeding anyway", file=sys.stderr)
        return True
    if tenant not in valid_tenants:
        print(f"\n❌ ERROR: Tenant '{tenant}' does not exist!", file=sys.stderr)
        print(f"\nValid tenants are: {', '.join(valid_tenants)}", file=sys.stderr)
        return False
    print(f"✓ Tenant '{tenant}' validated", file=sys.stderr)
    return True


# ---------------------------------------------------------------------------
# Debug / workflow info
# ---------------------------------------------------------------------------

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


# ---------------------------------------------------------------------------
# Curl display helper
# ---------------------------------------------------------------------------

def print_curl_commands(domain, csv_file_path, private_key, tenant, correlation_id,
                        signature, govstack, registering_institution, program):
    """Print equivalent curl commands to stderr as an educational aid."""
    key_display = private_key[:20] + "...<truncated>" if len(private_key) > 20 else private_key

    print(f"\n{'─'*72}", file=sys.stderr)
    print("EQUIVALENT CURL COMMANDS", file=sys.stderr)
    print(f"{'─'*72}", file=sys.stderr)

    print("\n# 1. Generate signature:", file=sys.stderr)
    print(f'curl -k -X POST "https://ops.{domain}/api/v1/util/x-signature" \\', file=sys.stderr)
    print(f'  -H "X-CorrelationID: {correlation_id}" \\', file=sys.stderr)
    print(f'  -H "Platform-TenantId: {tenant}" \\', file=sys.stderr)
    print(f'  -H "privateKey: {key_display}" \\', file=sys.stderr)
    print(f'  -F "data=@{csv_file_path}"', file=sys.stderr)

    print("\n# 2. Submit batch:", file=sys.stderr)
    print(f'curl -k -X POST "https://bulk-processor.{domain}/batchtransactions" \\', file=sys.stderr)
    print(f'  -H "X-Signature: {signature}" \\', file=sys.stderr)
    print(f'  -H "X-CorrelationID: {correlation_id}" \\', file=sys.stderr)
    print(f'  -H "Platform-TenantId: {tenant}" \\', file=sys.stderr)
    print(f'  -H "type: csv" \\', file=sys.stderr)
    print(f'  -H "filename: {Path(csv_file_path).name}" \\', file=sys.stderr)
    print(f'  -H "X-CallbackURL: http://ph-ee-connector-mock-payment-schema:8080/batches/{correlation_id}/callback" \\', file=sys.stderr)
    print(f'  -H "Purpose: Batch payment" \\', file=sys.stderr)
    if govstack and registering_institution:
        print(f'  -H "X-Registering-Institution-ID: {registering_institution}" \\', file=sys.stderr)
    if govstack and program:
        print(f'  -H "X-Program-ID: {program}" \\', file=sys.stderr)
    print(f'  -F "data=@{csv_file_path}"', file=sys.stderr)
    print(f"{'─'*72}\n", file=sys.stderr)


# ---------------------------------------------------------------------------
# Signature generation
# ---------------------------------------------------------------------------

def generate_signature(domain, csv_file_path, private_key, tenant='greenbank', correlation_id=None):
    """Generate X-Signature using ops service. Returns (signature, correlation_id)."""
    url = f"https://ops.{domain}/api/v1/util/x-signature"
    if correlation_id is None:
        correlation_id = str(uuid.uuid4())

    headers = {
        "X-CorrelationID": correlation_id,
        "Platform-TenantId": tenant,
        "privateKey": private_key,
    }

    try:
        with open(csv_file_path, 'rb') as f:
            files = {'data': (csv_file_path.name, f, 'text/csv')}
            print(f"Generating signature...", file=sys.stderr)
            response = requests.post(url, headers=headers, files=files, verify=False, timeout=30)

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


# ---------------------------------------------------------------------------
# Batch submission (callable by verify-batches.py)
# ---------------------------------------------------------------------------

def submit_batch_request(domain, csv_file_path, signature, tenant='greenbank',
                         correlation_id=None, govstack=False,
                         registering_institution=None, program=None):
    """
    POST batch to bulk-processor. Returns parsed response dict, or None on failure.

    This is the importable entry-point used by verify-batches.py.
    """
    url = f"https://bulk-processor.{domain}/batchtransactions"
    if correlation_id is None:
        correlation_id = str(uuid.uuid4())

    institution_id = registering_institution or tenant

    headers = {
        "X-Signature": signature,
        "X-CorrelationID": correlation_id,
        "Platform-TenantId": tenant,
        "type": "csv",
        "filename": Path(csv_file_path).name,
        "X-CallbackURL": f"http://ph-ee-connector-mock-payment-schema:8080/batches/{correlation_id}/callback",
        "Purpose": "Batch payment",
    }
    if govstack:
        headers['X-Registering-Institution-ID'] = institution_id
        if program:
            headers['X-Program-ID'] = program

    print(f"\n{'='*80}", file=sys.stderr)
    print(f"SUBMITTING BATCH", file=sys.stderr)
    print("="*80, file=sys.stderr)
    print(f"URL: {url}", file=sys.stderr)
    print(f"File: {Path(csv_file_path).name}", file=sys.stderr)
    print(f"Tenant: {tenant}", file=sys.stderr)
    print(f"Mode: {'GovStack' if govstack else 'Non-GovStack'}", file=sys.stderr)
    if govstack:
        print(f"Registering Institution: {institution_id}", file=sys.stderr)
        if program:
            print(f"Program: {program}", file=sys.stderr)
    print("="*80, file=sys.stderr)

    try:
        with open(csv_file_path, 'rb') as f:
            files = {'data': (Path(csv_file_path).name, f, 'text/csv')}
            response = requests.post(url, headers=headers, files=files, verify=False, timeout=60)

        print(f"\nResponse Status: {response.status_code}", file=sys.stderr)

        try:
            response_data = response.json()
            print(f"\nResponse Body:", file=sys.stderr)
            print(json.dumps(response_data, indent=2), file=sys.stderr)
            return response_data if 200 <= response.status_code < 300 else None
        except Exception:
            print(f"\nResponse Body (text):", file=sys.stderr)
            print(response.text, file=sys.stderr)
            return {"status": "success"} if 200 <= response.status_code < 300 else None

    except Exception as e:
        print(f"\nError submitting batch: {e}", file=sys.stderr)
        return None


def run_submit(csv_file, config_path, tenant, govstack, registering_institution,
               program, secret_key, debug, show_curl):
    """
    Full submission pipeline. Returns response dict or None.
    Extracted so verify-batches.py can call it directly.
    """
    cfg = load_config(config_path)
    domain = get_gazelle_domain(cfg)

    print("="*80, file=sys.stderr)
    print(f"PAYMENT HUB BATCH TOOL - {domain}", file=sys.stderr)
    print("="*80, file=sys.stderr)
    print(f"Using CSV: {csv_file}", file=sys.stderr)

    data_ok, data_issues, data_hint = check_data_loaded(domain, config_path=config_path, debug=debug)
    if not data_ok:
        print(f"\nError: MifosX data is not loaded:", file=sys.stderr)
        for issue in data_issues:
            print(f"  • {issue}", file=sys.stderr)
        print(f"{data_hint}", file=sys.stderr)
        sys.exit(1)

    if not validate_tenant(tenant):
        return None

    # Resolve registering institution for GovStack mode
    if govstack and registering_institution is None:
        payees = get_payee_identifiers_from_csv(csv_file)
        if payees:
            best, counts = detect_registering_institution(payees, debug=debug)
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
                print(f"   Fix: run generate-mifos-vnext-data.py --regenerate", file=sys.stderr)
                print(f"   Or:  pass --registering-institution explicitly", file=sys.stderr)
        else:
            print(f"⚠️  No payee_identifier column found in CSV — "
                  f"cannot auto-detect institution", file=sys.stderr)
    elif govstack and registering_institution is not None:
        count = check_identity_mapper(registering_institution, debug=debug)
        if count is not None:
            if count == 0:
                print(f"\n⚠️  WARNING: Identity mapper has 0 entries for "
                      f"institution '{registering_institution}'", file=sys.stderr)
                print(f"   --govstack mode will likely produce empty results.", file=sys.stderr)
                print(f"   Fix: run generate-mifos-vnext-data.py --regenerate", file=sys.stderr)
            else:
                n = count
                print(f"✓ Identity mapper: {n} beneficiar{'ies' if n != 1 else 'y'} "
                      f"found for '{registering_institution}'", file=sys.stderr)

    if debug:
        print_workflow_info(tenant, govstack, csv_file)

    correlation_id = str(uuid.uuid4())

    signature, correlation_id = generate_signature(
        domain, Path(csv_file), secret_key, tenant=tenant, correlation_id=correlation_id
    )

    if show_curl:
        print_curl_commands(
            domain, csv_file, secret_key, tenant, correlation_id,
            signature, govstack, registering_institution, program
        )

    return submit_batch_request(
        domain, csv_file, signature,
        tenant=tenant,
        correlation_id=correlation_id,
        govstack=govstack,
        registering_institution=registering_institution,
        program=program,
    )


# ---------------------------------------------------------------------------
# Interactive mode
# ---------------------------------------------------------------------------

def _prompt(msg, default=None):
    """Prompt to stderr, read from stdin. Returns stripped input or default."""
    suffix = f" [{default}]" if default is not None else ""
    print(f"{msg}{suffix}: ", end='', file=sys.stderr, flush=True)
    try:
        val = input().strip()
    except EOFError:
        val = ''
    return val if val else (default or '')


def _prompt_yn(msg, default=False):
    hint = "[Y/n]" if default else "[y/N]"
    print(f"{msg} {hint}: ", end='', file=sys.stderr, flush=True)
    try:
        val = input().strip().lower()
    except EOFError:
        val = ''
    if val in ('y', 'yes'):
        return True
    if val in ('n', 'no'):
        return False
    return default


def _prompt_choice(msg, choices, default_idx=0):
    """Display numbered choices, return chosen item."""
    print(f"\n{msg}", file=sys.stderr)
    for i, c in enumerate(choices, 1):
        marker = " (default)" if i - 1 == default_idx else ""
        print(f"  {i}. {c}{marker}", file=sys.stderr)
    print(f"  Enter number", end='', file=sys.stderr, flush=True)
    default_num = default_idx + 1
    print(f" [{default_num}]: ", end='', file=sys.stderr, flush=True)
    try:
        val = input().strip()
    except EOFError:
        val = ''
    if val.isdigit() and 1 <= int(val) <= len(choices):
        return choices[int(val) - 1]
    return choices[default_idx]


def interactive_mode(args):
    """Fill in any missing args interactively. Mutates args in place."""
    script_dir = Path(__file__).parent

    print("\n" + "="*72, file=sys.stderr)
    print("  PAYMENT HUB BATCH TOOL — Interactive Mode", file=sys.stderr)
    print("="*72, file=sys.stderr)

    # 1. Config file
    default_cfg = str(args.config) if args.config else str(
        Path(__file__).parent.parent.parent.parent / "config" / "config.ini"
    )
    cfg_input = _prompt("Config file path", default=default_cfg)
    args.config = Path(cfg_input).expanduser()

    # 2. CSV file
    if args.csv_file is None:
        csvs = sorted(script_dir.glob("bulk-gazelle-*.csv"))
        csv_choices = [str(p.name) for p in csvs] + ["Enter path manually"]
        chosen = _prompt_choice("CSV file to submit", csv_choices)
        if chosen == "Enter path manually":
            args.csv_file = Path(_prompt("CSV file path"))
        else:
            args.csv_file = script_dir / chosen

    # 3. Tenant
    if args.tenant is None:
        tenants = get_valid_tenants() or FALLBACK_TENANTS
        default_idx = tenants.index('greenbank') if 'greenbank' in tenants else 0
        args.tenant = _prompt_choice("Tenant", tenants, default_idx=default_idx)

    # 4. GovStack
    if not args.govstack:
        args.govstack = _prompt_yn("Enable GovStack mode (identity validation + de-bulking)", default=False)

    # 5. Registering institution (only if GovStack)
    if args.govstack and args.registering_institution is None:
        payees = get_payee_identifiers_from_csv(args.csv_file)
        best, _ = detect_registering_institution(payees) if payees else (None, {})
        default_inst = best or args.tenant
        val = _prompt("Registering institution ID", default=default_inst)
        args.registering_institution = val or None

    # 6. Program ID (only if GovStack)
    if args.govstack and args.program is None:
        val = _prompt("Program ID (optional, Enter to skip)", default="")
        args.program = val if val else None

    # 7. Debug mode
    if not args.debug:
        args.debug = _prompt_yn("Show workflow details (--debug)", default=False)

    # 8. Show curl
    if not args.show_curl:
        args.show_curl = _prompt_yn("Show equivalent curl commands (--show-curl)", default=False)

    # 9. Confirm
    print("\n" + "─"*72, file=sys.stderr)
    print("  Submission summary:", file=sys.stderr)
    print(f"    Config    : {args.config}", file=sys.stderr)
    print(f"    CSV file  : {args.csv_file}", file=sys.stderr)
    print(f"    Tenant    : {args.tenant}", file=sys.stderr)
    print(f"    GovStack  : {'yes' if args.govstack else 'no'}", file=sys.stderr)
    if args.govstack:
        print(f"    Institution: {args.registering_institution or '(auto-detect)'}", file=sys.stderr)
        print(f"    Program   : {args.program or '(none)'}", file=sys.stderr)
    print(f"    Debug     : {'yes' if args.debug else 'no'}", file=sys.stderr)
    print(f"    Show curl : {'yes' if args.show_curl else 'no'}", file=sys.stderr)
    print("─"*72, file=sys.stderr)

    if not _prompt_yn("Submit?", default=True):
        print("Aborted.", file=sys.stderr)
        sys.exit(0)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

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

  Without --govstack (standard mode):
    * Triggers bulk_processor-{tenant} workflow
    * No beneficiary validation — payer/payee taken directly from CSV

DECISION TABLE:
  Use case                        | --tenant  | --govstack | CSV payment_mode
  --------------------------------|-----------|------------|------------------
  Simple internal test            | redbank   | NO         | CLOSEDLOOP
  Multi-FSP via Mojaloop switch   | greenbank | NO         | MOJALOOP
  G2P bulk disbursement (switch)  | greenbank | YES        | MOJALOOP  ← recommended
  G2P closedloop (same PH only)   | redbank   | YES        | CLOSEDLOOP

EXAMPLES:
  # Interactive mode (prompts for all options)
  ./submit-batch.py -I
  ./submit-batch.py           # also triggers interactive when no -f given

  # Standard closedloop
  ./submit-batch.py -f bulk-gazelle-closedloop-4.csv --tenant redbank

  # GovStack G2P via Mojaloop
  ./submit-batch.py -f bulk-gazelle-mojaloop-4.csv --tenant greenbank --govstack

  # Show equivalent curl commands
  ./submit-batch.py -f bulk-gazelle-mojaloop-4.csv --tenant greenbank --show-curl
        """,
    )

    parser.add_argument('--csv-file', '-f', type=lambda p: Path(p).expanduser(), default=None,
                        help='CSV file to submit')
    parser.add_argument('--config', '-c', type=lambda p: Path(p).expanduser(), default=default_config,
                        help=f'Path to config.ini (default: {default_config})')
    parser.add_argument('--tenant', '-t', type=str, default=None,
                        help='Tenant ID (default: greenbank)')
    parser.add_argument('--govstack', '-g', action='store_true',
                        help='Enable GovStack mode')
    parser.add_argument('--registering-institution', '-i', type=str, default=None,
                        help='Registering institution ID (auto-detected if omitted)')
    parser.add_argument('--program', '-p', type=str, default=None,
                        help='Program ID (optional, GovStack budget-account lookup)')
    parser.add_argument('--secret-key', '-k', type=str, default=DEFAULT_SECRET_KEY,
                        help='Secret key for signing (default: built-in key)')
    parser.add_argument('--debug', '-d', action='store_true',
                        help='Show workflow details before submitting')
    parser.add_argument('--show-curl', action='store_true',
                        help='Print equivalent curl commands to stderr')
    parser.add_argument('--interactive', '-I', action='store_true',
                        help='Interactive mode — prompt for any missing options')

    args = parser.parse_args()

    # Auto-trigger interactive when no CSV provided and stdin is a TTY
    if args.csv_file is None and sys.stdin.isatty():
        args.interactive = True

    if args.interactive:
        interactive_mode(args)

    # Apply defaults for any still-unset values
    if args.csv_file is None:
        parser.error("--csv-file / -f is required (or use --interactive / -I)")
    if args.tenant is None:
        args.tenant = 'greenbank'

    if not args.csv_file.exists():
        print(f"Error: CSV file not found: {args.csv_file}", file=sys.stderr)
        sys.exit(1)

    result = run_submit(
        csv_file=args.csv_file,
        config_path=args.config,
        tenant=args.tenant,
        govstack=args.govstack,
        registering_institution=args.registering_institution,
        program=args.program,
        secret_key=args.secret_key,
        debug=args.debug,
        show_curl=args.show_curl,
    )

    if result:
        print("\n✓ Batch submitted successfully!", file=sys.stderr)
        sys.exit(0)
    else:
        print("\n✗ Batch submission failed", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
