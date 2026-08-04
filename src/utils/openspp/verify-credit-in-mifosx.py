#!/usr/bin/env python3
# DEMO verification step: check each agri beneficiary got their subsidy in MifosX.
# For each MSISDN in the beneficiaries CSV, look up the client in the payee tenant,
# find its savings account, and confirm a deposit matching the subsidy amount exists.
# Exit code: 0 if every beneficiary was credited, 1 if any is missing.
#
# A deposit only counts when it came through the payment rail and is recent enough.
# Other money in the account could match by chance: deposits made straight against
# Fineract (no routing code), interest postings (not a deposit) and the subsidies of
# previous runs (same amount, older date).
import argparse
import csv
import datetime
import json
import sys

import requests
import urllib3

# Fineract demo admin (mifos:password), base64-encoded for HTTP Basic auth.
FINERACT_BASIC_AUTH = "Basic bWlmb3M6cGFzc3dvcmQ="
HTTP_TIMEOUT = 30
AMOUNT_TOLERANCE = 0.01  # floats: treat amounts within one cent as equal.
# Payment Hub stamps this on every transfer it books through the interoperation rail.
# A deposit made straight against Fineract carries an empty routing code instead.
RAIL_ROUTING_CODE = "INTEROPERATION"
# Only the audit keeps a time; a savings transaction is dated by day. Cap on the rows
# read, since each one costs an extra call.
AUDIT_ROWS_SCANNED = 50


def a_day(text):
    """Parse YYYY-MM-DD into the (y, m, d) shape Fineract uses for a transaction date."""
    d = datetime.datetime.strptime(text, "%Y-%m-%d").date()
    return (d.year, d.month, d.day)


def parse_args():
    ap = argparse.ArgumentParser(description="Verify agri subsidies were credited in MifosX.")
    ap.add_argument("domain", help="Gazelle domain, e.g. mifos.gazelle.test")
    ap.add_argument("csv_path", help="Path to beneficiaries.csv")
    ap.add_argument("tenant", help="Payee tenant (Fineract tenant id), e.g. bluebank")
    ap.add_argument("--since", default=None, metavar="WHEN",
                    help="ignore anything older than this (default: today). A day, "
                         "YYYY-MM-DD, reads the savings transactions, which Fineract dates "
                         "by day, so two runs on the same day look the same. Add a time, "
                         "YYYY-MM-DD HH:MM:SS, to read Fineract's audit instead, which is "
                         "the only place with a clock and can tell those runs apart.")
    args = ap.parse_args()
    args.since_time = None
    # Validated here so a typo is answered with the usage text and not with a traceback.
    try:
        if args.since and " " in args.since:
            datetime.datetime.strptime(args.since, "%Y-%m-%d %H:%M:%S")
            args.since_time = args.since
            args.since = a_day(args.since.split(" ")[0])
        elif args.since:
            args.since = a_day(args.since)
    except ValueError:
        ap.error(f"--since {args.since!r} is not YYYY-MM-DD or 'YYYY-MM-DD HH:MM:SS'")
    if not args.since:
        today = datetime.date.today()
        args.since = (today.year, today.month, today.day)
    return args


def audited_transfers(get, since_text):
    """[(account external id, amount)] for rail transfers audited since a moment.

    Fineract audits every interoperation transfer with a millisecond stamp and a payload
    naming the account and the amount. The listing does not carry that payload, so each
    row has to be read on its own.
    """
    rows = get("audits", entityName="INTERTRANSFER", makerDateTimeFrom=since_text,
               dateFormat="yyyy-MM-dd HH:mm:ss", locale="en", limit=AUDIT_ROWS_SCANNED)
    rows = rows if isinstance(rows, list) else rows.get("pageItems", [])
    transfers = []
    for row in rows:
        detail = get(f"audits/{row.get('id')}")
        try:
            command = json.loads(detail.get("commandAsJson") or "{}")
        except (AttributeError, ValueError):
            continue
        transfers.append((command.get("accountId"), (command.get("amount") or {}).get("amount")))
    return transfers


def audited_transfer_found(transfers, account_external_id, amount):
    """True when the audited transfers hold one for this account and amount."""
    for account, credited in transfers:
        if not account or account != account_external_id:
            continue
        try:
            if abs(float(credited) - amount) < AMOUNT_TOLERANCE:
                return True
        except (TypeError, ValueError):
            continue
    return False


def is_subsidy_deposit(transaction, amount, since):
    """True for a deposit of this amount that came through the rail on or after a day.

    The date is compared with 'on or after' and never with equality: the deposit is dated
    by the connector's clock, which can run a day ahead.
    """
    if not transaction.get("transactionType", {}).get("deposit"):
        return False
    if not transaction.get("notReversed", True):
        return False
    if (transaction.get("paymentDetailData") or {}).get("routingCode") != RAIL_ROUTING_CODE:
        return False
    if tuple(transaction.get("date") or ()) < since:
        return False
    try:
        return abs(float(transaction.get("amount")) - amount) < AMOUNT_TOLERANCE
    except (TypeError, ValueError):
        return False


def main():
    urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)
    args = parse_args()
    base = f"https://mifos.{args.domain}/fineract-provider/api/v1"
    headers = {
        "Fineract-Platform-TenantId": args.tenant,
        "Authorization": FINERACT_BASIC_AUTH,
    }

    def get(path, **params):
        # verify=False: MifosX uses a self-signed cert in Gazelle (like curl -k).
        # An unreadable answer is a failure, not a traceback: Fineract returns 503
        # through the ingress while it restarts.
        try:
            response = requests.get(f"{base}/{path}", headers=headers, params=params,
                                    verify=False, timeout=HTTP_TIMEOUT)
            response.raise_for_status()
            return response.json()
        except (requests.RequestException, ValueError) as exc:
            # Same stream as the results, so the cause reads before its consequence.
            print(f"  WARN cannot read {path}: {exc.__class__.__name__}")
            return {}

    with open(args.csv_path) as f:
        beneficiaries = list(csv.DictReader(f))

    # Read once, not once per beneficiary. limit=-1 returns every client: Fineract pages
    # at 200 by default and the match happens here, so a client past the page would look
    # like it does not exist.
    clients = get("clients", limit=-1).get("pageItems", [])
    if not clients:
        print(f"  FAIL: no clients could be read from {args.tenant}")
        return 1

    # With a time the audit is the source, read once for the whole run.
    transfers = audited_transfers(get, args.since_time) if args.since_time else None

    all_credited = True
    for row in beneficiaries:
        msisdn = row["msisdn"]
        amount = float(row["amount"])

        match = [c for c in clients if c.get("mobileNo") == msisdn]
        if not match:
            print(f"  FAIL {msisdn}: no client in {args.tenant}")
            all_credited = False
            continue
        client_id = match[0]["id"]

        accounts = get(f"clients/{client_id}/accounts")
        savings = accounts.get("savingsAccounts", [])
        if not savings:
            print(f"  FAIL {msisdn}: no savings account")
            all_credited = False
            continue
        account_id = savings[0]["id"]

        account = get(f"savingsaccounts/{account_id}", associations="transactions")
        if transfers is None:
            credited = any(is_subsidy_deposit(t, amount, args.since)
                           for t in account.get("transactions", []))
        else:
            credited = audited_transfer_found(transfers, account.get("externalId"), amount)
        if credited:
            print(f"  OK {msisdn}: credited USD {amount:.2f} (acct {account_id})")
        else:
            since = args.since_time or "%04d-%02d-%02d" % args.since
            print(f"  FAIL {msisdn}: no subsidy of USD {amount:.2f} through the "
                  f"payment rail since {since} (acct {account_id})")
            all_credited = False

    return 0 if all_credited else 1


if __name__ == "__main__":
    sys.exit(main())
