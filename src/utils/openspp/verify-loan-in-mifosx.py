#!/usr/bin/env python3
# DEMO verification step: check each farmer got an agri loan in MifosX.
# For every MSISDN in the beneficiaries CSV, find the client in the lending tenant, confirm an
# active loan of the agri product, and confirm the loan carries the registry evidence that
# justified it.
# Exit code: 0 when every farmer holds a disbursed loan, 1 when any is missing.
#
# The principal is recomputed here from the evidence stored on the loan, so a loan whose amount
# does not match the farm it was granted on is a failure and not a pass.
import argparse
import csv
import sys

import requests
import urllib3

FINERACT_BASIC_AUTH = "Basic bWlmb3M6cGFzc3dvcmQ="
HTTP_TIMEOUT = 30
AMOUNT_TOLERANCE = 0.01

LOAN_PRODUCT_NAME = "Agri input loan"
REGISTRY_TABLE = "openspp_registry_snapshot"
BASE_PRINCIPAL = 100.0
PRINCIPAL_PER_HECTARE = 150.0
BAND_LIMITS = {"A": 1.0, "B": 0.75, "C": 0.5}


def parse_args():
    parser = argparse.ArgumentParser(description="Verify agri loans were disbursed in MifosX.")
    parser.add_argument("domain", help="Gazelle domain, e.g. mifos.gazelle.test")
    parser.add_argument("csv_path", help="Path to beneficiaries.csv")
    parser.add_argument("tenant", help="Lending tenant (Fineract tenant id)")
    return parser.parse_args()


def expected_principal(hectares, band):
    """The amount the evidence justifies, or None for a band this rule does not know.

    The rule is repeated here instead of imported on purpose: a check that reuses the code it
    checks only proves the code agrees with itself.
    """
    if band not in BAND_LIMITS:
        return None
    return round((BASE_PRINCIPAL + hectares * PRINCIPAL_PER_HECTARE) * BAND_LIMITS[band])


def agri_loan(accounts):
    """The agri loan of a client, whatever its state, or None."""
    for loan in (accounts or {}).get("loanAccounts", []):
        if loan.get("productName") == LOAN_PRODUCT_NAME:
            return loan
    return None


def evidence_row(rows):
    """The single row of the loan's datatable, or None.

    Fineract answers a one-row table either with the row or with a list holding it.
    """
    if isinstance(rows, list):
        return rows[0] if rows else None
    return rows or None


def main():
    urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)
    args = parse_args()
    base = f"https://mifos.{args.domain}/fineract-provider/api/v1"
    headers = {"Fineract-Platform-TenantId": args.tenant, "Authorization": FINERACT_BASIC_AUTH}

    def get(path, **params):
        # verify=False: MifosX uses a self-signed certificate in Gazelle.
        try:
            response = requests.get(f"{base}/{path}", headers=headers, params=params,
                                    verify=False, timeout=HTTP_TIMEOUT)
            response.raise_for_status()
            return response.json()
        except (requests.RequestException, ValueError) as exc:
            print(f"  WARN cannot read {path}: {exc.__class__.__name__}")
            return {}

    with open(args.csv_path) as f:
        farmers = list(csv.DictReader(f))

    clients = get("clients", limit=-1).get("pageItems", [])
    if not clients:
        print(f"  FAIL: no clients could be read from {args.tenant}")
        return 1

    all_lent = True
    # Which farmer each registry record was already seen on, so two loans cannot pass on the
    # same evidence.
    seen_registrants = {}
    for farmer in farmers:
        msisdn = farmer["msisdn"]
        match = [c for c in clients if c.get("mobileNo") == msisdn]
        if not match:
            print(f"  FAIL {msisdn}: no client in {args.tenant}")
            all_lent = False
            continue
        client_id = match[0]["id"]

        loan = agri_loan(get(f"clients/{client_id}/accounts"))
        if not loan:
            print(f"  FAIL {msisdn}: no '{LOAN_PRODUCT_NAME}' loan")
            all_lent = False
            continue
        if not loan.get("status", {}).get("active"):
            state = loan.get("status", {}).get("value", "unknown")
            print(f"  FAIL {msisdn}: loan {loan['id']} is {state}, not disbursed")
            all_lent = False
            continue

        evidence = evidence_row(get(f"datatables/{REGISTRY_TABLE}/{loan['id']}"))
        if not evidence or not evidence.get("registrant_id"):
            print(f"  FAIL {msisdn}: loan {loan['id']} carries no registry evidence")
            all_lent = False
            continue

        registrant = evidence["registrant_id"]
        if registrant in seen_registrants:
            print(f"  FAIL {msisdn}: loan {loan['id']} carries the registry record of "
                  f"{seen_registrants[registrant]} ({registrant})")
            all_lent = False
            continue
        seen_registrants[registrant] = msisdn

        principal = float(loan.get("originalLoan") or loan.get("principal") or 0)
        wanted = expected_principal(float(evidence.get("hectares") or 0), evidence.get("band"))
        if wanted is None:
            print(f"  FAIL {msisdn}: loan {loan['id']} carries the unknown band "
                  f"'{evidence.get('band')}'")
            all_lent = False
            continue
        if abs(principal - wanted) > AMOUNT_TOLERANCE:
            print(f"  FAIL {msisdn}: loan {loan['id']} is {principal:.2f} but its evidence "
                  f"({evidence.get('hectares')} ha, band {evidence.get('band')}) justifies {wanted}")
            all_lent = False
            continue

        print(f"  OK {msisdn}: loan {loan['id']} active for {principal:.2f}, band "
              f"{evidence.get('band')} on {evidence.get('hectares')} ha of "
              f"{evidence.get('crop')} (registrant {evidence.get('registrant_id')})")

    return 0 if all_lent else 1


if __name__ == "__main__":
    sys.exit(main())
