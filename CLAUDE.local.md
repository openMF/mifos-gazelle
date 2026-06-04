# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

Mifos Gazelle is a Digital Public Infrastructure as a Solution (DaaS) deployment tool that enables deployment of three Digital Public Goods (DPGs) on Kubernetes:
- **MifosX** (Core Banking with Apache Fineract v1.11.0)
- **Payment Hub EE (PHEE)** v1.13.0 (Payment orchestration)
- **Mojaloop vNext Beta1** (Financial transactions switch)


### Deployment Commands

```bash
# Deploy all components (requires sudo, 24GB RAM minimum)
sudo ./run.sh 
```

### Configuration File Support

Mifos Gazelle uses a centralized `config.ini` file for non-path configuration:
- **Default**: `config/config.ini`
- **Custom**: Use `-f` flag to specify alternative config file
- See [docs/CONFIG-FILE-SUPPORT.md](docs/CONFIG-FILE-SUPPORT.md) for full schema and details

### Monitoring and Debugging

```bash
# Check all pods status
kubectl get pods -A

# Check error summary across cluster
./src/utils/k8s-error-summary.py

# View logs for specific component
kubectl logs -n <namespace> -l app=<app-name> --tail=100

# Access MifosX database
~/mifos-gazelle/src/utils/mysql-client-mifos.sh

# Access PaymentHub database
~/mifos-gazelle/src/utils/mysql-client-mifos.sh -h operationsmysql.paymenthub.svc.cluster.local -p ethieTieCh8ahv -u root -d mysql
```
### Testing End-to-End Payment Flow

```bash
# Execute test payment from Greenbank to Bluebank via vNext switch
./src/utils/make-payment.sh
```

### GovStack G2P Bulk Disbursement

```bash
# Generate example CSV files for testing
./src/utils/data-loading/generate-example-csv-files.py -c ~/tomconfig.ini

# Submit closedloop batch (redbank payer, no switch)
./src/utils/data-loading/submit-batch.py \
  -c ~/tomconfig.ini \
  -f ./src/utils/data-loading/bulk-gazelle-closedloop-4.csv \
  --tenant redbank

# Submit Mojaloop batch (greenbank payer, via switch)
./src/utils/data-loading/submit-batch.py \
  -c ~/tomconfig.ini \
  -f ./src/utils/data-loading/bulk-gazelle-mojaloop-4.csv \
  --tenant greenbank

# Submit with GovStack identity validation
./src/utils/data-loading/submit-batch.py \
  -c ~/tomconfig.ini \
  -f ./src/utils/data-loading/bulk-gazelle-mojaloop-4.csv \
  --tenant greenbank \
  --govstack \
  --registering-institution greenbank
```

## Architecture Overview

### Directory Structure

```
mifos-gazelle/
├── run.sh                    # Main entry point for all operations
├── config/                   # Configuration files
│   ├── config.ini           # Main config (namespaces, repos, domains)
│   ├── ph_values.yaml       # Payment Hub Helm values
│   ├── nginx_values.yaml    # NGINX ingress values
│   └── mifos-tenant-config.csv  # MifosX tenant definitions
├── src/
│   ├── commandline/         # CLI parsing and configuration loading
│   ├── deployer/            # Deployment logic per DPG
│   │   ├── deployer.sh      # Main orchestrator
│   │   ├── mifosx.sh        # MifosX deployment
│   │   ├── phee.sh          # Payment Hub EE deployment
│   │   ├── vnext.sh         # Mojaloop vNext deployment
│   │   └── core.sh          # K8s cluster setup
│   ├── environmentSetup/    # Environment preparation
│   └── utils/               # Utility scripts
│       ├── data-loading/    # G2P test data generation
│       ├── localdev/        # Local development guides
│       └── test-scripts/    # Test utilities
├── repos/                   # Cloned DPG repositories
│   ├── mifosx/             # MifosX Docker deployments
│   ├── vnext/              # Mojaloop vNext manifests
│   ├── phlabs/             # Payment Hub EE Helm charts
│   └── ph_template/        # Payment Hub EE environment templates
├── orchestration/           # BPMN workflow definitions
├── docs/                    # Documentation
│   ├── MIFOS-GAZELLE-README.md  # Main deployment guide
│   ├── VNEXT-README.md          # vNext standalone guide
│   ├── CONFIG-FILE-SUPPORT.md   # Config file documentation
│   ├── DEV-TEST-TIPS.md         # Local development with hostPath
│   └── GOVSTACK.md              # G2P architecture deep-dive
└── postman/                 # Postman collections for testing
```

### Deployment Flow

1. **`run.sh`**: Entry point, sources `src/commandline/commandline.sh`
2. **Configuration Loading**: Reads `config.ini` using `crudini`, sets environment variables
3. **Validation**: Checks prerequisites (OS, RAM, disk space, dependencies)
4. **Environment Setup** (`src/environmentSetup/`):
   - Installs k3s Kubernetes cluster (if local mode)
   - Installs kubectl, helm, k9s
   - Sets up kubeconfig
5. **Infrastructure Deployment** (`src/deployer/core.sh`):
   - Creates namespaces
   - Deploys NGINX ingress controller
6. **Application Deployment** (`src/deployer/{mifosx,phee,vnext}.sh`):
   - Clones repositories from config
   - Applies Kubernetes manifests or Helm charts
   - Waits for pods to be ready

### Key Technologies

- **Kubernetes**: k3s for local, supports remote clusters
- **Deployment Methods**:
  - MifosX: kubectl apply on YAML manifests
  - Payment Hub EE: Helm charts with custom values
  - vNext: kubectl apply on layered manifests (crosscut → apps → reporting)
- **Databases**: MySQL (MifosX, PHEE), MongoDB (vNext)
- **Service Mesh**: NGINX ingress for routing
- **Workflow Engine**: Zeebe (for PHEE BPMN workflows)

## Important Concepts

### Tenants in MifosX and Payment Hub EE

Mifos Gazelle deploys three default tenants:
- **`greenbank`**: Payer using Mojaloop switch (PayerFundTransfer workflow)
- **`redbank`**: Payer using closedloop/direct transfers (minimal_mock_fund_transfer workflow)
- **`bluebank`**: Payee FSP (receives funds)

**Critical for Payment Hub**:
- Tenant workflows must be configured in BOTH `ph-ee-bulk-processor` AND `ph-ee-connector-channel`
- Configuration files:
  - `~/ph-ee-bulk-processor/src/main/resources/application.yaml`
  - `~/ph-ee-connector-channel/src/main/resources/application.yml`
- When using hostpath mounts (dev mode), must rebuild JARs and restart pods after config changes

### GovStack G2P Architecture

see @docs/GOVSTACK.md


#### GovStack Requirement Compliance

| Jira ID | Requirement | Mifos Gazelle Status | Implementation |
|---------|-------------|----------------------|----------------|
| GOV-75 | Payment to Bank Account | ✅ COMPLIANT | Bulk processor accepts IBAN as financial address |
| GOV-78 | Payment to MoMo Account | ✅ COMPLIANT | Supports MSISDN→IBAN via identity mapper |
| GOV-79 | Payment to MoMo (non-Mojaloop) | ✅ COMPLIANT | GSMA connector planned, MSISDN+BIC supported |
| GOV-99 | Interconnect with Aggregators | ✅ COMPLIANT | Payer FSP handles aggregator/bilateral integrations |
| GOV-106 | Periodic bulk payments | ⚠️ PARTIAL | Scheduling handled by Registration BB (out of scope) |
| GOV-119 | Distribution to Bank/MoMo | ✅ COMPLIANT | Agnostic to destination financial address type |
| GOV-121 | Status of payments | ✅ COMPLIANT | Payment_Status_Check API (Spec Section 3.1) |
| GOV-122 | Transaction logs | 🔧 DEFERRED | Audit/logging in Technical Architecture doc |

#### Key Configuration Files for GovStack Compliance

**Identity Account Mapper**:
- Database: `identity_account_mapper`
- API: `POST /api/v1/identity-account-mapper/batch-account-lookup`
- Returns: `bankingInstitutionCode` (payee FSP ID) per beneficiary

**Bulk Processor** (`ph-ee-bulk-processor/src/main/resources/application.yaml`):
```yaml
bpmns:
  tenants:
    - id: "greenbank"
      flows:
        batch-transactions: "bulk_processor_account_lookup-{dfspid}"  # GovStack mode
```

**Connector Channel** (`ph-ee-connector-channel/src/main/resources/application.yml`):
```yaml
bpmns:
  tenants:
    - id: "greenbank"
      flows:
        payment-transfer: "PayerFundTransfer-{dfspid}"  # Mojaloop routing
```

#### Verifying GovStack Compliance

```bash
# 1. Verify identity mapper database has beneficiaries
kubectl exec -n infra mysql-0 -- mysql -umifos -ppassword identity_account_mapper -e \
  "SELECT COUNT(*) FROM identity_details WHERE registering_institution_id = 'greenbank'"

# 2. Submit GovStack-compliant batch
./src/utils/data-loading/submit-batch.py \
  -c ~/tomconfig.ini \
  -f ./src/utils/data-loading/bulk-gazelle-mojaloop-4.csv \
  --tenant greenbank \
  --govstack \
  --registering-institution greenbank

# 3. Verify batch de-bulking occurred
kubectl logs -n paymenthub -l app=ph-ee-bulk-processor --tail=100 | grep -i "splitting"

# 4. Check transfers have payee FSP IDs
kubectl exec -n paymenthub operationsmysql-0 -- mysql -uroot -pmysql operations_app -e \
  "SELECT payee_identifier, payee_dfsp_id, status FROM transfers ORDER BY id DESC LIMIT 5"
```

#### Non-Compliance Notes

**What Mifos Gazelle Does NOT Implement** (per GovStack spec):
- **Voucher Engine**: Spec 4.1 component for offline payments (not in current scope)
- **CBDC Support**: Spec Scenarios 5-6 (Central Bank Digital Currency not yet supported)
- **Regional Switch**: Spec Scenario 1 (cross-border G2P not in current scope)

**What is Outside Payments BB Scope** (per spec):
- Beneficiary registration (Registration BB responsibility)
- Payment periodicity/scheduling (Source BB responsibility)
- Switch governance and operations (Scheme Operator responsibility)
- Reconciliation and settlement (handled by switch/scheme)

See [docs/GOVSTACK.md](docs/GOVSTACK.md) for detailed architecture and troubleshooting

### Payment Flow Example

**Greenbank → Bluebank via vNext**:
1. User initiates payment via Payment Hub API
2. PHEE orchestrates via BPMN workflow (PayerFundTransfer-greenbank)
3. Connector-channel starts tenant-specific workflow
4. Connector-mojaloop sends transfer to vNext switch
5. vNext queries oracle: "Which FSP owns MSISDN?"
6. vNext routes to bluebank FSP callback
7. Bluebank receives credit, confirms to switch
8. Switch confirms to greenbank
9. Greenbank commits funds

### Local Development with hostPath Mounts

For modifying Payment Hub EE components during development:
1. Mount local source directory into container via hostPath volume
2. Modify code locally (e.g., `~/ph-ee-bulk-processor/src/main/...`)
3. Rebuild JAR: `cd ~/ph-ee-bulk-processor && ./gradlew clean build -x test`
4. Restart pod: `kubectl delete pod -n paymenthub -l app=ph-ee-bulk-processor`

See [docs/DEV-TEST-TIPS.md](docs/DEV-TEST-TIPS.md) for full guide.

```

### URLs

- **MifosX Web Client**: http://mifos.mifos.gazelle.test (login: mifos/password, select tenant)
- **vNext Admin UI**: http://vnextadmin.mifos.gazelle.test (login: admin/superMegaPass)
- **Payment Hub Operations Web**: http://ops.mifos.gazelle.test
- **Zeebe Operate (BPMN monitoring)**: http://zeebe-operate.mifos.gazelle.test (login: demo/demo)

### When Modifying Deployment Scripts

- Configuration variables: Add to `config/config.ini` (not in shell scripts)
- Path/topology variables: Keep in `run.sh` or `src/deployer/core.sh`
- DPG-specific logic: Edit respective deployer scripts (`mifosx.sh`, `phee.sh`, `vnext.sh`)
- Always test with `-d true` (debug mode) first

### When Working with Payment Hub EE

- BPMN workflows located in: `orchestration/feel/*.bpmn`
- Zeebe workflow deployment: Use `./src/utils/deployBpmn-gazelle.sh`
- Tenant configuration changes: Requires JAR rebuild + pod restart (see tenant section above)
- Check workflow execution: Zeebe Operate UI at http://zeebe-operate.mifos.gazelle.test

### When Troubleshooting Deployments

1. Check pod status: `kubectl get pods -A`
2. View error summary: `./src/utils/k8s-error-summary.py`
3. Check specific component logs: `kubectl logs -n <namespace> -l app=<app-name>`
4. Verify configuration loaded correctly: Look for log output with `-d true` flag
5. For Payment Hub batch issues: Check operations_app database for batch/transfer status

### When Adding New Features

- Repository structure: Mifos Gazelle is deployment tooling, not application code
- Application code lives in: `repos/mifosx/`, `repos/vnext/`, `repos/phlabs/`, `repos/ph_template/`
- Deployment code lives in: `src/deployer/`, `src/environmentSetup/`
- Utilities: Add to `src/utils/` with descriptive names

