#!/usr/bin/env python3
"""
Generate GovStack Mastercard CBS batch CSV and load supplementary data.

Standalone tool for GovStack clusters where Mifos/Fineract/vNext are NOT
running.  Derives payee MSISDNs from the mock beneficiary phone numbers,
writes a ready-to-submit MASTERCARD_CBS batch CSV, and optionally loads the
mastercard_cbs_supplementary_data table in the cluster MySQL.

Source beneficiary data:
  https://github.com/GovStackWorkingGroup/sandbox-usecase-cross-border-payment
  /blob/main/src/mockdata/mock-african-beneficiaries.ts

Usage:
    # Generate CSV only (no cluster access required)
    ./generate-govstack-mastercard-batch.py --generate-csv

    # Load supplementary data into cluster MySQL
    ./generate-govstack-mastercard-batch.py --load-supplementary -c ~/config.ini

    # Do both
    ./generate-govstack-mastercard-batch.py --all -c ~/config.ini

    # Include only ACTIVE beneficiaries
    ./generate-govstack-mastercard-batch.py --all -c ~/config.ini --active-only
"""

import argparse
import configparser
import csv
import re
import subprocess
import sys
import uuid
from pathlib import Path

# ---------------------------------------------------------------------------
# GovStack mock beneficiary data
# Source: mock-african-beneficiaries.ts (10 records, Zimbabwe pension)
# ---------------------------------------------------------------------------
GOVSTACK_BENEFICIARIES = [
    {
        "payeeIdentity": "ZW0000000000000001",
        "bankingInstitutionCode": "SBZAZAJJ",
        "financialAddress": "ZA930000001000000001",
        "firstName": "Tendai", "middleName": "James", "lastName": "Mukamuri",
        "status": "ACTIVE",
        "phoneNumberPrimary": "+27-21-111-1111",
        "emailAddressPrimary": "tendai.mukamuri1@email.com",
        "currentAddressLine1": "12 Vilakazi Street",
        "currentAddressLine2": "Apartment 1A",
        "currentCity": "Johannesburg",
        "currentCountry": "ZAF",
        "monthlyPensionAmount": 3200.00,
        "bankName": "Standard Bank of South Africa",
        "bankBranch": "Johannesburg Central",
    },
    {
        "payeeIdentity": "ZW0000000000000002",
        "bankingInstitutionCode": "FNBSAJJ",
        "financialAddress": "ZA930000001000000002",
        "firstName": "Chipo", "middleName": "Rose", "lastName": "Chikafu",
        "status": "ACTIVE",
        "phoneNumberPrimary": "+27-31-222-2222",
        "emailAddressPrimary": "chipo.chikafu@email.com",
        "currentAddressLine1": "102 Long Street",
        "currentAddressLine2": "Flat 3C",
        "currentCity": "Cape Town",
        "currentCountry": "ZAF",
        "monthlyPensionAmount": 2890.00,
        "bankName": "First National Bank",
        "bankBranch": "Cape Town Central",
    },
    {
        "payeeIdentity": "ZW0000000000000003",
        "bankingInstitutionCode": "ABSAZAJJ",
        "financialAddress": "ZA930000001000000003",
        "firstName": "Farai", "middleName": "Peter", "lastName": "Ncube",
        "status": "ACTIVE",
        "phoneNumberPrimary": "+27-11-333-3333",
        "emailAddressPrimary": "farai.ncube@email.com",
        "currentAddressLine1": "88 Jan Smuts Avenue",
        "currentAddressLine2": "Unit 12",
        "currentCity": "Randburg",
        "currentCountry": "ZAF",
        "monthlyPensionAmount": 3100.00,
        "bankName": "ABSA Bank",
        "bankBranch": "Randburg Branch",
    },
    {
        "payeeIdentity": "ZW0000000000000004",
        "bankingInstitutionCode": "SBZAZAJJ",
        "financialAddress": "ZA930000001000000004",
        "firstName": "Nomsa", "middleName": "Grace", "lastName": "Maphosa",
        "status": "PENDING",
        "phoneNumberPrimary": "+27-41-444-4444",
        "emailAddressPrimary": "nomsa.maphosa@email.com",
        "currentAddressLine1": "34 Govan Mbeki Avenue",
        "currentAddressLine2": "Suite 10",
        "currentCity": "Port Elizabeth",
        "currentCountry": "ZAF",
        "monthlyPensionAmount": 2800.00,
        "bankName": "Standard Bank of South Africa",
        "bankBranch": "Port Elizabeth Main",
    },
    {
        "payeeIdentity": "ZW0000000000000005",
        "bankingInstitutionCode": "CAPITECJJ",
        "financialAddress": "ZA930000001000000005",
        "firstName": "Patience", "middleName": "Faith", "lastName": "Zhou",
        "status": "PENDING",
        "phoneNumberPrimary": "+27-21-555-5555",
        "emailAddressPrimary": "patience.zhou@email.com",
        "currentAddressLine1": "78 Greenmarket Square",
        "currentAddressLine2": "Flat 5D",
        "currentCity": "Cape Town",
        "currentCountry": "ZAF",
        "monthlyPensionAmount": 3000.00,
        "bankName": "Capitec Bank",
        "bankBranch": "Cape Town Branch",
    },
    {
        "payeeIdentity": "ZW0000000000000006",
        "bankingInstitutionCode": "SBZAZAJJ",
        "financialAddress": "ZA930000001000000006",
        "firstName": "Simba", "middleName": "John", "lastName": "Mutasa",
        "status": "REJECTED",
        "phoneNumberPrimary": "+27-12-666-6666",
        "emailAddressPrimary": "simba.mutasa@email.com",
        "currentAddressLine1": "501 Stanza Bopape Street",
        "currentAddressLine2": "",
        "currentCity": "Pretoria",
        "currentCountry": "ZAF",
        "monthlyPensionAmount": 3150.00,
        "bankName": "Standard Bank of South Africa",
        "bankBranch": "Pretoria Main",
    },
    {
        "payeeIdentity": "ZW0000000000000007",
        "bankingInstitutionCode": "FNBSAJJ",
        "financialAddress": "ZA930000001000000007",
        "firstName": "Tatenda", "middleName": "Peter", "lastName": "Moyo",
        "status": "REJECTED",
        "phoneNumberPrimary": "+27-21-777-7777",
        "emailAddressPrimary": "tatenda.moyo@email.com",
        "currentAddressLine1": "10 Wale Street",
        "currentAddressLine2": "Apartment 7B",
        "currentCity": "Cape Town",
        "currentCountry": "ZAF",
        "monthlyPensionAmount": 2850.00,
        "bankName": "First National Bank",
        "bankBranch": "Cape Town Central",
    },
    {
        "payeeIdentity": "ZW0000000000000008",
        "bankingInstitutionCode": "CAPITECJJ",
        "financialAddress": "ZA930000001000000008",
        "firstName": "Linda", "middleName": "Joyce", "lastName": "Mawere",
        "status": "REJECTED",
        "phoneNumberPrimary": "+27-21-888-8888",
        "emailAddressPrimary": "linda.mawere@email.com",
        "currentAddressLine1": "42 Roeland Street",
        "currentAddressLine2": "Suite 9E",
        "currentCity": "Cape Town",
        "currentCountry": "ZAF",
        "monthlyPensionAmount": 2990.00,
        "bankName": "Capitec Bank",
        "bankBranch": "Cape Town Branch",
    },
    {
        "payeeIdentity": "ZW0000000000000009",
        "bankingInstitutionCode": "ABSAZAJJ",
        "financialAddress": "ZA930000001000000009",
        "firstName": "Blessing", "middleName": "Timothy", "lastName": "Dube",
        "status": "PENDING",
        "phoneNumberPrimary": "+27-31-999-9999",
        "emailAddressPrimary": "blessing.dube@email.com",
        "currentAddressLine1": "15 Margaret Mncadi Ave",
        "currentAddressLine2": "",
        "currentCity": "Durban",
        "currentCountry": "ZAF",
        "monthlyPensionAmount": 3250.00,
        "bankName": "ABSA Bank",
        "bankBranch": "Durban Branch",
    },
    {
        "payeeIdentity": "ZW0000000000000010",
        "bankingInstitutionCode": "SBZAZAJJ",
        "financialAddress": "ZA930000001000000010",
        "firstName": "Rudo", "middleName": "Mercy", "lastName": "Mugabe",
        "status": "PENDING",
        "phoneNumberPrimary": "+27-12-101-0101",
        "emailAddressPrimary": "rudo.mugabe@email.com",
        "currentAddressLine1": "18 Francis Baard Street",
        "currentAddressLine2": "",
        "currentCity": "Pretoria",
        "currentCountry": "ZAF",
        "monthlyPensionAmount": 3400.00,
        "bankName": "Standard Bank of South Africa",
        "bankBranch": "Pretoria Main",
    },
]

# Fictional GovStack Ministry of Social Welfare payer MSISDN
# (used as the bulk-batch payer; no real account needed for Mastercard sandbox)
GOVSTACK_PAYER_MSISDN = "27000000000"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def normalize_msisdn(phone: str) -> str:
    """Strip all non-digit characters from a phone number."""
    return re.sub(r"\D", "", phone)


def filter_beneficiaries(beneficiaries, active_only: bool):
    if active_only:
        return [b for b in beneficiaries if b["status"] == "ACTIVE"]
    return beneficiaries


def build_address(b) -> str:
    parts = [b["currentAddressLine1"]]
    if b.get("currentAddressLine2"):
        parts.append(b["currentAddressLine2"])
    return ", ".join(parts)


# ---------------------------------------------------------------------------
# CSV generation
# ---------------------------------------------------------------------------

def generate_csv(beneficiaries, output_path: Path):
    fieldnames = [
        "id", "request_id", "payment_mode",
        "payer_identifier_type", "payer_identifier",
        "payee_identifier_type", "payee_identifier",
        "amount", "currency", "note",
    ]

    rows = []
    for idx, b in enumerate(beneficiaries):
        msisdn = normalize_msisdn(b["phoneNumberPrimary"])
        rows.append({
            "id": idx,
            "request_id": str(uuid.uuid4()),
            "payment_mode": "MASTERCARD_CBS",
            "payer_identifier_type": "MSISDN",
            "payer_identifier": GOVSTACK_PAYER_MSISDN,
            "payee_identifier_type": "MSISDN",
            "payee_identifier": msisdn,
            "amount": int(b["monthlyPensionAmount"]),
            "currency": "ZAR",
            "note": f"GovStack pension - {b['firstName']} {b['lastName']} ({b['payeeIdentity']})",
        })

    with open(output_path, "w", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)

    return rows


# ---------------------------------------------------------------------------
# Supplementary data loading
# ---------------------------------------------------------------------------

def get_ini_value(config_file: str, section: str, key: str) -> str:
    cfg = configparser.ConfigParser()
    cfg.read(config_file)
    try:
        return cfg.get(section, key)
    except (configparser.NoSectionError, configparser.NoOptionError):
        return ""


def run_kubectl(kubeconfig: str, namespace: str, pod: str, db: str, sql: str, db_pass: str) -> str:
    cmd = [
        "kubectl", "--kubeconfig", kubeconfig,
        "exec", "-n", namespace, pod, "--",
        "mysql", "-u", "root", f"-p{db_pass}", db,
        "-N", "-s", "-e", sql,
    ]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        return result.stdout.strip()
    except subprocess.TimeoutExpired:
        print(f"  ✗ kubectl exec timed out", file=sys.stderr)
        return ""
    except FileNotFoundError:
        print("  ✗ kubectl not found in PATH", file=sys.stderr)
        return ""


def load_supplementary_data(beneficiaries, config_file: str, namespace: str, debug: bool):
    config_file = str(Path(config_file).expanduser())

    k8s_user = get_ini_value(config_file, "kubernetes", "k8s_user")
    kubeconfig = get_ini_value(config_file, "kubernetes", "kubeconfig_path")
    kubeconfig = str(Path(kubeconfig.replace("$USER", k8s_user)).expanduser())

    if not Path(kubeconfig).exists():
        print(f"Error: kubeconfig not found: {kubeconfig}", file=sys.stderr)
        sys.exit(1)

    print(f"Kubeconfig : {kubeconfig}")
    print(f"Namespace  : {namespace}")

    # Get MySQL root password from k8s secret
    try:
        pw_cmd = [
            "kubectl", "--kubeconfig", kubeconfig,
            "get", "secret", "-n", namespace, "operationsmysql",
            "-o", "jsonpath={.data.mysql-root-password}",
        ]
        pw_b64 = subprocess.check_output(pw_cmd, text=True, timeout=15).strip()
        import base64
        db_pass = base64.b64decode(pw_b64).decode()
    except Exception as e:
        print(f"Error: Could not get MySQL password: {e}", file=sys.stderr)
        sys.exit(1)

    # Find the MySQL pod
    try:
        pod_cmd = [
            "kubectl", "--kubeconfig", kubeconfig,
            "get", "pods", "-n", namespace,
            "-l", "app.kubernetes.io/name=operationsmysql",
            "-o", "jsonpath={.items[0].metadata.name}",
        ]
        mysql_pod = subprocess.check_output(pod_cmd, text=True, timeout=15).strip()
    except Exception:
        mysql_pod = ""

    if not mysql_pod:
        print("Error: Could not find operationsmysql pod", file=sys.stderr)
        sys.exit(1)

    print(f"MySQL pod  : {mysql_pod}")

    def exec_sql(db, sql):
        return run_kubectl(kubeconfig, namespace, mysql_pod, db, sql, db_pass)

    # Ensure operations database exists
    exec_sql("mysql", "CREATE DATABASE IF NOT EXISTS operations")

    # Create table if not exists (reuse existing schema so this is idempotent)
    create_sql = (
        "CREATE TABLE IF NOT EXISTS mastercard_cbs_supplementary_data ("
        "  id BIGINT AUTO_INCREMENT PRIMARY KEY,"
        "  payee_msisdn VARCHAR(20) NOT NULL,"
        "  payee_account_number VARCHAR(50),"
        "  sender_organisation_name VARCHAR(255) NOT NULL DEFAULT 'GovStack Ministry of Social Welfare',"
        "  sender_address_line1 VARCHAR(255) NOT NULL DEFAULT '123 Government Boulevard',"
        "  sender_address_city VARCHAR(100) NOT NULL DEFAULT 'Capital City',"
        "  sender_address_country VARCHAR(3) NOT NULL DEFAULT 'ZAF',"
        "  payment_origination_country VARCHAR(3) NOT NULL DEFAULT 'ZAF',"
        "  destination_country_iso3 VARCHAR(3) NOT NULL DEFAULT 'ZAF',"
        "  beneficiary_currency VARCHAR(3) NOT NULL DEFAULT 'ZAR',"
        "  beneficiary_currency_decimal_precision INT NOT NULL DEFAULT 2,"
        "  destination_service_tag VARCHAR(20) NOT NULL DEFAULT 'ZAK-BK',"
        "  payment_type VARCHAR(10) NOT NULL DEFAULT 'B2P',"
        "  recipient_first_name VARCHAR(100),"
        "  recipient_last_name VARCHAR(100),"
        "  recipient_address_line1 VARCHAR(255),"
        "  recipient_address_city VARCHAR(100),"
        "  recipient_phone VARCHAR(20),"
        "  recipient_email VARCHAR(255),"
        "  recipient_address_country VARCHAR(3),"
        "  bank_name VARCHAR(255),"
        "  bank_swift_code VARCHAR(11),"
        "  bank_branch_name VARCHAR(255),"
        "  bank_country_code VARCHAR(3),"
        "  purpose_of_payment VARCHAR(500),"
        "  created_by VARCHAR(100),"
        "  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,"
        "  UNIQUE KEY uk_msisdn (payee_msisdn),"
        "  INDEX idx_account (payee_account_number)"
        ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4"
    )
    exec_sql("operations", create_sql)

    inserted = 0
    for b in beneficiaries:
        msisdn = normalize_msisdn(b["phoneNumberPrimary"])
        address = build_address(b)
        purpose = f"GovStack pension payment to {b['firstName']} {b['lastName']} ({b['payeeIdentity']})"
        # Escape single quotes in any string fields
        def esc(s): return str(s).replace("'", "\\'")

        insert_sql = (
            f"INSERT INTO mastercard_cbs_supplementary_data ("
            f"  payee_msisdn, payee_account_number,"
            f"  recipient_first_name, recipient_last_name,"
            f"  recipient_address_line1, recipient_address_city, recipient_address_country,"
            f"  recipient_phone, recipient_email,"
            f"  bank_name, bank_swift_code, bank_branch_name, bank_country_code,"
            f"  purpose_of_payment, created_by"
            f") VALUES ("
            f"  '{esc(msisdn)}', '{esc(b['financialAddress'])}',"
            f"  '{esc(b['firstName'])}', '{esc(b['lastName'])}',"
            f"  '{esc(address)}', '{esc(b['currentCity'])}', '{esc(b['currentCountry'])}',"
            f"  '{esc(msisdn)}', '{esc(b['emailAddressPrimary'])}',"
            f"  '{esc(b['bankName'])}', '{esc(b['bankingInstitutionCode'])}', '{esc(b['bankBranch'])}', 'ZA',"
            f"  '{esc(purpose)}', 'generate-govstack-mastercard-batch.py'"
            f") ON DUPLICATE KEY UPDATE"
            f"  payee_account_number = VALUES(payee_account_number),"
            f"  recipient_first_name = VALUES(recipient_first_name),"
            f"  recipient_last_name  = VALUES(recipient_last_name),"
            f"  bank_swift_code      = VALUES(bank_swift_code),"
            f"  bank_name            = VALUES(bank_name)"
        )

        if debug:
            print(f"  SQL: {insert_sql[:120]}...", file=sys.stderr)

        result = exec_sql("operations", insert_sql)
        status = b["status"]
        print(f"  + {msisdn}  {b['firstName']} {b['lastName']} ({b['payeeIdentity']}) [{status}]")
        inserted += 1

    return inserted


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    script_dir = Path(__file__).parent
    default_output = script_dir.parent / "batch"
    default_config = script_dir.parent.parent.parent / "config" / "config.ini"

    parser = argparse.ArgumentParser(
        description="Generate GovStack Mastercard batch CSV and load supplementary data",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Generate CSV (no cluster access needed):
  ./generate-govstack-mastercard-batch.py --generate-csv

  # Load supplementary data into cluster MySQL:
  ./generate-govstack-mastercard-batch.py --load-supplementary -c ~/config.ini

  # Both at once:
  ./generate-govstack-mastercard-batch.py --all -c ~/config.ini

  # ACTIVE beneficiaries only:
  ./generate-govstack-mastercard-batch.py --all -c ~/config.ini --active-only

Submit the generated CSV with:
  python3 src/utils/batch/submit-batch.py \\
      -f src/utils/batch/bulk-govstack-mastercard-10.csv \\
      --tenant greenbank-mastercard

Beneficiary statuses in mock data:
  ACTIVE  (3): ZW0000000000000001-003  — ready for payment
  PENDING (4): ZW0000000000000004-005, 009-010  — awaiting approval
  REJECTED(3): ZW0000000000000006-008  — included for test coverage
        """,
    )

    parser.add_argument("--generate-csv", action="store_true",
                        help="Write bulk-govstack-mastercard-N.csv to output dir")
    parser.add_argument("--load-supplementary", action="store_true",
                        help="Load supplementary data into cluster MySQL")
    parser.add_argument("--all", action="store_true",
                        help="Do both --generate-csv and --load-supplementary")
    parser.add_argument("-c", "--config", type=Path, default=default_config,
                        help=f"Path to config.ini (default: {default_config})")
    parser.add_argument("-o", "--output-dir", type=Path, default=default_output,
                        help=f"CSV output directory (default: {default_output})")
    parser.add_argument("-n", "--namespace", default="paymenthub",
                        help="Kubernetes namespace (default: paymenthub)")
    parser.add_argument("--active-only", action="store_true",
                        help="Include only ACTIVE beneficiaries (skips PENDING/REJECTED)")
    parser.add_argument("-d", "--debug", action="store_true",
                        help="Show detailed SQL and kubectl output")

    args = parser.parse_args()

    do_csv  = args.generate_csv or args.all
    do_supp = args.load_supplementary or args.all

    if not do_csv and not do_supp:
        parser.print_help()
        sys.exit(1)

    beneficiaries = filter_beneficiaries(GOVSTACK_BENEFICIARIES, args.active_only)
    n = len(beneficiaries)

    print("=" * 60)
    print("GovStack Mastercard Batch Generator")
    print("=" * 60)
    print(f"Beneficiaries : {n} ({'ACTIVE only' if args.active_only else 'all statuses'})")
    print(f"Payer MSISDN  : {GOVSTACK_PAYER_MSISDN}  (GovStack Ministry of Social Welfare)")
    print()

    if do_csv:
        args.output_dir.mkdir(parents=True, exist_ok=True)
        csv_name = f"bulk-govstack-mastercard-{n}.csv"
        csv_path = args.output_dir / csv_name
        rows = generate_csv(beneficiaries, csv_path)
        print(f"CSV generated : {csv_path}  ({len(rows)} rows)")
        print()
        print("  id  MSISDN           payeeIdentity           amount  name")
        print("  " + "-" * 72)
        for r, b in zip(rows, beneficiaries):
            msisdn = normalize_msisdn(b["phoneNumberPrimary"])
            print(f"  {r['id']:<3} {msisdn:<16} {b['payeeIdentity']:<23} {r['amount']:<7} "
                  f"{b['firstName']} {b['lastName']} [{b['status']}]")
        print()
        print(f"Submit with:")
        print(f"  python3 src/utils/batch/submit-batch.py \\")
        print(f"      -f {csv_path} \\")
        print(f"      --tenant greenbank-mastercard")
        print()

    if do_supp:
        if not args.config.exists():
            print(f"Error: config not found: {args.config}", file=sys.stderr)
            sys.exit(1)
        print(f"Loading supplementary data from: {args.config}")
        print()
        count = load_supplementary_data(
            beneficiaries,
            str(args.config),
            args.namespace,
            args.debug,
        )
        print()
        print(f"Loaded {count} supplementary data records into operations.mastercard_cbs_supplementary_data")
        print()
        print("Reload with:  ./generate-govstack-mastercard-batch.py --load-supplementary -c <config>")

    print("=" * 60)


if __name__ == "__main__":
    main()
