#!/usr/bin/env python3
"""
Load agri demo data into a running OpenSPP2 (Odoo 19) via XML-RPC.

Creates, idempotently, the OpenSPP half of the demo agri flow:
  - a program "Agri subsidy Q3" (currency USD)
  - one cycle
  - N farmer households (res.partner, is_registrant + is_group) with an MSISDN
  - the subsidy entitlements, generated the canonical OpenSPP way

The entitlements are generated through OpenSPP's own Cash Entitlement Manager
(so they carry is_cash_entitlement=true, a program fund and a journal, and show
up in the "Cash Entitlements" list in the UI), not injected by hand. They are left
in state 'approved', ready to be disbursed.

This script only loads data. It configures no payment manager, so it runs against
a stock OpenSPP image and never sends money. It also does NOT touch
generate-mifos-vnext-data.py: it is the OpenSPP-side loader that sits on top of
the base Gazelle data.

Requires the farmer-registry product installed in OpenSPP2:
  spp_starter_farmer_registry (brings spp_farmer_registry + spp_programs + ...).
"""

import argparse
import csv
import datetime
import json
import sys
import time
import xmlrpc.client
from pathlib import Path

PROGRAM_MODULE = "spp_starter_farmer_registry"
REQUIRED_COLUMNS = ("household_name", "msisdn", "amount")


def load_fixtures(fixtures_dir):
    """Read the fixtures and fail with a readable message if they are malformed.

    The fixtures are meant to be edited by hand, so a missing column or a typo in
    an amount should say what is wrong instead of raising a traceback later on.
    """
    program_file = fixtures_dir / "program.json"
    csv_file = fixtures_dir / "beneficiaries.csv"
    for path in (program_file, csv_file):
        if not path.exists():
            sys.exit(f"ERROR: fixture not found: {path}")

    program = json.loads(program_file.read_text()).get("program")
    if not program or not program.get("name"):
        sys.exit(f"ERROR: {program_file} must define program.name")

    with csv_file.open() as f:
        beneficiaries = list(csv.DictReader(f))
    if not beneficiaries:
        sys.exit(f"ERROR: {csv_file} has no rows")

    missing = [c for c in REQUIRED_COLUMNS if c not in beneficiaries[0]]
    if missing:
        sys.exit(f"ERROR: {csv_file} is missing column(s): {', '.join(missing)}")

    # Line 1 is the header, so the first row of data is line 2.
    for line, row in enumerate(beneficiaries, start=2):
        for column in REQUIRED_COLUMNS:
            if not (row.get(column) or "").strip():
                sys.exit(f"ERROR: {csv_file} line {line}: '{column}' is empty")
        try:
            float(row["amount"])
        except ValueError:
            sys.exit(f"ERROR: {csv_file} line {line}: amount '{row['amount']}' is not a number")

    return program, beneficiaries


def ensure_module_installed(call, module, tries=60, interval=5):
    """Install an Odoo module if it is not installed yet, then wait until it is.

    Idempotent: if the module is already installed it returns at once. The install
    reloads the Odoo registry, so the RPC call may drop; we keep polling the state.
    """
    rec = call("ir.module.module", "search_read", [["name", "=", module]], fields=["state"])
    if not rec:
        call("ir.module.module", "update_list")
        rec = call("ir.module.module", "search_read", [["name", "=", module]], fields=["state"])
    if not rec:
        sys.exit(f"ERROR: module {module} not found (wrong OpenSPP image?)")
    if rec[0]["state"] == "installed":
        print(f"Module {module} already installed", file=sys.stderr)
        return
    print(f"Installing module {module} (may take a few minutes)...", file=sys.stderr)
    mod_id = rec[0]["id"]
    try:
        call("ir.module.module", "button_immediate_install", [mod_id])
    except Exception as exc:
        print(f"  install RPC dropped ({exc}); polling state", file=sys.stderr)
    for _ in range(tries):
        time.sleep(interval)
        try:
            state = call("ir.module.module", "read", [mod_id], fields=["state"])[0]["state"]
        except Exception:
            continue
        if state == "installed":
            print(f"Module {module} installed", file=sys.stderr)
            return
    sys.exit(f"ERROR: module {module} did not reach state 'installed' in time")


def call_ignore_none(call, model, method, *cargs):
    """Call an Odoo action method whose return value is None.

    Some OpenSPP button methods (create_journal, prepare_entitlement) return None.
    XML-RPC cannot marshal a bare None return and raises a Fault even though the
    action ran fine, so we swallow only that specific error and re-raise real ones.
    """
    try:
        return call(model, method, *cargs)
    except xmlrpc.client.Fault as exc:
        if "cannot marshal None" in str(exc):
            return None
        raise


def ensure_journal(call, program_id):
    """Give the program a disbursement journal (needed by the fund and the manager)."""
    if not call("spp.program", "read", [program_id], fields=["journal_id"])[0]["journal_id"]:
        call_ignore_none(call, "spp.program", "create_journal", [program_id])


def ensure_fund(call, program_id, amount, name):
    """Post a program fund so the entitlement approval has enough balance.

    The Cash Entitlement Manager checks the fund balance when it approves; the
    balance is the sum of posted funds minus already-approved entitlements.
    """
    if not call("spp.program.fund", "search", [["program_id", "=", program_id], ["name", "=", name]]):
        call("spp.program.fund", "create",
             {"name": name, "program_id": program_id, "amount": amount, "state": "posted"})


def ensure_manager(call, program_id, model, m2m_field, name, extra_vals):
    """Configure a program manager of one kind, once.

    A program takes at most one manager of each kind: the wrapper M2M is what
    get_manager() reads, and spp.program refuses to hold two. So if the program
    already has one, nothing is created. Creating a second concrete record would
    only leave an unusable orphan behind, because it could never be linked.

    Creating the concrete record alone does NOT configure the program: the wrapper
    points at it through a Reference field (manager_ref_id).
    """
    if call("spp.program", "read", [program_id], fields=[m2m_field])[0][m2m_field]:
        print(f"  program already has its {m2m_field[:-4]}, left as is", file=sys.stderr)
        return None

    found = call(model, "search", [["name", "=", name], ["program_id", "=", program_id]])
    if found:
        mgr_id = found[0]
    else:
        vals = {"name": name, "program_id": program_id}
        vals.update(extra_vals)
        mgr_id = call(model, "create", vals)
    call("spp.program", "write", [program_id],
         {m2m_field: [(0, 0, {"manager_ref_id": f"{model},{mgr_id}"})]})
    return mgr_id


def wait_for_cycle_members(call, cycle_id, expected, tries=30, interval=2):
    """Wait until every beneficiary is in the cycle.

    copy_beneficiaries_from_program() enrols in the background above 200
    beneficiaries, so with a large fixture the next step would run before the
    enrolment finished and would generate nothing.
    """
    count = 0
    for _ in range(tries):
        count = call("spp.cycle.membership", "search_count", [["cycle_id", "=", cycle_id]])
        if count >= expected:
            return count
        time.sleep(interval)
    sys.exit(f"ERROR: only {count} of {expected} beneficiaries reached cycle {cycle_id}")


def main():
    here = Path(__file__).resolve()
    default_fixtures = here.parent.parent.parent.parent / "demos" / "openspp" / "fixtures"

    ap = argparse.ArgumentParser(description="Load agri demo data into OpenSPP2 via XML-RPC")
    # Odoo is reached over a port-forward (kubectl port-forward svc/openspp-odoo 8069:8069),
    # not the ingress, which is optional and serves a self-signed certificate.
    ap.add_argument("--url", default="http://localhost:8069")
    ap.add_argument("--db", default="openspp")
    ap.add_argument("--user", default="admin")
    ap.add_argument("--password", default="admin")
    ap.add_argument("--fixtures", type=Path, default=default_fixtures)
    args = ap.parse_args()

    program_fx, beneficiaries = load_fixtures(args.fixtures)

    common = xmlrpc.client.ServerProxy(f"{args.url}/xmlrpc/2/common")
    uid = common.authenticate(args.db, args.user, args.password, {})
    if not uid:
        sys.exit(f"ERROR: authentication failed for {args.user}@{args.db}")
    models = xmlrpc.client.ServerProxy(f"{args.url}/xmlrpc/2/object")

    # Thin wrapper: caller passes the raw Odoo args (domain / vals / ids) directly.
    def call(model, method, *cargs, **ckw):
        return models.execute_kw(args.db, uid, args.password, model, method, list(cargs), ckw)

    print(f"Connected to OpenSPP2 at {args.url} (db={args.db}, uid={uid})", file=sys.stderr)

    # Farmer-registry product must be installed; install it if missing (idempotent).
    ensure_module_installed(call, PROGRAM_MODULE)

    # Currency USD.
    cur = call("res.currency", "search", [["name", "=", "USD"]], context={"active_test": False})
    if not cur:
        sys.exit("ERROR: USD currency not found")
    usd_id = cur[0]

    # Program (idempotent by name).
    prog_name = program_fx["name"]
    prog_ids = call("spp.program", "search", [["name", "=", prog_name]])
    if prog_ids:
        program_id = prog_ids[0]
        print(f"Program '{prog_name}' already exists (id={program_id})", file=sys.stderr)
    else:
        program_id = call("spp.program", "create", {"name": prog_name, "currency_id": usd_id})
        print(f"Created program '{prog_name}' (id={program_id})", file=sys.stderr)

    # Cycle (idempotent by name within program).
    cycle_name = f"{prog_name} - Cycle 1"
    cyc_ids = call("spp.cycle", "search", [["name", "=", cycle_name], ["program_id", "=", program_id]])
    if cyc_ids:
        cycle_id = cyc_ids[0]
        print(f"Cycle '{cycle_name}' already exists (id={cycle_id})", file=sys.stderr)
    else:
        today = datetime.date.today()
        cycle_id = call("spp.cycle", "create", {
            "name": cycle_name,
            "program_id": program_id,
            "sequence": 1,
            "start_date": today.isoformat(),
            "end_date": (today + datetime.timedelta(days=90)).isoformat(),
        })
        print(f"Created cycle '{cycle_name}' (id={cycle_id})", file=sys.stderr)

    # Farmer households: registrant group + MSISDN + program enrollment (idempotent).
    for row in beneficiaries:
        hh_name = row["household_name"]
        msisdn = row["msisdn"]

        part_ids = call("res.partner", "search",
                        [["name", "=", hh_name], ["is_registrant", "=", True], ["is_group", "=", True]])
        if part_ids:
            partner_id = part_ids[0]
        else:
            partner_id = call("res.partner", "create",
                              {"name": hh_name, "is_registrant": True, "is_group": True})

        ph_ids = call("spp.phone.number", "search",
                      [["partner_id", "=", partner_id], ["phone_no", "=", msisdn]])
        if not ph_ids:
            call("spp.phone.number", "create", {"partner_id": partner_id, "phone_no": msisdn})

        mem_ids = call("spp.program.membership", "search",
                       [["partner_id", "=", partner_id], ["program_id", "=", program_id]])
        if not mem_ids:
            call("spp.program.membership", "create",
                 {"partner_id": partner_id, "program_id": program_id, "state": "enrolled"})
        print(f"  {hh_name} ({msisdn}) enrolled", file=sys.stderr)

    # Subsidy amount. The Cash Entitlement Manager applies one amount per cycle to
    # every enrolled beneficiary; the agri demo uses a flat amount for all of them.
    amounts = sorted({float(r["amount"]) for r in beneficiaries})
    item_amount = amounts[-1]
    if len(amounts) > 1:
        print("WARN: beneficiaries have different amounts; the Cash Entitlement Manager "
              f"applies one amount per cycle. Using {item_amount:.2f}.", file=sys.stderr)

    # Canonical entitlement setup: journal + fund + entitlement manager + cycle manager.
    ensure_journal(call, program_id)
    ensure_fund(call, program_id, item_amount * len(beneficiaries), f"{prog_name} fund")
    ensure_manager(call, program_id, "spp.program.entitlement.manager.cash",
                   "entitlement_manager_ids", f"{prog_name} cash entitlements",
                   {"entitlement_item_ids": [(0, 0, {"amount": item_amount})]})
    ensure_manager(call, program_id, "spp.cycle.manager.default",
                   "cycle_manager_ids", f"{prog_name} cycle manager",
                   {"cycle_duration": 1, "rrule_type": "monthly"})

    # No payment manager is configured here: that piece is what OpenSPP uses to send the
    # money itself, and it lives in an optional module. Leaving it out keeps this script
    # working on a stock OpenSPP image; the entitlements end up approved and are paid from
    # outside OpenSPP.

    # Generate the entitlements through the managers (the canonical flow).
    # copy -> cycle memberships enrolled; prepare -> draft cash entitlements;
    # validate -> approved. All idempotent: prepare skips beneficiaries that already
    # have an entitlement in the cycle, and validate only approves draft ones, so a
    # re-run never re-approves paid subsidies (state 'rdpd2ben').
    call("spp.cycle", "copy_beneficiaries_from_program", [cycle_id])
    wait_for_cycle_members(call, cycle_id, len(beneficiaries))
    call_ignore_none(call, "spp.cycle", "prepare_entitlement", [cycle_id])
    res = call("spp.cycle", "validate_entitlement", [cycle_id])
    if isinstance(res, dict) and res.get("params", {}).get("type") == "danger":
        sys.exit(f"ERROR: entitlement validation failed: {res['params'].get('message')}")

    # Check the load actually produced what was asked for, and fail loudly if not:
    # the whole point of this script is to leave one entitlement per beneficiary.
    # The check counts entitlements in any state, not only approved ones, because a
    # re-run after a disbursement finds them already paid ('rdpd2ben').
    total = call("spp.entitlement", "search_count", [["cycle_id", "=", cycle_id]])
    if total != len(beneficiaries):
        sys.exit(f"ERROR: cycle {cycle_id} has {total} entitlements for "
                 f"{len(beneficiaries)} beneficiaries. Check the program fund balance "
                 f"and that every beneficiary is enrolled.")

    approved = call("spp.entitlement", "search_count",
                    [["cycle_id", "=", cycle_id], ["state", "=", "approved"]])
    cash = call("spp.entitlement", "search_count",
                [["cycle_id", "=", cycle_id], ["is_cash_entitlement", "=", True]])
    print(f"\nOK: program id={program_id}, cycle id={cycle_id}, entitlements={total}, "
          f"cash={cash}, approved={approved}", file=sys.stderr)


if __name__ == "__main__":
    main()
