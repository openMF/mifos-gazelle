# Mastercard CBS Connector — Operator Deployment Guide

> **Prerequisites**: Payment Hub EE must be deployed before enabling the Mastercard CBS connector.
> For local development iteration, see [LOCALDEV.md](../LOCALDEV.md).
> For integration details, see [MIFOS_GAZELLE_INTEGRATION.md](MIFOS_GAZELLE_INTEGRATION.md).

---

## Architecture Overview

The Mastercard CBS connector uses a **Kubernetes Operator** pattern:
- A `MastercardCBSConnector` Custom Resource (CRD) declares the desired connector state
- A shell-based controller (`controllers/reconcile.sh`) watches the CR and reconciles — creating/updating deployments, loading DB schemas, and deploying BPMN workflows
- This lives entirely inside `src/deployer/operators/mastercard/` in the mifos-gazelle repo; the operator manages the connector image from `~/ph-ee-connector-mccbs`

---

## Quick Start

### Step 1 — Configure `config/config.ini`

```ini
[mastercard-demo]
enabled = true
MASTERCARD_NAMESPACE = mastercard-demo
MASTERCARD_CBS_HOME = ~/ph-ee-connector-mccbs
MASTERCARD_API_URL = https://sandbox.api.mastercard.com
MASTERCARD_PARTNER_ID = <your-partner-id>
MASTERCARD_CONSUMER_KEY = <your-consumer-key>
MASTERCARD_SIGNING_KEY_ALIAS = <alias>
MASTERCARD_SIGNING_KEY_PASSWORD = <password>
MASTERCARD_SIGNING_KEY_PATH = /path/to/signing.p12

# JWE encryption (optional)
MASTERCARD_ENCRYPTION_ENABLED = false
```

### Step 2 — Deploy

```bash
# Deploy with all other apps
sudo ./run.sh -u $USER -m deploy -a all

# Or deploy Mastercard connector only (Payment Hub must already be running)
sudo ./run.sh -u $USER -m deploy -a mastercard-demo
```

The deploy sequence (`src/deployer/mastercard.sh`):
1. Creates `mastercard-demo` namespace
2. Creates K8s secrets from config.ini values (credentials, certs, copies `operationsmysql` secret)
3. Deploys the CRD, RBAC, and operator pod from `src/deployer/operators/mastercard/`
4. Applies the `MastercardCBSConnector` CR → operator deploys the connector
5. Deploys BPMN workflow (`MastercardFundTransfer-DFSPID.bpmn` for greenbank/redbank/bluebank)
6. Loads supplementary data (`src/utils/mastercard/load-mastercard-supplementary-data.sh`)
7. Generates sample CSV (`src/utils/data-loading/bulk-gazelle-mastercard-6.csv`)

### Step 3 — Verify

```bash
# Custom Resource status
kubectl get mastercardcbsconnector -n mastercard-demo

# Pods
kubectl get pods -n mastercard-demo

# Operator logs
kubectl logs -n mastercard-demo -l app=mastercard-cbs-operator -f

# Connector logs
kubectl logs -n mastercard-demo -l app=ph-ee-connector-mastercard-cbs -f
```

**CR Status Fields:**
| Field | Values | Meaning |
|-------|--------|---------|
| `phase` | Pending, Initializing, Ready, Failed, Disabled | Overall lifecycle state |
| `connectorReady` | true/false | Connector deployment healthy |
| `workflowDeployed` | true/false | BPMN deployed to Zeebe |
| `dataLoaded` | true/false | Supplementary data loaded |

---

## Directory Structure

```
mifos-gazelle/
└── src/deployer/
    ├── mastercard.sh                           # Main deploy/cleanup functions
    └── operators/mastercard/
        ├── config/
        │   ├── crd/mastercard-cbs-connector.yaml
        │   ├── rbac/{service_account,role,role_binding}.yaml
        │   └── samples/
        │       ├── mastercard-cbs-default.yaml   # Standard CR sample
        │       └── mastercard-cbs-localdev.yaml  # hostPath local dev CR
        ├── controllers/reconcile.sh              # Operator reconciliation logic
        └── deploy-operator.sh                    # Operator install/uninstall

~/ph-ee-connector-mccbs/
└── orchestration/
    └── MastercardFundTransfer-DFSPID.bpmn        # BPMN workflow (required)
```

---

## Configuration Reference

### config.ini `[mastercard-demo]` section

| Key | Required | Default | Description |
|-----|----------|---------|-------------|
| `enabled` | Yes | `false` | Set `true` to deploy |
| `MASTERCARD_NAMESPACE` | No | `mastercard-demo` | K8s namespace |
| `MASTERCARD_CBS_HOME` | No | `~/ph-ee-connector-mccbs` | Path to connector source |
| `MASTERCARD_API_URL` | No | `https://sandbox.api.mastercard.com` | Mastercard API endpoint |
| `MASTERCARD_PARTNER_ID` | For real payments | — | From Mastercard Developers portal |
| `MASTERCARD_CONSUMER_KEY` | For real payments | — | OAuth1 consumer key |
| `MASTERCARD_SIGNING_KEY_ALIAS` | For real payments | — | P12 key alias |
| `MASTERCARD_SIGNING_KEY_PASSWORD` | For real payments | — | P12 key password |
| `MASTERCARD_SIGNING_KEY_PATH` | For Docker mode | — | Local path to signing .p12 (bundled as K8s Secret) |
| `MASTERCARD_ENCRYPTION_ENABLED` | No | `false` | Enable JWE encryption |
| `MASTERCARD_LOCALDEV_ENABLED` | No | `false` | Mount local source via hostPath (see [LOCALDEV.md](../LOCALDEV.md)) |

> **Note on cert paths**: `MASTERCARD_SIGNING_KEY_PATH` and related paths are read from the **local machine** and stored as a K8s Secret at deploy time. This is required for Docker image deployments. In `MASTERCARD_LOCALDEV_ENABLED=true` mode, certs can be bundled in the locally-compiled JAR instead.

### Custom Resource

The operator creates a CR like this (written to `/tmp/mastercard-cbs-cr.yaml` during deployment):

```yaml
apiVersion: paymenthub.mifos.io/v1alpha1
kind: MastercardCBSConnector
metadata:
  name: mastercard-cbs
  namespace: mastercard-demo
spec:
  enabled: true
  replicas: 1
  image:
    repository: ph-ee-connector-mastercard-cbs
    tag: "1.0.0"
  mastercard:
    apiUrl: "https://sandbox.api.mastercard.com"
    clientSecretName: "mastercard-cbs-credentials"
  paymenthub:
    namespace: "paymenthub"
    zeebeGateway: "phee-zeebe-gateway.paymenthub.svc.cluster.local:26500"
    operationsDb:
      host: "operationsmysql.paymenthub.svc.cluster.local"
      port: 3306
      database: "operations"
      secretName: "mysql-secret"
  dataLoading:
    autoLoad: true
    demoPayeeCount: 10
  workflow:
    autoDeploy: false
```

---

## Operator Lifecycle

### Update configuration

Edit the CR and apply:
```bash
kubectl edit mastercardcbsconnector mastercard-cbs -n mastercard-demo
# Operator automatically reconciles changes
```

### Scale
```bash
kubectl patch mastercardcbsconnector mastercard-cbs -n mastercard-demo \
  --type='json' -p='[{"op":"replace","path":"/spec/replicas","value":2}]'
```

### Disable (keep CR)
```bash
kubectl patch mastercardcbsconnector mastercard-cbs -n mastercard-demo \
  --type='merge' -p '{"spec":{"enabled":false}}'
```

### Remove
```bash
# Via run.sh
sudo ./run.sh -u $USER -m cleanapps -a mastercard-demo

# Manually
kubectl delete mastercardcbsconnector mastercard-cbs -n mastercard-demo
cd ~/mifos-gazelle/src/deployer/operators/mastercard
bash deploy-operator.sh undeploy
kubectl delete namespace mastercard-demo
```

---

## Troubleshooting

### Operator not starting
```bash
kubectl get pods -n mastercard-demo
kubectl describe pod -n mastercard-demo -l app=mastercard-cbs-operator
kubectl logs -n mastercard-demo -l app=mastercard-cbs-operator --tail=50
```

### CR stuck in `Initializing`
```bash
kubectl get mastercardcbsconnector mastercard-cbs -n mastercard-demo -o yaml | grep -A10 status
```
Check: PaymentHub namespace exists, `mysql-secret` was copied successfully, operator has correct RBAC.

### Connector not registering workers with Zeebe
```bash
kubectl logs -n mastercard-demo -l app=ph-ee-connector-mastercard-cbs | grep "Registered worker"
```
Expected: 8 workers registered (mastercard-cbs-validate-input, mastercard-cbs-authenticate, etc.). Check Zeebe gateway connectivity between namespaces.

### Supplementary data not loading
```bash
cat /tmp/mastercard-data-load.log
kubectl get jobs -n mastercard-demo
```

### Cert/secret errors
Ensure `MASTERCARD_SIGNING_KEY_PATH` points to a readable `.p12` file on the local machine before running `run.sh`. The file is read and stored as a K8s Secret (`mastercard-cbs-certs`).
