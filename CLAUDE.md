# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

Mifos Gazelle is a Kubernetes deployment orchestration tool (v2.0.0) that deploys three Digital Public Goods (DPGs) with a single command:
- **MifosX** — core banking (Apache Fineract v1.12.0)
- **Payment Hub EE (PHEE)** — payment orchestration
- **Mojaloop vNext Beta1** — payment switch

The tool is written primarily in Bash (requires bash 4+) with Python 3 utilities for data loading and batch operations.

## Key Commands

### Deploy
```bash
# Full deployment
sudo ./run.sh -u $USER -m deploy -a all

# Deploy specific component(s)
sudo ./run.sh -u $USER -m deploy -a mifosx
sudo ./run.sh -u $USER -m deploy -a phee
sudo ./run.sh -u $USER -m deploy -a vnext

# With debug output
sudo ./run.sh -u $USER -m deploy -a all -d true

# With custom timeout (seconds)
sudo ./run.sh -u $USER -m deploy -a all -t 900
```

### Teardown
```bash
sudo ./run.sh -u $USER -m cleanall -a all
```

### Python Utilities (from `.venv/`)
```bash
# Activate the project virtualenv first
source .venv/bin/activate

# Submit batch payments
python src/utils/batch/submit-batch.py

# Verify batch results
python src/utils/batch/verify-batches.py

# List tenants
python src/utils/batch/list-tenants.py
```

### Testing Scripts
```bash
# Make a test payment
src/utils/test-scripts/make-payment.sh

# Test batch payment APIs
src/utils/test-scripts/test-curl-batch.sh

# Retrieve Kubernetes logs
src/utils/get-kube-logs.sh

# End-to-end Mastercard CBS test
src/utils/test-scripts/test-mastercard-e2e.sh
```

### Logging
Set `logging = true` in `config/config.ini` to write a full run log to `/tmp/gazelle-YYYYMMDD-HHMM.log`.

## Architecture

### Script Execution Flow
```
run.sh  →  src/commandline/commandline.sh  →  src/deployer/deployer.sh
                                          →  src/environmentSetup/environmentSetup.sh
```

`run.sh` is the sole entry point. On macOS it re-execs itself with Homebrew bash 4+ if the system bash is 3.2. It sources `commandline.sh`, which sources all other modules and parses CLI flags + `config/config.ini`.

### Key Source Files

| File | Role |
|------|------|
| `src/commandline/commandline.sh` | CLI parsing, config loading (`crudini`), top-level dispatch |
| `src/deployer/deployer.sh` | Orchestrates component deployments in dependency order |
| `src/deployer/core.sh` | Shared K8s functions: pod readiness waits, TLS secrets, Helm deploy wrappers |
| `src/deployer/mifosx.sh` | MifosX/Fineract deployment logic |
| `src/deployer/phee.sh` | Payment Hub EE deployment logic |
| `src/deployer/vnext.sh` | Mojaloop vNext deployment logic |
| `src/deployer/mastercard.sh` | Mastercard CBS connector deployment |
| `src/environmentSetup/environmentSetup.sh` | OS prereqs, k3s setup, `/etc/hosts`, Python venv |
| `src/utils/logger.sh` | Logging framework (INFO/WARNING/ERROR levels) |
| `src/utils/helpers.sh` | Common helper functions shared across modules |

### Configuration

All deployment settings live in `config/config.ini` (INI format, parsed with `crudini`). Sections:
- `[general]` — mode, domain, version, startup timeout, logging
- `[kubernetes]` — environment type (`local`/`remote`/`mac`), k3s version, resource minimums
- `[dockerhub]` — optional credentials to raise Docker Hub pull rate limits
- `[infra]` / `[mifosx]` / `[vnext]` / `[phee]` / `[mastercard-demo]` — per-component `enabled` flag, namespace, repo, branch

Config values are loaded into shell variables via `crudini --get`. CLI flags override config file values. `$USER` in the config is expanded to the invoking (non-root) user at runtime.

### Kubernetes Targets

- **`mac`** — Colima with k3s (primary dev environment)
- **`local`** — fresh k3s install on Linux
- **`remote`** — pre-existing cluster via kubeconfig

### Deployment Dependencies

Infrastructure (NGINX, MySQL, Kafka, Redis, MongoDB, Elasticsearch) must be up before any DPG. Deployment order: `infra` → `mifosx` / `phee` / `vnext` (these three are independent of each other).

### Submodule Repos

`repos/` contains git submodules with deployment artifacts for each DPG:
- `repos/mifosx/` — K8s manifests and database Dockerfiles
- `repos/ph_template/` — Payment Hub EE Helm charts (`helm/gazelle/`, `helm/ph-ee-engine/`, etc.)
- `repos/vnext/` — Mojaloop vNext manifests

### Helm Charts

- `src/deployer/helm/infra/` — Infrastructure umbrella chart (bundles Kafka, Elasticsearch, Redis, MongoDB, MySQL, NGINX)
- `repos/ph_template/helm/` — Payment Hub EE charts managed by PHEE upstream

### Python Virtualenv

`.venv/` is the project-local Python environment. Dependencies are minimal (`requests`). Scripts in `src/utils/data-loading/` and `src/utils/batch/` use it. Always activate before running Python scripts.

## macOS-Specific Notes

- `run.sh` auto-installs Homebrew bash 4+ if needed (the system `/bin/bash` is 3.2)
- `sudo` strips PATH on macOS; `run.sh` prepends `/opt/homebrew/bin:/usr/local/bin` after re-exec
- `crudini` is installed via `pipx` on macOS (Homebrew Python blocks plain `pip install`)
- Colima + docker + docker-compose are installed automatically via Homebrew on first run; Homebrew itself is also auto-installed if absent
- The Colima k3s VM uses the `eth0` interface IP for `/etc/hosts` entries (not `127.0.0.1`) because klipper-lb uses iptables DNAT which bypasses Lima's port-forwarding
- Third-party browsers (Firefox, Opera, Chrome) require **Local Network** permission to reach the Colima VM IP (`192.168.68.x`): System Settings → Privacy & Security → Local Network → enable the browser. Safari works without this as a system app.
- Browsers require a one-time cert acceptance: visit `https://mifos.mifos.gazelle.test` first and click through the self-signed cert warning before logging in. The NGINX ingress uses a default self-signed cert with no trusted CA. TODO: automate self-signed cert generation + macOS keychain trust during deploy.

## CI/CD

CircleCI (`.circleci/config.yml`) runs `sudo ./run.sh -m deploy -u $USER -a all -d true` on both amd64 and arm64 instances, then verifies pod readiness and health-check endpoints for all three DPGs.
