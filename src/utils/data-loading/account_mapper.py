"""Reach paymenthub-ee-account-mapper from outside the cluster.

account-mapper has no authentication, so Gazelle doesn't publish it on an
ingress (GAZ-366). The data-loading scripts reach it through a
`kubectl port-forward` instead, started on first use and stopped on exit.
"""
import atexit
import re
import subprocess
import threading

SERVICE = "paymenthub-ee-account-mapper"
SERVICE_PORT = 80

_url = None


def account_mapper_url(namespace="paymenthub"):
    """Base URL of account-mapper, e.g. http://127.0.0.1:43127."""
    global _url
    if _url:
        return _url
    proc = subprocess.Popen(
        ["kubectl", "port-forward", "-n", namespace, f"svc/{SERVICE}", f":{SERVICE_PORT}"],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    )
    # kubectl prints "Forwarding from 127.0.0.1:<port> -> 8080" once it listens,
    # or exits with the reason on stderr
    line = proc.stdout.readline()
    match = re.search(r"127\.0\.0\.1:(\d+)", line)
    if not match:
        proc.kill()
        raise RuntimeError(f"kubectl port-forward to {namespace}/{SERVICE} failed: {proc.stderr.read().strip() or line}")
    # it then logs every connection; keep reading so a full pipe never blocks it
    for stream in (proc.stdout, proc.stderr):
        threading.Thread(target=stream.read, daemon=True).start()
    atexit.register(_stop, proc)
    _url = f"http://127.0.0.1:{match.group(1)}"
    return _url


def _stop(proc):
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
