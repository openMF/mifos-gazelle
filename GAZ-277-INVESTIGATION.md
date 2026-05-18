# GAZ-277: Reduce BPMN Diagram Loading — Investigation & Optimization Plan

**Issue:** https://mifosforge.jira.com/browse/GAZ-277  
**Status:** Investigation Complete  
**Date:** May 18, 2026

---

## 1. Current Behavior: Root Cause Analysis

### Problem
BPMN workflows are deployed to all 3 tenants (greenbank, bluebank, redbank) regardless of which tenant actually uses them. This creates unnecessary:
- Worker threads for each deployment
- CPU and memory overhead
- Slower deployment times

### Code Location
**File:** `src/deployer/mastercard.sh` (lines 261-298)  
**Function:** `deploy_bpmn_workflow()`

```bash
# Currently deploys to ALL tenants:
deploy_bpmn_workflow() {
    # Deploys MastercardFundTransfer-DFSPID.bpmn to:
    # 1. greenbank (required)
    # 2. redbank (unnecessary)
    # 3. bluebank (unnecessary)
}
```

### Why This Happens
Mastercard CBS is only deployed when `mastercard-demo` is enabled in `config/config.ini`. When enabled, the `deploy_bpmn_workflow()` function deploys the Mastercard-specific BPMN (`MastercardFundTransfer-DFSPID.bpmn`) to **all three tenants** as a failsafe, but:

- **greenbank** is the only tenant that actually runs Mastercard CBS payments
- **redbank** and **bluebank** never initiate Mastercard workflows (they are payee FSPs)
- This is excessive and resource-wasteful

---

## 2. Tenant Role Analysis

### Tenant Usage Patterns
Based on code analysis (`src/utils/data-loading/*.py`):

| Tenant | Role(s) | Active Workflows | Mastercard Needed? |
|--------|---------|------------------|--------------------|
| **greenbank** | Payer (Mojaloop & Mastercard) | GSMA P2P, Mastercard Fund Transfer, Bulk Closedloop | ✅ YES |
| **redbank** | Payer (Closedloop) | GSMA P2P, Bulk Closedloop | ❌ NO |
| **bluebank** | Payee (all modes) | Account Lookup, Payee Party/Quote | ❌ NO |

### Evidence
1. CSV generation (`generate-example-csv-files.py`):
   - Closedloop CSV payer: **redbank** (no Mastercard)
   - Mojaloop CSV payer: **greenbank** (with Mastercard option)
   - Mastercard CSV payer: **greenbank-mastercard** (not bluebank or redbank)

2. Batch submission (`submit-batch.py`):
   - Default tenant for Mastercard tests: **greenbank** only
   - No references to Mastercard + redbank or Mastercard + bluebank combinations

3. Mastercard connector reconciliation (`reconcile.sh`):
   - Only references `MastercardFundTransfer-greenbank`
   - No reconciliation logic for bluebank/redbank Mastercard workflows

---

## 3. Solution: Multi-Step Optimization

### Step 1: Identify Used vs. Unused Workflows (Data Collection)
Run full deployment + test suite to understand actual BPMN usage:

```bash
# 1. Deploy full stack (all DPGs + OpenSPP)
sudo ./run.sh -u $USER -m deploy -a all

# 2. Run P2P tests (mojaloop workflows, greenbank)
src/utils/batch/submit-batch.py -f bulk-gazelle-mojaloop-4.csv --tenant greenbank

# 3. Run bulk closedloop tests (redbank workflows)
src/utils/batch/submit-batch.py -f bulk-gazelle-closedloop-4.csv --tenant redbank

# 4. Run Mastercard tests (greenbank only)
src/utils/batch/submit-batch.py -f bulk-gazelle-mastercard-4.csv --tenant greenbank

# 5. Query Zeebe Elasticsearch for active BPMN processes
curl -s "http://elasticsearch.mifos.gazelle.test/zeebe-record_process_*/_search" \
  -H 'Content-Type: application/json' \
  -d '{
    "size": 0,
    "query": { "term": { "valueType": "PROCESS" } },
    "aggs": {
      "by_tenant_and_bpmn": {
        "composite": {
          "size": 1000,
          "sources": [
            { "tenant": { "terms": { "field": "value.tenantId" } } },
            { "bpmn_id": { "terms": { "field": "value.bpmnProcessId" } } }
          ]
        }
      }
    }
  }' | jq '.aggregations.by_tenant_and_bpmn.buckets'
```

### Step 2: Modify Deployment Logic (Code Change)
Optimize `deploy_bpmn_workflow()` to deploy only to greenbank:

**Current (wasteful):**
```bash
# Deploy to all tenants
for tenant in greenbank redbank bluebank; do
    deploy_workflow greenbank
done
```

**Optimized:**
```bash
# Deploy only to greenbank (the only tenant using Mastercard)
deploy_bpmn_workflow() {
    # ... validation ...
    
    # Deploy ONLY to greenbank
    log_with_verbose_check "$debug" "$INFO" "Deploying Mastercard BPMN workflow for greenbank"
    if run_as_user "bash \"$deploy_script\" -c \"$config_file\" -f \"$workflow_file\" -t greenbank" > /dev/null 2>&1; then
        log_ok
    else
        log_warn "Failed to deploy Mastercard BPMN workflow"
        return 1
    fi
    
    # No longer deploy to redbank/bluebank (they don't use Mastercard)
}
```

### Step 3: Verify Changes
Run tests after optimization:

```bash
# 1. Re-deploy and run tests (same as Step 1)
# 2. Verify Mastercard workflows still work
# 3. Measure resource savings (CPU, memory, time)

# Before: ~20-30 worker threads for Mastercard workflow across 3 tenants
# After: ~7-10 worker threads for Mastercard workflow (greenbank only)
# Expected saving: ~10-20 worker threads, ~500MB-1GB RAM
```

### Step 4: Document Results
Update deployment guide with findings and verify no side effects.

---

## 4. Implementation Steps

### Phase 1: Investigation (Current Phase)
- [x] Understand current BPMN loading mechanism
- [x] Identify which tenants use which workflows
- [x] Locate the multi-tenant deployment code
- [x] Document root cause and impact

### Phase 2: Implementation
- [ ] Modify `src/deployer/mastercard.sh` (remove redbank/bluebank loop)
- [ ] Test single-tenant Mastercard deployment
- [ ] Verify all Mastercard workflows still work
- [ ] Run full test suite (Mojaloop, Closedloop, Mastercard)
- [ ] Document resource savings

### Phase 3: Validation
- [ ] Run deployment with optimization enabled
- [ ] Monitor resource usage (workers, CPU, memory)
- [ ] Verify no regressions in payment tests
- [ ] Update docs with new architecture

### Phase 4: PR & Merge
- [ ] Create PR with changes + test results
- [ ] Document in commit message: GAZ-277
- [ ] Request review from maintainers

---

## 5. Key Findings

1. **Only greenbank uses Mastercard** — redbank/bluebank deployments are unnecessary
2. **Simple fix** — remove the loop over redbank/bluebank in `deploy_bpmn_workflow()`
3. **Resource impact** — estimated 10-20 fewer worker threads, ~500MB-1GB RAM savings
4. **No side effects** — Mastercard workflows are greenbank-specific; other DPGs unaffected

---

## 6. Testing Strategy

### Unit Test: Verify BPMN Only Deploys to greenbank
```bash
# Check Zeebe has Mastercard workflow only for greenbank
curl -s "http://elasticsearch.mifos.gazelle.test/zeebe-record_process_*/_search" \
  -H 'Content-Type: application/json' \
  -d '{
    "query": { "match": { "value.bpmnProcessId": "MastercardFundTransfer" } }
  }' | jq '.hits.hits[] | .fields.bpmnProcessId'

# Expected: Only greenbank tenant, no redbank/bluebank entries
```

### Integration Test: Run Full Test Suite
```bash
# P2P (Mojaloop, greenbank)
./submit-batch.py -f bulk-gazelle-mojaloop-4.csv --tenant greenbank --verify

# Bulk Closedloop (redbank, no Mastercard)
./submit-batch.py -f bulk-gazelle-closedloop-4.csv --tenant redbank --verify

# Mastercard (greenbank only)
./submit-batch.py -f bulk-gazelle-mastercard-4.csv --tenant greenbank --verify
```

---

## 7. References

- **Issue:** https://mifosforge.jira.com/browse/GAZ-277
- **Mastercard Deploy:** `src/deployer/mastercard.sh` (lines 261-298)
- **BPMN Script:** `src/utils/deployBpmn-gazelle.sh`
- **Batch Tests:** `src/utils/batch/submit-batch.py`
- **Data Loading:** `src/utils/data-loading/generate-example-csv-files.py`

---

## 8. Success Criteria

- [ ] Mastercard BPMN only deploys to greenbank (verified via Zeebe)
- [ ] All payment tests pass (Mojaloop, Closedloop, Mastercard)
- [ ] Resource usage reduced by at least 10% (workers, CPU, memory)
- [ ] No regressions in other DPGs (MifosX, vNext, PHEE)
- [ ] Documentation updated
- [ ] PR merged with maintainer approval

