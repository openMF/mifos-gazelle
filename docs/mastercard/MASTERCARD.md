# Mastercard CBS Connector

## What It Is

The Mastercard CBS connector is an optional enhancement to **Payment Hub EE** that adds cross-border payment capability via the [Mastercard Cross-Border Solutions (CBS)](https://developer.mastercard.com) API.

Without it, Payment Hub EE can route bulk G2P disbursements either through the **Mojaloop vNext switch** or as **closedloop** transfers within the same Payment Hub instance. The Mastercard CBS connector adds a third path: bulk payments that settle across borders via Mastercard's payment rails, enabling government programmes to disburse to beneficiaries whose financial institutions participate in Mastercard's network.

---

## How It Fits into Mifos Gazelle

```
┌─────────────────────────────────────────────────────────┐
│  Mifos Gazelle — Payment Hub EE                         │
│                                                         │
│  submit-batch.py ──► bulk-processor ──► connector-bulk  │
│                                               │         │
│                    ┌──────────────────────────┤         │
│                    │              │            │        |
│         payment_mode=   payment_mode=  payment_mode=    │
│          CLOSEDLOOP      MOJALOOP    MASTERCARD_CBS     │
│                    │              │            │        │
│                    ▼              ▼            ▼        │
│            connector-channel  connector-  connector-    │
│            (same instance)    mojaloop      mccbs       │
│                    │              │            │        │
└────────────────────┼──────────────┼────────────┼─────────┘
                     ▼              ▼            ▼
                (direct debit) Mojaloop vNext  Mastercard
                               Switch          CBS API
```

The connector sits alongside the existing Mojaloop and closedloop connectors. It shares the same infrastructure:
- **Same BPMN pipeline**: bulk-processor → connector-bulk → connector-channel → `MastercardFundTransfer-{dfspid}` workflow
- **Same identity-account-mapper**: for payee MSISDN lookups
- **Same tenants**: `greenbank` (or any payer tenant) can use `MASTERCARD_CBS` payment mode
- **Additional data requirement**: a `mastercard_cbs_supplementary_data` table holds the regulatory/KYC data that Mastercard CBS requires per payee (country, bank details, etc.) — this is loaded automatically during deployment

The connector itself (`ph-ee-connector-mccbs`) is a Java Spring Boot service deployed via a **Kubernetes Operator** — meaning you declare the desired state in a `MastercardCBSConnector` Custom Resource and the operator manages the pod lifecycle, secrets, and data loading automatically.

---

## Prerequisites

- Payment Hub EE deployed and running (`sudo ./run.sh -u $USER -m deploy -a phee`)
- A Mastercard Developers portal account with a sandbox or production app (for real payments; demo mode works without valid credentials)
- `~/ph-ee-connector-mccbs` present on the server (the connector source / Docker image)

---

## Getting Started

### 1. Enable in `config/config.ini`

```ini
[mastercard-demo]
enabled = true
MASTERCARD_CBS_HOME = ~/ph-ee-connector-mccbs
MASTERCARD_API_URL  = https://sandbox.api.mastercard.com
# For real payments — get these from developer.mastercard.com:
MASTERCARD_PARTNER_ID          = <partner-id>
MASTERCARD_CONSUMER_KEY        = <consumer-key>
MASTERCARD_SIGNING_KEY_ALIAS   = <alias>
MASTERCARD_SIGNING_KEY_PASSWORD = <password>
MASTERCARD_SIGNING_KEY_PATH    = /path/to/signing.p12
```

### 2. Deploy

```bash
# Deploy Mastercard connector alongside everything else
sudo ./run.sh -u $USER -m deploy -a all

# Or add it to an existing running Gazelle deployment
sudo ./run.sh -u $USER -m deploy -a mastercard-demo
```

This deploys the CRD, operator, connector pod, BPMN workflows, and loads supplementary data. A sample 6-row CSV is generated at `src/utils/data-loading/bulk-gazelle-mastercard-6.csv`.

### 3. Test a payment

```bash
cd src/utils/batch
./submit-batch.py \
  -c ~/config/config.ini \
  -f ../data-loading/bulk-gazelle-mastercard-6.csv \
  --tenant greenbank
```

Monitor the connector:
```bash
kubectl logs -n mastercard-demo -l app=ph-ee-connector-mastercard-cbs -f
```

### 4. Remove

```bash
sudo ./run.sh -u $USER -m cleanapps -a mastercard-demo
```

---

## Payment Mode Configuration

To enable the `MASTERCARD_CBS` routing in the bulk-processor, the following entry must be present (it is added automatically when the connector is deployed via `run.sh`):

```yaml
# ph-ee-bulk-processor application.yaml or config/ph_values.yaml
payment-modes:
  - id: "MASTERCARD_CBS"
    type: "BULK"
    endpoint: "bulk_connector_mastercard_cbs-{dfspid}"
```

> If using hostPath mounts (localdev mode), edit `~/ph-ee-bulk-processor/src/main/resources/application.yaml`, rebuild the JAR, and restart the pod.

---

## Data Loading

**Supplementary data** (Mastercard regulatory/KYC fields per payee) is loaded automatically during deployment. To reload manually:

```bash
bash src/utils/mastercard/load-mastercard-supplementary-data.sh -c config/config.ini
```

**Sample CSV** generation:
```bash
python3 src/utils/data-loading/generate-example-csv-files.py \
  -c config/config.ini --mode mastercard --num-rows 6 \
  --output-dir src/utils/data-loading
```

---

## Comparison: Mastercard CBS vs Other Payment Modes

| | CLOSEDLOOP | MOJALOOP | MASTERCARD_CBS |
|--|-----------|----------|----------------|
| **Switch** | None | Mojaloop vNext | Mastercard CBS API |
| **Scope** | Same PH instance | Inter-FSP domestic | Cross-border |
| **Payee lookup** | identity-account-mapper | vNext oracle | identity-account-mapper + supplementary data |
| **Credentials needed** | None | None | Mastercard developer account |
| **Typical use** | Testing | Domestic G2P | Cross-border G2P |

---

## Further Reading

- **[Operator Deployment Guide](OPERATOR_DEPLOYMENT_GUIDE.md)** — full config.ini reference, CR spec, operator lifecycle, monitoring, and troubleshooting
- **[GovStack Architecture](../GOVSTACK.md)** — how G2P bulk disbursement works end-to-end
- **[Local Development](../LOCALDEV.md)** — iterating on connector code with hostPath mounts
