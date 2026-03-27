# Mifos Gazelle Deployment Guide

[![Mifos](https://img.shields.io/badge/Mifos-Gazelle-blue)](https://github.com/openMF/mifos-gazelle)

> Mifos Gazelle v2.0.0 — March 2026. Deploys MifosX, Payment Hub EE, and Mojaloop vNext Beta1 on Kubernetes.

## Table of Contents
- [Goal](#goal-of-mifos-gazelle)
- [Features](#mifos-gazelle-features)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Deployment Options](#deployment-options)
- [What to Do Next](#what-to-do-next)
  - [Deployed Web Consoles](#deployed-web-consoles)
  - [Test a Payment](#execute-a-transfer-from-greenbank-to-bluebank)
  - [Test Bulk Processing](#bulk-processing)
- [Application Deployment Modes](#application-deployment-modes)
- [Cleanup](#cleanup)
- [Accessing Deployed Applications](#accessing-deployed-applications-dpgs)
- [Kibana Dashboards](#kibana-dashboards)
- [Demo Tools](#demo-tools)
- [Adding Tenants to MifosX](#adding-tenants-to-mifosx)
- [Development Status](#development-status)
- [Known Issues](#known-issues)
- [FAQ](#faq)
- [Version Information](#version-information)

---

## Goal of Mifos Gazelle

Mifos Gazelle provides a very simple kubernetes based installation for cloud native Digital Public Goods (DPGs) — initially MifosX (core banking), Payment Hub EE (payment orchestration), and Mojaloop vNext Beta1 (payment switch). The goal is a rapidly deployable showcase and lab environment that others can build on.

> **IMPORTANT:** v2.0.0 is recommended for development, test, and demonstration only. Security hardening has not yet occurred, so it is NOT currently production ready. 

---

## Mifos Gazelle Features

- Installs each or all 3 DPGs in a reliable, repeatable and integrated way with demonstration data generated and loaded so that end to end testing of transactions is immediately available after deployment. 
- Bash scripts designed to be readable and modifiable
- Full installation in ~15 minutes on capable hardware
- Fully functioning MifosX with multi-tenant support
- Fully functioning vNext (Beta1) with integrated test environment and pre-loaded demo data
- Deployed Payment Hub EE with Operations Web UI

---

## Prerequisites

- Ubuntu 22.04 or 24.04 LTS (x86_64 or ARM64)
- 16 GB RAM minimum (less if deploying individual components)
- 75 GB+ free space in home directory
- Non-root user with sudo privileges

---

## Quick Start

```bash
cd $HOME
git clone --branch main https://github.com/openMF/mifos-gazelle.git
cd mifos-gazelle
sudo ./run.sh -u $USER -m deploy -a all
```

The deployment takes 10–20 minutes.  See [Deployment times out](#deployment-times-out-waiting-for-pods) in the FAQ if deployments time out on slower hardware.

---

## Deployment Options

| Flag | Description | Values | Default |
|------|-------------|--------|---------|
| `-f` | Config file path | path to `.ini` | `config/config.ini` |
| `-m` | Mode (required) | `deploy`, `cleanapps`, `cleanall` | — |
| `-u` | Non-root user (required) | `$USER` | — |
| `-a` | Components to deploy | `all`, `infra`, `vnext`, `phee`, `mifosx`, `mastercard-demo`, `setup-data` | `all` |
| `-e` | Cluster environment | `local`, `remote` | `local` |
| `-d` | Debug output | `true`, `false` | `false` |
| `-r` | Force redeploy | `true`, `false` | `true` |
| `-h` | Show help | — | — |

`config/config.ini` is the central configuration file — it controls namespaces, repo branches, domains, and which components are enabled. Use `-f` to point to an alternative file (e.g. for per-environment variants). The file is self-documenting; all keys have inline comments.

---

## What to Do Next

Once `kubectl get pods -A` or `~/local/bin/k9s` shows all pods running:

1. **[Browse the web consoles](#deployed-web-consoles)** — MifosX, Operations Web, Zeebe Operate, MinIO, Kibana, vNext Admin
2. **[Run a test payment](#execute-a-transfer-from-greenbank-to-bluebank)** — send funds from Greenbank to Bluebank via the vNext switch
3. **[Test bulk processing](./BULK.md)** — submit a G2P bulk disbursement batch
4. **[Read the DPG docs](#dpg-documentation)** — upstream documentation for each component

---

### Deployed Web Consoles

> All URLs use the default domain `mifos.gazelle.test`. Ensure your browser machine has the correct `/etc/hosts` entries — see [Accessing Deployed Applications](#accessing-deployed-applications-dpgs).

**MifosX**

| Console | URL | Login |
|---------|-----|-------|
| MifosX Web Client | https://mifos.mifos.gazelle.test | mifos / password (select tenant: `default`, `greenbank`, `bluebank`, `redbank`) |

**Payment Hub EE**

| Console | URL | Login |
|---------|-----|-------|
| Operations Web | https://ops.mifos.gazelle.test | — |
| Zeebe Operate (BPMN monitor) | https://zeebe-operate.mifos.gazelle.test | demo / demo |
| MinIO Console (object storage) | https://minio-console.mifos.gazelle.test | root / password |
| Kibana (payment dashboards) | https://kibana.mifos.gazelle.test | — |

**Mojaloop vNext**

| Console | URL | Login |
|---------|-----|-------|
| vNext Admin UI | https://vnextadmin.mifos.gazelle.test | admin / superMegaPass |
| Redpanda Console (Kafka UI) | https://redpanda-console.mifos.gazelle.test | — |
| Mongo Express (MongoDB browser) | https://mongoexpress.mifos.gazelle.test | — |

---

### DPG Documentation

- vNext: https://github.com/mojaloop/platform-shared-tools/blob/main/packages/deployment/docker-compose-apps/README.md
- MifosX: https://docs.mifos.org/core-banking-and-embedded-finance/core-banking
- Payment Hub EE: https://mifos.gitbook.io/docs/payment-hub-ee/business-overview/vision

Join the `#mifos-gazelle` channel on [Mifos Slack](https://mifos.slack.com)

---

## Execute a Transfer from Greenbank to Bluebank

When all 3 DPGs are deployed, demonstration data is pre-loaded so you can immediately run a payment from a Greenbank customer to a Bluebank customer via the vNext switch.

```bash
./src/utils/make-payment.sh
```

To view the resulting transaction history across all tenants:
```bash
./src/utils/view-mifos-transactions.py -c config/config.ini
```

**Observe the results:**
- **Zeebe Operate** at https://zeebe-operate.mifos.gazelle.test (login: demo/demo) → Dashboard → PayerFundTransfer-greenbank → see the BPMN execution path (blue line)
- **Payment Hub Operations Web** at https://ops.mifos.gazelle.test → paymenthub → transfers
- **vNext Admin UI** at https://vnextadmin.mifos.gazelle.test (login: admin/superMegaPass) → quotes and transfers
- **MifosX** at https://mifos.mifos.gazelle.test (login: mifos/password, tenant: greenbank or bluebank) → institution → clients → account → transactions (payer starts at $5000). See [known issues](#known-issues) for workarounds if issues with login


---

## Application Deployment Modes

```bash
sudo ./run.sh -u $USER -m deploy -a vnext   # Mojaloop vNext only
sudo ./run.sh -u $USER -m deploy -a mifosx  # MifosX only
sudo ./run.sh -u $USER -m deploy -a phee    # Payment Hub EE only
```

---

## Cleanup

```bash
sudo ./run.sh -u $USER -m cleanall           # Remove everything including k3s
sudo ./run.sh -u $USER -m cleanapps          # Remove all apps, keep k3s AND IMAGES !
sudo ./run.sh -u $USER -m cleanapps -a mifosx
sudo ./run.sh -u $USER -m cleanapps -a phee
sudo ./run.sh -u $USER -m cleanapps -a vnext
```

---

## Accessing Deployed Applications (DPGs)

Add the following to your **local** `/etc/hosts` (or Windows `C:\Windows\System32\drivers\etc\hosts`), where `<VM-IP>` is the server's IP address.

### MifosX

```
# Linux/macOS
<VM-IP> fineract.mifos.gazelle.test mifos.mifos.gazelle.test

# Windows (one per line)
<VM-IP> mifos.mifos.gazelle.test
<VM-IP> fineract.mifos.gazelle.test
```

Login at https://mifos.mifos.gazelle.test with user `mifos` / password `password`. Select tenant: `default`, `greenbank`, or `bluebank`.

### vNext

```
# Linux/macOS
<VM-IP> vnextadmin.mifos.gazelle.test elasticsearch.mifos.gazelle.test kibana.mifos.gazelle.test mongoexpress.mifos.gazelle.test kafkaconsole.mifos.gazelle.test fspiop.mifos.gazelle.test bluebank.mifos.gazelle.test greenbank.mifos.gazelle.test redpanda-console.mifos.gazelle.test

# Windows (one per line)
<VM-IP> vnextadmin.mifos.gazelle.test
<VM-IP> elasticsearch.mifos.gazelle.test
<VM-IP> kibana.mifos.gazelle.test
<VM-IP> mongoexpress.mifos.gazelle.test
<VM-IP> kafkaconsole.mifos.gazelle.test
<VM-IP> fspiop.mifos.gazelle.test
<VM-IP> bluebank.mifos.gazelle.test
<VM-IP> greenbank.mifos.gazelle.test
<VM-IP> redpanda-console.mifos.gazelle.test
```

### Payment Hub EE

```
# Linux/macOS
<VM-IP> ops.mifos.gazelle.test kibana-phee.mifos.gazelle.test zeebe-operate.mifos.gazelle.test

# Windows (one per line)
<VM-IP> ops.mifos.gazelle.test
<VM-IP> kibana-phee.mifos.gazelle.test
<VM-IP> zeebe-operate.mifos.gazelle.test
```

---

## Kibana Dashboards

Payment Hub EE ships with pre-built Kibana visualizations and dashboards for monitoring payment flows.

**Import dashboards after deployment:**
```bash
# Default URL (kibana.mifos.gazelle.localhost)
./src/utils/kibana-dashboard-setup.sh

# Custom Kibana URL
export KIBANA_URL=https://kibana-phee.mifos.gazelle.test
./src/utils/kibana-dashboard-setup.sh
```

The script imports objects from `repos/ph_template/Kibana Visualisations/` in the correct order: index patterns → searches → visualizations → lenses → dashboards. It reports a success/failure count on completion.

Access Kibana at http://kibana-phee.mifos.gazelle.test (add to `/etc/hosts` as shown in [Payment Hub EE Host Configuration](#payment-hub-ee)).

---

## Demo Tools

Two companion tools exist for creating and presenting interactive demos using a live Gazelle deployment:

### Demo Creator

[mifos-gazelle-demo-creator](https://github.com/openMF/mifos-gazelle-demo-creator) — a Python terminal UI (TUI) for authoring, managing, and syncing demos to JFrog Artifactory.

```bash
git clone https://github.com/openMF/mifos-gazelle-demo-creator.git
cd mifos-gazelle-demo-creator
bash ./scripts/install_dependencies.sh
just setup && just run
```

Features: create demo steps, upload to JFrog, trigger Gazelle deployments with live log output.

### Demo Runtime

[mifos-gazelle-demo-runtime](https://github.com/openMF/mifos-gazelle-demo-runtime) — a React web app for running interactive demos against a live Gazelle deployment.

```bash
git clone https://github.com/openMF/mifos-gazelle-demo-runtime.git
cd mifos-gazelle-demo-runtime && npm install && npm start
# Open http://localhost:3000
```

Features: split-panel interface (instructions on the left, live DPG iframe on the right), demo catalogue loaded from JFrog, product and platform demo categories.

---

## Adding Tenants to MifosX

Mifos Gazelle deploys four default tenants: `default`, `greenbank`, `bluebank` and `redbank`.

1. Edit `config/mifos-tenant-config.csv` — add your tenant names
2. Apply: `src/utils/data-loading/update-mifos-tenants.sh -f ./config/mifos-tenant-config.csv`
3. Restart fineract-server in k9s (`Ctrl-k` on the pod) — Kubernetes will recreate it
4. Watch Liquibase create the new schema: in k9s, select the new pod and press `l` for logs

---

## Development Status

> Limitations below are those of the Mifos Gazelle configuration, not of the underlying DPGs.

- Operations-Web UI has been vastly improved but is still WIP
- Payment Hub EE mifos-v2.0.0 is deployed which is a branch that builds on v1.13.3 release and is reflected in the mifos-v2.0.0 branches of the Paymenthub EE repositories deployed by mifos-gazelle 
- ARM64 supported for all 3 DPGs; Raspberry Pi 4 has a MongoDB limitation (requires ARMv8.2A) but Pi 5 is well tested now and works well for P2P payments i.e. make-payment.sh. 
- Memory reduction is still wip but 16GB generally works fine for all 3 DPGs on a single node.
- Kubernetes operator work (openMF/mifos-operators) still planned for a future release
---

## Known Issues

- Helm tests (`helm test phee`) have not been updated to reflect the latest Payment Hub EE changes — WIP, expect failures.
- Docker Hub rate limits (100 pulls/6 hrs per IP for anonymous users) can cause image pull failures — set credentials in `config/config.ini` under `[dockerhub]` to authenticate. See [FAQ](#docker-hub-rate-limit-errors-during-deployment).
- On 16GB systems, occasional pod OOM events require a pod restart or re-run
- Kubernetes Single-node only in Local Mode (no technical barrier; just not yet tested multi-node)
- Operations-Web can show wrong status for batches while the batch is being processed , check the transfers and once they are all done both batch status and totals should be correct
- Postman collections not yet fully adapted to Gazelle environment
- Some issues on older Intel/Opteron hardware with nginx, MongoDB, and ElasticSearch
- **Security:** the deployment is not hardened — use for dev/test/demo only
- **MifosX Web-app**  requires to be called in https:// in chrome firefox or safari otherwise login will not work and username/password issue will be highlighted [issue](https://mifosforge.jira.com/browse/GAZ-260).  The first time you go to the https://mifos.mifos.gazelle.test you will get a security warning you will need to accept the risk. Then when you try to login it will be accepted. [workaround instructions](./mifosx_workaround/web-app_workaround.md)
- MifosX Web-app Edge and other browsers have not been tested.

---

## FAQ

### Deployment times out waiting for pods

MifosX runs Liquibase database migrations on first boot, which can take several minutes on slower hardware. Increase `startup_timeout` in `config/config.ini` and re-run:

```ini
[general]
startup_timeout = 600   # default — modern hardware
startup_timeout = 1800  # Raspberry Pi or slow disks
```

To monitor progress while waiting:
```bash
kubectl get pods -n mifosx -w
kubectl logs -n mifosx -l app=fineract-server --tail=100 -f
```

### Docker Hub rate limit errors during deployment

Docker Hub limits anonymous pulls to 100 per 6 hours per IP. Set credentials in `config/config.ini` to authenticate:

```ini
[dockerhub]
DOCKERHUB_USERNAME = your-dockerhub-username
DOCKERHUB_PASSWORD = your-dockerhub-password
DOCKERHUB_EMAIL    = your-email@example.com
```

Or pass them as environment variables:
```bash
export DOCKERHUB_USERNAME=your-username
export DOCKERHUB_PASSWORD=your-password
export DOCKERHUB_EMAIL=your-email@example.com
sudo -E ./run.sh -u $USER -m deploy -a all
```

When credentials are set, `src/utils/k3s-docker-login.sh` creates a `dockerhub-secret` in each namespace and patches all service accounts with `imagePullSecrets` automatically.

### Operations-Web shows "REJECTED" or "null" status during batch processing

This is expected. During batch processing, individual transfer records pass through intermediate states that can appear as `REJECTED`, `null`, or similar in the Operations-Web UI. **The correct final status is set when processing completes** (typically 60–90 seconds after batch submission). Refresh the page after processing finishes to see accurate results.

The database is always the authoritative source:
```bash
kubectl exec -n paymenthub operationsmysql-0 -- env MYSQL_PWD=ethieTieCh8ahv mysql -uroot tenants \
  -e "SELECT batch_id, total_transactions, completed, status FROM batches ORDER BY id DESC LIMIT 5\G"
```

### MifosX fails to start / Liquibase migration error

Check the fineract-server logs:
```bash
kubectl logs -n mifosx -l app=fineract-server --tail=200
kubectl describe pod -n mifosx -l app=fineract-server
```

If the pod keeps restarting, check MySQL is healthy:
```bash
kubectl get pods -n infra
kubectl logs -n infra -l app=mysql --tail=50
```

### Cannot reach web UIs in browser

Ensure the `/etc/hosts` entries (or Windows hosts file) are set on the machine where your **browser** runs, pointing to the Gazelle server IP. See [Accessing Deployed Applications](#accessing-deployed-applications-dpgs).

### make-payment.sh fails or returns errors

The test payment script requires that demonstration data (clients, accounts, and vNext oracle registrations) was successfully generated and loaded during deployment. This can silently fail if MifosX was still starting up when the data generation step ran (e.g. Liquibase migration not yet complete).

**Re-run data generation:**
```bash
sudo ./run.sh -u $USER -m deploy -a setup-data
```

This reruns only the data generation and loading step — it does not redeploy any components. After it completes, retry `./src/utils/make-payment.sh`.

**To verify data is present before retrying:**
```bash
# Check MifosX has clients in greenbank and bluebank tenants
./src/utils/view-mifos-transactions.py -c config/config.ini

# Check vNext oracle has MSISDN registrations
kubectl exec -n vnext -l app=account-lookup-svc -- \
  curl -s http://localhost:3030/participants/MSISDN/0413356886
```

### MifosX Login issue

If you experience login issues for MifosX UI please refer to these [workaround instructions](./mifosx_workaround/web-app_workaround.md)


