# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

Mifos Gazelle is a Kubernetes deployment orchestration tool (v2.0.0) that deploys three Digital Public Goods (DPGs) with a single command:
- **MifosX** — core banking (Apache Fineract v1.12.0)
- **Payment Hub EE (PHEE)** — payment orchestration
- **Mojaloop vNext Beta1** — payment switch

Written primarily in Bash (requires bash 4+) with Python 3 utilities for data loading and batch operations.

## Key Commands

### First time / new machine
```bash
# Linux or macOS — OS is auto-detected (k3s on Linux, Colima on macOS)
sudo ./setup-env.sh -u $USER

# Remote / pre-existing cluster (/etc/hosts only)
sudo ./setup-env.sh -e remote -u $USER
```

### Deploy (no sudo required after setup)
```bash
./run.sh -m deploy -a all           # full deployment
./run.sh -m deploy -a mifosx        # single component
./run.sh -m deploy -a paymenthub
./run.sh -m deploy -a vnext
./run.sh -m deploy -a all -d true   # with debug output
# Increase startup_timeout in config/config.ini to adjust pod wait timeout
```

### Teardown
```bash
./run.sh -m cleanapps -a all                # remove apps only (no sudo)
sudo ./setup-env.sh -m cleanall             # full teardown (k3s or Colima)
```

### Utility Scripts
```bash
# Payments
src/utils/make-payment.sh                   # test payment
src/utils/batch/test-curl-batch.sh          # batch payment API test
src/utils/batch/test-mastercard-e2e.sh      # Mastercard CBS end-to-end

# Kubernetes
src/utils/get-kube-logs.sh                  # retrieve cluster logs
src/utils/apply-crs.sh                      # reapply modified Custom Resources

# Data loading (activate .venv first: source .venv/bin/activate)
python src/utils/data-loading/generate-mifos-vnext-data.py
python src/utils/batch/submit-batch.py
python src/utils/batch/verify-batches.py
python src/utils/batch/list-tenants.py

# Kibana
src/utils/kibana-dashboard-setup.sh
```

### Local Development
```bash
# Patches Helm Deployment.yaml files for local dev (no live cluster needed)
python src/utils/localdev/localdev.py
```

### Logging
Set `logging = true` in `config/config.ini` to write a full run log to `/tmp/gazelle-YYYYMMDD-HHMM.log`.

## Architecture

### Script Execution Flow
```
setup-env.sh  →  src/commandline/commandline.sh  →  src/environmentSetup/environmentSetup.sh
                                                 (sudo required; handles OS, k3s, /etc/hosts)

run.sh        →  src/commandline/commandline.sh  →  src/deployer/deployer.sh
                                                 (no sudo; handles helm/kubectl cluster ops)
```

Two entry points own different concerns:
- `setup-env.sh` — privileged; runs once per machine to install OS prereqs, k3s, Colima, /etc/hosts, tools. Modes: `setup` (default), `cleanall`.
- `run.sh` — unprivileged; orchestrates all cluster operations (helm/kubectl). Modes: `deploy`, `cleanapps`.

Both source `commandline.sh` which sources all other modules and parses CLI flags + `config/config.ini`. On macOS, both re-exec themselves with Homebrew bash 4+ if the system bash is 3.2.

### Key Source Files

| File | Role |
|------|------|
| `setup-env.sh` | Entry point for privileged env setup/teardown (k3s, OS packages, /etc/hosts) |
| `run.sh` | Entry point for cluster operations — no sudo required |
| `src/commandline/commandline.sh` | CLI parsing, config loading (`crudini`), top-level dispatch |
| `src/deployer/deployer.sh` | Orchestrates component deployments in dependency order |
| `src/deployer/core.sh` | Shared K8s functions: pod readiness waits, TLS secrets, Helm deploy wrappers |
| `src/deployer/mifosx.sh` | MifosX/Fineract deployment logic |
| `src/deployer/paymenthub.sh` | PaymentHub EE deployment logic |
| `src/deployer/vnext.sh` | Mojaloop vNext deployment logic |
| `src/deployer/mastercard.sh` | Mastercard CBS connector deployment (uses K8s operator) |
| `src/deployer/cross-border-mifos.sh` | GovStack cross-border payment web app deployment |
| `src/environmentSetup/environmentSetup.sh` | OS prereqs, k3s setup, `/etc/hosts`, Python venv; `env_cleanall_main()` for teardown |
| `src/environmentSetup/k8s.sh` | K3s status checks and K8s-specific env setup |
| `src/environmentSetup/mac_setup.sh` | macOS/Colima-specific setup (Homebrew, Colima kubeconfig) |
| `src/environmentSetup/helpers.sh` | Helper functions for environment setup |
| `src/utils/logger.sh` | Logging framework (INFO/WARNING/ERROR levels) |
| `src/utils/helpers.sh` | Common helper functions shared across deployer modules |

### Configuration

All deployment settings live in `config/config.ini` (INI format, parsed with `crudini`). Sections:
- `[general]` — mode, domain, version, startup timeout, logging
- `[kubernetes]` — environment type (`local`/`remote`), k3s version, resource minimums
- `[dockerhub]` — optional credentials to raise Docker Hub pull rate limits
- `[infra]` / `[mifosx]` / `[vnext]` / `[paymenthub]` / `[mastercard-demo]` — per-component `enabled` flag, namespace, repo, branch

Config values are loaded into shell variables via `crudini --get`. CLI flags override config file values. `$USER` in the config is expanded to the invoking (non-root) user at runtime.

### Kubernetes Targets

- **`local`** — auto-detected: k3s on Linux, Colima on macOS
- **`remote`** — pre-existing cluster via kubeconfig

### Deployment Dependencies

Infrastructure (NGINX, MySQL, Kafka, Redis, MongoDB, Elasticsearch) must be up before any DPG. Deployment order: `infra` → `mifosx` / `paymenthub` / `vnext` (these three are independent of each other).

### Vendored Manifests

All Kubernetes manifests are vendored directly into the repo — no external clones or submodules are needed:
- `src/deployer/manifests/mifosx/` — MifosX K8s manifests
- `src/deployer/manifests/vnext/` — Mojaloop vNext manifests

At deploy time, `mifosx.sh` and `vnext.sh` copy these into `/tmp/gazelle-deploy/` (`$DEPLOY_WORK_DIR`) and perform domain substitution on the copies, leaving the committed sources untouched.

### Helm Charts

- `src/deployer/helm/infra/` — Infrastructure umbrella chart (Kafka, Elasticsearch, Redis, MongoDB, MySQL, NGINX)
- `src/deployer/helm/paymenthub-infra/` — PaymentHub EE infrastructure chart

### Kubernetes Operators

Operator CRs and configs live in `src/deployer/operators/`. The Mastercard CBS connector deployment (`mastercard.sh`) uses a K8s operator rather than raw manifests. `src/utils/apply-crs.sh` re-applies modified CRs without a full redeploy.

### Python Virtualenv

`.venv/` is the project-local Python environment. Dependencies are minimal (`requests`). Scripts in `src/utils/data-loading/` and `src/utils/batch/` use it. Always activate before running Python scripts.

### Other Top-Level Directories

- `orchestration/` — feel/readme: workflow orchestration notes
- `performance-testing/` — JMeter test plan (`paymentHubEE.jmx`) and Mastercard perf tests
- `postman/` — Postman collections for API testing
- `docs/` — project documentation

## macOS-Specific Notes

- `run.sh` auto-installs Homebrew bash 4+ if needed (system `/bin/bash` is 3.2)
- `sudo` strips PATH on macOS; `run.sh` prepends `/opt/homebrew/bin:/usr/local/bin` after re-exec
- `crudini` is installed via `pipx` on macOS (Homebrew Python blocks plain `pip install`)
- Colima + docker + docker-compose are installed automatically via Homebrew on first run; Homebrew itself is also auto-installed if absent
- The Colima k3s VM uses the `eth0` interface IP for `/etc/hosts` entries (not `127.0.0.1`) because klipper-lb uses iptables DNAT which bypasses Lima's port-forwarding
- Third-party browsers (Firefox, Opera, Chrome) require **Local Network** permission to reach the Colima VM IP (`192.168.68.x`): System Settings → Privacy & Security → Local Network → enable the browser. Safari works without this.
- Browsers require a one-time cert acceptance: visit `https://mifos.mifos.gazelle.test` first and click through the self-signed cert warning. The NGINX ingress uses a default self-signed cert with no trusted CA (automating cert generation + macOS keychain trust is a known gap).

## CI/CD

CircleCI (`.circleci/config.yml`) runs the two-step workflow on both amd64 and arm64 instances:
1. `sudo ./setup-env.sh -e local -u "$USER" -d true` — installs k3s and OS prereqs
2. `./run.sh -m deploy -a all -d true` — deploys all components without sudo

After deployment, CI verifies pod readiness and health-check endpoints for all three DPGs.
