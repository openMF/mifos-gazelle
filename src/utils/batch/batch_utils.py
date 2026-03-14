#!/usr/bin/env python3
"""
batch_utils.py — shared utilities for submit-batch.py and verify-batches.py
"""

import base64
import configparser
import csv as csv_module
import subprocess
import sys
from pathlib import Path

try:
    import requests
    requests.packages.urllib3.disable_warnings(
        requests.packages.urllib3.exceptions.InsecureRequestWarning
    )
    _REQUESTS_AVAILABLE = True
except ImportError:
    _REQUESTS_AVAILABLE = False


# ---------------------------------------------------------------------------
# Config helpers
# ---------------------------------------------------------------------------

def load_config(config_file):
    """Load configuration from config.ini. Exits on failure."""
    cfg = configparser.ConfigParser()
    if not cfg.read(config_file):
        print(f"Cannot read config {config_file}", file=sys.stderr)
        sys.exit(1)
    return cfg


def get_gazelle_domain(cfg):
    """Extract GAZELLE_DOMAIN from a loaded ConfigParser. Exits on failure."""
    try:
        return cfg.get('general', 'GAZELLE_DOMAIN')
    except (configparser.NoSectionError, configparser.NoOptionError) as e:
        print(f"Config error: {e}", file=sys.stderr)
        sys.exit(1)


# ---------------------------------------------------------------------------
# Tenant helpers
# ---------------------------------------------------------------------------

FALLBACK_TENANTS = ['greenbank', 'redbank', 'bluebank']


def get_valid_tenants(namespace='paymenthub', pod='operationsmysql-0'):
    """
    Query operationsmysql for tenant names from tenant_server_connections.

    Returns list of tenant name strings, or None if query fails.
    """
    try:
        password_cmd = [
            'kubectl', 'get', 'secret', '-n', namespace, 'operationsmysql',
            '-o', 'jsonpath={.data.mysql-root-password}',
        ]
        pw_result = subprocess.run(
            password_cmd, capture_output=True, text=False, timeout=10
        )
        if pw_result.returncode != 0:
            return None

        password = base64.b64decode(pw_result.stdout).decode('utf-8').strip()

        query_cmd = [
            'kubectl', 'exec', '-n', namespace, pod, '--',
            'mysql', '-uroot', f'-p{password}', 'tenants',
            '-e', 'SELECT schema_name FROM tenant_server_connections',
            '--batch', '--skip-column-names',
        ]
        result = subprocess.run(query_cmd, capture_output=True, text=True, timeout=10)
        if result.returncode != 0:
            return None

        tenants = [
            line.strip()
            for line in result.stdout.split('\n')
            if line.strip() and not line.startswith('mysql:')
        ]
        return tenants or None

    except subprocess.TimeoutExpired:
        return None
    except FileNotFoundError:
        return None
    except Exception:
        return None


# ---------------------------------------------------------------------------
# CSV helpers
# ---------------------------------------------------------------------------

def get_payment_modes_from_csv(csv_file_path):
    """Return set of unique (uppercased) payment_mode values from CSV."""
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
    """Return list of payee_identifier values from CSV."""
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


# ---------------------------------------------------------------------------
# Identity mapper helpers
# ---------------------------------------------------------------------------

def detect_registering_institution(payee_identifiers, debug=False):
    """
    Query identity_details to find which registering_institution_id(s) the
    payee MSISDNs belong to.

    Returns:
        (best_institution: str|None, counts: dict)
    """
    if not payee_identifiers:
        return None, {}

    if debug:
        print(
            f"\nAuto-detecting registering institution from "
            f"{len(payee_identifiers)} payee identifiers...",
            file=sys.stderr,
        )

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
            '--batch', '--skip-column-names',
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
        if debug:
            print("Warning: institution detection query timed out", file=sys.stderr)
        return None, {}
    except FileNotFoundError:
        return None, {}
    except Exception as e:
        if debug:
            print(f"Warning: institution detection failed: {e}", file=sys.stderr)
        return None, {}


# ---------------------------------------------------------------------------
# Data-loaded pre-flight check
# ---------------------------------------------------------------------------

def check_data_loaded(domain, config_path=None, debug=False):
    """
    Verify that generate-mifos-vnext-data.py has been run by checking that
    Fineract has at least one client in each tenant (greenbank, redbank, bluebank).

    Returns:
        (ok: bool, issues: list[str], retry_hint: str)

    Callers should exit on failure — no point submitting batches without data.
    """
    if not _REQUESTS_AVAILABLE:
        return True, [], ""

    tenants = ['greenbank', 'redbank', 'bluebank']
    auth = "Basic bWlmb3M6cGFzc3dvcmQ="   # mifos:password
    base_url = f"https://mifos.{domain}/fineract-provider/api/v1"

    hint = f"  Fix: sudo ./run.sh -a setup-data"
    if config_path:
        hint += f" -f {config_path}"

    issues = []
    for tenant in tenants:
        try:
            resp = requests.get(
                f"{base_url}/clients",
                headers={"Authorization": auth, "Fineract-Platform-TenantId": tenant},
                verify=False, timeout=10,
            )
            if resp.status_code == 200:
                total = resp.json().get("totalFilteredRecords", 0)
                if total == 0:
                    issues.append(f"tenant '{tenant}': Fineract has no clients")
                elif debug:
                    print(f"✓ Data check: tenant '{tenant}' has {total} client(s)", file=sys.stderr)
            else:
                issues.append(f"tenant '{tenant}': Fineract returned HTTP {resp.status_code}")
        except Exception as e:
            issues.append(f"tenant '{tenant}': could not reach Fineract ({type(e).__name__})")

    return (len(issues) == 0), issues, hint


# ---------------------------------------------------------------------------
# Cluster health checks (used by verify-batches.py to decide whether to
# keep waiting for in-progress mojaloop batches)
# ---------------------------------------------------------------------------

def count_zeebe_incidents(domain):
    """
    Count unresolved Zeebe incidents via Elasticsearch.
    Returns int (may be 0) or None if the check could not run.
    """
    if not _REQUESTS_AVAILABLE:
        return None
    try:
        resp = requests.post(
            f"http://elasticsearch.{domain}/zeebe-record_incident_*/_search",
            json={"size": 0, "query": {"term": {"value.state": "CREATED"}}},
            timeout=10,
        )
        if resp.status_code == 200:
            return resp.json().get("hits", {}).get("total", {}).get("value", 0)
        return None
    except Exception:
        return None


def get_k8s_error_pods(namespace="paymenthub"):
    """
    Return list of strings describing pods in error state in the given namespace.
    Returns a list (possibly empty), or None if the check could not run.
    Error states checked: CrashLoopBackOff, Error, OOMKilled, ImagePullBackOff, ErrImagePull.
    """
    error_states = {"Error", "CrashLoopBackOff", "OOMKilled", "ImagePullBackOff", "ErrImagePull"}
    try:
        result = subprocess.run(
            ["kubectl", "get", "pods", "-n", namespace, "--no-headers"],
            capture_output=True, text=True, timeout=10,
        )
        if result.returncode != 0:
            return None
        error_pods = []
        for line in result.stdout.split("\n"):
            parts = line.split()
            if len(parts) >= 3 and parts[2] in error_states:
                error_pods.append(f"{parts[0]} ({parts[2]})")
        return error_pods
    except Exception:
        return None


def check_identity_mapper(registering_institution, debug=False):
    """
    Return count of beneficiary entries for institution in identity_account_mapper,
    or None if the check could not run.
    """
    if debug:
        print(
            f"\nPre-flight: checking identity mapper for '{registering_institution}'...",
            file=sys.stderr,
        )

    try:
        query_cmd = [
            'kubectl', 'exec', '-n', 'infra', 'mysql-0', '--',
            'mysql', '-umifos', '-ppassword', 'identity_account_mapper',
            '-e', (
                f"SELECT COUNT(*) FROM identity_details "
                f"WHERE registering_institution_id = '{registering_institution}'"
            ),
            '--batch', '--skip-column-names',
        ]
        result = subprocess.run(query_cmd, capture_output=True, text=True, timeout=10)

        if result.returncode != 0:
            return None

        lines = [l for l in result.stdout.split('\n')
                 if l.strip() and not l.startswith('mysql:')]
        return int(lines[0].strip()) if lines else None

    except subprocess.TimeoutExpired:
        return None
    except FileNotFoundError:
        return None
    except Exception:
        return None
