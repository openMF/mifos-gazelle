#!/usr/bin/env python3
"""
GAZ-DEMO bridge: OpenSPP2 -> Payment Hub EE -> MifosX (agri subsidy).

For each APPROVED entitlement of the program in OpenSPP2:
  1. make sure the beneficiary is a payable payee in the payee bank (Fineract
     client + savings + interop party + vNext oracle + identity mapper),
  2. record the payment in OpenSPP as 'sent' and only then disburse it via PHEE's
     channel/transfer (payer -> payee), the same call as make-payment.sh, which
     does the real debit/credit through the Mojaloop switch and the ams-mifos
     connector,
  3. wait until the payee's MifosX savings account is actually credited, then
     close that payment as paid and mark the entitlement 'rdpd2ben', which is what
     shows as "Paid" in the OpenSPP UI.

Idempotent: a re-run only pays entitlements that are still approved. Payment Hub does
not deduplicate, so the payment is recorded before it is sent and a later run looks that
record up by its reference instead of sending a second transfer.

NOTE: channel/transfer needs no extra OpenSPP module. The bulk /batchtransactions rail
ends up on the same one: ph-ee-connector-bulk posts each payment to /channel/transfer,
which runs PayerFundTransfer for the payer tenant greenbank and books in Fineract.
Payments go one at a time, each confirmed before the next, so the single-instance
switch and connectors are not overwhelmed.

Own script per DPG: does NOT modify generate-mifos-vnext-data.py; it reuses its
Fineract/oracle/mapper helpers. Needs the full stack (OpenSPP2 + PHEE + MifosX +
vNext) on one machine.
"""

import argparse
import datetime
import importlib.util
import sys
import time
import uuid
import xmlrpc.client
from pathlib import Path

import requests
import urllib3

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

REPO_ROOT = Path(__file__).resolve().parent.parent.parent.parent
DATA_DIR = REPO_ROOT / "src" / "utils" / "data-loading"
DEFAULT_CONFIG = REPO_ROOT / "config" / "config.ini"
CREDIT_POLL_TRIES = 15
CREDIT_POLL_INTERVAL = 8   # seconds -> up to 2 min per payment
# Cap on the audit rows read when checking a transfer. Each row costs one extra call.
AUDIT_ROWS_SCANNED = 25


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


gen = _load("gen_mifos_vnext", DATA_DIR / "generate-mifos-vnext-data.py")


def fineract_headers(tenant):
    # Credentials come from the data generator so there is one place to change them.
    return {"Fineract-Platform-TenantId": tenant, "Authorization": gen.AUTH_HEADER_VALUE,
            "Content-Type": "application/json", "Accept": "application/json"}


def openspp_call(url, db, user, pw):
    """Return a call(model, method, *args, **kw) bound to verified Odoo credentials.

    Odoo's XML-RPC API keeps no session: execute_kw takes the database, user id and
    password on every call, so the closure carries them.
    """
    uid = xmlrpc.client.ServerProxy(f"{url}/xmlrpc/2/common").authenticate(db, user, pw, {})
    if not uid:
        sys.exit(f"ERROR: OpenSPP auth failed for {user}@{db}")
    models = xmlrpc.client.ServerProxy(f"{url}/xmlrpc/2/object")
    return lambda model, method, *a, **k: models.execute_kw(db, uid, pw, model, method, list(a), k)


def read_approved_entitlements(call, program_name):
    """Return [{id, msisdn, amount, name, cycle_id}] for the approved entitlements."""
    prog = call("spp.program", "search", [["name", "=", program_name]])
    if not prog:
        sys.exit(f"ERROR: program '{program_name}' not found in OpenSPP")
    ents = call("spp.entitlement", "search_read",
                [["state", "=", "approved"], ["program_id", "=", prog[0]]],
                fields=["partner_id", "initial_amount", "cycle_id"])
    out = []
    for e in ents:
        pid = e["partner_id"][0]                       # M2o -> [id, name]
        # Skip decommissioned numbers: the registry marks them with a 'disabled' date,
        # and paying one of those sends the money to a phone nobody owns any more.
        phones = call("spp.phone.number", "search_read",
                      [["partner_id", "=", pid], ["disabled", "=", False]],
                      fields=["phone_no"])
        if not phones:
            print(f"  WARN: {e['partner_id'][1]} has no phone number, skipping", file=sys.stderr)
            continue
        out.append({"id": e["id"], "msisdn": phones[0]["phone_no"],
                    "amount": e["initial_amount"], "name": e["partner_id"][1],
                    "cycle_id": e["cycle_id"][0] if e.get("cycle_id") else None})
    return out


def pending_payment(call, entitlement_id):
    """The spp.payment of this entitlement with no outcome yet, or None.

    Pending means an empty status: 'paid' and 'failed' are both final and leave the
    entitlement free to be paid. In Odoo, '=' False also matches an empty column.
    """
    pays = call("spp.payment", "search_read",
                [["entitlement_id", "=", entitlement_id], ["status", "=", False]],
                fields=["create_date", "name"], limit=1)
    return pays[0] if pays else None


def open_payment_in_openspp(call, entitlement_id, amount, cycle_id=None, account_no=None):
    """Record the intent to pay in OpenSPP, before sending anything to Payment Hub.

    The entitlement's "Payment Status" is a computed field: it reads the entitlement's
    spp.payment records and shows "Paid" only when one has status='paid'. The cycle's
    "Payments" counter also counts spp.payment by cycle_id. The disbursement happens
    outside OpenSPP, through PHEE, so without this record the UI stays on "Not Paid".

    Created before the transfer and left in state 'sent'. Recording it afterwards would
    lose any payment whose credit lands after the wait, and the next run would pay again.
    """
    vals = {
        "entitlement_id": entitlement_id,
        # The model default for name is one uuid built at module load, shared by every
        # record created without it, so each payment needs its own.
        "name": str(uuid.uuid4()),
        "amount_issued": amount,
        "state": "sent",
        "is_status_final": False,
    }
    if cycle_id:
        vals["cycle_id"] = cycle_id   # so the cycle's "Payments" counter sees it
    if account_no:
        vals["account_number"] = account_no   # which account should receive the money
    return call("spp.payment", "create", vals)


def fail_payment_in_openspp(call, payment_id):
    """Mark a payment as failed so the entitlement can be paid again."""
    now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
    call("spp.payment", "write", [payment_id],
         {"status": "failed", "is_status_final": True, "status_datetime": now})


def close_payment_as_paid(call, entitlement_id, amount):
    """Close the open spp.payment of this entitlement once the credit is confirmed.

    The payment is already recorded by the time the credit lands, so it is updated rather
    than duplicated. Idempotent: a paid one is not picked up again.
    """
    # Only the ones with no outcome yet: status holds 'paid' or 'failed', and both are
    # final.
    pays = call("spp.payment", "search",
                [["entitlement_id", "=", entitlement_id], ["status", "=", False]])
    if not pays:
        return
    now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
    call("spp.payment", "write", pays, {
        "status": "paid", "state": "reconciled", "is_status_final": True,
        "amount_paid": amount, "payment_datetime": now, "status_datetime": now,
    })


def find_client_id_by_mobile(headers, msisdn):
    """Fineract client id whose mobileNo == msisdn (the ?mobileNo filter is unreliable)."""
    # limit=-1 returns every client. Fineract pages at 200 by default, and since the
    # match happens here, a client past the page would look like it does not exist.
    data = gen.make_api_request("GET", gen.CLIENTS_API_URL, headers, params={"limit": -1})
    for c in (data or {}).get("pageItems", []):
        if c.get("mobileNo") == msisdn:
            return c.get("id")
    return None


def ensure_payee(headers, tenant, msisdn, payer_tenant):
    """Ensure MSISDN is a Fineract client with savings + interop + oracle + mapper. Returns acct id."""
    client_id = find_client_id_by_mobile(headers, msisdn)
    if client_id:
        account_id = gen.get_savings_accounts_for_client(headers, client_id)
        if account_id:
            gen.register_client_with_vnext(headers, tenant, msisdn)
            gen.register_beneficiary_with_identity_mapper(tenant, msisdn, account_id, payer_tenant)
            return account_id
        # Client without a savings account: reuse it and create the account below.
    product_id = gen.create_savings_product(headers, f"{tenant}-savings")
    if not client_id:
        client_id, _m, _n = gen.create_client(headers, "en", tenant, msisdn)
        if not client_id:
            return None
    account_id, ext_id = gen.create_savings_account(headers, client_id, product_id, "en")
    if not account_id:
        return None
    today = datetime.datetime.now().strftime(gen.DATE_FORMAT)
    gen.approve_savings_account(gen.API_BASE_URL, headers, account_id, today)
    gen.activate_savings_account(gen.API_BASE_URL, headers, account_id, today)
    gen.make_deposit(gen.API_BASE_URL, headers, account_id, 5000, today)
    gen.register_interop_party(headers, client_id, ext_id, msisdn)
    gen.register_client_with_vnext(headers, tenant, msisdn)
    gen.register_beneficiary_with_identity_mapper(tenant, msisdn, account_id, payer_tenant)
    return account_id


def savings_account_no(headers, account_id):
    """Fineract's human-visible account number, not the internal account id."""
    d = gen.make_api_request("GET", f"{gen.API_BASE_URL}/savingsaccounts/{account_id}", headers)
    return (d or {}).get("accountNo")


def savings_balance(headers, account_id):
    """Account balance, or None when it could not be read.

    None is not the same as zero. A failed read taken as a zero baseline would make the
    next successful read look like the payment had arrived, so the caller has to tell
    "the account is empty" apart from "I could not ask".
    """
    return _balance_field(headers, account_id, "accountBalance")


def spendable_balance(headers, account_id):
    """What the account can actually pay with, or None when it could not be read.

    Funds a transfer put on hold still count in the book balance but cannot be spent,
    so the payer has to be measured with this one. Falls back to the book balance when
    Fineract does not report it.
    """
    available = _balance_field(headers, account_id, "availableBalance")
    if available is not None:
        return available
    return _balance_field(headers, account_id, "accountBalance")


def _balance_field(headers, account_id, field):
    d = gen.make_api_request("GET", f"{gen.API_BASE_URL}/savingsaccounts/{account_id}", headers)
    if not d:
        return None
    summary = d.get("summary")
    if not isinstance(summary, dict):
        return None
    balance = summary.get(field)
    if balance is None:
        return 0.0 if field == "accountBalance" else None
    try:
        return float(balance)
    except (TypeError, ValueError):
        return None


def transfer_booked(headers, transaction_id, since=None):
    """True when Fineract's audit shows this transfer reference.

    since: only read audit rows after this UTC moment, as 'YYYY-MM-DD HH:MM:SS'.
    One extra call per row: the audit listing does not carry the payload.
    """
    params = {"entityName": "INTERTRANSFER", "limit": AUDIT_ROWS_SCANNED}
    if since:
        params.update({"makerDateTimeFrom": since,
                       "dateFormat": "yyyy-MM-dd HH:mm:ss", "locale": "en"})
    rows = gen.make_api_request("GET", f"{gen.API_BASE_URL}/audits", headers, params=params)
    if not rows:
        return False
    for row in rows if isinstance(rows, list) else rows.get("pageItems", []):
        detail = gen.make_api_request("GET", f"{gen.API_BASE_URL}/audits/{row.get('id')}", headers)
        command = (detail or {}).get("commandAsJson") or ""
        if transaction_id and transaction_id in command:
            return True
    return False


def credit_seen(headers, account_id, baseline, amount):
    """True when the balance has risen by at least amount since baseline.

    An unreadable balance returns False so the caller keeps waiting instead of taking a
    failed read as proof of anything.
    """
    current = savings_balance(headers, account_id)
    if current is None:
        return False
    return current >= baseline + amount - 0.01


def get_payer_msisdn(payer_tenant):
    """The MSISDN of the first client in the payer tenant, which is who pays."""
    for c in gen.get_clients_from_mifos(fineract_headers(payer_tenant), payer_tenant):
        if c.get("mobile"):
            return c["mobile"]
    sys.exit(f"ERROR: no payer client with MSISDN found in tenant {payer_tenant}")


def ensure_payer_funds(headers, payer_msisdn, total_needed):
    """Make sure the payer account can cover total_needed; top up the shortfall (demo money).

    Idempotent: only deposits when the balance is short. Mirrors the payee seeding in
    ensure_payee, so the demo stays self-sufficient across runs (each run debits the payer).
    """
    client_id = find_client_id_by_mobile(headers, payer_msisdn)
    if not client_id:
        return
    account_id = gen.get_savings_accounts_for_client(headers, client_id)
    if not account_id:
        return
    # Spendable, not book balance: a transfer left hanging keeps its funds on hold, and
    # topping up against the book balance would leave the payer short by that much.
    balance = spendable_balance(headers, account_id)
    if balance is None:
        print("Payer balance could not be read, skipping the top-up", file=sys.stderr)
        return
    if balance < total_needed:
        topup = total_needed - balance
        today = datetime.datetime.now().strftime(gen.DATE_FORMAT)
        gen.make_deposit(gen.API_BASE_URL, headers, account_id, topup, today)
        print(f"Payer funded: +{topup} (was {balance}, needs {total_needed})", file=sys.stderr)


def main():
    ap = argparse.ArgumentParser(description="Bridge OpenSPP2 approved entitlements -> PHEE channel/transfer -> MifosX")
    ap.add_argument("--openspp-url", default="http://localhost:8069")
    ap.add_argument("--openspp-db", default="openspp")
    ap.add_argument("--openspp-user", default="admin")
    ap.add_argument("--openspp-password", default="admin")
    ap.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    ap.add_argument("--program-name", default="Agri subsidy Q3")
    ap.add_argument("--payer-tenant", default="greenbank")
    ap.add_argument("--payee-tenant", default="bluebank")
    ap.add_argument("--currency", default="USD")
    ap.add_argument("--no-writeback", action="store_true", help="do not mark entitlements paid in OpenSPP")
    ap.add_argument("--no-payer-topup", action="store_true",
                    help="do not auto-fund the payer even if its balance is short")
    args = ap.parse_args()

    cfg = gen.load_config(str(args.config))
    domain = gen.get_gazelle_domain(cfg)
    gen.set_global_urls(domain)
    print(f"Domain: {domain}", file=sys.stderr)

    call = openspp_call(args.openspp_url, args.openspp_db, args.openspp_user, args.openspp_password)

    # Read approved entitlements from OpenSPP.
    # None left is the idempotent case (a previous run already paid them): report 0, exit ok.
    ents = read_approved_entitlements(call, args.program_name)
    if not ents:
        print("No approved entitlements to pay (already paid). Nothing to do.", file=sys.stderr)
        print(0)
        return
    print(f"Read {len(ents)} approved entitlement(s) from OpenSPP", file=sys.stderr)

    # Ensure each beneficiary is a payable payee (Fineract + oracle + mapper).
    payee_headers = fineract_headers(args.payee_tenant)
    for e in ents:
        e["acct"] = ensure_payee(payee_headers, args.payee_tenant, e["msisdn"], args.payer_tenant)
        state = "ready" if e["acct"] else "NO ACCOUNT"
        print(f"  payee {state}: {e['name']} ({e['msisdn']}) acct={e['acct']} USD {e['amount']:.2f}", file=sys.stderr)
    payable = [e for e in ents if e["acct"]]
    if not payable:
        # Not the same as "already paid": there was work to do and no payee could take it.
        print(f"ERROR: none of the {len(ents)} beneficiaries could be made payable in "
              f"{args.payee_tenant}, nothing was sent.", file=sys.stderr)
        print(0)
        return

    # Disburse, confirm each credit, mark it paid.
    payer_msisdn = get_payer_msisdn(args.payer_tenant)
    print(f"Payer MSISDN ({args.payer_tenant}): {payer_msisdn}", file=sys.stderr)

    # Make sure the payer can cover the subsidies (it drains across runs); top up if short.
    payer_headers = fineract_headers(args.payer_tenant)
    total_needed = sum(int(round(e["amount"])) for e in payable)
    if not args.no_payer_topup:
        ensure_payer_funds(payer_headers, payer_msisdn, total_needed)

    transfer_url = f"https://channel.{domain}/channel/transfer"
    paid = 0
    for e in payable:
        amount = int(round(e["amount"]))
        # An unresolved payment means the money may already be on its way or already there.
        # Payment Hub does not deduplicate, so a second transfer would pay twice.
        reference = None
        earlier = None if args.no_writeback else pending_payment(call, e["id"])
        if earlier:
            print(f"  WARN {e['name']} ({e['msisdn']}): an earlier run already sent this one, "
                  f"looking for it instead of paying again", file=sys.stderr)
            # Only the reference settles this: a deposit of the right amount is not
            # proof, since an earlier run may have left one. create_date bounds the
            # audit window; Odoo keeps it in UTC, in the format Fineract expects.
            arrived = bool(earlier.get("name")) and transfer_booked(
                payee_headers, earlier["name"], since=earlier.get("create_date"))
            if not arrived:
                print(f"  ERROR {e['name']} ({e['msisdn']}): that payment is unresolved and "
                      f"cannot be confirmed, left alone on purpose. Check the account before "
                      f"forcing it.", file=sys.stderr)
                continue
            paid += 1
            msg = f"  OK {e['name']} ({e['msisdn']}) acct {e['acct']}: the earlier payment did arrive"
            call("spp.entitlement", "write", [e["id"]], {"state": "rdpd2ben"})
            close_payment_as_paid(call, e["id"], amount)
            print(f"{msg} - marked Paid in OpenSPP", file=sys.stderr)
            continue
        else:
            baseline = savings_balance(payee_headers, e["acct"])
            if baseline is None:
                print(f"  ERROR {e['name']} ({e['msisdn']}): balance unreadable, not paying so a "
                      f"re-run can, since the credit could not be verified", file=sys.stderr)
                continue
            payload = {
                "payer": {"partyIdInfo": {"partyIdType": "MSISDN", "partyIdentifier": payer_msisdn}},
                "payee": {"partyIdInfo": {"partyIdType": "MSISDN", "partyIdentifier": e["msisdn"]}},
                "amount": {"amount": amount, "currency": args.currency},
            }
            headers = {"Platform-TenantId": args.payer_tenant, "X-PayeeDFSP-ID": args.payee_tenant,
                       "X-CorrelationID": str(uuid.uuid4()), "Content-Type": "application/json", "Accept": "*/*"}
            # Recorded before the transfer: a credit landing after the wait is not lost,
            # and the record is what stops a re-run from paying twice. --no-writeback
            # leaves OpenSPP untouched and therefore without that protection.
            payment_id = None
            if not args.no_writeback:
                payment_id = open_payment_in_openspp(call, e["id"], amount, e.get("cycle_id"),
                                                     savings_account_no(payee_headers, e["acct"]))
            try:
                r = requests.post(transfer_url, json=payload, headers=headers, verify=False, timeout=30)
            except requests.ReadTimeout:
                # Sent without an answer: the payment may have gone through, so the record
                # stays open and the balance below decides.
                print(f"  WARN {e['name']} ({e['msisdn']}): no reply from channel/transfer, "
                      f"checking the account anyway", file=sys.stderr)
            except requests.RequestException as exc:
                # Never sent: close the record so a later run can pay this one.
                if payment_id:
                    fail_payment_in_openspp(call, payment_id)
                print(f"  ERROR {e['name']} ({e['msisdn']}): transfer not sent "
                      f"({exc.__class__.__name__})", file=sys.stderr)
                continue
            else:
                if r.status_code != 200:
                    if payment_id:
                        fail_payment_in_openspp(call, payment_id)
                    print(f"  ERROR {e['name']} ({e['msisdn']}): transfer HTTP {r.status_code} {r.text[:150]}", file=sys.stderr)
                    continue
                # Payment Hub's reference, stored because Fineract's audit records it.
                try:
                    reference = r.json().get("transactionId")
                except ValueError:
                    reference = None
                if reference and payment_id:
                    call("spp.payment", "write", [payment_id], {"name": reference})

        # Wait until the payee savings account is actually credited.
        credited = False
        for _ in range(CREDIT_POLL_TRIES):
            time.sleep(CREDIT_POLL_INTERVAL)
            if credit_seen(payee_headers, e["acct"], baseline, amount):
                credited = True
                break
        if not credited and reference:
            # The balance can move for other reasons, so before calling a transfer lost
            # Fineract is asked about that exact reference.
            if transfer_booked(payee_headers, reference):
                credited = True
                print(f"  WARN {e['name']} ({e['msisdn']}): the credit was not visible in the "
                      f"balance, but Fineract booked the transfer", file=sys.stderr)
        if not credited:
            print(f"  ERROR {e['name']} ({e['msisdn']}): transfer sent but credit not seen (still in flight)", file=sys.stderr)
            continue

        paid += 1
        msg = f"  OK {e['name']} ({e['msisdn']}) acct {e['acct']}: credited USD {amount}"
        if not args.no_writeback:
            call("spp.entitlement", "write", [e["id"]], {"state": "rdpd2ben"})   # Status -> Paid to Beneficiary
            close_payment_as_paid(call, e["id"], amount)                   # Payment Status -> Paid
            msg += " - marked Paid in OpenSPP"
        print(msg, file=sys.stderr)

    print(f"\nOK: {paid}/{len(payable)} agri subsidies disbursed & confirmed in MifosX.", file=sys.stderr)
    print(paid)   # stdout: count for the orchestrator


if __name__ == "__main__":
    main()
