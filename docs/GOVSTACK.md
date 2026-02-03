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
3. [GovStack Mode vs Payment Mode](#govstack-mode-vs-payment-mode)
4. [Component Details](#component-details)
5. [Tenant Configuration](#tenant-configuration)
6. [Workflow Comparison](#workflow-comparison)
7. [How to Run G2P Successfully](#how-to-run-g2p-successfully)
8. [Troubleshooting](#troubleshooting)

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
- `CLOSEDLOOP` != "non-GovStack" - it's a routing method
- `CLOSEDLOOP` can be used WITH GovStack identity validation
- `MOJALOOP` can be used WITHOUT GovStack identity validation
- These are independent concerns

### How Payment Mode Affects Routing

**Location:** [ph-ee-connector-bulk/.../BatchTransferWorker.java:123-139](/home/tdaly/ph-ee-connector-bulk/src/main/java/org/mifos/connector/phee/zeebe/workers/implementation/BatchTransferWorker.java#L123-L139)

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

**Closedloop flow:**
```
connector-bulk → HTTP POST /channel/transfer → connector-channel
→ starts workflow (tenant-specific) → executes payment
```

**Mojaloop flow:**
```
connector-bulk → POST back to bulk-processor (recursive batch)
→ eventually reaches connector-channel → PayerFundTransfer workflow
→ connector-mojaloop → Mojaloop switch → payee FSP
```

---

## GovStack Mode vs Payment Mode

### Two Independent Flags

#### 1. GovStack Mode (`--govstack` flag in submit-batch.py)

**What it does:**
- Sends `X-Registering-Institution-ID` header to bulk-processor
- Triggers `bulk_processor_account_lookup-{dfspid}.bpmn` workflow
- Calls identity-account-mapper for beneficiary validation
- De-bulks batch by `bankingInstitutionCode` (payee FSP)

**When to use:**
- Government-to-Person (G2P) disbursements
- Need pre-validation of beneficiaries
- Need to identify which FSP serves each beneficiary
- Want batch de-bulking by payee institution

**Code:** [submit-batch.py:116-119](/home/tdaly/mifos-gazelle/src/utils/data-loading/submit-batch.py#L116-L119)

#### 2. Payment Mode (CSV `payment_mode` field)

**What it does:**
- Determines routing mechanism (direct vs switch)
- Selects which connector/workflow to use
- Independent of validation

### The debulkingDfspid Configuration

**Location:** [ph-ee-bulk-processor/src/main/resources/application.yaml](/home/tdaly/ph-ee-bulk-processor/src/main/resources/application.yaml)

The `debulkingDfspid` field in payment-mode configuration controls which tenant handles closedloop transfers:

```yaml
payment-modes:
  - id: "CLOSEDLOOP"
    type: "BULK"
    endpoint: "bulk_connector_{MODE}-{dfspid}"
    # debulkingDfspid: "greenbank"  # ❌ DO NOT hardcode - overrides tenant selection
```

**How it works:**
- When `debulkingDfspid` is specified, it becomes the `Platform-TenantId` header sent to channel-connector
- When `debulkingDfspid` is null/undefined, it defaults to the submitting tenant (correct behavior)
- Hardcoding this value causes ALL closedloop batches to use the same tenant workflows, regardless of `--tenant` flag

**Code reference:** [InitSubBatchRoute.java:128](/home/tdaly/ph-ee-bulk-processor/src/main/java/org/mifos/processor/bulk/camel/routes/InitSubBatchRoute.java#L128)
```java
variables.put(DEBULKINGDFSPID,
    mapping.getDebulkingDfspid() == null ? tenantName : mapping.getDebulkingDfspid());
```

### Valid Combinations

| --govstack flag | payment_mode | Tenant | Workflow | Use Case | Status |
|-----------------|--------------|--------|----------|----------|--------|
| NO | CLOSEDLOOP | redbank | minimal_mock_fund_transfer-redbank | Simple testing, single Payment Hub | ✅ WORKS |
| NO | MOJALOOP | greenbank | PayerFundTransfer-greenbank | Multi-FSP via switch, no validation | ✅ WORKS |
| YES | CLOSEDLOOP | any | account_lookup → minimal_mock-{tenant} | G2P with validation, no switch | ⚠️ PARTIAL (see notes) |
| **YES** | MOJALOOP | greenbank | account_lookup → PayerFundTransfer-greenbank | **TRUE GOVSTACK** - G2P via switch | ✅ **RECOMMENDED** |

**Note:** The workflow suffix changes based on tenant (e.g., `-greenbank`, `-redbank`). If you see the wrong tenant suffix in logs, check that `debulkingDfspid` is not hardcoded in the payment-mode configuration.

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
      "payeeIdentity": "0495822412",  // MSISDN
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
      "financialAddress": "000000001",      // Account number
      "bankingInstitutionCode": "bluebank"  // Payee FSP identifier
    }
  ]
}
```

**Critical Understanding:**
- `financialAddress` is for reconciliation, not party lookup
- `bankingInstitutionCode` identifies which FSP serves this beneficiary
- MSISDN should be preserved for party lookup
- Batch de-bulking uses `bankingInstitutionCode` to group by payee FSP

### 2. Batch De-bulking (GovStack Requirement)

**Location:** [ph-ee-bulk-processor/.../SplittingRoute.java:74-109](/home/tdaly/ph-ee-bulk-processor/src/main/java/org/mifos/processor/bulk/camel/routes/SplittingRoute.java#L74-L109)

**How it works:**
```java
if (isPartyLookupEnabled && isBatchAccountLookupEnabled) {
    // Get distinct payee FSP IDs from account lookup response
    Set<String> distinctPayeeIds = transactionList.stream()
        .map(Transaction::getPayeeDfspId)  // bankingInstitutionCode
        .collect(Collectors.toSet());

    // Create separate sub-batch CSV for each payee FSP
    for (String payeeId : distinctPayeeIds) {
        List<Transaction> transactionsForPayee = transactionList.stream()
            .filter(transaction -> payeeId.equals(transaction.getPayeeDfspId()))
            .collect(Collectors.toList());

        String filename = UUID.randomUUID() + "_sub-batch-" + payeeId + ".csv";
        // Write CSV with only transactions for this payee FSP
    }
}
```

**When enabled:**
- Original batch: 10 transactions to 3 different FSPs
- After splitting: 3 sub-batches (1 per FSP)
- Each sub-batch processed independently

### 3. Mojaloop vNext Switch (Optional)

**GovStack does NOT mandate Mojaloop** - any switch/scheme can be used.

**Oracle Registration:**
```
MSISDN: 0495822412 → fspId: "bluebank", currency: "USD"
MSISDN: 0424942603 → fspId: "bluebank", currency: "USD"
```

**How Routing Works:**
1. Payer FSP sends transfer request with MSISDN to switch
2. Switch queries oracle: "Which FSP owns this MSISDN?"
3. Oracle responds with FSP ID
4. Switch routes transfer to that FSP's callback URL
5. Destination FSP does party lookup with MSISDN

---

## Tenant Configuration

### Critical: Multi-Component Tenant Configuration

**IMPORTANT:** Tenant workflows must be configured in BOTH bulk-processor AND channel-connector for batch processing to work correctly.

### Bulk-Processor Configuration

**File:** [ph-ee-bulk-processor/src/main/resources/application.yaml](/home/tdaly/ph-ee-bulk-processor/src/main/resources/application.yaml)

- Requires tenant in both the `tenants:` list AND `bpmns.tenants[]` section
- Controls batch-transactions workflow selection
- Uses `@ConfigurationProperties` annotation - reads YAML, NOT .properties files

```yaml
# Line 74: Add tenant to list
tenants: "greenbank, bluebank, redbank"

# Lines 232+: Define tenant workflows
bpmns:
  tenants:
    - id: "greenbank"
      flows:
        payment-transfer: "minimal_mock_fund_transfer-{dfspid}"
        batch-transactions: "bulk_processor-{dfspid}"
    - id: "redbank"
      flows:
        payment-transfer: "minimal_mock_fund_transfer-{dfspid}"
        batch-transactions: "bulk_processor-{dfspid}"
    - id: "bluebank"
      flows:
        batch-transactions: "bulk_processor-{dfspid}"
```

**For GovStack mode with identity validation:**
```yaml
    - id: "greenbank"
      flows:
        batch-transactions: "bulk_processor_account_lookup-{dfspid}"
```

### Connector-Channel Configuration

**File:** [ph-ee-connector-channel/src/main/resources/application.yml](/home/tdaly/ph-ee-connector-channel/src/main/resources/application.yml)

- Controls payment-transfer workflow selection
- Must match bulk-processor tenant definitions

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

**Key Point:** The `payment-transfer` workflow is determined by the **payer tenant**, not the payment mode in the CSV.

### Helm Template Configuration (For Reference)

**File:** [repos/ph_template/helm/gazelle/config/application-tenants.properties](/home/tdaly/mifos-gazelle/repos/ph_template/helm/gazelle/config/application-tenants.properties)

This file is used by Helm templates for deployment, but when using hostpath mounts, the actual configuration comes from the source YAML files above.

```properties
# Greenbank - Payer using Mojaloop switch
bpmns.tenants[0].id=greenbank
bpmns.tenants[0].flows.payment-transfer=PayerFundTransfer-{dfspid}
bpmns.tenants[0].flows.outbound-transfer-request={ps}_flow_{ams}-{dfspid}
bpmns.tenants[0].flows.batch-transactions=bulk_processor-{dfspid}

# Redbank - Payer using closedloop (direct Fineract => minimal_mock_transfer_request)
bpmns.tenants[1].id=redbank
bpmns.tenants[1].flows.payment-transfer=minimal_mock_fund_transfer-{dfspid}
bpmns.tenants[1].flows.outbound-transfer-request=minimal_mock_transfer_request-{dfspid}
bpmns.tenants[1].flows.batch-transactions=bulk_processor-{dfspid}

# Bluebank - Payee FSP (receives funds)
bpmns.tenants[2].id=bluebank
bpmns.tenants[2].flows.payment-transfer=minimal_mock_fund_transfer-{dfspid}
bpmns.tenants[2].flows.batch-transactions=bulk_processor-{dfspid}
```

### Deployment with Hostpath Mounts

When using hostpath mounts (development mode):
1. Edit source YAML files in `~/ph-ee-bulk-processor/src/main/resources/application.yaml` and `~/ph-ee-connector-channel/src/main/resources/application.yml`
2. Rebuild JARs:
   ```bash
   cd ~/ph-ee-bulk-processor && ./gradlew clean build -x test
   cd ~/ph-ee-connector-channel && ./gradlew clean build -x test
   ```
3. Restart pods:
   ```bash
   kubectl delete pod -n paymenthub -l app=ph-ee-bulk-processor
   kubectl delete pod -n paymenthub -l app=ph-ee-connector-channel
   ```

**Note:** ConfigMap updates alone do NOT work with hostpath mounts - the JARs must be rebuilt.

### Workflow Selection Logic

**Location:** [ph-ee-connector-channel/.../ChannelRouteBuilder.java:304-367](/home/tdaly/ph-ee-connector-channel/src/main/java/org/mifos/connector/channel/camel/routes/ChannelRouteBuilder.java#L304-L367)

```java
String tenantId = exchange.getIn().getHeader("Platform-TenantId", String.class);
String bpmn = getWorkflowForTenant(tenantId, "payment-transfer");
String tenantSpecificBpmn = bpmn.replace("{dfspid}", tenantId);

// Examples:
// tenantId="greenbank" → "PayerFundTransfer-greenbank"
// tenantId="redbank" → "minimal_mock_fund_transfer-redbank"
```

---

## Workflow Comparison

### PayerFundTransfer-{dfspid} (Mojaloop Switch Routing)

**Used by:** greenbank tenant (Mojaloop payer)

**Flow:**
1. Payee User Lookup - Query switch for payee FSP
2. Local Quote - Calculate payer FSP quote
3. Payee Quote - Get quote from payee FSP via switch
4. Payer Block Funds - Reserve funds in payer account
5. Send transfer request - POST to Mojaloop switch `/transfers`
6. Payer Book Funds - Commit/rollback based on response

**Worker:** [connector-mojaloop-java/.../TransferWorkers.java:105-111](/home/tdaly/ph-ee-connector-mojaloop-java/src/main/java/org/mifos/connector/mojaloop/transfer/TransferWorkers.java#L105-L111)

```java
if(isMojaloopEnabled) {
    producerTemplate.send("direct:send-transfer", exchange);
    // → HTTP POST to switch.transfers-host/transfers
}
```

### minimal_mock_fund_transfer-{dfspid} (Direct Fineract)

**Used by:** redbank tenant (closedloop payer), bluebank tenant (payee)

**Flow:**
1. mockPayeeLookup - Simulate party lookup (no actual API call)
2. mockInitiateTransfer - Simulate transfer (no actual execution)
3. mockPayeeAccountStatus - Return success

**Purpose:** Development/testing without actual Fineract integration

---

## How to Run G2P Successfully

### Option 1: Closedloop Mode (Simple Testing)

**Use Case:** Testing within single Payment Hub, no switch

**Generate CSVs:**
```bash
cd ~/mifos-gazelle
./src/utils/data-loading/generate-example-csv-files.py -c ~/tomconfig.ini
```

This queries Mifos and generates:
- `bulk-gazelle-closedloop-4.csv` - Redbank payer, CLOSEDLOOP mode
- `bulk-gazelle-mojaloop-4.csv` - Greenbank payer, MOJALOOP mode

**Submit:**
```bash
# Closedloop batch to redbank payer
./src/utils/data-loading/submit-batch.py \
  -c ~/tomconfig.ini \
  -f ./src/utils/data-loading/bulk-gazelle-closedloop-4.csv \
  --tenant redbank

# Mojaloop batch to greenbank payer
./src/utils/data-loading/submit-batch.py \
  -c ~/tomconfig.ini \
  -f ./src/utils/data-loading/bulk-gazelle-mojaloop-4.csv \
  --tenant greenbank
```

**NO `--govstack` flag** - skips identity validation

---

### Option 2: GovStack Mode with Mojaloop (Production-Ready)

**Use Case:** True GovStack G2P with validation and switch routing

**Prerequisites:**
```bash
# 1. Ensure identity-account-mapper has beneficiaries
cd ~/mifos-gazelle/src/utils/data-loading
./generate-mifos-vnext-data.py --regenerate

# 2. Verify registrations
kubectl exec -n infra mysql-0 -- mysql -umifos -ppassword identity_account_mapper -e \
  "SELECT id.payee_identity, pmd.financial_address, pmd.institution_code
   FROM identity_details id
   JOIN payment_modality_details pmd ON id.payment_modality_id = pmd.id
   WHERE id.registering_institution_id = 'greenbank'
   LIMIT 5"
```

**Configure greenbank for account lookup:**

Edit `ph-ee-bulk-processor/src/main/resources/application.yaml`:
```yaml
bpmns:
  tenants:
    - id: "greenbank"
      flows:
        batch-transactions: "bulk_processor_account_lookup-{dfspid}"
```

**Generate and Submit:**
```bash
# Use mojaloop CSV with greenbank payer
./src/utils/data-loading/submit-batch.py \
  -c ~/tomconfig.ini \
  -f ./src/utils/data-loading/bulk-gazelle-mojaloop-4.csv \
  --tenant greenbank \
  --govstack \
  --registering-institution greenbank
```

**Expected Flow:**
1. Identity mapper validates all beneficiaries ✓
2. Returns `bankingInstitutionCode` for each (e.g., "bluebank") ✓
3. Batch de-bulked by payee FSP ✓
4. Sub-batches sent to greenbank workflows ✓
5. PayerFundTransfer workflow executes ✓
6. Transfers go via Mojaloop switch ✓
7. Switch routes to destination FSPs ✓

---

### Option 3: GovStack Mode with Closedloop (Limited)

**Use Case:** G2P validation without switch (all payees in same Payment Hub)

**Configure:**
```yaml
bpmns:
  tenants:
    - id: "redbank"
      flows:
        batch-transactions: "bulk_processor_account_lookup-{dfspid}"
```

**Submit:**
```bash
./src/utils/data-loading/submit-batch.py \
  -c ~/tomconfig.ini \
  -f ./src/utils/data-loading/bulk-gazelle-closedloop-4.csv \
  --tenant redbank \
  --govstack \
  --registering-institution redbank
```

**Limitations:**
- All beneficiaries must be in the same Payment Hub instance
- No real multi-FSP support
- Batch de-bulking happens but sub-batches go to same instance

---

## Troubleshooting

### Diagnostic Commands

```bash
# 1. Check batch status
kubectl exec -n paymenthub operationsmysql-0 -- mysql -uroot -pmysql operations_app -e \
  "SELECT batch_id, total, successful, failed, ongoing FROM batch ORDER BY id DESC LIMIT 3"

# 2. Check transfer details with FSP mapping
kubectl exec -n paymenthub operationsmysql-0 -- mysql -uroot -pmysql operations_app -e \
  "SELECT id, batch_id, payee_identifier, payee_dfsp_id, status
   FROM transfers ORDER BY id DESC LIMIT 5"

# 3. Check bulk-processor logs for de-bulking
kubectl logs -n paymenthub -l app=ph-ee-bulk-processor --tail=100 | grep -i splitting

# 4. Check which workflow was used
kubectl logs -n paymenthub -l app=ph-ee-connector-channel --tail=100 | grep -i "starting workflow"

# 5. Verify identity mapper was called (if using --govstack)
kubectl logs -n paymenthub -l app=ph-ee-identity-account-mapper --tail=50
```

### Common Issues

| Symptom | Likely Cause | Solution |
|---------|--------------|----------|
| Batch total = 0 | Identity mapper returned empty | Check registering_institution_id or skip --govstack |
| All transactions same FSP | Missing vNext registration | Run `generate-mifos-vnext-data.py --regenerate` |
| No sub-batches created | Not using account_lookup workflow | Check tenant batch-transactions config |
| Wrong workflow used | Tenant mismatch | Verify `--tenant` matches your intent (greenbank/redbank) |
| CSV payer mismatch | Using wrong CSV for tenant | Regenerate CSVs with `generate-example-csv-files.py` |

### Tenant Configuration Issues

| Symptom | Likely Cause | Solution |
|---------|--------------|----------|
| "Process definition not found" (412 error) | Tenant missing from bpmns.tenants[] in bulk-processor | Add tenant to `~/ph-ee-bulk-processor/src/main/resources/application.yaml`, rebuild JAR |
| PARTY_NOT_FOUND errors | Tenant missing from channel-connector config | Add tenant to `~/ph-ee-connector-channel/src/main/resources/application.yml`, rebuild JAR |
| Wrong workflow triggered despite correct tenant | Hardcoded debulkingDfspid in payment-mode config | Remove debulkingDfspid from CLOSEDLOOP payment-mode in bulk-processor application.yaml |
| Changes not taking effect | Using hostpath mounts | Rebuild JAR files and restart pods after config changes |

### Verifying Configuration

```bash
# Check which payer MSISDN is in each tenant
curl -s -u mifos:password -H "Fineract-Platform-TenantId: greenbank" \
  "http://mifos.mifos.gazelle.localhost/fineract-provider/api/v1/clients?limit=1" | \
  jq '.pageItems[0].mobileNo'

curl -s -u mifos:password -H "Fineract-Platform-TenantId: redbank" \
  "http://mifos.mifos.gazelle.localhost/fineract-provider/api/v1/clients?limit=1" | \
  jq '.pageItems[0].mobileNo'
```

---

## Summary

### Key Takeaways

1. **GovStack Spec is Switch-Agnostic**
   - Does NOT mandate Mojaloop
   - Requires: identity validation, de-bulking, payer FSP intermediary
   - Switch type is implementation choice

2. **Three Tenant Roles:**
   - **greenbank** = Mojaloop payer (uses PayerFundTransfer workflow)
   - **redbank** = Closedloop payer (uses minimal_mock_fund_transfer workflow)
   - **bluebank** = Payee FSP (receives funds)

3. **Two Independent Flags:**
   - `--govstack` = enables identity validation and batch de-bulking
   - `payment_mode` in CSV = routing method (CLOSEDLOOP vs MOJALOOP)
   - `--tenant` = which payer workflows to use

4. **Batch De-bulking Works:**
   - Enabled by `bulk_processor_account_lookup` workflow
   - Splits batch by `bankingInstitutionCode` from identity mapper
   - Creates separate sub-batch CSV per payee FSP

5. **CSV Generation is Dynamic:**
   - `generate-example-csv-files.py` queries Mifos for current clients
   - Closedloop CSV uses redbank payer MSISDN
   - Mojaloop CSV uses greenbank payer MSISDN
   - No hardcoded values

### Quick Reference

**Simple closedloop testing:**
```bash
cd ~/mifos-gazelle/src/utils/data-loading
./generate-example-csv-files.py
./submit-batch.py -c ~/tomconfig.ini -f bulk-gazelle-closedloop-4.csv --tenant redbank
```

**True GovStack G2P via Mojaloop:**
```bash
./submit-batch.py -c ~/tomconfig.ini -f bulk-gazelle-mojaloop-4.csv \
  --tenant greenbank --govstack --registering-institution greenbank
```

---

## File References

### Configuration
- Connector-channel tenants: `repos/ph_template/helm/gazelle/config/application-tenants.properties`
- Bulk-processor workflows: `ph-ee-bulk-processor/src/main/resources/application.yaml`
- Connector-mojaloop switch config: `ph-ee-connector-mojaloop-java/src/main/resources/application.yml:40`

### Workflows
- GovStack batch processing: `orchestration/feel/bulk_processor_account_lookup-DFSPID.bpmn`
- Batch de-bulking: `ph-ee-bulk-processor/src/main/java/org/mifos/processor/bulk/camel/routes/SplittingRoute.java:74-109`
- Mojaloop transfer: `repos/phlabs/orchestration/feel/PayerFundTransfer-DFSPID.bpmn`
- Closedloop transfer: `orchestration/feel/minimal_mock_fund_transfer-DFSPID.bpmn`

### Code
- Payment mode routing: `ph-ee-connector-bulk/.../BatchTransferWorker.java:123-139`
- Workflow selection: `ph-ee-connector-channel/.../ChannelRouteBuilder.java:304-367`
- Mojaloop switch call: `ph-ee-connector-mojaloop-java/.../TransferRoutes.java:214-216`

### Test Data
- CSV generator: `src/utils/data-loading/generate-example-csv-files.py`
- Batch submitter: `src/utils/data-loading/submit-batch.py`
- Data generator: `src/utils/data-loading/generate-mifos-vnext-data.py`

---

**Last Updated:** January 2026 - Based on GovStack spec analysis and codebase investigation
