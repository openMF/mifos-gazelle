#!/usr/bin/env python3
"""
verify-batches.py

Submits and verifies bulk batch scenarios via the operations-app REST API.

Default: all 4 non-Mastercard scenarios.
  1. Mojaloop  / Non-GovStack  (tenant: greenbank)
  2. Closedloop / Non-GovStack  (tenant: redbank)
  3. Mojaloop  / GovStack       (tenant: greenbank --govstack)
  4. Closedloop / GovStack       (tenant: redbank   --govstack)

Usage:
  ./verify-batches.py                    # uses ~/tomconfig.ini
  ./verify-batches.py -c ~/myconfig.ini
  ./verify-batches.py --timeout 180
  ./verify-batches.py -I                 # interactive — choose scenarios + options
"""

import contextlib
import importlib.util
import io
import sys
import time
import argparse
import requests
import urllib3
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# ---------------------------------------------------------------------------
# Load shared utilities
# ---------------------------------------------------------------------------
_SCRIPT_DIR = Path(__file__).parent

def _load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod

_utils = _load_module("batch_utils", _SCRIPT_DIR / "batch_utils.py")
_submit = _load_module("submit_batch", _SCRIPT_DIR / "submit-batch.py")

load_config           = _utils.load_config
get_gazelle_domain    = _utils.get_gazelle_domain
FALLBACK_TENANTS      = _utils.FALLBACK_TENANTS
check_data_loaded     = _utils.check_data_loaded
count_zeebe_incidents = _utils.count_zeebe_incidents
get_k8s_error_pods    = _utils.get_k8s_error_pods
run_submit            = _submit.run_submit
DEFAULT_SECRET_KEY    = _submit.DEFAULT_SECRET_KEY

# ---------------------------------------------------------------------------
# Paths / constants
# ---------------------------------------------------------------------------
DEFAULT_CFG    = Path(__file__).parent.parent.parent.parent / "config" / "config.ini"
MOJALOOP_CSV   = _SCRIPT_DIR / "bulk-gazelle-mojaloop-4.csv"
CLOSEDLOOP_CSV = _SCRIPT_DIR / "bulk-gazelle-closedloop-4.csv"

SCENARIOS = [
    {
        "name":          "Mojaloop / Non-GovStack",
        "csv":           MOJALOOP_CSV,
        "tenant":        "greenbank",
        "govstack":      False,
        "stall_timeout": 180,   # mojaloop through vNext switch takes longer
    },
    {
        "name":     "Closedloop / Non-GovStack",
        "csv":      CLOSEDLOOP_CSV,
        "tenant":   "redbank",
        "govstack": False,
    },
    {
        "name":          "Mojaloop / GovStack",
        "csv":           MOJALOOP_CSV,
        "tenant":        "greenbank",
        "govstack":      True,
        "stall_timeout": 180,
    },
    {
        "name":     "Closedloop / GovStack",
        "csv":      CLOSEDLOOP_CSV,
        "tenant":   "redbank",
        "govstack": True,
    },
]

# ---------------------------------------------------------------------------
# ANSI colours
# ---------------------------------------------------------------------------
GREEN  = "\033[92m"
RED    = "\033[91m"
YELLOW = "\033[93m"
CYAN   = "\033[96m"
BOLD   = "\033[1m"
RESET  = "\033[0m"

def ok(msg):   return f"{GREEN}✓ {msg}{RESET}"
def fail(msg): return f"{RED}✗ {msg}{RESET}"
def warn(msg): return f"{YELLOW}⚠ {msg}{RESET}"
def info(msg): return f"{CYAN}{msg}{RESET}"
def bold(msg): return f"{BOLD}{msg}{RESET}"


# ---------------------------------------------------------------------------
# Batch submission — calls submit-batch.py directly (no subprocess)
# ---------------------------------------------------------------------------

def submit_scenario(scenario, config_path):
    """
    Run the submission pipeline for a scenario.
    Returns (batch_id: str|None, success: bool).
    """
    # Suppress the verbose per-step output from run_submit
    buf = io.StringIO()
    with contextlib.redirect_stderr(buf):
        response = run_submit(
            csv_file=scenario["csv"],
            config_path=config_path,
            tenant=scenario["tenant"],
            govstack=scenario["govstack"],
            registering_institution=None,
            program=None,
            secret_key=DEFAULT_SECRET_KEY,
            debug=False,
            show_curl=False,
        )

    if response is None:
        return None, False

    # Extract batch_id from PollingPath
    polling_path = response.get("PollingPath", "")
    if polling_path:
        # "/batch/Summary/<uuid>"
        parts = polling_path.rstrip("/").split("/")
        batch_id = parts[-1] if parts else None
        return batch_id, True

    return None, True  # submitted ok but no batch_id


# ---------------------------------------------------------------------------
# Operations-app API helpers
# ---------------------------------------------------------------------------

def _ops_get(url, tenant, timeout=15):
    """GET from ops API with Platform-TenantId header. Returns parsed JSON or None."""
    try:
        resp = requests.get(
            url,
            headers={"Platform-TenantId": tenant},
            verify=False,
            timeout=timeout,
        )
        if resp.status_code == 200:
            return resp.json()
        return None
    except Exception:
        return None


def fetch_batch_summary(domain, batch_id, tenant):
    url = f"https://ops.{domain}/api/v1/batch/{batch_id}?command=aggregate"
    return _ops_get(url, tenant)


def fetch_batch_transfers(domain, batch_id, tenant, page_size=20):
    url = f"https://ops.{domain}/api/v1/batch/detail?batchId={batch_id}&pageSize={page_size}"
    data = _ops_get(url, tenant)
    if data and "content" in data:
        return data["content"]
    return []


# ---------------------------------------------------------------------------
# Polling
# ---------------------------------------------------------------------------

def wait_for_batch(domain, batch_id, tenant, timeout=600, poll_interval=5, stall_timeout=120,
                   on_progress=None):
    """
    Poll until ongoing==0, hard timeout, or stall with cluster errors.
    on_progress(successful, total) called each poll when summary is available.
    On stall: checks Zeebe incidents + K8s pod errors; resets timer if healthy.
    """
    hard_deadline    = time.time() + timeout
    batch_start      = time.time()
    last_successful  = -1
    last_progress_at = time.time()
    last             = None

    while True:
        now     = time.time()
        elapsed = int(now - batch_start)
        summary = fetch_batch_summary(domain, batch_id, tenant)

        if summary is not None:
            last       = summary
            total      = summary.get("total",      0)
            ongoing    = summary.get("ongoing",    -1)
            successful = summary.get("successful", 0)

            if on_progress:
                on_progress(successful, total)

            if total > 0 and ongoing == 0:
                return last

            if successful > last_successful:
                last_progress_at = now
                last_successful  = successful

        timed_out = now >= hard_deadline
        stalled   = (now - last_progress_at) > stall_timeout

        if timed_out:
            break

        if stalled:
            incidents  = count_zeebe_incidents(domain)
            error_pods = get_k8s_error_pods()

            zeebe_ok = incidents is not None and incidents == 0
            k8s_ok   = error_pods is not None and len(error_pods) == 0

            if not zeebe_ok or not k8s_ok:
                print(warn(f"    stopped: stalled after {elapsed}s with errors detected"))
                if incidents and incidents > 0:
                    print(warn(f"    Zeebe: {incidents} active incident(s)"))
                if error_pods:
                    for p in error_pods:
                        print(warn(f"    Pod error: {p}"))
                break

            # System is healthy — reset stall timer and keep waiting silently
            last_progress_at = now

        time.sleep(poll_interval)

    final = fetch_batch_summary(domain, batch_id, tenant)
    return final if final is not None else last


# ---------------------------------------------------------------------------
# Display helpers
# ---------------------------------------------------------------------------

def print_sep(char="─", width=72):
    print(char * width)


def print_scenario_header(idx, scenario):
    print()
    print(bold(f"[{idx}] {scenario['name']}  (tenant: {scenario['tenant']})"))


def print_batch_result(summary, elapsed):
    if summary is None:
        print(warn("  Could not retrieve batch summary from operations-app"))
        return

    total      = summary.get("total",      0)
    successful = summary.get("successful", 0)
    failed     = summary.get("failed",     0)
    ongoing    = summary.get("ongoing",    0)
    status     = summary.get("status",     "?")
    pct_ok     = summary.get("successPercentage", "?")
    payer_fsp  = summary.get("payerFsp", "?")
    reg_inst   = summary.get("registeringInstitutionId", "?")

    print(f"  Status           : {status}")
    print(f"  Total            : {total}")
    print(f"  Successful       : {successful}  ({pct_ok}%)")
    print(f"  Failed           : {failed}")
    print(f"  Ongoing          : {ongoing}")
    print(f"  Payer FSP        : {payer_fsp}")
    if reg_inst and reg_inst != "null":
        print(f"  Registering Inst : {reg_inst}")
    print(f"  Elapsed          : {elapsed:.1f}s")

    all_done = (ongoing == 0)
    if all_done and successful == total and failed == 0 and total > 0:
        print(ok(f"  ALL {total} transactions PASSED"))
    elif all_done and failed > 0:
        print(fail(f"  {failed}/{total} transactions FAILED"))
    elif all_done and total == 0:
        print(warn("  Batch total=0 — transfers may not have started yet (try --timeout 240)"))
        print(warn("  For GovStack: run generate-mifos-vnext-data.py --regenerate if identity mapper is empty"))
    elif not all_done:
        print(warn(f"  {ongoing} transaction(s) still IN_PROGRESS after {elapsed:.0f}s"))
        print(warn(f"  Increase --stall-timeout if Zeebe workflows are still running"))
    else:
        print(warn(f"  Unexpected state: status={status}"))


def print_transfers(transfers):
    if not transfers:
        return
    print(f"\n  {'Payee MSISDN':<16} {'Payee FSP':<14} {'Status':<14} {'Amount':>8}  Error")
    print(f"  {'─'*14:<16} {'─'*12:<14} {'─'*12:<14} {'─'*8:>8}  {'─'*20}")
    for t in transfers:
        payee   = t.get("payeePartyId")  or "?"
        dfsp    = t.get("payeeDfspId")   or "?"
        status  = t.get("status")        or "?"
        amount  = t.get("amount")        or "?"
        err     = t.get("errorInformation") or ""
        err_str = str(err)[:30] if err else ""
        line    = f"  {str(payee):<16} {str(dfsp):<14} {str(status):<14} {str(amount):>8}  {err_str}"
        if status == "COMPLETED":
            print(f"{GREEN}{line}{RESET}")
        elif status == "FAILED":
            print(f"{RED}{line}{RESET}")
        else:
            print(line)


# ---------------------------------------------------------------------------
# Interactive mode
# ---------------------------------------------------------------------------

def _prompt(msg, default=None):
    suffix = f" [{default}]" if default is not None else ""
    print(f"{msg}{suffix}: ", end='', flush=True)
    try:
        val = input().strip()
    except EOFError:
        val = ''
    return val if val else (str(default) if default is not None else '')


def _prompt_yn(msg, default=False):
    hint = "[Y/n]" if default else "[y/N]"
    print(f"{msg} {hint}: ", end='', flush=True)
    try:
        val = input().strip().lower()
    except EOFError:
        val = ''
    if val in ('y', 'yes'):
        return True
    if val in ('n', 'no'):
        return False
    return default


def interactive_mode(args):
    """Fill in any missing args interactively."""
    print("\n" + "="*60)
    print("  BULK BATCH VERIFICATION")
    print("="*60)

    # 1. Config file
    cfg_str = _prompt("Config file", default=str(args.config))
    args.config = Path(cfg_str).expanduser()

    # 2. Scenarios
    print("\nScenarios (enter numbers separated by commas, or Enter for all):")
    for i, s in enumerate(SCENARIOS, 1):
        print(f"  {i}. {s['name']}  [{s['tenant']}]")
    print("Choice [all]: ", end='', flush=True)
    try:
        raw = input().strip().lower()
    except EOFError:
        raw = ''

    if raw and raw != 'a':
        selected = []
        for part in raw.split(','):
            part = part.strip()
            if part.isdigit() and 1 <= int(part) <= len(SCENARIOS):
                selected.append(SCENARIOS[int(part) - 1])
        args.scenarios = selected if selected else SCENARIOS
    else:
        args.scenarios = SCENARIOS

    # 3. Confirm
    scenario_names = ', '.join(s['name'] for s in args.scenarios)
    print(f"\n  Config    : {args.config}")
    print(f"  Scenarios : {scenario_names}")
    print()
    if not _prompt_yn("Run?", default=True):
        print("Aborted.")
        sys.exit(0)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Submit and verify bulk batch scenarios",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Scenarios (default: all 4):
  1. Mojaloop  / Non-GovStack  --tenant greenbank
  2. Closedloop / Non-GovStack  --tenant redbank
  3. Mojaloop  / GovStack       --tenant greenbank --govstack
  4. Closedloop / GovStack       --tenant redbank   --govstack

Prerequisites for GovStack scenarios:
  identity-account-mapper must be populated — run:
    generate-mifos-vnext-data.py --regenerate
        """,
    )
    parser.add_argument("-c", "--config", type=lambda p: Path(p).expanduser(), default=DEFAULT_CFG,
                        help=f"Path to config.ini (default: {DEFAULT_CFG})")
    parser.add_argument("--timeout", type=int, default=600,
                        help="Hard max seconds to wait per batch (default: 600)")
    parser.add_argument("--stall-timeout", type=int, default=120,
                        help="Base stall timeout in seconds; mojaloop scenarios use 180s (default: 120)")
    parser.add_argument("--poll-interval", type=int, default=5,
                        help="Polling interval in seconds (default: 5)")
    parser.add_argument("--no-transfers", action="store_true",
                        help="Skip per-transfer detail output")
    parser.add_argument("--interactive", "-I", action="store_true",
                        help="Interactive mode — choose scenarios and options via prompts")
    args = parser.parse_args()

    # Default scenarios (can be overridden by interactive mode)
    args.scenarios = SCENARIOS

    # Auto-trigger interactive when stdin is a TTY (no explicit args given) or -I passed
    if args.interactive or sys.stdin.isatty():
        interactive_mode(args)

    if not args.config.exists():
        print(fail(f"Config file not found: {args.config}"))
        sys.exit(1)

    for csv_path in (MOJALOOP_CSV, CLOSEDLOOP_CSV):
        if not csv_path.exists():
            print(fail(f"CSV not found: {csv_path}"))
            print("  Run generate-example-csv-files.py first.")
            sys.exit(1)

    cfg    = load_config(args.config)
    domain = get_gazelle_domain(cfg)

    data_ok, data_issues, data_hint = check_data_loaded(domain, config_path=args.config)
    if not data_ok:
        print(fail(f"\nError: MifosX data is not loaded:"))
        for issue in data_issues:
            print(f"  • {issue}")
        print(data_hint)
        sys.exit(1)

    print(bold(f"\nBULK BATCH VERIFICATION — {domain}"))
    print(f"Config: {args.config}  |  {len(args.scenarios)} scenario(s)\n")

    submissions = []

    for idx, scenario in enumerate(args.scenarios, start=1):
        print_scenario_header(idx, scenario)
        print(f"  Submitting…", end="", flush=True)
        t0 = time.time()

        try:
            batch_id, ok_flag = submit_scenario(scenario, args.config)
        except Exception as e:
            print(f"\r  {fail(f'Error: {e}')}")
            submissions.append({"scenario": scenario, "batch_id": None, "submitted": False})
            continue

        elapsed = time.time() - t0

        if ok_flag and batch_id:
            print(f"\r  {ok(f'Submitted ({elapsed:.1f}s)  batch_id: {batch_id}')}")
        elif ok_flag:
            print(f"\r  {warn('HTTP 2xx but no batch_id in response')}")
        else:
            print(f"\r  {fail('Submission FAILED')}")

        submissions.append({
            "scenario": scenario,
            "batch_id": batch_id,
            "submitted": ok_flag and batch_id is not None,
        })

    pending = [s for s in submissions if s["submitted"]]
    skipped = [s for s in submissions if not s["submitted"]]

    print(bold(f"\nWaiting for {len(pending)} batch(es)…\n"))
    for sub in skipped:
        print(warn(f"  {sub['scenario']['name']}: skipped (not submitted)"))

    # Poll all submitted batches in parallel; print a line as each completes.
    import threading
    result_map  = {}                         # batch_id → {summary, elapsed}
    _print_lock = threading.Lock()
    _progress   = {}                         # batch_id → (name, successful, total, elapsed)
    _stop_prog  = threading.Event()

    def _print_result(msg):
        """Clear the progress line then print a completion line."""
        with _print_lock:
            print(f"\r\033[2K{msg}", flush=True)

    _wall_start = time.time()

    def _progress_thread():
        """Background thread: redraws the in-flight status line every 2s."""
        while not _stop_prog.wait(timeout=2):
            in_flight = list(_progress.values())
            if in_flight:
                wall = int(time.time() - _wall_start)
                parts = []
                for name, succ, total, _ in in_flight:
                    parts.append(f"{name}: {succ}/{total}" if total else f"{name}: waiting")
                line = f"  … [{wall}s/{args.timeout}s] " + "  |  ".join(parts)
                with _print_lock:
                    print(f"\r{line}\033[K", end="", flush=True)

    def _poll(sub):
        t0     = time.time()
        name   = sub["scenario"]["name"]
        bid    = sub["batch_id"]
        tenant = sub["scenario"]["tenant"]
        stall  = sub["scenario"].get("stall_timeout", args.stall_timeout)

        _progress[bid] = (name, 0, None, 0)   # visible immediately, total=None until first poll

        def _on_progress(successful, total):
            if total > 0:
                _progress[bid] = (name, successful, total, int(time.time() - t0))

        summary = wait_for_batch(
            domain, bid, tenant,
            timeout=args.timeout, poll_interval=args.poll_interval,
            stall_timeout=stall, on_progress=_on_progress,
        )
        return sub, summary, time.time() - t0

    prog_t = threading.Thread(target=_progress_thread, daemon=True)
    prog_t.start()

    with ThreadPoolExecutor(max_workers=max(len(pending), 1)) as ex:
        futures = {ex.submit(_poll, sub): sub for sub in pending}
        for future in as_completed(futures):
            try:
                sub, summary, elapsed = future.result()
            except Exception as e:
                sub      = futures[future]
                name     = sub["scenario"]["name"]
                batch_id = sub["batch_id"]
                _progress.pop(batch_id, None)
                _print_result(f"  {RED}✗{RESET} {name:<38} ERROR: {e}")
                result_map[batch_id] = {"summary": None, "elapsed": 0}
                continue

            name     = sub["scenario"]["name"]
            batch_id = sub["batch_id"]
            s        = summary or {}
            total    = s.get("total",      0)
            succ     = s.get("successful", 0)
            status   = s.get("status",     "?")
            marker   = f"{GREEN}✓{RESET}" if succ == total and total > 0 else f"{RED}✗{RESET}"
            _progress.pop(batch_id, None)
            _print_result(f"  {marker} {name:<38} {succ}/{total} ok  ({elapsed:.0f}s)  [{status}]")
            result_map[batch_id] = {"summary": summary, "elapsed": elapsed}

    _stop_prog.set()
    prog_t.join()
    with _print_lock:
        print("\r\033[2K", end="", flush=True)   # clear any leftover progress line

    # Print full details in original submission order.
    results = []
    print()
    for sub in submissions:
        scenario = sub["scenario"]
        batch_id = sub["batch_id"]

        if not sub["submitted"]:
            results.append({
                "name": scenario["name"], "submitted": False,
                "batch_id": None, "summary": None, "elapsed": 0,
            })
            continue

        r       = result_map.get(batch_id, {})
        summary = r.get("summary")
        elapsed = r.get("elapsed", 0)

        print(f"\n  {bold(scenario['name'])}  [{batch_id}]")
        print_batch_result(summary, elapsed)

        if not args.no_transfers:
            transfers = fetch_batch_transfers(domain, batch_id, scenario["tenant"])
            print_transfers(transfers)

        results.append({
            "name": scenario["name"],
            "submitted": True,
            "batch_id": batch_id,
            "summary": summary,
            "elapsed": elapsed,
        })

    print(bold("\nSUMMARY"))
    print(f"  {'Scenario':<35} {'Total':>5} {'OK':>5} {'Fail':>5}  Result")
    print(f"  {'─'*33:<35} {'─'*5:>5} {'─'*5:>5} {'─'*5:>5}  {'─'*6}")

    all_passed = True
    for r in results:
        s = r["summary"]

        if not r["submitted"] or s is None:
            verdict    = fail("NO DATA")
            all_passed = False
            total_s = ok_s = fail_s = "—"
        else:
            total_s = str(s.get("total",      0))
            ok_s    = str(s.get("successful", 0))
            fail_s  = str(s.get("failed",     0))
            total   = s.get("total",      0)
            succ    = s.get("successful", 0)
            failed  = s.get("failed",     0)
            ongoing = s.get("ongoing",    0)
            passed  = (succ == total and failed == 0 and total > 0 and ongoing == 0)
            verdict = ok("PASS") if passed else fail("FAIL")
            if not passed:
                all_passed = False

        print(f"  {r['name']:<35} {total_s:>5} {ok_s:>5} {fail_s:>5}  {verdict}")

    print()
    if all_passed:
        print(ok(bold("  ALL SCENARIOS PASSED")))
    else:
        print(fail(bold("  ONE OR MORE SCENARIOS FAILED — see details above")))
    print()


if __name__ == "__main__":
    main()
