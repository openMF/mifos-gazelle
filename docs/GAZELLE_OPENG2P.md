# OpenG2P

## What It Is

[OpenG2P](https://openg2p.org/) is a Digital Public Good for Government-to-Person (G2P) payment programmes — beneficiary registration, payment batch management, and program-to-payment-rail bridging. Mifos Gazelle deploys it as its own app (`-a openg2p`), independent of MifosX, Payment Hub EE, and vNext.

Each OpenG2P module is installed as its own Helm release in the `openg2p` namespace so subchart-generated object names never collide across modules.

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

Deploy order (`deploy_openg2p()` in `src/deployer/openg2p.sh`): namespace + TLS → prerequisite CRDs (Istio networking, optional operator CRDs — installed so upstream chart objects apply harmlessly; Gazelle routes traffic via NGINX instead) → **commons** (must be healthy — an unhealthy commons aborts the OpenG2P deploy) → enabled modules in fixed order `social-registry` → `pbms` → `spar` → `g2p-bridge`. A module that fails to become ready is recorded and skipped; it does not block the rest, and failures are summarized at the end of the run.

Once PBMS is up, Gazelle enables the `g2p_payment_phee` Odoo addon (`src/utils/openg2p/setup-pbms-phee.sh`) so PBMS can issue payment batches to **Payment Hub EE**.

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


---

## PBMS ↔ Payment Hub EE Connector

After PBMS becomes ready, `src/utils/openg2p/setup-pbms-phee.sh` idempotently enables the `g2p_payment_phee` Odoo addon so PBMS can issue payment batches to Payment Hub EE:

- Fetches the `openg2p-registry` and `openg2p-program` addon repos into the PBMS pod
- Patches `payment_manager.py` so `amount_issued` is cast to `int` (PHEE's parser otherwise throws on a float and silently zeroes the batch total)
- Stubs an Enterprise-only module reference that `g2p_programs` needs but Community edition lacks
- Sets `batch_type_header=csv` on the PHEE payment manager

This step is non-fatal — a failure logs a warning and the script can be re-run manually:

```bash
./src/utils/openg2p/setup-pbms-phee.sh
```


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
