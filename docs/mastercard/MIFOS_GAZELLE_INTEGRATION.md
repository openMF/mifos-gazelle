# Mastercard CBS Integration with Mifos-Gazelle

> **Note**: For architectural concepts and GovStack G2P flows, see [GOVSTACK.md](GOVSTACK.md) and [MASTERCARD-GOVSTACK-IMPLEMENTATION.md](MASTERCARD-GOVSTACK-IMPLEMENTATION.md). This document focuses on mifos-gazelle integration patterns, data loading scripts, and deployment configuration.

## Overview

The Mastercard CBS connector integrates with mifos-gazelle deployment system, leveraging existing PaymentHub infrastructure and data loading tools.

## Integration Points

### 1. Identity Account Mapper (Existing)

**Current Flow** (Mojaloop vNext):
```
generate-mifos-vnext-data.py
  ↓
Populates identity_account_mapper database
  ↓
Maps MSISDN → Account Number + FSP ID
  ↓
Used by bulk-processor for party lookup
```

**Mastercard CBS Flow** (New):
```
generate-mifos-vnext-data.py (existing)
  ↓
identity_account_mapper (existing)
  ↓
NEW: load-mastercard-supplementary-data.py
  ↓
mastercard_cbs_supplementary_data (new table)
  ↓
Looked up by CBS connector for regulatory data
```

**Key Point**: Use the **same MSISDNs** already in identity_account_mapper

### 2. Data Loading Pattern

Follow the existing mifos-gazelle pattern:

**Existing Script** (`generate-mifos-vnext-data.py`):
- Queries MifosX tenants for clients
- Gets MSISDNs from client records
- Registers with Mojaloop oracle
- Populates identity_account_mapper

**New Script** (`load-mastercard-supplementary-data.py`):
- Queries identity_account_mapper for existing MSISDNs
- OR queries MifosX tenants directly (same as vNext script)
- Generates supplementary regulatory data for those MSISDNs
- Populates mastercard_cbs_supplementary_data table

### 3. Tenant Structure Integration

**Existing Tenants**:
- `greenbank` - Mojaloop payer
- `redbank` - Closedloop payer
- `bluebank` - Payee FSP

**Mastercard CBS Tenant** (New option):
- Add `mastercard_cbs` payment mode to tenant configuration
- Use same tenant (e.g., `greenbank`) but route to CBS connector

**Configuration** (`config/ph_values.yaml`):
```yaml
# Existing payment modes
payment-modes:
  - id: "MOJALOOP"
    type: "BULK"
    endpoint: "bulk_connector_mojaloop-{dfspid}"
  - id: "CLOSEDLOOP"
    type: "BULK"
    endpoint: "bulk_connector_closedloop-{dfspid}"
  # NEW: Mastercard CBS mode
  - id: "MASTERCARD_CBS"
    type: "BULK"
    endpoint: "bulk_connector_mastercard_cbs-{dfspid}"
```

### 4. Database Location

Add new table to **existing operations database**:

```bash
# Operations DB already has:
# - transfers table
# - batches table
# - identity_account_mapper database

# Add to same MySQL instance:
mysql -h operationsmysql.paymenthub.svc.cluster.local \
  -u root -p mysql \
  -e "CREATE DATABASE IF NOT EXISTS operations;"

mysql -h operationsmysql.paymenthub.svc.cluster.local \
  -u root -p operations \
  < src/utils/data-loading/mastercard-cbs-schema.sql
```

---

## Leveraging Existing Tools

### 1. Local Development (hostPath Mounts)

**Existing Pattern** (from `docs/DEV-TEST-TIPS.md`):
```yaml
# ph_values.yaml for local dev
hostpaths:
  ph-ee-bulk-processor: ~/ph-ee-bulk-processor
  ph-ee-connector-channel: ~/ph-ee-connector-channel
```

**Add CBS Connector**:
```yaml
hostpaths:
  ph-ee-connector-mastercard-cbs: ~/ph-ee-connector-mccbs
```

**Rebuild Pattern**:
```bash
# Same as existing connectors
cd ~/ph-ee-connector-mccbs
gradle clean build -x test
kubectl delete pod -n paymenthub -l app=ph-ee-connector-mastercard-cbs
```

### 2. Data Loading Scripts Location

**Existing Scripts** (`~/mifos-gazelle/src/utils/data-loading/`):
- `generate-mifos-vnext-data.py`
- `generate-example-csv-files.py`
- `submit-batch.py`
- `register-beneficiaries.sh`

**New Scripts** (add to same directory):
- `load-mastercard-supplementary-data.py`
- `generate-mastercard-demo-batch.py`

**Benefits**:
- Same config file (`~/tomconfig.ini`)
- Same database connection patterns
- Same MSISDN lookup logic
- Same CSV generation patterns

### 3. Configuration File Integration

**Existing** (`config/config.ini`):
```ini
[namespaces]
ph-ee = paymenthub
vnext = mojaloop
mifos = mifos

[domains]
operations = ops.mifos.gazelle.test
mifos = mifos.mifos.gazelle.test

[databases]
operations_host = operationsmysql.paymenthub.svc.cluster.local
operations_db = operations
```

**Add CBS Configuration**:
```ini
[mastercard_cbs]
enabled = true
connector_image = ph-ee-connector-mastercard-cbs:1.0.0
api_url = https://sandbox.api.mastercard.com
partner_id = ${MASTERCARD_PARTNER_ID}
```

---

## Recommended Data Generation Approach

### Approach 1: Extend generate-mifos-vnext-data.py (RECOMMENDED)

**Add `--mastercard` flag** to existing script:

```python
# generate-mifos-vnext-data.py (modifications)

def load_mastercard_supplementary_data(clients, config):
    """
    Generate supplementary data for Mastercard CBS
    Using same clients as vNext/identity mapper
    """
    for client in clients:
        msisdn = client['mobileNo']
        account = client['savingsAccountId']

        # Generate South African data if --south-africa flag
        if args.south_africa:
            bank = random.choice(SA_BANKS)  # Standard Bank, FNB, etc.
            country = 'ZA'
        else:
            bank = random.choice(INTERNATIONAL_BANKS)
            country = random.choice(COUNTRIES)

        # Insert into mastercard_cbs_supplementary_data
        insert_supplementary_data(msisdn, account, bank, country)

# Add CLI argument
parser.add_argument('--mastercard', action='store_true',
                    help='Also populate Mastercard CBS supplementary data')
parser.add_argument('--south-africa', action='store_true',
                    help='Use only South African banks for Mastercard data')
```

**Usage**:
```bash
cd ~/mifos-gazelle/src/utils/data-loading

# Populate everything (vNext + Identity Mapper + Mastercard)
./generate-mifos-vnext-data.py --regenerate --mastercard --south-africa

# Or just Mastercard supplementary data
./generate-mifos-vnext-data.py --mastercard-only --south-africa
```

### Approach 2: Separate Script (Simpler Initially)

**Create new script** that follows same pattern:

```python
#!/usr/bin/env python3
# load-mastercard-supplementary-data.py

import mysql.connector
import configparser
import random

# South African banks (from research)
SA_BANKS = [
    {'name': 'Standard Bank', 'swift': 'SBZAZAJJ', 'branch': 'Sandton'},
    {'name': 'First National Bank', 'swift': 'FIRNZAJJ', 'branch': 'Cape Town CBD'},
    {'name': 'Nedbank', 'swift': 'NEDSZAJJ', 'branch': 'Durban Central'},
    {'name': 'ABSA Bank', 'swift': 'ABSAZAJJ', 'branch': 'Johannesburg'},
    {'name': 'Capitec Bank', 'swift': 'CABLZAJJ', 'branch': 'Pretoria'},
    # ... more banks
]

def main():
    config = configparser.ConfigParser()
    config.read(os.path.expanduser('~/tomconfig.ini'))

    # Connect to operations DB (same as vNext script)
    db = mysql.connector.connect(
        host=config.get('operations_db', 'host'),
        user=config.get('operations_db', 'user'),
        password=config.get('operations_db', 'password'),
        database='operations'
    )

    # Query existing MSISDNs from identity_account_mapper
    cursor = db.cursor()
    cursor.execute("""
        SELECT DISTINCT id.payee_identity, pmd.destination_account
        FROM identity_account_mapper.identity_details id
        JOIN identity_account_mapper.payment_modality_details pmd
          ON id.master_id = pmd.master_id
        WHERE id.payee_identity_type = 'MSISDN'
        LIMIT 10
    """)

    beneficiaries = cursor.fetchall()

    # Generate supplementary data for each
    for msisdn, account in beneficiaries:
        bank = random.choice(SA_BANKS)

        insert_sql = """
        INSERT INTO mastercard_cbs_supplementary_data
        (payee_msisdn, payee_account_number,
         recipient_first_name, recipient_last_name,
         recipient_address_line1, recipient_address_city,
         recipient_phone, recipient_email,
         bank_name, bank_swift_code, bank_branch_name,
         destination_country, beneficiary_currency)
        VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, 'ZAF', 'ZAR')
        """

        cursor.execute(insert_sql, (
            msisdn, account,
            generate_sa_first_name(), generate_sa_last_name(),
            generate_sa_address(), generate_sa_city(),
            msisdn, generate_sa_email(msisdn),
            bank['name'], bank['swift'], bank['branch']
        ))

    db.commit()
    print(f"Loaded {len(beneficiaries)} supplementary data records")

if __name__ == '__main__':
    main()
```

**Usage**:
```bash
cd ~/mifos-gazelle/src/utils/data-loading

# After running generate-mifos-vnext-data.py
./load-mastercard-supplementary-data.py -c ~/tomconfig.ini
```

---

## CSV Batch Generation Integration

### Extend generate-example-csv-files.py

**Existing Script**: Generates `bulk-gazelle-mojaloop-4.csv` and `bulk-gazelle-closedloop-4.csv`

**Add Mastercard CSV Generation**:

```python
# generate-example-csv-files.py (add to existing script)

def generate_mastercard_cbs_batch(config):
    """
    Generate CSV batch for Mastercard CBS payments
    Uses same payer as Mojaloop batch (greenbank)
    """
    # Query MifosX for greenbank payer client (same as existing)
    payer = get_client_by_tenant(config, 'greenbank')

    # Query supplementary data table for payees
    cursor.execute("""
        SELECT payee_msisdn, payee_account_number
        FROM operations.mastercard_cbs_supplementary_data
        WHERE is_active = true
        LIMIT 10
    """)

    payees = cursor.fetchall()

    # Generate CSV
    with open('bulk-gazelle-mastercard-cbs-10.csv', 'w') as f:
        writer = csv.writer(f)
        writer.writerow([
            'id', 'request_id', 'payment_mode',
            'payee_identifier_type', 'payee_identifier',
            'amount', 'currency', 'note'
        ])

        for idx, (msisdn, account) in enumerate(payees):
            writer.writerow([
                idx,
                f'cbs-{idx+1:03d}',
                'MASTERCARD_CBS',  # Payment mode
                'MSISDN',
                msisdn,
                random.uniform(100, 1000),
                'ZAR',  # South African Rand
                f'Government grant payment {idx+1}'
            ])

    print("Generated bulk-gazelle-mastercard-cbs-10.csv")
```

---

## Deployment Integration

### Add to run.sh Deployment Flow

**Existing Flow**:
```
run.sh
  ↓
src/deployer/core.sh (infra)
  ↓
src/deployer/mifosx.sh
  ↓
src/deployer/phee.sh
  ↓
src/deployer/vnext.sh
```

**Add CBS Connector** (Option 1 - Part of PHEE):
```bash
# src/deployer/phee.sh (add at end)

if [ "$DEPLOY_MASTERCARD_CBS" = "true" ]; then
  echo "Deploying Mastercard CBS Connector..."

  kubectl create deployment ph-ee-connector-mastercard-cbs \
    --image=${MASTERCARD_CBS_IMAGE:-ph-ee-connector-mastercard-cbs:1.0.0} \
    -n ${PH_NAMESPACE:-paymenthub}

  kubectl set env deployment/ph-ee-connector-mastercard-cbs \
    ZEEBE_BROKER_CONTACTPOINT=zeebe-gateway:26500 \
    MASTERCARD_API_URL=${MASTERCARD_API_URL} \
    DATASOURCE_URL=jdbc:mysql://operationsmysql:3306/operations \
    -n ${PH_NAMESPACE:-paymenthub}

  # Deploy BPMN workflow
  zbctl deploy ~/ph-ee-connector-mccbs/orchestration/bulk_connector_mastercard_cbs-DFSPID.bpmn \
    --address zeebe-gateway.${PH_NAMESPACE}.svc.cluster.local:26500
fi
```

**Add CBS Connector** (Option 2 - Separate Script):
```bash
# src/deployer/mastercard-cbs.sh (new file)

#!/bin/bash
set -e

echo "======================================"
echo "Deploying Mastercard CBS Components"
echo "======================================"

# Deploy CBS Connector
kubectl create deployment ph-ee-connector-mastercard-cbs \
  --image=${MASTERCARD_CBS_IMAGE} \
  -n ${PH_NAMESPACE}

# Load supplementary data
mysql -h operationsmysql -u root -p${MYSQL_PASSWORD} operations \
  < ~/ph-ee-connector-mccbs/src/utils/data-loading/mastercard-cbs-schema.sql

# Deploy BPMN workflow
zbctl deploy ~/ph-ee-connector-mccbs/orchestration/bulk_connector_mastercard_cbs-DFSPID.bpmn

echo "Mastercard CBS deployment complete"
```

### config.ini Integration

```ini
# config/config.ini (add section)

[mastercard_cbs]
enabled=true
connector_image=ph-ee-connector-mastercard-cbs:1.0.0
api_url=https://sandbox.api.mastercard.com
```

---

## Testing Integration

### Use Existing Test Pattern

**Existing Test**:
```bash
# From mifos-gazelle
cd ~/mifos-gazelle/src/utils

# Generate test data
./data-loading/generate-mifos-vnext-data.py --regenerate

# Make payment
./make-payment.sh
```

**Add Mastercard CBS Test**:
```bash
# make-mastercard-payment.sh (new script)
#!/bin/bash

set -e

echo "Testing Mastercard CBS Payment Flow"

# 1. Load supplementary data
python3 data-loading/load-mastercard-supplementary-data.py -c ~/tomconfig.ini

# 2. Generate test batch CSV
python3 data-loading/generate-example-csv-files.py -c ~/tomconfig.ini

# 3. Submit batch
python3 data-loading/submit-batch.py \
  -c ~/tomconfig.ini \
  -f data-loading/bulk-gazelle-mastercard-cbs-10.csv \
  --tenant greenbank \
  --payment-mode MASTERCARD_CBS

# 4. Monitor progress
echo "Checking batch status..."
BATCH_ID=$(kubectl logs -n paymenthub -l app=ph-ee-bulk-processor --tail=10 | grep "Batch ID" | awk '{print $NF}')

kubectl exec -n paymenthub operationsmysql-0 -- \
  mysql -uroot -pmysql operations_app -e \
  "SELECT batch_id, total, successful, failed, ongoing
   FROM batch WHERE batch_id = '${BATCH_ID}'"

echo "Mastercard CBS payment test complete"
```

---

## Directory Structure in mifos-gazelle

```
mifos-gazelle/
├── branches/
│   └── mastercard/  (new branch)
│       ├── config/
│       │   ├── config.ini (add [mastercard_cbs] section)
│       │   └── ph_values.yaml (add CBS connector config)
│       ├── src/
│       │   ├── deployer/
│       │   │   └── mastercard-cbs.sh (new)
│       │   └── utils/
│       │       ├── data-loading/
│       │       │   ├── load-mastercard-supplementary-data.py (new)
│       │       │   └── generate-example-csv-files.py (update)
│       │       ├── make-mastercard-payment.sh (new)
│       │       └── k8s-error-summary.py (existing)
│       └── repos/
│           └── ph-ee-connector-mccbs/ (symlink to ~/ph-ee-connector-mccbs)
```

---

## Benefits of Integration

### 1. Reuse Existing Infrastructure
- Same databases (operations, identity_account_mapper)
- Same tenant structure
- Same Payment Hub components
- Same monitoring tools

### 2. Consistent Data Management
- Same MSISDNs across all payment modes
- Single source of truth for beneficiaries
- Consistent CSV format
- Same submission patterns

### 3. Simplified Testing
- Test Mojaloop, Closedloop, and Mastercard CBS together
- Compare payment modes
- Use same test scripts
- Same monitoring approach

### 4. Easier Development
- hostPath mounts work same way
- Rebuild pattern consistent
- Configuration pattern familiar
- Same troubleshooting tools

---

## Next Steps

### 1. Create Mastercard Branch in mifos-gazelle
```bash
cd ~/mifos-gazelle
git checkout -b mastercard
```

### 2. Add CBS Connector to repos/
```bash
cd ~/mifos-gazelle/repos
ln -s ~/ph-ee-connector-mccbs ph-ee-connector-mccbs
```

### 3. Create Data Loading Script
```bash
cp ~/mifos-gazelle/src/utils/data-loading/generate-mifos-vnext-data.py \
   ~/mifos-gazelle/src/utils/data-loading/load-mastercard-supplementary-data.py

# Modify to populate mastercard_cbs_supplementary_data table
```

### 4. Update ph_values.yaml
```bash
# Add CBS connector to config/ph_values.yaml
vi ~/mifos-gazelle/config/ph_values.yaml
```

### 5. Test End-to-End
```bash
# Deploy everything
cd ~/mifos-gazelle
sudo ./run.sh

# Load CBS data
./src/utils/data-loading/load-mastercard-supplementary-data.py -c ~/tomconfig.ini

# Test payment
./src/utils/make-mastercard-payment.sh
```

---

**Document Created**: January 24, 2026
**Purpose**: Integrate Mastercard CBS with mifos-gazelle ecosystem
**Next**: Create mastercard branch and add data loading scripts
