# GovStack Mode: Payer Bank Account Configuration Flow

## Overview

In GovStack mode, Payment Hub EE uses a **dual-source** approach for determining accounts:

- **Payer (Government/Program):** Configured in `application.yml` via `budget-account.registeringInstitutions`
- **Payee (Beneficiary/Citizen):** Looked up in identity-account-mapper database

This document explains how the payer bank account is determined and configured.

---

## ⚠️ IMPORTANT: What is "GovStack Mode"?

**"GovStack mode" is NOT an actual mode or configuration setting** - it's descriptive terminology for behavior triggered by HTTP headers.

### Key Facts

| Question | Answer |
|----------|--------|
| **Is there a `govstack.enabled` flag?** | ❌ **NO** - no such configuration exists |
| **Is there a "mode" setting?** | ❌ **NO** - no enum, variable, or mode flag |
| **What triggers the behavior?** | ✅ **HTTP headers** - presence of both headers |
| **What headers?** | `X-Registering-Institution-ID` AND `X-Program-ID` |
| **Can I use it without headers?** | ❌ **NO** - headers are required |

### How It Works

**"GovStack mode" is triggered by including BOTH headers in your HTTP request:**

```bash
POST /batchtransactions
Headers:
  X-Registering-Institution-ID: greenbank  # ← Header 1 (REQUIRED)
  X-Program-ID: SocialWelfare              # ← Header 2 (REQUIRED)
  Platform-TenantId: greenbank
  ...

Body: CSV file (payer columns optional)
```

**What happens:**
- ✅ **Headers present** → System looks up payer from `budget-account` configuration
- ❌ **Headers missing** → System uses payer from CSV (CSV must have payer columns)

### The "Mode" is 100% Header-Driven

**Code logic:**

**File:** `ph-ee-bulk-processor/src/main/java/org/mifos/processor/bulk/connectors/service/ProcessorStartRouteService.java` (Lines 168-173)

```java
if (!(StringUtils.hasText(registeringInstituteId) && StringUtils.hasText(programId))) {
    // Headers are missing - use CSV payer values
    exchange.setProperty(IS_UPDATED, false);
    return;
}
// Headers are present - lookup configuration and override CSV payer values
```

**Translation:**
- If `X-Registering-Institution-ID` AND `X-Program-ID` headers exist → "GovStack behavior"
- If either header is missing → "Non-GovStack behavior"

### Configuration is Passive

The `budget-account` configuration in `application.yml` is **passive** - it defines what payer account to use **IF the headers are provided**:

```yaml
budget-account:
  registeringInstitutions:
    - id: "greenbank"              # Matches X-Registering-Institution-ID header
      programs:
        - id: "SocialWelfare"      # Matches X-Program-ID header
          identifierType: "ACCOUNT"
          identifierValue: "1"     # ← Used ONLY when headers present
```

**Without the headers, this configuration is completely ignored.**

### Practical Summary

**"GovStack mode" simply means:**
> "I'm providing `X-Registering-Institution-ID` and `X-Program-ID` headers, so the system should look up the payer account from the configured `budget-account.registeringInstitutions` instead of using CSV payer values."

**You don't "enable" GovStack mode - you trigger it by including the headers.**

---

## ⚠️ CRITICAL: Different BPMN Workflows for GovStack vs Non-GovStack

**The headers determine which BPMN workflow is executed.** Two distinct workflows exist, and they handle transactions differently.

### Two Workflows Deployed

| Workflow | Process ID | Used When | Key Tasks |
|----------|-----------|-----------|-----------|
| **Non-GovStack** | `bulk_processor-{dfspid}` | Headers **NOT** provided | `partyLookup`, `deduplicate` |
| **GovStack** | `bulk_processor_account_lookup-{dfspid}` | Headers **PROVIDED** | `batchAccountLookup`, `batchAccountLookupCallback` |

**File Locations:**
- Non-GovStack: `/orchestration/feel/bulk_processor-DFSPID.bpmn` (1289 lines)
- GovStack: `/orchestration/feel/bulk_processor_account_lookup-DFSPID.bpmn` (1265 lines)

### Workflow Selection Logic

```
HTTP Request to /batchtransactions
│
├─ Headers: X-Registering-Institution-ID + X-Program-ID present?
│  │
│  ├─ YES → Use: bulk_processor_account_lookup-{dfspid}
│  │         │
│  │         ├─ Task: batchAccountLookup (async)
│  │         ├─ Task: batchAccountLookupCallback
│  │         └─ Payer: From budget-account config
│  │
│  └─ NO  → Use: bulk_processor-{dfspid}
│            │
│            ├─ Task: partyLookup
│            ├─ Task: deduplicate
│            └─ Payer: From CSV
```

### Key Differences

**bulk_processor-{dfspid} (Non-GovStack):**
- ✅ Has `partyLookup` task - looks up payer/payee accounts via identity-account-mapper
- ✅ Has `deduplicate` task - removes duplicate transactions
- ❌ NO batch account lookup
- **Payer source:**
  - **Payer identifier:** From CSV columns (`payer_identifier_type`, `payer_identifier`)
  - **Payer DFSP:** From `Platform-TenantId` HTTP header (requesting tenant = payer's bank)
- **Use case:** Standard closedloop/mojaloop transfers

**bulk_processor_account_lookup-{dfspid} (GovStack):**
- ✅ Has `batchAccountLookup` task - async batch lookup
- ✅ Has `batchAccountLookupCallback` task - handles lookup response
- ❌ NO partyLookup task
- ❌ NO deduplicate task
- **Payer source:** HTTP headers → `budget-account` configuration
- **Use case:** Government disbursements (G2P)

### Deployment Requirements

**Both workflows MUST be deployed to Zeebe:**

```bash
# Deploy both BPMN files to Zeebe
zbctl deploy resource orchestration/feel/bulk_processor-DFSPID.bpmn
zbctl deploy resource orchestration/feel/bulk_processor_account_lookup-DFSPID.bpmn
```

**Why both?**
- They are **NOT mutually exclusive**
- Selection happens **at runtime** based on headers
- Both are deployed by default in mifos-gazelle
- The bulk-processor service chooses which to invoke based on request headers

### Configuration

**Non-GovStack Configuration:**

**File:** `config/ph_values.yaml`

```yaml
ph_ee_bulk_processor:
  config:
    partylookup:
      enable: true    # Enables partyLookup task (non-GovStack workflow)
```

**GovStack Configuration:**

**File:** `ph-ee-bulk-processor/src/main/resources/application.yaml`

```yaml
budget-account:
  registeringInstitutions:
    - id: "greenbank"              # Matches X-Registering-Institution-ID
      programs:
        - id: "SocialWelfare"      # Matches X-Program-ID
          identifierType: "ACCOUNT"
          identifierValue: "1"     # Payer account (GovStack workflow)
```

### Critical Clarification: How Payer DFSP is Determined in Non-GovStack Mode

**Important:** The CSV in non-GovStack mode does NOT have a column specifying which bank/DFSP the payer is at.

**CSV has:**
```csv
payer_identifier_type,payer_identifier,payee_identifier_type,payee_identifier,...
MSISDN,0413356886,MSISDN,0495822412,...
```

**CSV does NOT have:**
- ❌ No `payer_dfsp_id` column
- ❌ No `payer_bank` column
- ❌ No explicit payer DFSP/institution identifier

**So how does the system know the payer is at greenbank?**

**Answer:** The `Platform-TenantId` HTTP header determines the payer's DFSP:

```bash
POST /batchtransactions
Headers:
  Platform-TenantId: greenbank  # ← THIS means: "I am greenbank, the payer is at my bank"
```

**Logic:**
- The **requesting tenant** (from `Platform-TenantId` header) is **assumed to be the payer's DFSP**
- If greenbank submits the batch → payer is AT greenbank
- If bluebank submits the batch → payer is AT bluebank

**Example:**
```
CSV: payer_identifier = 0413356886 (just a phone number, no bank specified)
HTTP Header: Platform-TenantId = greenbank (the submitting bank)
Result: System determines payer 0413356886 is AT greenbank
```

This is fundamentally different from GovStack mode where the payer comes from configuration, not from the requesting tenant.

---

### Practical Implications

**If you submit WITHOUT GovStack headers:**
```bash
POST /batchtransactions
Headers:
  Platform-TenantId: greenbank  # ← Payer DFSP determined by THIS
  # NO X-Registering-Institution-ID
  # NO X-Program-ID

Body: CSV with payer columns (identifier only, no DFSP)
```
→ **Workflow:** `bulk_processor-{dfspid}`
→ **Payer identifier:** From CSV (`payer_identifier`)
→ **Payer DFSP:** From HTTP header (`Platform-TenantId`)
→ **Payer account:** Looked up via `partyLookup` task using identity-account-mapper
→ **Tasks:** partyLookup, deduplicate

**If you submit WITH headers:**
```bash
POST /batchtransactions
Headers:
  Platform-TenantId: greenbank
  X-Registering-Institution-ID: greenbank  # ← Triggers different workflow
  X-Program-ID: SocialWelfare              # ← Triggers different workflow

Body: CSV (no payer columns needed)
```
→ **Workflow:** `bulk_processor_account_lookup-{dfspid}`
→ **Payer:** From configuration
→ **Tasks:** batchAccountLookup, batchAccountLookupCallback

### Verification

**Check deployed workflows in Zeebe Operate:**

1. Open: `https://zeebe-operate.mifos.gazelle.test`
2. Login: `demo` / `demo`
3. Navigate to: **Processes**
4. Verify both processes are listed:
   - `bulk_processor-greenbank`
   - `bulk_processor_account_lookup-greenbank`

**Check running instances:**
- Non-GovStack requests → `bulk_processor-{dfspid}` instances
- GovStack requests → `bulk_processor_account_lookup-{dfspid}` instances

### Summary Table

| Aspect | Non-GovStack Workflow | GovStack Workflow |
|--------|----------------------|-------------------|
| **Triggered By** | No GovStack headers | Headers: X-Registering-Institution-ID + X-Program-ID |
| **Process ID** | `bulk_processor-{dfspid}` | `bulk_processor_account_lookup-{dfspid}` |
| **Payer Identifier** | From CSV (`payer_identifier`) | From configuration (`identifierValue`) |
| **Payer DFSP** | From HTTP header (`Platform-TenantId`) | From configuration (`registeringInstitutions.id`) |
| **Payer Account Lookup** | partyLookup task via identity-account-mapper | From configuration (no lookup needed) |
| **Account Lookup** | partyLookup (single, synchronous) | batchAccountLookup (batch, async callback) |
| **Deduplication** | Yes | No |
| **CSV Payer Columns** | REQUIRED (identifier only, no DFSP) | Optional (completely ignored) |
| **Configuration** | partylookup.enable | budget-account.registeringInstitutions |
| **Use Case** | P2P transfers, bank-initiated | Government disbursements (G2P) |

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                      BULK CSV SUBMISSION                         │
│                                                                  │
│  POST /batchtransactions                                         │
│  Headers:                                                        │
│    X-Registering-Institution-ID: "greenbank"                     │
│    X-Program-ID: "SocialWelfare"                                 │
│                                                                  │
│  Body: CSV with beneficiary details                              │
└─────────────────────┬───────────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────────┐
│              BULK-PROCESSOR: CONFIGURATION LOOKUP                │
│                                                                  │
│  Reads: src/main/resources/application.yml                       │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │ budget-account:                                           │  │
│  │   registeringInstitutions:                                │  │
│  │     - id: "greenbank"        ← Matches header             │  │
│  │       programs:                                           │  │
│  │         - id: "SocialWelfare" ← Matches header            │  │
│  │           identifierType: "ACCOUNT"                       │  │
│  │           identifierValue: "1" ← PAYER ACCOUNT!           │  │
│  └───────────────────────────────────────────────────────────┘  │
│                                                                  │
│  Result: Payer = greenbank account #1                            │
└─────────────────────┬───────────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────────┐
│            TRANSACTION UPDATE (In-Memory)                        │
│                                                                  │
│  For each transaction in CSV:                                    │
│    transaction.setPayerIdentifierType("ACCOUNT")                 │
│    transaction.setPayerIdentifier("1")                           │
│                                                                  │
│  CSV payer columns are OVERWRITTEN!                              │
└─────────────────────┬───────────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────────┐
│         IDENTITY-ACCOUNT-MAPPER: PAYEE LOOKUP                    │
│                                                                  │
│  Query: WHERE payee_identity = '0495822412'                      │
│         AND registering_institution_id = 'greenbank'             │
│                                                                  │
│  Result: Payee = bluebank account #1                             │
└─────────────────────┬───────────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────────┐
│                  ZEEBE WORKFLOW EXECUTION                        │
│                                                                  │
│  Variables:                                                      │
│    payerIdentifierType: "ACCOUNT"                                │
│    payerIdentifier: "1"                                          │
│    payeeIdentifier: "0495822412"                                 │
│    payeeAccount: "1"                                             │
│    payeeDFSP: "bluebank"                                         │
│                                                                  │
│  Transfer: greenbank acct 1 → bluebank acct 1                   │
└─────────────────────────────────────────────────────────────────┘
```

---

## Critical Distinction: Payer vs. Payee

| Aspect | Payer (Government/Program) | Payee (Beneficiary/Citizen) |
|--------|---------------------------|----------------------------|
| **Source** | Configuration file (`application.yml`) | Database (identity-account-mapper) |
| **Lookup Key** | `registeringInstitution ID` + `program ID` | `payeeIdentity` + `registeringInstitutionId` |
| **Service Component** | `BudgetAccountConfig` → `Program` | `MasterRepository` → `PaymentModalityDetails` |
| **Config Location** | `bulk-processor/src/main/resources/application.yaml` | Tables: `identity_details`, `payment_modality_details` |
| **Determined By** | HTTP request headers | CSV payee identifier or database lookup |
| **Purpose** | "Which government account pays?" | "Which citizen account receives?" |
| **Can Change at Runtime** | No (requires restart) | Yes (database updates) |
| **GovStack Role** | Government program/institution | Registered beneficiaries |

---

## Three Scenarios: How Payer Account is Determined

Understanding how the payer account is determined depends on **two factors**:
1. Whether payer information exists in the CSV
2. Whether GovStack headers are provided in the HTTP request

### Scenario Matrix

| Scenario | CSV Has Payer Columns? | GovStack Headers Provided? | Payer Source | Result |
|----------|------------------------|----------------------------|--------------|--------|
| **1. Non-GovStack Mode** | ✅ Yes (REQUIRED) | ❌ No | CSV values | Success - uses payer from CSV |
| **2. GovStack Mode** | ❌ No (optional) | ✅ Yes | Configuration via headers | Success - uses payer from config |
| **3. Missing Both** | ❌ No | ❌ No | N/A | **FAILURE - RuntimeException** |

---

### Scenario 1: Non-GovStack Mode (closedloop/mojaloop)

**Request:**
```bash
POST /batchtransactions
Headers:
  Platform-TenantId: greenbank
  # NO X-Registering-Institution-ID
  # NO X-Program-ID

Body: CSV file
```

**CSV Format (payer identifier REQUIRED, but NO payer DFSP column):**
```csv
id,request_id,payment_mode,payer_identifier_type,payer_identifier,payee_identifier_type,payee_identifier,amount,currency,note,account_number
0,uuid1,closedloop,MSISDN,0413356886,MSISDN,0495822412,10,USD,Payment,1
```

**Note:** CSV has `payer_identifier` (phone number) but NO column specifying which bank the payer is at!

**What Happens:**

**File:** `ph-ee-bulk-processor/src/main/java/org/mifos/processor/bulk/connectors/service/ProcessorStartRouteService.java` (Lines 168-173)

```java
if (!(StringUtils.hasText(registeringInstituteId) && StringUtils.hasText(programId))) {
    // Headers are missing or empty
    logger.debug("InstitutionId or programId is null");
    exchange.setProperty(IS_UPDATED, false);  // Don't update CSV values
    return;  // Exit - use CSV values as-is
}
```

**Flow:**
1. GovStack headers are missing → `registeringInstituteId = null`, `programId = null`
2. Condition `!(StringUtils.hasText(...))` is TRUE
3. `IS_UPDATED = false` → CSV payer values are NOT overwritten
4. Processing continues using **CSV payer values directly**
5. Payer identifier: `MSISDN 0413356886` (from CSV)
6. **Payer DFSP:** `greenbank` (from `Platform-TenantId` header - the requesting tenant!)
7. Payer account: Looked up via `partyLookup` task in identity-account-mapper

**Key Insight:** The `Platform-TenantId` header (`greenbank`) determines that payer `0413356886` is AT greenbank.

**Result:** ✅ **Success** - Transaction processes with:
- Payer identifier from CSV
- Payer DFSP from HTTP header
- Payer account from identity-account-mapper lookup

---

### Scenario 2: GovStack Mode with Headers

**Request:**
```bash
POST /batchtransactions
Headers:
  Platform-TenantId: greenbank
  X-Registering-Institution-ID: greenbank  # ✅ PROVIDED
  X-Program-ID: SocialWelfare              # ✅ PROVIDED

Body: CSV file
```

**CSV Format (payer columns OPTIONAL):**
```csv
id,request_id,payment_mode,payee_identifier_type,payee_identifier,amount,currency,note,account_number
0,uuid1,closedloop,MSISDN,0495822412,10,USD,Payment,1
```

**What Happens:**

**File:** `ph-ee-bulk-processor/src/main/java/org/mifos/processor/bulk/connectors/service/ProcessorStartRouteService.java` (Lines 168-177)

```java
if (!(StringUtils.hasText(registeringInstituteId) && StringUtils.hasText(programId))) {
    // Headers are present - condition is FALSE
    // Continue to configuration lookup
}

// Lines 178-187: Lookup configuration
RegisteringInstitutionConfig registeringInstitutionConfig =
    budgetAccountConfig.getByRegisteringInstituteId("greenbank");

Program program = registeringInstitutionConfig.getByProgramId("SocialWelfare");

// Lines 197-206: Update transactions
transactionList.forEach(transaction -> {
    transaction.setPayerIdentifierType(program.getIdentifierType());    // "ACCOUNT"
    transaction.setPayerIdentifier(program.getIdentifierValue());       // "1"
});
```

**Configuration Source:**

**File:** `ph-ee-bulk-processor/src/main/resources/application.yaml`

```yaml
budget-account:
  registeringInstitutions:
    - id: "greenbank"
      programs:
        - id: "SocialWelfare"
          identifierType: "ACCOUNT"
          identifierValue: "1"    # ← PAYER ACCOUNT
```

**Flow:**
1. Headers provided: `registeringInstituteId = "greenbank"`, `programId = "SocialWelfare"`
2. Condition `!(StringUtils.hasText(...))` is FALSE → continue
3. Lookup institution config: finds `greenbank`
4. Lookup program config: finds `SocialWelfare`
5. Extract payer account: `identifierValue = "1"`
6. **Overwrite** CSV payer values with config values
7. Payer: `ACCOUNT 1` (from configuration)

**Result:** ✅ **Success** - Transaction processes with payer from configuration

---

### Scenario 3: Missing Both (CSV Payer + Headers) - FAILS

**Request:**
```bash
POST /batchtransactions
Headers:
  Platform-TenantId: greenbank
  # NO X-Registering-Institution-ID  ❌
  # NO X-Program-ID                   ❌

Body: CSV file
```

**CSV Format (NO payer columns):**
```csv
id,request_id,payment_mode,payee_identifier_type,payee_identifier,amount,currency,note,account_number
0,uuid1,closedloop,MSISDN,0495822412,10,USD,Payment,1
```

**What Happens:**

**File:** `ph-ee-bulk-processor/src/main/java/org/mifos/processor/bulk/connectors/service/ProcessorStartRouteService.java` (Lines 168-177)

```java
if (!(StringUtils.hasText(registeringInstituteId) && StringUtils.hasText(programId))) {
    // Headers missing: registeringInstituteId = null, programId = null
    // Condition is TRUE - should return early...
    logger.debug("InstitutionId or programId is null");
    exchange.setProperty(IS_UPDATED, false);
    return;  // Exit early
}
```

**WAIT - This would exit early and use CSV values!**

But in this scenario, **CSV also has NO payer values**:
- `payer_identifier_type` = null/empty
- `payer_identifier` = null/empty

**What Happens Next:**

The transaction proceeds with **NULL payer values** to the Zeebe workflow:

**Workflow Validation Failure:**

When the workflow attempts to execute tasks like `block-funds` or `party-lookup-request-DFSPID`:

**File:** `ph-ee-connector-ams-mifos` or workflow workers

```java
String payerIdentifier = variables.get("payerIdentifier");  // null or empty

if (payerIdentifier == null || payerIdentifier.isEmpty()) {
    throw new WorkflowException("Payer identifier is required");
}
```

**Alternative Path - Earlier Validation:**

Some deployments may have CSV validation that checks for required fields:

**File:** `ph-ee-bulk-processor` validation (if enabled)

```java
if (transaction.getPayerIdentifier() == null) {
    throw new ValidationException("Payer identifier is required");
}
```

**Flow:**
1. Headers missing: `registeringInstituteId = null`, `programId = null`
2. Early return: CSV values used as-is
3. CSV payer values: null/empty
4. Transaction created with null payer
5. **Validation failure** OR **Workflow execution failure**

**Error Response:**
```
HTTP/1.1 400 Bad Request
OR
HTTP/1.1 500 Internal Server Error

{
  "error": "Payer identifier is required",
  "message": "Transaction validation failed"
}
```

**Result:** ❌ **FAILURE** - Cannot process without payer information

---

### Critical Finding: NO vNext Oracle Lookup for Payer

**IMPORTANT:** Unlike payee/beneficiary account resolution, there is **NO vNext oracle lookup** or automatic payer discovery mechanism.

**Payer vs. Payee Lookup:**

| Aspect | Payer | Payee |
|--------|-------|-------|
| **Lookup Service** | NONE - must be in CSV or config | identity-account-mapper database |
| **Oracle/vNext Integration** | ❌ NO | ✅ YES (via party lookup) |
| **Automatic Discovery** | ❌ NO | ✅ YES (MSISDN → account mapping) |
| **Fallback Mechanism** | ❌ NO | ✅ YES (can use CSV account_number) |
| **Required Information** | MUST be provided (CSV OR headers) | Can be discovered via lookup |

**Why No Payer Lookup?**

In GovStack use cases:
- **Payer is always known** - it's the government program/institution
- **Payer is configured** - set in `application.yml` at deployment time
- **Payer rarely changes** - government budget accounts are stable
- **Security** - payer accounts shouldn't be discoverable via external lookups

In contrast, **Payee lookup exists** because:
- Beneficiaries change frequently
- Need to map citizen IDs/phone numbers to bank accounts
- Beneficiary registration is dynamic

---

### Decision Tree: Which Scenario Applies?

```
┌─────────────────────────────────────────────┐
│ Incoming Request: POST /batchtransactions  │
└──────────────────┬──────────────────────────┘
                   │
                   ▼
      ┌────────────────────────────┐
      │ Are GovStack headers       │
      │ (X-Registering-Institution │
      │  + X-Program-ID) present?  │
      └────────┬───────────────────┘
               │
        ┌──────┴──────┐
        │             │
       YES           NO
        │             │
        ▼             ▼
   ┌─────────┐   ┌──────────────────┐
   │ SCENARIO│   │ Does CSV have    │
   │    2    │   │ payer columns?   │
   │         │   └────┬─────────────┘
   │ GovStack│        │
   │  Mode   │   ┌────┴────┐
   │         │  YES       NO
   │ Config  │   │         │
   │ Lookup  │   ▼         ▼
   │         │ ┌────┐   ┌────────┐
   │ Payer   │ │ S1 │   │   S3   │
   │  from   │ │    │   │        │
   │ Config  │ │Non-│   │ FAILS  │
   └─────────┘ │GS  │   │        │
               │    │   │  No    │
               │CSV │   │ Payer  │
               │    │   │  Info  │
               └────┘   └────────┘
                 │          │
                 ▼          ▼
            ✅ SUCCESS  ❌ FAILURE
```

---

## Configuration Details

### 1. Application Configuration Structure

**File:** `ph-ee-bulk-processor/src/main/resources/application.yaml` (lines 157-165)

```yaml
budget-account:
  registeringInstitutions:
    - id: "greenbank"                      # Institution identifier
      programs:
        - id: "SocialWelfare"              # Program identifier
          name: "Social Welfare Program"   # Human-readable name
          identifierType: "ACCOUNT"        # Type: ACCOUNT, MSISDN, etc.
          identifierValue: "1"             # CRITICAL: Payer bank account number
```

**Configuration Fields Explained:**

| Field | Description | Example | Required |
|-------|-------------|---------|----------|
| `registeringInstitutions.id` | Unique identifier for institution/bank | `"greenbank"`, `"ministry-of-welfare"` | Yes |
| `programs.id` | Program identifier within institution | `"SocialWelfare"`, `"ChildBenefit"` | Yes |
| `programs.name` | Human-readable program name | `"Social Welfare Program"` | Yes |
| `programs.identifierType` | Type of payer identifier | `"ACCOUNT"`, `"MSISDN"` | Yes |
| `programs.identifierValue` | **Actual payer account number** | `"1"`, `"123456789"` | Yes |

**Multiple Programs Example:**

```yaml
budget-account:
  registeringInstitutions:
    - id: "greenbank"
      programs:
        - id: "SocialWelfare"
          name: "Social Welfare Program"
          identifierType: "ACCOUNT"
          identifierValue: "1"              # Greenbank account #1

        - id: "ChildBenefit"
          name: "Child Benefit Program"
          identifierType: "ACCOUNT"
          identifierValue: "2"              # Greenbank account #2

        - id: "DisasterRelief"
          name: "Emergency Disaster Relief"
          identifierType: "ACCOUNT"
          identifierValue: "3"              # Greenbank account #3

    - id: "ministry-agriculture"
      programs:
        - id: "FarmerSubsidy"
          name: "Agricultural Subsidy Program"
          identifierType: "ACCOUNT"
          identifierValue: "100"            # Different bank account
```

### 2. HTTP Request Headers

**POST Request to `/batchtransactions`:**

```bash
curl -X POST https://bulk-processor.mifos.gazelle.localhost/batchtransactions \
  -H "X-Registering-Institution-ID: greenbank" \
  -H "X-Program-ID: SocialWelfare" \
  -H "Content-Type: text/csv" \
  --data-binary @welfare-batch.csv
```

**Header Mapping:**

| HTTP Header | Maps To | Purpose |
|-------------|---------|---------|
| `X-Registering-Institution-ID` | `registeringInstitutions.id` | Selects which institution config |
| `X-Program-ID` | `programs.id` | Selects which program within institution |

**Result:** System looks up `greenbank` → `SocialWelfare` → finds `identifierValue = "1"`

---

## Code Flow: Header to Payer Account

### Step-by-Step Execution

#### Step 1: Request Entry Point

**File:** `ph-ee-bulk-processor/src/main/java/org/mifos/processor/bulk/api/implementation/BatchTransactionsController.java`

```java
// Line 70: Extract registeringInstitutionId from header
String registeringInstitutionId = request.getHeader(HEADER_REGISTERING_INSTITUTE_ID);

// Line 76: Add to Camel headers
HeadersBuilder headersBuilder = HeadersBuilder.aHeadersBuilder()
    .addHeader(HEADER_REGISTERING_INSTITUTE_ID, registeringInstitutionId)
    .addHeader(HEADER_PROGRAM_ID, programId);
```

**Header Constant Definition:**
**File:** `ph-ee-bulk-processor/src/main/java/org/mifos/processor/bulk/camel/config/CamelProperties.java`

```java
// Line 74-76
public static final String HEADER_REGISTERING_INSTITUTE_ID = "X-Registering-Institution-ID";
public static final String HEADER_PROGRAM_ID = "X-Program-ID";
```

#### Step 2: Camel Route Processing

**File:** `ph-ee-bulk-processor/src/main/java/org/mifos/processor/bulk/camel/routes/ProcessorStartRoute.java`

```java
// Line 121-129: Route definition
from("direct:post-batch-transactions")
    .id("direct:post-batch-transactions")
    .log(LoggingLevel.INFO, "Starting route direct:post-batch-transactions")
    .to("direct:executeBatch");
```

#### Step 3: Extract to Exchange Properties

**File:** `ph-ee-bulk-processor/src/main/java/org/mifos/processor/bulk/connectors/service/ProcessorStartRouteService.java`

```java
// Lines 140-149: executeBatch() method
String registeringInstituteId = (String) exchange.getIn()
    .getHeader(HEADER_REGISTERING_INSTITUTE_ID);
String programId = (String) exchange.getIn()
    .getHeader(HEADER_PROGRAM_ID);

logger.info("RegisteringInstitutionId {}, programId {}",
    registeringInstituteId, programId);

exchange.setProperty(REGISTERING_INSTITUTE_ID, registeringInstituteId);
exchange.setProperty(PROGRAM_ID, programId);
```

#### Step 4: Configuration Lookup

**File:** `ph-ee-bulk-processor/src/main/java/org/mifos/processor/bulk/connectors/service/ProcessorStartRouteService.java`

```java
// Lines 163-213: updateIncomingData() method

// Extract from exchange properties
String registeringInstituteId = exchange.getProperty(REGISTERING_INSTITUTE_ID, String.class);
String programId = exchange.getProperty(PROGRAM_ID, String.class);

// Lookup institution configuration
RegisteringInstitutionConfig registeringInstitutionConfig =
    budgetAccountConfig.getByRegisteringInstituteId(registeringInstituteId);

if (registeringInstitutionConfig == null) {
    throw new RuntimeException("No registering institution found for id: " + registeringInstituteId);
}

// Lookup program within institution
Program program = registeringInstitutionConfig.getByProgramId(programId);

if (program == null) {
    throw new RuntimeException("No program found for id: " + programId);
}

// Extract payer account details
String payerIdentifierType = program.getIdentifierType();    // "ACCOUNT"
String payerIdentifier = program.getIdentifierValue();       // "1"
```

**Configuration Classes:**

**BudgetAccountConfig.java:**
```java
// File: ph-ee-bulk-processor/src/main/java/org/mifos/processor/bulk/config/BudgetAccountConfig.java
// Lines 18-20
public RegisteringInstitutionConfig getByRegisteringInstituteId(String id) {
    return registeringInstitutions.stream()
        .filter(ri -> ri.getId().equals(id))
        .findFirst()
        .orElse(null);
}
```

**RegisteringInstitutionConfig.java:**
```java
// File: ph-ee-bulk-processor/src/main/java/org/mifos/processor/bulk/config/RegisteringInstitutionConfig.java
// Lines 19-21
public Program getByProgramId(String id) {
    return programs.stream()
        .filter(p -> p.getId().equals(id))
        .findFirst()
        .orElse(null);
}
```

**Program.java:**
```java
// File: ph-ee-bulk-processor/src/main/java/org/mifos/processor/bulk/config/Program.java
// Lines 14-17
private String id;
private String name;
private String identifierType;
private String identifierValue;  // ← THE PAYER ACCOUNT!
```

#### Step 5: Transaction Update (Critical!)

**File:** `ph-ee-bulk-processor/src/main/java/org/mifos/processor/bulk/connectors/service/ProcessorStartRouteService.java`

```java
// Lines 197-206
transactionList.forEach(transaction -> {
    // OVERWRITES CSV payer columns with config values!
    transaction.setPayerIdentifierType(program.getIdentifierType());
    transaction.setPayerIdentifier(program.getIdentifierValue());
});
```

**This is THE critical step:** Any `payer_identifier` values in the CSV are **ignored and overwritten** with the configured value!

**Important Note:** In GovStack mode, payer columns in the CSV are **OPTIONAL**. You can:
- ✅ Omit `payer_identifier_type` and `payer_identifier` columns entirely from your CSV
- ✅ Include them with empty values (they'll be populated from config)
- ✅ Include them with any values (they'll be overwritten by config)

The payer account is **always** determined by the `budget-account.registeringInstitutions[].programs[].identifierValue` configuration.

#### Step 6: Set Zeebe Workflow Variables

**File:** `ph-ee-bulk-processor/src/main/java/org/mifos/processor/bulk/connectors/service/ProcessorStartRouteService.java`

```java
// Lines 264-266: startBatchProcessCsv() method
variables.put(PROGRAM_NAME, program.getName());
variables.put(PAYER_IDENTIFIER_TYPE, program.getIdentifierType());
variables.put(PAYER_IDENTIFIER_VALUE, program.getIdentifierValue());
```

These variables are passed to the Zeebe BPMN workflow for execution.

---

## Complete Flow Diagram

```
┌──────────────────────────────────────────────────────────────────┐
│ 1. HTTP Request                                                   │
│    POST /batchtransactions                                        │
│    Headers:                                                       │
│      X-Registering-Institution-ID: "greenbank"                    │
│      X-Program-ID: "SocialWelfare"                                │
└────────────────────┬─────────────────────────────────────────────┘
                     │
                     ▼
┌──────────────────────────────────────────────────────────────────┐
│ 2. BatchTransactionsController.java:70,76                         │
│    - Extract headers                                              │
│    - Pass to Camel route                                          │
└────────────────────┬─────────────────────────────────────────────┘
                     │
                     ▼
┌──────────────────────────────────────────────────────────────────┐
│ 3. ProcessorStartRouteService.executeBatch():140-149              │
│    - Convert headers to exchange properties                       │
│    - REGISTERING_INSTITUTE_ID = "greenbank"                       │
│    - PROGRAM_ID = "SocialWelfare"                                 │
└────────────────────┬─────────────────────────────────────────────┘
                     │
                     ▼
┌──────────────────────────────────────────────────────────────────┐
│ 4. ProcessorStartRouteService.updateIncomingData():178            │
│    budgetAccountConfig.getByRegisteringInstituteId("greenbank")   │
│                                                                   │
│    Looks up in application.yml:                                   │
│    ┌──────────────────────────────────────────────────────────┐  │
│    │ registeringInstitutions:                                 │  │
│    │   - id: "greenbank"  ← MATCH!                            │  │
│    └──────────────────────────────────────────────────────────┘  │
└────────────────────┬─────────────────────────────────────────────┘
                     │
                     ▼
┌──────────────────────────────────────────────────────────────────┐
│ 5. ProcessorStartRouteService.updateIncomingData():187            │
│    registeringInstitutionConfig.getByProgramId("SocialWelfare")   │
│                                                                   │
│    Looks up program:                                              │
│    ┌──────────────────────────────────────────────────────────┐  │
│    │ programs:                                                │  │
│    │   - id: "SocialWelfare"  ← MATCH!                        │  │
│    │     identifierType: "ACCOUNT"                            │  │
│    │     identifierValue: "1"                                 │  │
│    └──────────────────────────────────────────────────────────┘  │
│                                                                   │
│    Result: payerIdentifierType = "ACCOUNT"                        │
│            payerIdentifier = "1"                                  │
└────────────────────┬─────────────────────────────────────────────┘
                     │
                     ▼
┌──────────────────────────────────────────────────────────────────┐
│ 6. ProcessorStartRouteService.updateIncomingData():197-206        │
│    transactionList.forEach(transaction -> {                       │
│      transaction.setPayerIdentifierType("ACCOUNT");               │
│      transaction.setPayerIdentifier("1");                         │
│    });                                                            │
│                                                                   │
│    ⚠️ CSV payer columns are OVERWRITTEN!                          │
└────────────────────┬─────────────────────────────────────────────┘
                     │
                     ▼
┌──────────────────────────────────────────────────────────────────┐
│ 7. ProcessorStartRouteService.startBatchProcessCsv():264-266      │
│    variables.put("payerIdentifierType", "ACCOUNT");               │
│    variables.put("payerIdentifier", "1");                         │
│                                                                   │
│    → Passed to Zeebe BPMN workflow                                │
└────────────────────┬─────────────────────────────────────────────┘
                     │
                     ▼
┌──────────────────────────────────────────────────────────────────┐
│ 8. Zeebe Workflow Execution                                       │
│    - Payer: greenbank, account 1                                  │
│    - Payee: (from CSV + identity-account-mapper)                  │
│    - Transfer initiated                                           │
└──────────────────────────────────────────────────────────────────┘
```

---

## Identity-Account-Mapper Integration

### Payer vs. Payee: Different Sources

**Important:** identity-account-mapper is used ONLY for **payee (beneficiary)** lookups, NOT payer!

### Payee Lookup Flow

**File:** `ph-ee-identity-account-mapper/src/main/java/org/mifos/identityaccountmapper/service/AccountLookupService.java`

```java
// Lines 72-73: Batch account lookup
if (masterRepository.existsByPayeeIdentityAndRegisteringInstitutionId(
    beneficiary.getPayeeIdentity(), registeringInstitutionId))
```

**Database Query:**
**File:** `ph-ee-identity-account-mapper/src/main/java/org/mifos/identityaccountmapper/repository/MasterRepository.java`

```java
// Line 16
Optional<IdentityDetails> findByPayeeIdentityAndRegisteringInstitutionId(
    String functionalId, String registeringInstitutionId);
```

### Database Tables

**`identity_details` Table:**
```sql
CREATE TABLE identity_details (
    id BIGINT PRIMARY KEY AUTO_INCREMENT,
    master_id VARCHAR(200) NOT NULL,
    payee_identity VARCHAR(200) NOT NULL,       -- Beneficiary MSISDN/ID
    registering_institution_id VARCHAR(200)     -- Links to institution
);
```

**`payment_modality_details` Table:**
```sql
CREATE TABLE payment_modality_details (
    id BIGINT PRIMARY KEY AUTO_INCREMENT,
    master_id VARCHAR(200) NOT NULL,
    destination_account VARCHAR(200),           -- PAYEE account number
    institution_code VARCHAR(200),              -- PAYEE institution
    modality BIGINT
);
```

**Example Data:**
```
identity_details:
master_id       | payee_identity | registering_institution_id
----------------|----------------|---------------------------
bluebank-james  | 0495822412     | greenbank

payment_modality_details:
master_id       | destination_account | institution_code
----------------|---------------------|------------------
bluebank-james  | 1                   | bluebank
```

**Meaning:**
- Registering institution "greenbank" registered beneficiary with MSISDN 0495822412
- That beneficiary's account is: account #1 at bluebank
- Payer (greenbank) pays from account configured in `application.yml`
- Payee (beneficiary) receives at account from identity-account-mapper database

---

## Complete End-to-End Example

### Scenario

**Government Program:**
- Institution: Greenbank (government's banking partner)
- Program: Social Welfare (monthly benefits)
- Payer Account: Greenbank account #1 (starting balance: $50,000)

**Beneficiaries:**
- James Ramirez (MSISDN: 0495822412) - Bluebank account #1 ($0 balance)
- Caleb Harris (MSISDN: 0495822413) - Bluebank account #2 ($0 balance)

### Configuration

**1. Bulk-Processor Configuration:**

**File:** `ph-ee-bulk-processor/src/main/resources/application.yaml`

```yaml
budget-account:
  registeringInstitutions:
    - id: "greenbank"
      programs:
        - id: "SocialWelfare"
          name: "Social Welfare Program"
          identifierType: "ACCOUNT"
          identifierValue: "1"           # ← Greenbank account #1
```

**2. Identity-Account-Mapper Database:**

```sql
-- Beneficiaries registered under greenbank program
INSERT INTO identity_details (master_id, payee_identity, registering_institution_id)
VALUES
  ('bluebank-james', '0495822412', 'greenbank'),
  ('bluebank-caleb', '0495822413', 'greenbank');

-- Beneficiary account mappings
INSERT INTO payment_modality_details (master_id, destination_account, institution_code, modality)
VALUES
  ('bluebank-james', '1', 'bluebank', 1),
  ('bluebank-caleb', '2', 'bluebank', 1);
```

**3. Batch CSV (Minimal GovStack Format):**

**File:** `welfare-september-2025.csv`

In GovStack mode, the CSV can use a **minimal format** with only the essential fields:

```csv
id,request_id,payment_mode,payee_identifier_type,payee_identifier,amount,currency,note,account_number
0,550e8400-e29b-41d4-a716-446655440001,mojaloop,MSISDN,0495822412,250,USD,Sept welfare,1
1,550e8400-e29b-41d4-a716-446655440002,mojaloop,MSISDN,0495822413,250,USD,Sept welfare,2
```

**Key Points:**
- ✅ **NO** `payer_identifier_type` column - not needed in GovStack mode
- ✅ **NO** `payer_identifier` column - payer account comes from configuration
- ✅ Only beneficiary/payee information is required
- ✅ The `account_number` column specifies the beneficiary's bank account
- ✅ Payer is automatically set to the configured budget account

**Alternative: Full CSV Format (also works):**

If your CSV generation tool always includes payer columns, that's fine too - they'll just be ignored:

```csv
id,request_id,payment_mode,payer_identifier_type,payer_identifier,payee_identifier_type,payee_identifier,amount,currency,note,account_number
0,uuid1,mojaloop,ACCOUNT,1,MSISDN,0495822412,250,USD,Sept welfare,1
1,uuid2,mojaloop,ACCOUNT,1,MSISDN,0495822413,250,USD,Sept welfare,2
```

These payer values will be **overwritten** by configuration anyway.

**4. Submit Batch:**

```bash
curl -X POST https://bulk-processor.mifos.gazelle.localhost/batchtransactions \
  -H "X-Registering-Institution-ID: greenbank" \
  -H "X-Program-ID: SocialWelfare" \
  -H "Content-Type: text/csv" \
  --data-binary @welfare-september-2025.csv
```

### Execution Flow

**Transaction 1: James Ramirez**

```
1. Request received with headers:
   registeringInstitutionId = "greenbank"
   programId = "SocialWelfare"

2. Configuration lookup:
   greenbank → SocialWelfare → identifierValue = "1"

3. Transaction updated:
   payerIdentifierType = "ACCOUNT"
   payerIdentifier = "1"              (Greenbank account #1)
   payeeIdentifier = "0495822412"     (From CSV)
   payeeAccount = "1"                 (From CSV)

4. Party lookup (identity-account-mapper):
   Query: payee_identity = '0495822412' AND registering_institution_id = 'greenbank'
   Result: institution_code = 'bluebank', destination_account = '1'

5. Zeebe workflow execution:
   Variables:
   - payerIdentifierType: "ACCOUNT"
   - payerIdentifier: "1"
   - payerDFSP: "greenbank"
   - payeeIdentifier: "0495822412"
   - payeeAccount: "1"
   - payeeDFSP: "bluebank"
   - amount: 250.00
   - currency: "USD"

6. Transfer execution:
   Debit:  greenbank account 1 → $50,000 - $250 = $49,750
   Credit: bluebank account 1  → $0 + $250 = $250

7. Result: SUCCESS
```

**Transaction 2: Caleb Harris** (similar flow with different payee account #2)

### Final Balances

```
Before:
- Greenbank account #1: $50,000
- Bluebank account #1 (James): $0
- Bluebank account #2 (Caleb): $0

After:
- Greenbank account #1: $49,500  (-$500 total)
- Bluebank account #1 (James): $250  (+$250)
- Bluebank account #2 (Caleb): $250  (+$250)
```

---

## Configuration Requirements

### Payer Account Must:

1. ✅ **Exist in Fineract:** Must be a valid account in the payer institution
2. ✅ **Be Active:** Account status must be active
3. ✅ **Have Balance:** Sufficient funds for all batch payments
4. ✅ **Be Accessible:** Connector must have permissions to debit account
5. ✅ **Match identifierType:** If "ACCOUNT", use Fineract account ID; if "MSISDN", use phone number

### How to Find Your Payer Account

**Option 1: Via Fineract UI**

1. Access greenbank Fineract: `https://fineract.mifos.gazelle.test`
2. Login: `mifos` / `password`, Tenant: `greenbank`
3. Navigate to: Clients → [Government Program Client] → Accounts
4. Note the "Account No" (e.g., 1, 2, 3, etc.)
5. Use this value as `identifierValue`

**Option 2: Via Database**

```bash
kubectl exec -n infra mysql-0 -- mysql -u root -p<password> \
  -D mifostenant-greenbank \
  -e "SELECT id, account_no, display_name, account_balance_derived
      FROM m_savings_account
      WHERE client_id = <government_client_id>;"
```

**Option 3: Via Fineract API**

```bash
curl -X GET "https://fineract.mifos.gazelle.test/fineract-provider/api/v1/clients/<client_id>/accounts" \
  -H "Fineract-Platform-TenantId: greenbank" \
  -u "mifos:password"
```

---

## Troubleshooting

### Problem: "No registering institution found for id: greenbank"

**Cause:** `registeringInstitutions.id` in `application.yml` doesn't match header value

**Solution:**
```yaml
# Ensure this matches your header
budget-account:
  registeringInstitutions:
    - id: "greenbank"  # ← Must match X-Registering-Institution-ID header exactly
```

### Problem: "No program found for id: SocialWelfare"

**Cause:** `programs.id` doesn't match `X-Program-ID` header

**Solution:**
```yaml
programs:
  - id: "SocialWelfare"  # ← Must match X-Program-ID header exactly
```

### Problem: Transfer fails with "Insufficient balance"

**Cause:** Payer account doesn't have enough funds

**Solution:**
1. Check payer account balance in Fineract
2. Deposit funds to payer account
3. Or reduce batch payment amounts

### Problem: "Account not found" during transfer

**Cause:** `identifierValue` doesn't match actual Fineract account

**Solution:**
1. Verify account exists in Fineract
2. Confirm account ID matches `identifierValue`
3. Check account is active and not closed

### Problem: Payer identifier is wrong in workflow

**Cause:** Configuration not reloaded after `application.yml` change

**Solution:**
```bash
# Restart bulk-processor pod to reload configuration
kubectl rollout restart deployment/bulk-processor -n paymenthub
```

---

## Key File Locations Reference

| Component | File Path | Lines | Purpose |
|-----------|-----------|-------|---------|
| **Configuration** | `ph-ee-bulk-processor/src/main/resources/application.yaml` | 157-165 | Payer account config |
| **Config Classes** | `ph-ee-bulk-processor/src/main/java/org/mifos/processor/bulk/config/BudgetAccountConfig.java` | 18-20 | Load and lookup institutions |
| | `ph-ee-bulk-processor/src/main/java/org/mifos/processor/bulk/config/RegisteringInstitutionConfig.java` | 19-21 | Lookup programs |
| | `ph-ee-bulk-processor/src/main/java/org/mifos/processor/bulk/config/Program.java` | 14-17 | Payer account details |
| **HTTP Entry** | `ph-ee-bulk-processor/src/main/java/org/mifos/processor/bulk/api/implementation/BatchTransactionsController.java` | 70, 76 | Extract headers |
| **Header Constants** | `ph-ee-bulk-processor/src/main/java/org/mifos/processor/bulk/camel/config/CamelProperties.java` | 74-76 | Header definitions |
| **Account Mapping** | `ph-ee-bulk-processor/src/main/java/org/mifos/processor/bulk/connectors/service/ProcessorStartRouteService.java` | 163-213 | Config lookup and transaction update |
| **Camel Routes** | `ph-ee-bulk-processor/src/main/java/org/mifos/processor/bulk/camel/routes/ProcessorStartRoute.java` | 121-129 | Route definitions |
| **Payee Lookup** | `ph-ee-identity-account-mapper/src/main/java/org/mifos/identityaccountmapper/service/AccountLookupService.java` | 68-107 | Beneficiary account lookup |
| **Database Queries** | `ph-ee-identity-account-mapper/src/main/java/org/mifos/identityaccountmapper/repository/MasterRepository.java` | 14-20 | Database access |

---

## Summary: Key Takeaways

### ✅ Payer Account Configuration

1. **Source:** Configured in `application.yml`, NOT in database
2. **Key Field:** `budget-account.registeringInstitutions[].programs[].identifierValue`
3. **Lookup:** Uses HTTP headers (`X-Registering-Institution-ID` + `X-Program-ID`)
4. **Updates:** CSV payer columns are OVERWRITTEN by configuration
5. **Restart Required:** Changes require bulk-processor pod restart

### ✅ Payee Account Configuration

1. **Source:** identity-account-mapper database
2. **Key Tables:** `identity_details` + `payment_modality_details`
3. **Lookup:** Uses `payeeIdentity` + `registeringInstitutionId`
4. **Updates:** Can be updated in database without restart
5. **CSV Integration:** `account_number` column (optional with mapper)

### ✅ Complete Payment Flow

```
HTTP Headers → Configuration Lookup → Payer Account
CSV + Database → Identity-Account-Mapper → Payee Account
Both → Zeebe Workflow → Transfer Execution → Success
```

### ✅ Your Configuration for Greenbank

```yaml
budget-account:
  registeringInstitutions:
    - id: "greenbank"
      programs:
        - id: "SocialWelfare"
          identifierType: "ACCOUNT"
          identifierValue: "1"    # ← Your greenbank payer account number
```

**This account will be debited for all transfers in the batch!**

---

## Related Documentation

- [Identity-Account-Mapper Flow](./identity-account-mapper-flow.md) - Payee account lookup
- [Payment Hub EE Architecture](https://mifos.gitbook.io/docs) - Official documentation
- [Bulk CSV Format](https://mifos.gitbook.io/docs/payment-hub-ee/business-operations/bulk-payments) - CSV specification

---

**Document Version:** 1.0
**Last Updated:** 2025-12-05
**Author:** Claude Code Analysis
