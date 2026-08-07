# MifosX

## What It Is

[MifosX](https://mifos.org/) is the core banking Digital Public Good deployed by Mifos Gazelle alongside Payment Hub EE, Mojaloop vNext, OpenSPP and OpenG2P. It provides client and account management, savings, loans, accounting and reporting, and is the system of record that Payment Hub EE debits and credits when a payment settles.

Gazelle deploys MifosX as its own app (`-a mifosx`) into the `mifosx` namespace, tracking the MifosX **25.12.25** release line — Apache Fineract 1.14.0, the Angular web app, and PostgreSQL 16.6. Beyond the core platform, Gazelle integrates three of MifosX's extension modules: Pentaho reporting, the Flowable workflow engine, and credit bureau integration.

This document describes each component Gazelle deploys, how to use it, and where the deeper upstream documentation lives.

---

## Table of Contents

- [What It Is](#what-it-is)
- [Deployment Method](#deployment-method)
- [How It Fits into Mifos Gazelle](#how-it-fits-into-mifos-gazelle)
- [Components](#components)
  - [Apache Fineract — core banking engine](#apache-fineract--core-banking-engine)
  - [Web App — Angular user interface](#web-app--angular-user-interface)
  - [Reports Module (Pentaho)](#reports-module-pentaho)
  - [Workflow Engine (Flowable)](#workflow-engine-flowable)
  - [Credit Bureau Integration](#credit-bureau-integration)
  - [SMS & Messaging Module — planned](#sms--messaging-module--planned)
  - [Loan Assessment Module — planned](#loan-assessment-module--planned)
- [Prerequisites](#prerequisites)
- [Getting Started](#getting-started)
- [Adding a New MifosX Module](#adding-a-new-mifosx-module)
- [Version Pins](#version-pins)
- [Known Limitations](#known-limitations)
- [Troubleshooting](#troubleshooting)
- [Further Reading](#further-reading)

---

## Deployment Method

MifosX is deployed from **vendored Kubernetes manifests**, which live under `src/deployer/manifests/mifosx/`.

At deploy time, `deploy_mifosx_from_yaml()` in `src/deployer/mifosx.sh` recreates the namespace, copies the manifest directory into a scratch working directory (`/tmp/gazelle-deploy/mifosx`), substitutes the real domain into the web app's deployment and ingress (`apply_domain_to_file`), restores the Fineract demo-data dump, and applies the whole directory with `apply_kube_manifests`. It then blocks in `wait_for_fineract_api_ready()` until every tenant listed in `FINERACT_TENANTS` answers on the Fineract API before reporting success.

Because the entire directory is applied, **adding a module is a matter of adding its manifests** — `mifosx.sh` needs no code change. That is how the reporting, workflow and credit bureau modules were integrated, and it is why per-module setup logic (downloading a plugin, creating a database, waiting on a dependency) is expressed as initContainers in the manifests rather than as shell steps in the deployer.

Image tags are pinned in the manifests; see [Version Pins](#version-pins).

---

## How It Fits into Mifos Gazelle

The MifosX product architecture, showing the modules that make up the platform:

![Mifos X Product and Roadmap architecture](mifosx-images/mifos-x-product-architecture.png)

The same architecture annotated to show which components Mifos Gazelle actually integrates:

```
  MifosX Product — annotated for Mifos Gazelle

  User Interfaces
  ┌──────────────────────┐  ┌──────────────────────┐
  │ Existing UI          │  │ Modularised UI       │
  │ (Angular)      [LIVE]│  │ (React/ShadCN) [ -- ]│
  └──────────────────────┘  └──────────────────────┘

  Extension Modules
  ┌──────────────────────┐  ┌──────────────────────┐  ┌──────────────────────┐
  │ Credit Bureau        │  │ SMS & Messaging      │  │ Templates            │
  │ Integration    [LIVE]│  │ Module         [PLAN]│  │ Module         [ -- ]│
  └──────────────────────┘  └──────────────────────┘  └──────────────────────┘
  ┌──────────────────────┐  ┌──────────────────────┐  ┌──────────────────────┐
  │ Workflow Engine      │  │ Reports Module *     │  │ Loan Assessment      │
  │                [LIVE]│  │                [LIVE]│  │ Module         [PLAN]│
  └──────────────────────┘  └──────────────────────┘  └──────────────────────┘

  Secure Interface Modules  Mobile Apps
  ┌──────────────────────┐  ┌──────────────────────┐
  │ Self Service         │  │ MobileApps     [ -- ]│
  │ Plugin Module  [ -- ]│  │ Mifos Pay      [ -- ]│
  └──────────────────────┘  └──────────────────────┘

  Core Modules
  ┌──────────────────────┐  ┌──────────────────────┐  ┌──────────────────────┐
  │ Current Account      │  │ Teller Module        │  │ Microfinance         │
  │ Module         [CORE]│  │                [CORE]│  │ Features       [CORE]│
  └──────────────────────┘  └──────────────────────┘  └──────────────────────┘

  Backend Solutions Used
  ┌──────────────────────┐  ┌──────────────────────┐
  │ Apache Fineract[LIVE]│  │ PostgreSQL     [LIVE]│
  └──────────────────────┘  └──────────────────────┘
```

| Tag | Meaning |
|---|---|
| `[LIVE]` | Integrated — deployed by `./run.sh -m deploy -a mifosx` |
| `[PLAN]` | Planned — researched, not yet deployed |
| `[CORE]` | Available through the deployed Fineract, not separately configured or demoed by Gazelle |
| `[ -- ]` | Not in Gazelle's current MifosX scope |

\* Reports is integrated and rendering, with one upstream dependency outstanding — see [Reports Module](#reports-module-pentaho).

MySQL and Kafka are not used by the MifosX Gazelle deployment.

Components deployed into the `mifosx` namespace:

| Component | Deployed as | Image | Purpose |
|---|---|---|---|
| Fineract | `fineract-server` pod | `openmf/fineract:1.14.0` | Core banking engine and API |
| Web App | `web-app` pod + ingress | `openmf/web-app:dev-10d24b8` | Angular user interface |
| Reports | *inside* `fineract-server` | plugin staged by initContainer | Pentaho formatted reporting |
| Workflow Engine | `mifos-workflow` pod | `kanishksingh23/mifos-workflow:27072026` | Flowable BPMN process orchestration |
| Credit Bureau | `credit-bureau` pod | `kanishksingh23/mifos-credit-bureau:30072026` | Credit bureau integration |

PostgreSQL is shared with the rest of Gazelle and lives in the `infra` namespace, not in `mifosx`.

---

## Components

### Apache Fineract — core banking engine

The core platform and API. Multi-tenant: each tenant has its own schema, and every API call must carry a tenant header.

| | |
|---|---|
| In-cluster URL | `http://fineract-server:8080/fineract-provider/api/v1/` |
| External URL | `https://mifos.<GAZELLE_DOMAIN>/fineract-provider/api/v1/` |
| Database | shared PostgreSQL, one schema per tenant |
| TLS | disabled in-cluster (`FINERACT_SERVER_SSL_ENABLED=false`); TLS terminates at the NGINX ingress |
| Tenants | `greenbank`, `bluebank`, `redbank` (from `FINERACT_TENANTS` in `config.ini`), plus `default` |

```bash
curl -k -u mifos:password \
  -H 'Fineract-Platform-TenantId: greenbank' \
  https://mifos.<GAZELLE_DOMAIN>/fineract-provider/api/v1/offices
```

Upstream documentation: <https://docs.mifos.org/core-banking-and-embedded-finance/core-banking> · API reference: <https://fineract.apache.org/docs/current/>

### Web App — Angular user interface

The standard MifosX web interface, served through an NGINX ingress at `https://mifos.<GAZELLE_DOMAIN>`. Log in as `mifos` / `password` and pick a tenant.

The pinned image is a `dev-` tag rather than the `1.12` release image because the published `1.12` release image is **amd64-only**, which breaks Gazelle's ARM64 targets (Apple Silicon via Colima, and Raspberry Pi). `dev-10d24b8` is the nearest multi-architecture build to that release. This pin should move to a release tag once the web-app release pipeline publishes multi-arch images.

The web app's tenant selector is configured with `greenbank`, `bluebank` and `default`. Note that `redbank` **is** a seeded tenant that Gazelle waits on at deploy time, but it is not in the selector — it is reachable through the API only.

### Reports Module (Pentaho)

Pentaho reporting is **not a separate pod** — the plugin is staged into the `fineract-server` pod at startup. Source: [openMF/mifos-reporting-plugin](https://github.com/openMF/mifos-reporting-plugin); releases are published on [SourceForge](https://sourceforge.net/projects/mifos/files/mifos-plugins/MifosReportingPlugin/).

Apache Fineract ships without Pentaho: it was removed from core during the Mifos → Apache migration for licence reasons, and the ASF-friendly BIRT replacement has no release yet. Fineract's built-in "Stretchy" reports cover on-screen and spreadsheet output only, so formatted PDF reporting requires the plugin.

An initContainer in `fineract-server-deployment.yaml` therefore runs on every deploy and: downloads `MifosReportingPlugin-1.14.0.zip` from SourceForge; stages its 71 jars into `/app/plugins` along with 49 PostgreSQL `.prpt` report definitions; and stages DejaVu fonts plus the fontconfig native library closure, which the Pentaho renderer needs in order to produce PDFs. No custom Fineract image is required, and no change to `mifosx.sh` — the automation lives entirely in the manifest.

**Using it.** In the web app, log in and open **Reports**. Of the 128 reports listed for a tenant, 44 are Pentaho reports — Balance Sheet, Income Statement, Trial Balance, Portfolio at Risk, Aging Detail, Active Loans and so on. Or call the API directly:

```bash
# HTML output
curl -k -u mifos:password \
  -H 'Fineract-Platform-TenantId: greenbank' \
  'https://mifos.<GAZELLE_DOMAIN>/fineract-provider/api/v1/runreports/Client%20Listing(Pentaho)?R_selectOffice=1&output-type=HTML'

# PDF output
curl -k -u mifos:password \
  -H 'Fineract-Platform-TenantId: greenbank' \
  'https://mifos.<GAZELLE_DOMAIN>/fineract-provider/api/v1/runreports/Trial%20Balance(Pentaho)?output-type=PDF' \
  -o trial-balance.pdf
```

Date parameters must be supplied as `dd MMMM yyyy`, for example `01 January 2026`.

Upstream documentation: <https://docs.mifos.org/core-banking-and-embedded-finance/core-banking/pentaho-reporting-plugin>

### Workflow Engine (Flowable)

Orchestrates MifosX business processes — client onboarding, offboarding and transfer; loan origination, disbursement and cancellation — as BPMN 2.0 processes, calling Fineract over REST and persisting process state in its own database. Source: [openMF/mifos-workflow](https://github.com/openMF/mifos-workflow).

| | |
|---|---|
| Port | `8081` |
| Health | `GET /actuator/health` |
| API base | `/api/v1` |
| Database | `mifos_flowable` on the shared PostgreSQL |
| Fineract tenant | `greenbank` |

BPMN definitions are auto-deployed from the image at startup and Flowable creates its own schema, so nothing needs restoring. Two initContainers gate startup: `wait-postgres` and `wait-fineract`.

**Using it.** The service has no ingress, so port-forward it:

```bash
kubectl -n mifosx port-forward svc/mifos-workflow 8081:8081
```

Every endpoint uses Basic auth with the Fineract credentials, and **you must authenticate before calling a workflow endpoint**:

```bash
curl -u mifos:password -X POST http://localhost:8081/api/v1/auth/authenticate
curl -u mifos:password -X POST http://localhost:8081/api/v1/workflow/client-onboarding/start \
  -H 'Content-Type: application/json' -d '{ ... }'
```

The module runs on PostgreSQL, in line with the move of MifosX to standardise on PostgreSQL.

### Credit Bureau Integration

Registers credit-bureau credentials, pulls client and address data from Fineract, and fetches or submits credit reports. Source: [openMF/mifos-x-credit-bureau-plugin](https://github.com/openMF/mifos-x-credit-bureau-plugin).

| | |
|---|---|
| Port | `8081` |
| Health | `GET /credit-bureaus` |
| Database | `creditbureau` on the shared PostgreSQL |

Gazelle runs it with `CDC_MOCK_ENABLED=true` — the default bureau target is Círculo de Crédito, and no real bureau credentials are configured. Two initContainers gate startup: `ensure-creditbureau-db` creates the database if it does not exist, and `wait-for-fineract` blocks until the core API answers.

**Using it.** No ingress, so port-forward:

```bash
kubectl -n mifosx port-forward svc/credit-bureau 8081:8081
curl http://localhost:8081/credit-bureaus
```

Two things worth knowing. Health probes hit `GET /credit-bureaus` rather than `/actuator/health`, because Jersey is mapped at `/*` and shadows the actuator endpoints — `/actuator/*` returns 404. That endpoint needs no auth (only `/api/**` is authenticated) and touches the database, so it is a genuine readiness signal. And `MIFOS_SECURITY_ENCRYPTION_KEY` has no default: the application will not start without it.

### SMS & Messaging Module — planned

[openMF/message-gateway](https://github.com/openMF/message-gateway) provides SMS and email delivery to MifosX through a REST push interface on port 9191. It is not yet in Gazelle because it is MySQL-only while Gazelle's MifosX stack is PostgreSQL-only. Adopting it needs the same database-agnostic treatment applied to the Workflow Engine.

### Loan Assessment Module — planned

[openMF/reactive-loan-module](https://github.com/openMF/reactive-loan-module) is a reactive (WebFlux + R2DBC) loan assessment service that consumes Fineract events over Kafka. It is PostgreSQL-native, so the database is not a blocker, but it is still depends on outstanding Fineract changes and on Fineract's external-events Kafka support being enabled.

---

## Prerequisites

- Same base setup as any Gazelle deployment (`sudo ./setup-env.sh -u $USER`)
- No sudo required to deploy MifosX itself

---

## Getting Started

### 1. Enable in `config/config.ini`

```ini
[mifosx]
enabled = true
MIFOSX_NAMESPACE = mifosx
FINERACT_USERNAME = mifos
FINERACT_PASSWORD = password
FINERACT_TENANTS = greenbank bluebank redbank
```

`FINERACT_TENANTS` is the list of tenants the deployer waits on before declaring MifosX ready.

### 2. Deploy

```bash
./run.sh -m deploy -a mifosx      # MifosX only
./run.sh -m deploy -a all         # every DPG
```

The deploy recreates the namespace, restores the demo-data dump, applies the manifests, and waits for each tenant's API to answer.

### 3. Log in

Open `https://mifos.<GAZELLE_DOMAIN>` — by default `https://mifos.mifos.gazelle.test` — and log in as `mifos` / `password`. Select tenant `greenbank`, `bluebank` or `default`.

The workflow engine and credit bureau modules have no ingress; reach them with `kubectl port-forward` as shown in their sections above.

### /etc/hosts entries

```
# Linux/macOS
<VM-IP> fineract.mifos.gazelle.test mifos.mifos.gazelle.test

# Windows (one per line)
<VM-IP> mifos.mifos.gazelle.test
<VM-IP> fineract.mifos.gazelle.test
```

---

## Adding a New MifosX Module

The three modules integrated so far follow one pattern. To add a fourth:

1. **Check the database.** Gazelle's MifosX stack is PostgreSQL-only. If the module is tied to MySQL, make it database-agnostic at source — add the PostgreSQL driver alongside the existing one, make the datasource environment-overridable, keep the upstream default unchanged, and remove any hardcoded dialect. That keeps the change upstreamable instead of creating a fork.
2. **Build a multi-architecture image.** Gazelle targets amd64 and arm64 — an amd64-only image breaks Apple Silicon and Raspberry Pi deployments. Use the repo's own builder rather than raw `docker buildx`; see [Building images for Gazelle](BUILDING-IMAGES.md):
   ```bash
   src/utils/build-and-import-image.sh -n openmf/<module> -t <tag> \
       --platform linux/amd64,linux/arm64 --push
   ```
3. **Share the infrastructure.** Point the module at `postgres.infra.svc.cluster.local:5432` with its own database rather than deploying a database pod, and add an initContainer that creates that database if it does not exist.
4. **Gate on dependencies.** Add initContainers that wait for PostgreSQL and for Fineract's API, so the module does not crash-loop while the core is still starting.
5. **Verify the probe path.** Confirm which port and path actually answer — several MifosX modules document ports or actuator paths that do not match their runtime behaviour.
6. **Add manifests and document.** Drop the deployment and service YAML into `src/deployer/manifests/mifosx/`, pin the image tag explicitly, add a section to this file and a row to the component table, and verify with a real `./run.sh -m deploy -a mifosx`.

---

## Version Pins

All image tags are pinned — no `:latest`. The current pins live in the manifests under `src/deployer/manifests/mifosx/`; the components and their tags are listed in the table under [How It Fits into Mifos Gazelle](#how-it-fits-into-mifos-gazelle).

---

## Known Limitations

- **Pentaho per-tenant routing needs a fixed plugin release.** The published plugin resolves its datasource in a way that can return another tenant's data. The fix is a two-line change, merged upstream into `openMF/mifos-reporting-plugin` ([PR #513](https://github.com/openMF/mifos-reporting-plugin/pull/513), `pentaho` branch), but **no fixed release has been published yet** and Gazelle installs the published artifact. Until a fixed release ships, treat multi-tenant report output as unreliable. Closing this needs either a new plugin release or a temporary class swap in the initContainer.
- **Financial reports render empty on the seeded tenants.** Reports run, but totals come out zero because the seeded tenants have no posted general-ledger entries — Gazelle's demo data is payment-oriented (clients and savings accounts for transfers) rather than loan- and GL-heavy. This is a demo-data gap, not a reporting fault, and is a to-do for the data loading to remedy before release.
- **The Workflow Engine and Credit Bureau images are temporary.** Neither project publishes a container image, so both are built from source and pushed to a personal DockerHub namespace. Both pins should move to `openMF` images once those are published.
- **`redbank` is not selectable in the web app.** It is seeded and waited on at deploy time, but absent from the web app's tenant list, so it is reachable through the API only.
- **MifosX is deployed from raw manifests, not Helm**, unlike OpenG2P and Payment Hub EE.

---

## Troubleshooting

**A module pod is stuck in `Init`** — its initContainers are still waiting on a dependency:
```bash
kubectl -n mifosx get pods
kubectl -n mifosx logs <pod-name> -c wait-fineract
kubectl -n mifosx logs <pod-name> -c wait-postgres
```

**A Pentaho report returns 403 "Failed to execute query"** — the plugin's datasource did not resolve for the tenant; see the per-tenant limitation above. Confirm the plugin itself loaded:
```bash
kubectl -n mifosx logs <fineract-pod> -c fetch-reporting-plugin
kubectl -n mifosx exec <fineract-pod> -- ls /app/plugins | wc -l   # expect 71 jars
```

**A Pentaho report renders but every total is zero** — expected on the seeded tenants, which have no posted GL entries. Not a fault.

**A report rejects its date parameter** — dates must be formatted `dd MMMM yyyy`, e.g. `01 January 2026`.

**A workflow endpoint returns 401** — authenticate first; Basic auth alone is not enough:
```bash
curl -u mifos:password -X POST http://localhost:8081/api/v1/auth/authenticate
```

**`/actuator/health` on the Credit Bureau returns 404** — expected, Jersey shadows `/actuator/*`. Use `GET /credit-bureaus` instead.

**Fineract never becomes ready and the deploy times out** — check which tenant is failing to initialise:
```bash
kubectl -n mifosx logs deploy/fineract-server | tail -50
```
Raise `startup_timeout` in `config/config.ini` on slow or resource-constrained hosts.

---

## Further Reading

- [Mifos Gazelle deployment guide](MIFOS-GAZELLE-README.md)
- [Release notes](RELEASE-NOTES.md)
- MifosX core banking: <https://docs.mifos.org/core-banking-and-embedded-finance/core-banking>
- Apache Fineract API: <https://fineract.apache.org/docs/current/>
