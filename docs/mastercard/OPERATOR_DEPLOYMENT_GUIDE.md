###  Mastercard CBS - Operator Deployment Guide

> **Related Documentation:**
> - For local development with operator, see [LOCALDEV.md](LOCALDEV.md)
> - For mifos-gazelle integration, see [MASTERCARD-CBS-INTEGRATION.md](MASTERCARD-CBS-INTEGRATION.md)
> - For configuration options, see [MASTERCARD-CONFIG.md](MASTERCARD-CONFIG.md)

## Architecture Overview

The Mastercard CBS connector uses a **Kubernetes Operator** pattern instead of traditional Helm charts. This provides:

- **Declarative Configuration**: Define desired state in Custom Resources
- **Automatic Reconciliation**: Operator ensures actual state matches desired state
- **Self-Healing**: Operator automatically fixes drift
- **Future-Ready**: Easy migration to Go-based operator later

---

## Operator Components

### 1. Custom Resource Definition (CRD)

Defines the `MastercardCBSConnector` resource type:

```yaml
apiVersion: paymenthub.mifos.io/v1alpha1
kind: MastercardCBSConnector
metadata:
  name: mastercard-cbs
  namespace: mastercard-demo
spec:
  enabled: true
  mastercard:
    apiUrl: "https://sandbox.api.mastercard.com"
  ...
```

### 2. Operator Controller

Shell-based controller that watches CRs and reconciles state:
- Creates/updates deployments
- Loads database schemas
- Deploys BPMN workflows
- Manages lifecycle

### 3. RBAC

Service account, roles, and bindings for operator permissions.

---

## Quick Start

### Option 1: Deploy via mifos-gazelle run.sh

1. **Add to config.ini**:
```ini
[mastercard-demo]
enabled=true
namespace=mastercard-demo
...
```

2. **Run deployment**:
```bash
cd ~/mifos-gazelle
sudo ./run.sh -a mastercard-demo 
```

### Option 2: Deploy Standalone

1. **Deploy operator**:
```bash
cd ~/ph-ee-connector-mccbs/operator
./deploy-operator.sh deploy
```

2. **Create connector instance**:
```bash
kubectl apply -f config/samples/mastercard-cbs-default.yaml
```

3. **Check status**:
```bash
kubectl get mastercardcbsconnector -n mastercard-demo
```

### Option 3: Use mifos-gazelle deployer

```bash
cd ~/mifos-gazelle
source src/deployer/mastercard.sh
deploy_mastercard
```

---

## Configuration Options

### config.ini Section

```ini
[mastercard-demo]
# Enable/disable Mastercard CBS
enabled=true

# Kubernetes namespace
namespace=mastercard-demo

# Mastercard CBS home directory
cbs_home=/home/tdaly/ph-ee-connector-mccbs

# Mastercard CBS sandbox API URL
api_url=https://sandbox.api.mastercard.com

# Sandbox credentials
# client_id=YOUR_CLIENT_ID
# client_secret=YOUR_CLIENT_SECRET
# partner_id=YOUR_PARTNER_ID

# PaymentHub namespace
paymenthub_namespace=paymenthub

# Connector replicas
replicas=1
```

### Custom Resource Spec

Full CR specification:

```yaml
apiVersion: paymenthub.mifos.io/v1alpha1
kind: MastercardCBSConnector
metadata:
  name: mastercard-cbs
  namespace: mastercard-demo
spec:
  # Enable the connector
  enabled: true

  # Number of replicas
  replicas: 1

  # Connector image
  image:
    repository: ph-ee-connector-mastercard-cbs
    tag: "1.0.0"
    pullPolicy: IfNotPresent

  # Mastercard API configuration
  mastercard:
    apiUrl: "https://sandbox.api.mastercard.com"
    partnerId: "YOUR_PARTNER_ID"
    clientSecretName: "mastercard-cbs-credentials"

  # PaymentHub integration
  paymenthub:
    namespace: "paymenthub"
    zeebeGateway: "zeebe-gateway.paymenthub.svc.cluster.local:26500"
    operationsDb:
      host: "operationsmysql.paymenthub.svc.cluster.local"
      port: 3306
      database: "operations"
      secretName: "mysql-secret"

  # Data loading
  dataLoading:
    autoLoad: true
    demoPayeeCount: 10

  # BPMN workflow
  workflow:
    autoDeploy: true

  # Resource limits
  resources:
    limits:
      cpu: "500m"
      memory: "512Mi"
    requests:
      cpu: "250m"
      memory: "256Mi"
```

---

## Operator Lifecycle

### Deploy

```bash
# Deploy operator
cd ~/ph-ee-connector-mccbs/operator
./deploy-operator.sh deploy

# Create connector instance
kubectl apply -f config/samples/mastercard-cbs-default.yaml

# Or via mifos-gazelle
cd ~/mifos-gazelle
source src/deployer/mastercard.sh
deploy_mastercard
```

### Update Configuration

Edit the CR and apply:

```bash
kubectl edit mastercardcbsconnector mastercard-cbs -n mastercard-demo

# Or update YAML and apply
kubectl apply -f my-updated-config.yaml
```

Operator automatically reconciles changes!

### Scale

```bash
kubectl patch mastercardcbsconnector mastercard-cbs -n mastercard-demo \
  --type='json' \
  -p='[{"op": "replace", "path": "/spec/replicas", "value":2}]'
```

### Disable (but keep CR)

```bash
kubectl patch mastercardcbsconnector mastercard-cbs -n mastercard-demo \
  --type='merge' \
  -p '{"spec":{"enabled":false}}'
```

Operator will cleanup all resources but preserve CR.

### Undeploy

```bash
# Delete CR (operator cleans up resources)
kubectl delete mastercardcbsconnector mastercard-cbs -n mastercard-demo

# Undeploy operator
cd ~/ph-ee-connector-mccbs/operator
./deploy-operator.sh undeploy

# Or via mifos-gazelle
cd ~/mifos-gazelle
source src/deployer/mastercard.sh
cleanup
```

---

## Monitoring

### Check CR Status

```bash
# List all connectors
kubectl get mastercardcbsconnector --all-namespaces

# Get detailed status
kubectl get mastercardcbsconnector mastercard-cbs -n mastercard-demo -o yaml

# Watch status changes
kubectl get mastercardcbsconnector -n mastercard-demo -w
```

**Status Fields**:
- `phase`: Pending, Initializing, Ready, Failed, Disabled
- `connectorReady`: CBS connector deployment ready
- `workflowDeployed`: BPMN workflow deployed
- `dataLoaded`: Supplementary data loaded

### Check Operator Logs

```bash
kubectl logs -n mastercard-demo -l app=mastercard-cbs-operator -f
```

### Check Connector Logs

```bash
kubectl logs -n mastercard-demo -l app=ph-ee-connector-mastercard-cbs -f
```

---

## Troubleshooting

### Operator Not Starting

**Check:**
```bash
kubectl get pods -n mastercard-demo
kubectl logs -n mastercard-demo -l app=mastercard-cbs-operator --tail=50
```

**Fix:**
- Verify RBAC permissions
- Check operator pod events: `kubectl describe pod -n mastercard-demo -l app=mastercard-cbs-operator`

### CR Stuck in Initializing

**Check:**
```bash
kubectl get mastercardcbsconnector mastercard-cbs -n mastercard-demo -o yaml | grep -A 10 status
```

**Fix:**
- Check operator logs for errors
- Verify PaymentHub namespace exists
- Verify mysql-secret exists

### Connector Not Registered with Zeebe

**Check:**
```bash
kubectl logs -n mastercard-demo -l app=ph-ee-connector-mastercard-cbs | grep "Registered worker"
```

**Expected output** (8 workers):
```
Registered worker: mastercard-cbs-validate-input
Registered worker: mastercard-cbs-authenticate
Registered worker: mastercard-cbs-match-regulatory-data
Registered worker: mastercard-cbs-initiate-payment
Registered worker: mastercard-cbs-check-status
Registered worker: mastercard-cbs-update-operations
Registered worker: mastercard-cbs-retry-handler
Registered worker: mastercard-cbs-log-error
```

**Fix:**
- Verify Zeebe gateway service exists in paymenthub namespace
- Check network connectivity between namespaces

### Data Not Loading

**Check:**
```bash
kubectl get jobs -n mastercard-demo
kubectl logs -n mastercard-demo job/mastercard-cbs-data-loader
```

**Fix:**
- Verify database connection
- Check if identity_account_mapper has data
- Run data loading manually

---

## Advanced Operations

### Manual Data Loading

```bash
cd ~/mifos-gazelle/src/utils/data-loading
./load-mastercard-supplementary-data.py -c ~/tomconfig.ini --regenerate
```

### Manual Workflow Deployment

```bash
zbctl deploy ~/ph-ee-connector-mccbs/orchestration/bulk_connector_mastercard_cbs-DFSPID.bpmn \
  --address zeebe-gateway.paymenthub.svc.cluster.local:26500
```

### Update Sandbox Credentials

Update CR:
```bash
kubectl patch mastercardcbsconnector mastercard-cbs -n mastercard-demo \
  --type='merge' \
  -p '{
    "spec":{
      "mastercard":{
        "apiUrl":"https://sandbox.api.mastercard.com",
        "partnerId":"YOUR_PARTNER_ID"
      }
    }
  }'
```

Update secret:
```bash
kubectl create secret generic mastercard-cbs-credentials \
  -n mastercard-demo \
  --from-literal=client_id=YOUR_CLIENT_ID \
  --from-literal=client_secret=YOUR_CLIENT_SECRET \
  --from-literal=partner_id=YOUR_PARTNER_ID \
  --dry-run=client -o yaml | kubectl apply -f -
```

---

## Integration with run.sh

### Option 1: Add to run.sh directly

Edit `~/mifos-gazelle/run.sh`:

```bash
# After PaymentHub deployment
if [ "$DEPLOY_MASTERCARD" == "true" ]; then
    source "$DEPLOYER_DIR/mastercard.sh"
    deploy_mastercard
fi
```

### Option 2: Conditional deployment

```bash
# Deploy core gazelle
cd ~/mifos-gazelle
sudo ./run.sh

# Then deploy mastercard
sudo bash -c 'source src/deployer/mastercard.sh && deploy_mastercard'
```

### Option 3: Separate command

```bash
# Add to run.sh
case "$1" in
    --mastercard)
        source src/deployer/mastercard.sh
        deploy_mastercard
        ;;
    --mastercard-only)
        source src/deployer/mastercard.sh
        deploy_mastercard
        ;;
esac
```

Usage:
```bash
cd ~/mifos-gazelle
sudo ./run.sh --mastercard
```

---

## Future Migration to Go Operator

The current shell-based operator can be migrated to Go using Operator SDK:

```bash
# Initialize Go operator project
operator-sdk init --domain=mifos.io --repo=github.com/mifos/mastercard-cbs-operator

# Create API
operator-sdk create api --group=paymenthub --version=v1alpha1 --kind=MastercardCBSConnector

# Implement controller logic
# ... (migrate reconcile.sh logic to Go)

# Build and deploy
make docker-build docker-push IMG=mastercard-cbs-operator:v1.0.0
make deploy IMG=mastercard-cbs-operator:v1.0.0
```

CRD remains the same! Just controller implementation changes.

---

## Benefits Over Helm

| Feature | Helm | Operator |
|---------|------|----------|
| **Installation** | One-time install | Continuous reconciliation |
| **Updates** | Manual helm upgrade | Automatic when CR changes |
| **Drift Detection** | None | Automatic |
| **Complex Logic** | Limited | Full programming language |
| **Day-2 Operations** | Manual scripts | Built-in automation |
| **State Management** | Client-side | Server-side (etcd) |
| **Migration to Operator** | Full rewrite | Already there! |

---

## Directory Structure

```
ph-ee-connector-mccbs/
├── operator/
│   ├── config/
│   │   ├── crd/
│   │   │   └── mastercard-cbs-connector.yaml    # CRD definition
│   │   ├── rbac/
│   │   │   ├── service_account.yaml
│   │   │   ├── role.yaml
│   │   │   └── role_binding.yaml
│   │   └── samples/
│   │       └── mastercard-cbs-default.yaml      # Sample CR
│   ├── controllers/
│   │   └── reconcile.sh                         # Controller logic
│   └── deploy-operator.sh                       # Operator deployment

mifos-gazelle/
└── src/deployer/
    └── mastercard.sh                            # Integration script
```

---

## Summary

**What You Get**:
- ✅ Kubernetes-native deployment
- ✅ Declarative configuration
- ✅ Automatic reconciliation
- ✅ Self-healing
- ✅ Integrated with mifos-gazelle
- ✅ Future-ready for Go operator

**Next Steps**:
1. Add [mastercard-demo] to config.ini
2. Run: `cd ~/mifos-gazelle && sudo ./run.sh`
3. Deploy: `source src/deployer/mastercard.sh && deploy_mastercard`
4. Verify: `kubectl get mastercardcbsconnector -n mastercard-demo`

---

**Document Created**: January 24, 2026
**Operator Version**: v1alpha1 (shell-based)
**Status**: Ready for deployment
**Migration Path**: Go operator when needed
