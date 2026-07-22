# OpenG2P

## What It Is

[OpenG2P](https://openg2p.org/) is a Digital Public Good for Government-to-Person (G2P) payment programmes — beneficiary registration, payment batch management, and program-to-payment-rail bridging. Mifos Gazelle deploys it as its own app (`-a openg2p`), independent of MifosX, Payment Hub EE, and vNext.

Each OpenG2P module is installed as its own Helm release in the `openg2p` namespace so subchart-generated object names never collide across modules.

---

## Deployment Method

OpenG2P is deployed via Helm, consistent with the rest of Gazelle's infra (`src/deployer/helm/`). Five thin wrapper charts are vendored under `src/deployer/helm/openg2p/` — one per module: `openg2p-commons`, `openg2p-pbms`, `openg2p-social-registry`, `openg2p-spar`, `openg2p-g2p-bridge`.

Each wrapper chart's `Chart.yaml` declares exactly one dependency: the corresponding upstream OpenG2P chart pinned to a specific version, pulled from OpenG2P's own chart repo (`https://openg2p.github.io/openg2p-helm`):

```yaml
dependencies:
- name: openg2p-pbms
  alias: pbms
  version: "3.0.0"
  repository: https://openg2p.github.io/openg2p-helm
```

Pinned versions: `openg2p-commons-base` 2.0.1, `openg2p-pbms` 3.0.0, `openg2p-social-registry` 2.0.8, `openg2p-spar` 0.0.0-develop, `openg2p-g2p-bridge` 3.0.0. The resolved upstream chart `.tgz` is vendored into each wrapper's `charts/` directory (`helm dependency update`, wrapped by `ensure_helm_dependencies()` in `src/deployer/core.sh`, which skips re-fetching if the `.tgz` count already matches `Chart.lock`) — so a deploy doesn't need live network access to the OpenG2P chart repo on every run.

Gazelle-specific overrides (ingress hostnames, image repoints, fixed demo credentials, cross-module DB wiring) live in each wrapper's own `values.yaml`, layered on top of the vendored upstream chart's defaults. The upstream chart itself is never modified.

At deploy time (`_deploy_openg2p_release()`), each chart is copied to a scratch working directory, its `values.yaml` has FQDN placeholders substituted for the real domain (`apply_domain_to_file`), and installed with `helm upgrade --install` (idempotent — a rerun against an already-healthy release is a no-op). No `--wait` is used, since Helm's readiness poll can misreport large charts as failed; Gazelle polls real pod status itself after the Helm apply returns.

---

## How It Fits into Mifos Gazelle

```
┌──────────────────────────────────────────────────────────────┐
│  Mifos Gazelle — openg2p namespace                           │
│                                                                │
│                     ┌─────────────────┐                       │
│                     │  openg2p-commons │  (always deployed)   │
│                     │  Postgres        │                       │
│                     │  Keycloak (SSO)  │                       │
│                     │  MinIO           │                       │
│                     └────────┬─────────┘                       │
│               ┌──────────────┼──────────────┬───────────────┐ │
│               ▼              ▼              ▼               ▼ │
│      social-registry       pbms           spar        g2p-bridge│
│     (beneficiaries)   (payment batches) (SR mapper)  (depends  │
│                              │                        on spar) │
└──────────────────────────────┼────────────────────────────────┘
                               ▼
                     Payment Hub EE (PHEE)
              via g2p_payment_phee Odoo connector
```

Modules:

| Module | Helm chart | Enabled by default | Purpose |
|---|---|---|---|
| commons | `openg2p-commons` | always | Postgres, Keycloak (SSO/OIDC), MinIO — shared foundation every other module connects to |
| social-registry | `openg2p-social-registry` | false | Beneficiary/registrant data management |
| pbms | `openg2p-pbms` | true | Payment Batch Management System (Odoo) — creates and issues G2P payment batches |
| spar | `openg2p-spar` | false | Social Registry mapper/API |
| g2p-bridge | `openg2p-g2p-bridge` | false | Bridges G2P programs to payment rails; depends on the SPAR mapper |

Deploy order (`deploy_openg2p()` in `src/deployer/openg2p.sh`): namespace + TLS → prerequisite CRDs → **commons** (must be healthy — an unhealthy commons aborts the OpenG2P deploy) → enabled modules in fixed order `social-registry` → `pbms` → `spar` → `g2p-bridge`. A module that fails to become ready is recorded and skipped; it does not block the rest, and failures are summarized at the end of the run.

Once PBMS is up, Gazelle enables the `g2p_payment_phee` Odoo addon (`src/utils/openg2p/setup-pbms-phee.sh`) so PBMS can issue payment batches to **Payment Hub EE**.

### NGINX ingress instead of Istio

OpenG2P's Keycloak subchart unconditionally emits Istio `Gateway` and `VirtualService` objects for routing. Gazelle standardizes on NGINX ingress across all DPGs, so no Istio control plane is installed. Rather than patching the upstream chart to strip these objects, they're allowed to apply harmlessly (see CRDs below) and real traffic is routed through Gazelle's existing NGINX ingress + per-module TLS secrets instead.

### Why CRDs are needed

Since the Istio/logging/monitoring controllers aren't installed, the CRDs (Custom Resource Definitions) for the object kinds those upstream charts emit don't exist either — without them, `helm install` fails validation on an unknown kind. Two minimal, open-schema CRD manifests are vendored to satisfy this, with no controller behind them (the objects land inertly, unused):

- `src/deployer/manifests/openg2p/istio-networking-crds.yaml` — `gateways.networking.istio.io`, `virtualservices.networking.istio.io`
- `src/deployer/manifests/openg2p/optional-operator-crds.yaml` — `flows.logging.banzaicloud.io`, `outputs.logging.banzaicloud.io`, `servicemonitors.monitoring.coreos.com`

These are applied once per deploy, before any module Helm release, via `kubectl apply` in `deploy_openg2p()`.

### Independent per-module releases

OpenG2P already ships each app (commons, social-registry, pbms, spar, g2p-bridge) as its own separate upstream chart. What Gazelle adds is installing each as an independent Helm release in the `openg2p` namespace, so any single module can be individually enabled, disabled, or torn down via its own `OPENG2P_*_ENABLED` flag without touching the others.

Upstream still expects all charts installed together against a shared reference — some modules' charts reference secrets that a sibling module's chart creates (e.g. `pbms` mounts a `social-registry-postgresql` secret regardless of whether social-registry is enabled). Since Gazelle allows any subset of modules to be enabled, `_openg2p_preflight_secrets()` pre-creates placeholder versions of these cross-module secrets when the module that would normally create them is disabled — otherwise the dependent module's pods crash-loop on `CreateContainerConfigError`. Real cross-module DB access via these secrets is a known follow-up (see [Known Limitations](#known-limitations)).

---

## Prerequisites

- Same base setup as any Gazelle deployment (`sudo ./setup-env.sh ...`)
- No sudo required to deploy OpenG2P itself

---

## Getting Started

### 1. Enable in `config/config.ini`

```ini
[openg2p]
enabled = true
OPENG2P_NAMESPACE = openg2p
OPENG2P_SOCIAL_REGISTRY_ENABLED = false
OPENG2P_PBMS_ENABLED = true
OPENG2P_SPAR_ENABLED = false
OPENG2P_G2P_BRIDGE_ENABLED = false
```

Each module has its own `OPENG2P_*_ENABLED` flag. Disabling a module that was previously deployed tears down its Helm release on the next deploy.

### 2. Deploy

```bash
./run.sh -m deploy -a openg2p          # OpenG2P only
./run.sh -m deploy -a all              # all DPGs, including OpenG2P
./run.sh -m deploy -a openg2p -d true  # with debug output
```

Teardown:

```bash
./run.sh -m cleanapps -a openg2p
```

### 3. Log in

Printed at the end of a successful deploy. With the default config (PBMS enabled, others disabled):

| Console | URL |
|---|---|
| PBMS (Odoo) | https://pbms.mifos.gazelle.test |
| Keycloak | https://keycloak.mifos.gazelle.test |
| MinIO | https://minio.mifos.gazelle.test |

If enabled, `social-registry`, `spar`, and `g2p-bridge` are reachable the same way at `https://<module>.mifos.gazelle.test`.

PBMS and social-registry Odoo login is `admin@openg2p.org` / `adminopeng2p`.

### /etc/hosts entries

These hostnames must resolve to the cluster's ingress IP. `sudo ./setup-env.sh` adds them **automatically** for a local (k3s/Colima) deploy, so on a standard install there is nothing to do. On a **remote / pre-existing cluster** (`setup-env.sh -e remote`), or if you manage `/etc/hosts` yourself, add the OpenG2P block — one line, all seven hosts pointing at your ingress IP (replace `<INGRESS-IP>`; use `127.0.0.1` for a local single-node cluster, the Colima VM IP on macOS, or the node/LB IP for remote):

```
<INGRESS-IP>  openg2p.mifos.gazelle.test social-registry.mifos.gazelle.test pbms.mifos.gazelle.test spar.mifos.gazelle.test g2p-bridge.mifos.gazelle.test keycloak.mifos.gazelle.test minio.mifos.gazelle.test
```

| Hostname | Serves |
|---|---|
| `pbms.mifos.gazelle.test` | PBMS (Odoo) UI |
| `social-registry.mifos.gazelle.test` | Social Registry UI (if enabled) |
| `spar.mifos.gazelle.test` | SPAR mapper API (if enabled) |
| `g2p-bridge.mifos.gazelle.test` | G2P Bridge API (if enabled) |
| `keycloak.mifos.gazelle.test` | Keycloak (shared commons) |
| `minio.mifos.gazelle.test` | MinIO console (shared commons) |
| `openg2p.mifos.gazelle.test` | OpenG2P TLS SAN / base host |

> All seven are covered by the `openg2p-tls` ingress cert (created in `deploy_openg2p`), and match the `OPENG2PHOSTS` list in `src/environmentSetup/environmentSetup.sh`. Substitute your own domain for `mifos.gazelle.test` if you changed `GAZELLE_DOMAIN`.

---

## PBMS ↔ Payment Hub EE Connector

The default PBMS Odoo image ships with none of the OpenG2P addon modules at all — no `g2p_payment_phee`, no `g2p_programs`, no registry addons are baked in or present out of the box. Once PBMS is ready, `src/utils/openg2p/setup-pbms-phee.sh` idempotently:

- Downloads the `openg2p-registry` (branch `17.0-1.5`) and `openg2p-program` (branch `17.0-1.3`) addon source repos from GitHub directly onto the pod's filesystem (PVC) and points Odoo at them via `ODOO_ADDONS_DIR`
- Runs Odoo's `update_list()` so the addons even appear in Odoo's app list
- Installs the specific modules PBMS needs — `g2p_social_registry_importer` and `g2p_payment_phee` — so PBMS can issue payment batches to Payment Hub EE (`pbms_theme_extension` is deliberately excluded: it depends on the `website` module and 500s the Community edition login page)

This step is non-fatal — a failure logs a warning and the script can be re-run manually:

```bash
./src/utils/openg2p/setup-pbms-phee.sh
```

### Patches applied to `g2p_payment_phee`

The upstream `g2p_payment_phee` addon does not work out of the box against Gazelle's Payment Hub EE and Community-edition Odoo, so the setup script applies fixes after fetching the addon source and around the install:

- **Enterprise-only module stub.** Installing `g2p_payment_phee` transitively reloads Odoo core's `payment` module data, which references the Enterprise-only `base.module_payment_sepa_direct_debit` xmlid — this does not exist in Community edition and crashes the install. This is a long-standing Odoo core Community/Enterprise packaging inconsistency (unrelated to OpenG2P's own code — `g2p_payment_phee` and `g2p_programs` do not declare this dependency themselves), documented in Odoo core issues since v13/v14. There is no official Community-edition fix upstream, so the script creates a stub `ir.module.module` record named `payment_sepa_direct_debit` (state `uninstalled`, no functionality activated) plus its `ir.model.data` entry, satisfying the reference so the install proceeds. This is a recognized community workaround pattern for this class of problem, not something specific or fragile to Gazelle — though it compensates for Odoo core behavior rather than an OpenG2P-published fix, so it should be re-verified on future Odoo/OpenG2P version bumps.
- **`amount_issued` float→int cast.** `g2p_payment_phee`'s `payment_manager.py` (`prepare_csv_for_batch`) emits the payment batch's CSV row with `payment_id.amount_issued` as a float. PHEE's own CSV parser calls `parseInt` on that field, which throws on a float and silently zeroes the batch total. The script `sed`-patches the emission line to wrap it in `int(...)`. Applied before the module install (not after) so the single post-install Odoo restart reloads the patched source in the same step.
- **`batch_type_header` / `payee_id_type` config.** After install, the script sets `batch_type_header=csv` on any existing `g2p.program.payment.manager.phee` record — upstream's default value of `"type"` causes PHEE to respond 500 — and aligns `payee_id_type` to `phone`.

All patches are idempotent — safe to re-run against an already-patched deployment.

## Known Limitations

- **Keycloak is a hard dependency of `openg2p-commons`** and always deploys when OpenG2P is enabled — it is not a per-module toggle. PBMS's own login uses local Odoo auth and doesn't require it; Keycloak backs MinIO console SSO and is required if `social-registry`/`spar`/`g2p-bridge` are enabled.
- Resource footprint (Postgres + Keycloak + MinIO + per-module services) has not yet been tuned for low-resource targets (e.g. Raspberry Pi) the way the other three DPGs have been.
- The `g2p_payment_phee` Enterprise-module stub compensates for an Odoo-core artifact rather than an OpenG2P-published fix — re-verify it if the pinned Odoo/OpenG2P addon versions change.

## Troubleshooting

**A module never becomes ready / deploy warns "unready module(s)":**
```bash
kubectl get pods -n openg2p | grep -E '<module-name>'
kubectl describe pod <pod-name> -n openg2p
kubectl logs <pod-name> -n openg2p
```

**PBMS Odoo login fails after deploy** — re-run the admin fixup manually (idempotent):
```bash
kubectl exec -n openg2p <pbms-odoo-pod> -- bash -lc "odoo shell -c /etc/odoo/odoo.conf -d pbmsdb --no-http"
```

**A previously-failed Helm release blocks redeploy** — force it:
```bash
helm uninstall <release-name> -n openg2p --wait
./run.sh -m deploy -a openg2p
```
