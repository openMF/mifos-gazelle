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
- **Same BPMN pipeline**: bulk-processor → connector-bulk → `MastercardFundTransfer-{dfspid}` workflow
- **Same identity-account-mapper**: for payee MSISDN lookups and de-bulking by destination bank
- **Same tenants**: `greenbank` (or any payer tenant) submits with `--govstack` and `MASTERCARD_CBS` payment mode
- **Additional data requirement**: a `mastercard_cbs_supplementary_data` table holds the regulatory/KYC data that Mastercard CBS requires per payee (country, bank details, SWIFT code) — this is populated from the identity mapper during `setup-data`

The connector itself (`ph-ee-connector-mccbs`) is a Java Spring Boot service deployed via a **Kubernetes Operator** — meaning you declare the desired state in a `MastercardCBSConnector` Custom Resource and the operator manages the pod lifecycle, secrets, and data loading automatically.

---

## Prerequisites

- Payment Hub EE deployed and running
- **`setup-data` must run after `mastercard-demo`** — it populates the identity-account-mapper and then loads Mastercard supplementary data. See the deployment steps below.
- A Mastercard Developers portal account with a sandbox or production app (for real payments; demo mode works without fully encrypted payload)
- `~/ph-ee-connector-mccbs` present on the server (the connector source)

---

## Getting Started

### 1. Enable in `config/config.ini`

```ini
[mastercard-demo]
enabled = true
MASTERCARD_CBS_HOME = ~/ph-ee-connector-mccbs
MASTERCARD_API_URL  = https://sandbox.api.mastercard.com
# For real payments — get these from developer.mastercard.com:
MASTERCARD_PARTNER_ID           = <partner-id>
MASTERCARD_CONSUMER_KEY         = <consumer-key>
MASTERCARD_SIGNING_KEY_ALIAS    = <alias>
MASTERCARD_SIGNING_KEY_PASSWORD = <password>
MASTERCARD_SIGNING_KEY_PATH     = /path/to/signing.p12
# For local development with hostPath JAR mount:
MASTERCARD_LOCALDEV_ENABLED     = true
```

### 2. Deploy

**Option A — all in one step** (recommended): with `enabled = true` in `config/config.ini`, a single `run.sh` call deploys everything in the correct order, ending with `setup-data` which populates the identity mapper and loads Mastercard supplementary data:

```bash
./run.sh -m deploy -a all
```

**Option B — add to an existing deployment**: deploy the connector first, then run `setup-data` last to populate the identity mapper and load supplementary data:

```bash
# Deploy the Mastercard connector, operator, and BPMN workflows
./run.sh -m deploy -a mastercard-demo

# Load all data: Fineract clients, identity mapper, and Mastercard supplementary data
./run.sh -m deploy -a setup-data
```

> **`setup-data` must run after `mastercard-demo`**, not before. The supplementary data
> loader reads payee MSISDNs from the identity-account-mapper, which is populated by
> `setup-data`. Running them in this order ensures both tables are populated correctly.
>
> If you need to reload supplementary data manually (e.g. after regenerating data):
> ```bash
> bash src/utils/mastercard/load-mastercard-supplementary-data.sh
> ```

### 3. Submit a test batch

Mastercard CBS **requires `--govstack`**. This triggers the `bulk_processor_account_lookup-{tenant}` BPMN, which validates payees via the identity-account-mapper and de-bulks the batch by destination bank before handing off to the connector. Without it, the account lookup step is skipped and the connector cannot determine the payee's bank routing details.

```bash
cd src/utils/batch
./submit-batch.py \
  -f ../data-loading/bulk-gazelle-mastercard-6.csv \
  --tenant greenbank \
  --govstack \
  --debug
```

Expected output:
```
✓ Identity mapper: 6 beneficiaries found for 'greenbank'

WORKFLOW DETAILS
──────────────────────────────────────────────────
  Bulk-processor workflow : bulk_processor_account_lookup-greenbank
  Payment mode(s) in CSV  : MASTERCARD_CBS
  Submission mode         : GovStack — identity validation + de-bulking by payee FSP
──────────────────────────────────────────────────

Response Status: 202
✓ Batch submitted successfully!
```

### 4. Remove

```bash
./run.sh -m cleanapps -a mastercard-demo
```

---

## Verifying Successful Payments

### Operations Web UI

Partial batch and transfer details are available in the Payment Hub operations web UI at:

```
http://ops.<GAZELLE_DOMAIN>
```

where `GAZELLE_DOMAIN` is set in your `config/config.ini` (e.g. `http://ops.mifos.gazelle.test`). Note that transfer-level detail (Mastercard Payment IDs, SWIFT codes) is only visible via the connector logs and database queries below — the UI shows batch status and per-transfer status/amounts but not CBS-specific fields.

### Connector logs

```bash
kubectl logs -n mastercard-demo -l app=ph-ee-connector-mastercard-cbs --tail=100
```

A successful payment looks like:
```
✓ MASTERCARD CBS PAYMENT SUCCESS (XML Unencrypted)
  Transaction Reference : 408f5e43-5004-4c33-b979-e79a3fe9501f
  Mastercard Payment ID : rem_NgDyY0qkCvMJZwi-6XE0tq75Paw
  Status                : SUCCESS
  Amount                : 10.0 USD
  Beneficiary           : Scarlett Taylor
```

Each successful transfer has a real `Mastercard Payment ID` (`rem_...`) returned from the CBS API.

### Transfer records

```bash
MYSQL_PW=$(kubectl get secret -n paymenthub operationsmysql \
  -o jsonpath='{.data.mysql-root-password}' | base64 -d)

kubectl exec -n paymenthub operationsmysql-0 -- \
  env MYSQL_PWD="$MYSQL_PW" mysql -uroot \
  -e "SELECT transaction_id, status, status_detail, payee_party_id, amount, currency \
      FROM greenbank.transfers ORDER BY id DESC LIMIT 6\G"
```

Expected: `status: COMPLETED`, `status_detail: SUCCESS | Mastercard Payment ID: rem_...`

### Batch summary

```bash
MYSQL_PW=$(kubectl get secret -n paymenthub operationsmysql \
  -o jsonpath='{.data.mysql-root-password}' | base64 -d)

kubectl exec -n paymenthub operationsmysql-0 -- \
  env MYSQL_PWD="$MYSQL_PW" mysql -uroot greenbank \
  -e "SELECT batch_id, total_transactions, completed, failed, status \
      FROM batches ORDER BY id DESC LIMIT 3\G"
```

### Supplementary data check

```bash
MYSQL_PW=$(kubectl get secret -n paymenthub operationsmysql \
  -o jsonpath='{.data.mysql-root-password}' | base64 -d)

kubectl exec -n paymenthub operationsmysql-0 -- \
  env MYSQL_PWD="$MYSQL_PW" mysql -uroot \
  -e "SELECT account_number, beneficiary_name, bank_name, bank_swift_code, country \
      FROM operations.mastercard_cbs_supplementary_data"
```

---

## Payment Mode Configuration

To enable the `MASTERCARD_CBS` routing in the bulk-processor, the following entry must be present (it is added automatically when the connector is deployed via `run.sh`):

```yaml
# paymenthub-ee-bulk-processor application.yaml, or the shared ph-ee-config ConfigMap
# (src/deployer/operators/paymenthub/config/cr/00-configmap.yaml)
payment-modes:
  - id: "MASTERCARD_CBS"
    type: "BULK"
    endpoint: "bulk_connector_mastercard_cbs-{dfspid}"
```

> If using hostPath mounts (localdev mode), edit `~/paymenthub-ee-bulk-processor/src/main/resources/application.yaml`, rebuild the JAR, and restart the pod.

---

## Data Loading

**Supplementary data** (Mastercard regulatory/KYC fields per payee) is loaded automatically as part of `setup-data`. To reload manually after data has been regenerated:

```bash
bash src/utils/mastercard/load-mastercard-supplementary-data.sh
```

**Sample CSV** generation:
```bash
python3 src/utils/data-loading/generate-example-csv-files.py \
  --mode mastercard --num-rows 6 \
  --output-dir src/utils/data-loading
```

---

## Comparison: Mastercard CBS vs Other Payment Modes

| | CLOSEDLOOP | MOJALOOP | MASTERCARD_CBS |
|--|-----------|----------|----------------|
| **Switch** | None | Mojaloop vNext | Mastercard CBS API |
| **Scope** | Same PH instance | Inter-FSP domestic | Cross-border |
| **Payee lookup** | identity-account-mapper | vNext oracle | identity-account-mapper + supplementary data |
| **`--govstack` required** | Optional | Optional | **Yes** |
| **Credentials needed** | None | None | Mastercard developer account |
| **Typical use** | Testing | Domestic G2P | Cross-border G2P |

---

## Further Reading

- **[Operator Deployment Guide](OPERATOR_DEPLOYMENT_GUIDE.md)** — full config.ini reference, CR spec, operator lifecycle, monitoring, and troubleshooting
- **[GovStack Architecture](../GOVSTACK.md)** — how G2P bulk disbursement works end-to-end
- **[Local Development](../LOCALDEV.md)** — iterating on connector code with hostPath mounts
