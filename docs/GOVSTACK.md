# GovStack G2P Bulk Disbursement Architecture

## Document Purpose

This document explains the GovStack Government-to-Person (G2P) bulk disbursement architecture as implemented in mifos-gazelle, based on the official GovStack specification and the actual codebase implementation.

**Key References:**
- GovStack Spec: `/home/tdaly/my-mac-dir/tmp/bulk-disburesement.pdf`
- Implementation: Payment Hub EE (PHEE) components in this repository

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Understanding Payment Modes and Tenants](#understanding-payment-modes-and-tenants)
3. [How GovStack Mode Works](#how-govstack-mode-works)
4. [Payer Account Configuration](#payer-account-configuration)
5. [Component Details](#component-details)
6. [Tenant Configuration](#tenant-configuration)
7. [Workflow Comparison](#workflow-comparison)
8. [How to Run G2P Successfully](#how-to-run-g2p-successfully)
9. [Troubleshooting](#troubleshooting)

---

## Architecture Overview

### GovStack Specification Architecture

According to the official GovStack spec (pages 9-13), the architecture for G2P bulk disbursement is:

```
┌────────────────────────────────────────────────────────┐
│  GOVERNMENT ENTITY (e.g., Social Welfare Ministry)     │
│  - Treasury Single Account (TSA)                       │
│  - Registration Building Block (beneficiary lists)     │
└──────────────────┬─────────────────────────────────────┘
                   │
                   │ (2) Bulk Payment Batch
                   │ (RegisteringInstID, ProgramID, CSV)
                   ▼
┌────────────────────────────────────────────────────────┐
│  PAYMENTS BUILDING BLOCK (Payment Hub)                 │
│  ┌──────────────────────────────────────────────────┐  │
│  │  Account Mapper (Identity Account Mapper)        │  │
│  │  - Pre-validates beneficiaries                   │  │
│  │  - Identifies payee FSPs                         │  │
│  │  - Returns bankingInstitutionCode                │  │
│  └──────────────────────────────────────────────────┘  │
│  ┌──────────────────────────────────────────────────┐  │
│  │  Bulk Processor                                   │  │
│  │  - De-bulks by receiving institution             │  │
│  │  - Creates sub-batches per payee FSP             │  │
│  └──────────────────────────────────────────────────┘  │
└──────────────────┬─────────────────────────────────────┘
                   │
                   │ (3) De-bulked Sub-batches
                   │ (grouped by Payee FSP)
                   ▼
┌────────────────────────────────────────────────────────┐
│  PAYER FSP (Payer Bank - e.g., greenbank/redbank)     │
│  - Holds government settlement account                 │
│  - Participant in payment switch/scheme                │
└──────────────────┬─────────────────────────────────────┘
                   │
                   │ (4) Clearing Instructions
                   │ (per scheme rules)
                   ▼
┌────────────────────────────────────────────────────────┐
│  PAYMENT SWITCH / SCHEME (Switch-Agnostic)             │
│  - Routes to destination FSPs                          │
│  - Handles settlement                                  │
│  - Could be: Mojaloop vNext, GSMA, National Switch,   │
│    Bilateral, or Direct (closedloop)                   │
└──────────────────┬─────────────────────────────────────┘
                   │
                   │ (5) Individual Credits
          ┌────────┴────────┬────────────────┐
          ▼                 ▼                ▼
    ┌──────────┐      ┌──────────┐    ┌──────────┐
    │ Payee    │      │ Payee    │    │ Payee    │
    │ FSP 1    │      │ FSP 2    │    │ FSP 3    │
    │(bluebank)│      │(redbank) │    │(momo)    │
    └──────────┘      └──────────┘    └──────────┘
```

**Key Principle from GovStack Spec (Page 12-13):**
> "Payments Building Block does not interface directly with the Payment Switch. Payments Building Block interfaces with the Switch/Scheme through a Participant of the Switch/Scheme. The Payer forwards all instructions to the Scheme/Switch."

**CRITICAL:** The GovStack spec does NOT mandate Mojaloop - it is switch-agnostic. The spec only requires:
1. Identity/Account Mapper for validation
2. Batch de-bulking by payee FSP
3. Payer FSP as intermediary to switch
4. Switch type is implementation-specific

---

## Understanding Payment Modes and Tenants

### Tenant Architecture

In mifos-gazelle, we configure three tenant roles:

| Tenant | Role | Database | Use Case |
|--------|------|----------|----------|
| **greenbank** | Payer (Mojaloop) | greenbank schema | Government/payer using Mojaloop switch |
| **redbank** | Payer (Closedloop) | redbank schema | Government/payer using direct transfers |
| **bluebank** | Payee FSP | bluebank schema | Beneficiary financial institution |

**Key Point:** The tenant you specify when submitting a batch (`--tenant`) determines which **payer** workflows are used, not the switch type.

### Payment Modes in CSV

The `payment_mode` column in the batch CSV determines the **routing mechanism**:

| Payment Mode | Routing | Switch Involved? | Use Case |
|--------------|---------|------------------|----------|
| `CLOSEDLOOP` | Direct connector-bulk → connector-channel | NO | Internal transfers, same Payment Hub instance |
| `MOJALOOP` | Via Mojaloop vNext switch | YES | Inter-FSP transfers via Mojaloop |
| `GSMA` | Via GSMA mobile money connector | Depends | Mobile money providers |

**Critical Understanding:**
- `CLOSEDLOOP` is a routing method, NOT the same as "non-GovStack"
- `CLOSEDLOOP` can be used WITH GovStack identity validation
- `MOJALOOP` can be used WITHOUT GovStack identity validation
- These are independent concerns

### How Payment Mode Affects Routing

**Location:** [ph-ee-connector-bulk/.../BatchTransferWorker.java:123-139](../ph-ee-connector-bulk/src/main/java/org/mifos/connector/phee/zeebe/workers/implementation/BatchTransferWorker.java#L123-L139)

```java
if("closedloop".equalsIgnoreCase(paymentMode)){
    // Direct HTTP call to connector-channel
    boolean success = processClosedloopTransfers(transactionList, batchId, debulkingDfspId);
}
else{
    // Create recursive batch back to bulk-processor (e.g., for Mojaloop)
    String batchId = invokeBatchTransactionApi(fileName, updatedCsvData, ...);
}
```

---

## How GovStack Mode Works

### GovStack "Mode" is Header-Driven

**Important:** There is no `govstack.enabled` configuration flag. "GovStack mode" is triggered at runtime by the presence of HTTP headers in the batch submission request. The `--govstack` flag in `submit-batch.py` simply causes those headers to be sent.

**The triggering header:**
```
X-Registering-Institution-ID: greenbank
```

When this header is present, the bulk-processor:
1. Uses the `bulk_processor_account_lookup-{tenant}` BPMN workflow (configured in `bpmns.tenants`)
2. Calls identity-account-mapper to validate all beneficiaries
3. De-bulks the batch by `bankingInstitutionCode` (payee FSP)
4. Looks up the payer account from `budget-account` YAML config (if `X-Program-ID` also present)

Without this header, the `bulk_processor-{tenant}` workflow runs and payer/payee values come from the CSV.

**Code reference:** `ph-ee-bulk-processor/.../ProcessorStartRouteService.java:168-173`
```java
if (!(StringUtils.hasText(registeringInstituteId) && StringUtils.hasText(programId))) {
    // Headers missing — use CSV payer values as-is
    exchange.setProperty(IS_UPDATED, false);
    return;
}
// Headers present — look up payer from budget-account configuration
```

### Two BPMN Workflows

Both workflows are deployed at startup and selected at runtime:

| Workflow | Process ID | Triggered When | Key Tasks |
|----------|-----------|----------------|-----------|
| **Standard** | `bulk_processor-{tenant}` | No GovStack headers | `partyLookup`, `deduplicate` |
| **GovStack** | `bulk_processor_account_lookup-{tenant}` | `X-Registering-Institution-ID` present | `batchAccountLookup`, `batchAccountLookupCallback` |

**File locations:**
- Standard: `orchestration/feel/bulk_processor-DFSPID.bpmn`
- GovStack: `orchestration/feel/bulk_processor_account_lookup-DFSPID.bpmn`

**Configuring which workflow a tenant uses** (in `ph-ee-bulk-processor/src/main/resources/application.yaml`):
```yaml
bpmns:
  tenants:
    - id: "greenbank"
      flows:
        batch-transactions: "bulk_processor_account_lookup-{dfspid}"  # GovStack
        # batch-transactions: "bulk_processor-{dfspid}"              # Standard
```

### Payer vs Payee: Different Sources

| Aspect | Payer (Government/Program) | Payee (Beneficiary/Citizen) |
|--------|---------------------------|----------------------------|
| **Source** | `budget-account` config in `application.yaml` (GovStack mode) OR CSV columns (standard mode) | `identity_account_mapper` database |
| **Lookup Key** | `X-Registering-Institution-ID` + `X-Program-ID` headers | `payeeIdentity` + `registeringInstitutionId` |
| **Auto-discoverable?** | No — must be in CSV or configured | Yes — MSISDN → account via mapper |
| **Changes require restart?** | Yes (config change → JAR rebuild) | No (live DB updates) |

**identity-account-mapper is used ONLY for payee (beneficiary) lookups, never for payer.**

### Valid Combinations

| `--govstack` | `payment_mode` | `--tenant` | Bulk Workflow | Payment Workflow | Use Case |
|-------------|--------------|-----------|--------------|----------------|---------|
| NO | CLOSEDLOOP | redbank | bulk_processor | minimal_mock_fund_transfer | Simple testing |
| NO | MOJALOOP | greenbank | bulk_processor | PayerFundTransfer | Multi-FSP via switch |
| YES | CLOSEDLOOP | redbank | bulk_processor_account_lookup | minimal_mock_fund_transfer | G2P validation, no switch |
| **YES** | **MOJALOOP** | **greenbank** | **bulk_processor_account_lookup** | **PayerFundTransfer** | **TRUE GOVSTACK — recommended** |

---

## Payer Account Configuration

In GovStack mode with `X-Program-ID` header, the payer bank account is looked up from a static YAML configuration (not the database). This removes the need for payer details in the CSV.

### Configuration

**File:** `ph-ee-bulk-processor/src/main/resources/application.yaml`

```yaml
budget-account:
  registeringInstitutions:
    - id: "greenbank"                       # matches X-Registering-Institution-ID header
      programs:
        - id: "SocialWelfare"              # matches X-Program-ID header
          name: "Social Welfare Program"
          identifierType: "ACCOUNT"        # ACCOUNT, MSISDN, etc.
          identifierValue: "1"             # Fineract account number for payer
```

**Header → config mapping:**

| HTTP Header | Config Field | Effect |
|-------------|-------------|--------|
| `X-Registering-Institution-ID: greenbank` | `registeringInstitutions[].id` | Selects institution |
| `X-Program-ID: SocialWelfare` | `programs[].id` | Selects program within institution |

When both headers match, `identifierValue` (e.g., `"1"`) is used as the payer account. Any payer columns in the CSV are **overwritten** with this value.

**Multiple programs example:**
```yaml
budget-account:
  registeringInstitutions:
    - id: "greenbank"
      programs:
        - id: "SocialWelfare"
          name: "Social Welfare Program"
          identifierType: "ACCOUNT"
          identifierValue: "1"       # Greenbank account #1

        - id: "ChildBenefit"
          name: "Child Benefit Program"
          identifierType: "ACCOUNT"
          identifierValue: "2"       # Greenbank account #2
```

### How to Find Your Payer Account Number

**Via MifosX web client:**
1. Open `http://mifos.mifos.gazelle.test`, select tenant `greenbank`
2. Navigate to the government program client → Savings Accounts
3. Note the Account No (use this as `identifierValue`)

**Via database:**
```bash
kubectl exec -n infra mysql-0 -- mysql -umifos -ppassword \
  -D mifostenant-greenbank \
  -e "SELECT id, account_no, display_name FROM m_savings_account LIMIT 10;"
```

### CSV Format in GovStack Mode

When `X-Program-ID` is supplied (payer from config), payer columns are optional:

```csv
id,request_id,payment_mode,payee_identifier_type,payee_identifier,amount,currency,note,account_number
0,uuid1,mojaloop,MSISDN,0495822412,250,USD,Sept welfare,1
1,uuid2,mojaloop,MSISDN,0495822413,250,USD,Sept welfare,2
```

When `X-Program-ID` is NOT supplied (standard mode or GovStack without budget-account lookup), payer columns are required:

```csv
id,request_id,payment_mode,payer_identifier_type,payer_identifier,payee_identifier_type,payee_identifier,amount,currency,note,account_number
0,uuid1,mojaloop,MSISDN,0413356886,MSISDN,0495822412,250,USD,Sept welfare,1
```

Note: In standard mode, the CSV has `payer_identifier` (phone number) but no payer DFSP column. The `Platform-TenantId` header determines the payer's FSP (e.g., `Platform-TenantId: greenbank` → payer is at greenbank).

---

## Component Details

### 1. Identity Account Mapper

**Purpose (GovStack spec page 7):**
> "The account mapper service identifies the FSP, and exact destination address where the payee's account is used to route payouts to beneficiaries."

**Database:** `identity_account_mapper`

**API:** `POST /api/v1/identity-account-mapper/batch-account-lookup`

**Request:**
```json
{
  "requestID": "batch-001",
  "registeringInstitutionID": "greenbank",
  "beneficiaries": [
    {
      "payeeIdentity": "0495822412",
      "paymentModality": "00"
    }
  ]
}
```

**Response (to callback URL):**
```json
{
  "requestID": "batch-001",
  "registeringInstitutionID": "greenbank",
  "beneficiaries": [
    {
      "payeeIdentity": "0495822412",
      "paymentModality": "00",
      "financialAddress": "000000001",
      "bankingInstitutionCode": "bluebank"
    }
  ]
}
```

- `bankingInstitutionCode` identifies which FSP serves this beneficiary (used for de-bulking)
- `financialAddress` is for reconciliation, not party lookup

### 2. Batch De-bulking (GovStack Requirement)

**Location:** [ph-ee-bulk-processor/.../SplittingRoute.java:74-109](../ph-ee-bulk-processor/src/main/java/org/mifos/processor/bulk/camel/routes/SplittingRoute.java#L74-L109)

**How it works:**
- Original batch: 10 transactions to 3 different FSPs
- After de-bulking: 3 sub-batches (1 per FSP), each processed independently
- Grouping key: `bankingInstitutionCode` from identity-account-mapper response

Enabled when both `isPartyLookupEnabled` and `isBatchAccountLookupEnabled` are true in the GovStack workflow.

### 3. Mojaloop vNext Switch (Optional)

**GovStack does NOT mandate Mojaloop** - any switch/scheme can be used.

**Oracle Registration:**
```
MSISDN: 0495822412 → fspId: "bluebank", currency: "USD"
```

**How Routing Works:**
1. Payer FSP sends transfer request with MSISDN to switch
2. Switch queries oracle: "Which FSP owns this MSISDN?"
3. Oracle responds with FSP ID
4. Switch routes transfer to that FSP's callback URL

### 4. The debulkingDfspid Configuration

**Location:** `ph-ee-bulk-processor/src/main/resources/application.yaml`

```yaml
payment-modes:
  - id: "CLOSEDLOOP"
    type: "BULK"
    endpoint: "bulk_connector_{MODE}-{dfspid}"
    # debulkingDfspid: "greenbank"  # ❌ DO NOT hardcode
```

- When `debulkingDfspid` is null, the submitting tenant is used (correct behavior)
- Hardcoding this causes ALL closedloop batches to use the same tenant workflows

**Code reference:** `ph-ee-bulk-processor/.../InitSubBatchRoute.java:128`
```java
variables.put(DEBULKINGDFSPID,
    mapping.getDebulkingDfspid() == null ? tenantName : mapping.getDebulkingDfspid());
```

---

## Tenant Configuration

### Critical: Multi-Component Tenant Configuration

Tenant workflows must be configured in BOTH bulk-processor AND channel-connector.

### Bulk-Processor Configuration

**File:** `ph-ee-bulk-processor/src/main/resources/application.yaml`

Uses `@ConfigurationProperties` — reads YAML, NOT .properties files.

```yaml
# Tenant list
tenants: "greenbank, bluebank, redbank"

# Workflow mapping per tenant
bpmns:
  tenants:
    - id: "greenbank"
      flows:
        payment-transfer: "minimal_mock_fund_transfer-{dfspid}"
        batch-transactions: "bulk_processor-{dfspid}"           # Standard
        # batch-transactions: "bulk_processor_account_lookup-{dfspid}"  # GovStack
    - id: "redbank"
      flows:
        payment-transfer: "minimal_mock_fund_transfer-{dfspid}"
        batch-transactions: "bulk_processor-{dfspid}"
    - id: "bluebank"
      flows:
        batch-transactions: "bulk_processor-{dfspid}"
```

### Connector-Channel Configuration

**File:** `ph-ee-connector-channel/src/main/resources/application.yml`

```yaml
bpmns:
  tenants:
    - id: "greenbank"
      flows:
        payment-transfer: "PayerFundTransfer-{dfspid}"
        outbound-transfer-request: "{ps}_flow_{ams}-{dfspid}"
    - id: "redbank"
      flows:
        payment-transfer: "minimal_mock_fund_transfer-{dfspid}"
        outbound-transfer-request: "minimal_mock_transfer_request-{dfspid}"
    - id: "bluebank"
      flows:
        payment-transfer: "minimal_mock_fund_transfer-{dfspid}"
        outbound-transfer-request: "minimal_mock_transfer_request-{dfspid}"
```

**Key Point:** The `payment-transfer` workflow is determined by the **payer tenant**, not the `payment_mode` in the CSV.

**Workflow selection logic:** `ph-ee-connector-channel/.../ChannelRouteBuilder.java:304-367`
```java
String tenantId = exchange.getIn().getHeader("Platform-TenantId", String.class);
// tenantId="greenbank" → "PayerFundTransfer-greenbank"
// tenantId="redbank" → "minimal_mock_fund_transfer-redbank"
```

### Helm Template Configuration (For Reference)

**File:** `repos/ph_template/helm/gazelle/config/application-tenants.properties`

Used by Helm at deploy time. When using hostPath mounts (local dev), changes must be made to the source YAML files above, not this file.

### Applying Configuration Changes (hostPath Mounts)

```bash
# 1. Edit source YAML files
nano ~/ph-ee-bulk-processor/src/main/resources/application.yaml
nano ~/ph-ee-connector-channel/src/main/resources/application.yml

# 2. Rebuild JARs
cd ~/ph-ee-bulk-processor && ./gradlew clean build -x test
cd ~/ph-ee-connector-channel && ./gradlew clean build -x test

# 3. Restart pods
kubectl delete pod -n paymenthub -l app=ph-ee-bulk-processor
kubectl delete pod -n paymenthub -l app=ph-ee-connector-channel
```

ConfigMap updates alone do NOT work with hostPath mounts.

---

## Workflow Comparison

### PayerFundTransfer-{dfspid} (Mojaloop Switch Routing)

**Used by:** greenbank tenant

**Flow:**
1. Payee User Lookup — Query switch for payee FSP
2. Local Quote — Calculate payer FSP quote
3. Payee Quote — Get quote from payee FSP via switch
4. Payer Block Funds — Reserve funds in payer account
5. Send transfer request — POST to Mojaloop switch `/transfers`
6. Payer Book Funds — Commit/rollback based on response

### minimal_mock_fund_transfer-{dfspid} (Development/Closedloop)

**Used by:** redbank tenant (payer), bluebank tenant (payee)

**Flow:**
1. mockPayeeLookup — Simulate party lookup
2. mockInitiateTransfer — Simulate transfer (no actual Fineract call)
3. mockPayeeAccountStatus — Return success

**Purpose:** Development/testing without full Fineract integration.

---

## How to Run G2P Successfully

### submit-batch.py Flags

```bash
./src/utils/data-loading/submit-batch.py \
  -c ~/tomconfig.ini \
  -f <csv-file> \
  --tenant <greenbank|redbank|bluebank> \
  [--govstack] \
  [--registering-institution <id>]  \   # auto-detected from CSV if omitted
  [--program <program-id>]          \   # sends X-Program-ID for budget-account lookup
  [--debug]                             # shows BPMN workflow and payment modes before submit
```

**Decision table:**

| Use case | `--tenant` | `--govstack` | `payment_mode` |
|----------|-----------|-------------|----------------|
| Simple internal test | redbank | NO | CLOSEDLOOP |
| Multi-FSP via Mojaloop | greenbank | NO | MOJALOOP |
| G2P bulk disbursement (recommended) | greenbank | YES | MOJALOOP |
| G2P closedloop (same PH instance only) | redbank | YES | CLOSEDLOOP |

### Option 1: Standard Mode (Simple Testing)

```bash
# Generate CSVs from current Mifos client data
./src/utils/data-loading/generate-example-csv-files.py -c ~/tomconfig.ini

# Closedloop — redbank payer, no identity validation
./src/utils/data-loading/submit-batch.py \
  -c ~/tomconfig.ini \
  -f ./src/utils/data-loading/bulk-gazelle-closedloop-4.csv \
  --tenant redbank

# Mojaloop — greenbank payer, no identity validation
./src/utils/data-loading/submit-batch.py \
  -c ~/tomconfig.ini \
  -f ./src/utils/data-loading/bulk-gazelle-mojaloop-4.csv \
  --tenant greenbank
```

### Option 2: GovStack Mode with Mojaloop (Production-Ready)

**Prerequisites:**
```bash
# Ensure identity-account-mapper has beneficiaries
./src/utils/data-loading/generate-mifos-vnext-data.py --regenerate

# Verify registrations
kubectl exec -n infra mysql-0 -- mysql -umifos -ppassword identity_account_mapper -e \
  "SELECT id.payee_identity, pmd.institution_code
   FROM identity_details id
   JOIN payment_modality_details pmd ON id.payment_modality_id = pmd.id
   WHERE id.registering_institution_id = 'greenbank'
   LIMIT 5"
```

**Configure greenbank for GovStack workflow** (in `~/ph-ee-bulk-processor/src/main/resources/application.yaml`):
```yaml
bpmns:
  tenants:
    - id: "greenbank"
      flows:
        batch-transactions: "bulk_processor_account_lookup-{dfspid}"
```
Rebuild JAR and restart pod after this change.

**Submit:**
```bash
# --registering-institution is auto-detected from CSV payees
./src/utils/data-loading/submit-batch.py \
  -c ~/tomconfig.ini \
  -f ./src/utils/data-loading/bulk-gazelle-mojaloop-4.csv \
  --tenant greenbank \
  --govstack

# With budget-account payer lookup (requires budget-account config in application.yaml)
./src/utils/data-loading/submit-batch.py \
  -c ~/tomconfig.ini \
  -f ./src/utils/data-loading/bulk-gazelle-mojaloop-4.csv \
  --tenant greenbank \
  --govstack \
  --program SocialWelfare

# Debug mode — shows workflow name, payment modes, institution detection
./src/utils/data-loading/submit-batch.py \
  -c ~/tomconfig.ini \
  -f ./src/utils/data-loading/bulk-gazelle-mojaloop-4.csv \
  --tenant greenbank \
  --govstack \
  --debug
```

**Expected Flow:**
1. `--registering-institution` auto-detected from CSV payee MSISDNs via identity-account-mapper DB
2. Identity mapper validates all beneficiaries
3. Returns `bankingInstitutionCode` for each (e.g., "bluebank")
4. Batch de-bulked by payee FSP
5. Sub-batches sent to greenbank's PayerFundTransfer workflow
6. Transfers go via Mojaloop switch
7. Switch routes to destination FSPs

### Option 3: GovStack Mode with Closedloop (Limited)

```yaml
# Configure redbank for GovStack workflow
bpmns:
  tenants:
    - id: "redbank"
      flows:
        batch-transactions: "bulk_processor_account_lookup-{dfspid}"
```

```bash
./src/utils/data-loading/submit-batch.py \
  -c ~/tomconfig.ini \
  -f ./src/utils/data-loading/bulk-gazelle-closedloop-4.csv \
  --tenant redbank \
  --govstack
```

**Limitations:** All beneficiaries must be in the same Payment Hub instance. De-bulking occurs but all sub-batches go to the same system.

---

## Troubleshooting

### Diagnostic Commands

```bash
# Check batch status
kubectl exec -n paymenthub operationsmysql-0 -- mysql -uroot -pmysql operations_app -e \
  "SELECT batch_id, total, successful, failed, ongoing FROM batch ORDER BY id DESC LIMIT 3"

# Check transfer details with FSP mapping
kubectl exec -n paymenthub operationsmysql-0 -- mysql -uroot -pmysql operations_app -e \
  "SELECT id, batch_id, payee_identifier, payee_dfsp_id, status
   FROM transfers ORDER BY id DESC LIMIT 5"

# Check bulk-processor logs for de-bulking
kubectl logs -n paymenthub -l app=ph-ee-bulk-processor --tail=100 | grep -i splitting

# Check which workflow was used
kubectl logs -n paymenthub -l app=ph-ee-connector-channel --tail=100 | grep -i "starting workflow"

# Verify identity mapper was called (--govstack submissions)
kubectl logs -n paymenthub -l app=ph-ee-identity-account-mapper --tail=50

# Verify identity mapper has entries for your institution
kubectl exec -n infra mysql-0 -- mysql -umifos -ppassword identity_account_mapper -e \
  "SELECT COUNT(*) FROM identity_details WHERE registering_institution_id = 'greenbank'"
```

### Common Issues

| Symptom | Likely Cause | Solution |
|---------|--------------|----------|
| Batch total = 0 | Identity mapper empty for this institution | Run `generate-mifos-vnext-data.py --regenerate` or submit without `--govstack` |
| All transactions same FSP | Missing vNext oracle registration | Run `generate-mifos-vnext-data.py --regenerate` |
| No sub-batches created | Using `bulk_processor` instead of `bulk_processor_account_lookup` workflow | Check `batch-transactions` config in bulk-processor application.yaml |
| Wrong workflow triggered | Wrong `--tenant` | Verify tenant matches your CSV (redbank for closedloop, greenbank for mojaloop) |
| Auto-detection fails | Payees not in identity-account-mapper | Pass `--registering-institution` explicitly; check mapper has data |
| "No registering institution found for id: X" | `budget-account.registeringInstitutions.id` doesn't match header | Check YAML config matches `X-Registering-Institution-ID` value exactly |

### Tenant Configuration Issues

| Symptom | Likely Cause | Solution |
|---------|--------------|----------|
| "Process definition not found" (412 error) | Tenant missing from `bpmns.tenants[]` in bulk-processor | Add tenant to `~/ph-ee-bulk-processor/src/main/resources/application.yaml`, rebuild JAR |
| PARTY_NOT_FOUND errors | Tenant missing from channel-connector config | Add tenant to `~/ph-ee-connector-channel/src/main/resources/application.yml`, rebuild JAR |
| Wrong workflow triggered despite correct tenant | Hardcoded `debulkingDfspid` in payment-mode config | Remove `debulkingDfspid` from CLOSEDLOOP payment-mode in bulk-processor application.yaml |
| Changes not taking effect | Using hostPath mounts | Rebuild JAR files and restart pods after config changes |
| Payer account wrong after config change | Pod not restarted | `kubectl delete pod -n paymenthub -l app=ph-ee-bulk-processor` |

### Verifying Payer Configuration

```bash
# Check which clients are in each tenant's Fineract
curl -s -u mifos:password -H "Fineract-Platform-TenantId: greenbank" \
  "http://mifos.mifos.gazelle.localhost/fineract-provider/api/v1/clients?limit=1" | \
  jq '.pageItems[0].mobileNo'

# List Fineract savings accounts for payer account lookup
kubectl exec -n infra mysql-0 -- mysql -umifos -ppassword \
  -D mifostenant-greenbank \
  -e "SELECT id, account_no, display_name FROM m_savings_account LIMIT 10;"
```

---

## Summary

### Key Takeaways

1. **GovStack Spec is Switch-Agnostic**
   - Does NOT mandate Mojaloop
   - Requires: identity validation, de-bulking, payer FSP intermediary
   - Switch type is implementation choice

2. **GovStack "mode" is header-driven, not a config flag**
   - `X-Registering-Institution-ID` header triggers the GovStack workflow
   - `X-Program-ID` header additionally enables budget-account payer lookup
   - `--govstack` in `submit-batch.py` sends these headers

3. **Three Tenant Roles:**
   - **greenbank** = Mojaloop payer (PayerFundTransfer workflow)
   - **redbank** = Closedloop payer (minimal_mock_fund_transfer workflow)
   - **bluebank** = Payee FSP (receives funds)

4. **Payer and Payee have different sources:**
   - Payer → `budget-account` config in application.yaml (GovStack with X-Program-ID) OR CSV columns
   - Payee → identity-account-mapper database (always)

5. **Three independent controls:**
   - `--govstack` = enables identity validation and batch de-bulking
   - `payment_mode` in CSV = routing method (CLOSEDLOOP vs MOJALOOP)
   - `--tenant` = which payer workflows to use

6. **`--registering-institution` is now auto-detected**
   - submit-batch.py queries the identity-account-mapper DB to find the institution
   - Override with `--registering-institution` if needed

### Quick Reference

```bash
# Standard closedloop testing
cd ~/mifos-gazelle/src/utils/data-loading
./generate-example-csv-files.py -c ~/tomconfig.ini
./submit-batch.py -c ~/tomconfig.ini -f bulk-gazelle-closedloop-4.csv --tenant redbank

# True GovStack G2P via Mojaloop (registering institution auto-detected)
./submit-batch.py -c ~/tomconfig.ini -f bulk-gazelle-mojaloop-4.csv \
  --tenant greenbank --govstack

# GovStack with explicit program/payer account config
./submit-batch.py -c ~/tomconfig.ini -f bulk-gazelle-mojaloop-4.csv \
  --tenant greenbank --govstack --program SocialWelfare

# Debug: see which BPMN workflow will fire before submitting
./submit-batch.py -c ~/tomconfig.ini -f bulk-gazelle-mojaloop-4.csv \
  --tenant greenbank --govstack --debug
```

---

## File References

### Configuration
- Bulk-processor workflows + budget-account: `ph-ee-bulk-processor/src/main/resources/application.yaml`
- Connector-channel tenants: `ph-ee-connector-channel/src/main/resources/application.yml`
- Helm template tenants: `repos/ph_template/helm/gazelle/config/application-tenants.properties`
- Connector-mojaloop switch config: `ph-ee-connector-mojaloop-java/src/main/resources/application.yml:40`

### BPMN Workflows
- GovStack batch: `orchestration/feel/bulk_processor_account_lookup-DFSPID.bpmn`
- Standard batch: `orchestration/feel/bulk_processor-DFSPID.bpmn`
- Mojaloop transfer: `repos/phlabs/orchestration/feel/PayerFundTransfer-DFSPID.bpmn`
- Closedloop transfer: `orchestration/feel/minimal_mock_fund_transfer-DFSPID.bpmn`

### Code
- GovStack header processing + payer config lookup: `ph-ee-bulk-processor/.../ProcessorStartRouteService.java:140-213`
- Budget-account config classes: `ph-ee-bulk-processor/.../config/BudgetAccountConfig.java`
- Batch de-bulking: `ph-ee-bulk-processor/.../SplittingRoute.java:74-109`
- Payment mode routing: `ph-ee-connector-bulk/.../BatchTransferWorker.java:123-139`
- Workflow selection (channel): `ph-ee-connector-channel/.../ChannelRouteBuilder.java:304-367`
- Mojaloop switch call: `ph-ee-connector-mojaloop-java/.../TransferRoutes.java:214-216`

### Test Data / Utilities
- CSV generator: `src/utils/data-loading/generate-example-csv-files.py`
- Batch submitter: `src/utils/data-loading/submit-batch.py`
- Data generator: `src/utils/data-loading/generate-mifos-vnext-data.py`

---

**Last Updated:** February 2026
