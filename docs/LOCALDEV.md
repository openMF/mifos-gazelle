# Local Development Tools for Payment Hub EE

## Overview

`src/utils/localdev/` contains tools for iterating on Payment Hub EE Java components without rebuilding Docker images or pushing to a registry.

**The Problem:** Normal testing of Java changes requires: edit → build JAR → build Docker image → push to registry → redeploy. This is slow.

**The Solution:** `localdev.py` mounts your local project directory into the running pod via a `hostPath` volume. You rebuild the JAR locally and restart the pod — no Docker build required.

All PHEE components are **operator-managed**: deployed by the PaymentHub Kubernetes operator from `PaymentHubDeployment` CRs in `src/deployer/operators/paymenthub/config/cr/`. `localdev.py` patches live Kubernetes Deployments directly via `kubectl get/apply` (k8s-direct-mode).

> **Naming note:** the upstream `openMF/ph-ee-*` repos are being renamed to `paymenthub-ee-*`. In-cluster Kubernetes Deployment/pod names have mostly already moved to `paymenthub-ee-*`, but a few source repos (and therefore local checkout directories) haven't been renamed upstream yet — e.g. `ph-ee-operations-web`, `ph-ee-importer-rdbms`, `ph-ee-zeebe-ops`. The tables below reflect the current, mixed state; always verify with `kubectl get deployments -n paymenthub` before assuming a name.

### Files

| File | Purpose |
|------|---------|
| `localdev.py` | Main script — patches Deployments and manages repo checkouts |
| `localdev.ini` | Configuration: which components to patch and where your local repos live |

---

## Quick Start

> **Prerequisite:** `localdev.py` patches a component's *existing* Deployment — it can't patch what isn't there yet. PaymentHub must already be deployed to the cluster first:
> ```bash
> cd ~/mifos-gazelle
> ./run.sh -m deploy -a paymenthub
> ```
> Do this once per cluster (not before every `--setup`). If you see `namespaces "paymenthub" not found` or `deployments.apps "<name>" not found`, this step hasn't been done yet.

```bash
cd ~/mifos-gazelle/src/utils/localdev

# 1. Check current state
./localdev.py --status

# 2. Setup a component (checkout repo + patch deployment)
./localdev.py --setup --component importer-rdbms

# 3. Build the JAR (must use Java 17 — see note below)
cd ~/ph-ee-importer-rdbms
JAVA_HOME=/home/mifosu/jdk-17.0.2 ./gradlew build -x test

# 4. Restart the pod to pick up the new JAR
kubectl delete pod -n paymenthub -l app=paymenthub-ee-importer-rdbms

# 5. When done, restore the original deployment
cd ~/mifos-gazelle/src/utils/localdev
./localdev.py --restore --component importer-rdbms
```

> **Java version:** PHEE components target Java 17. The system Java may be newer (e.g., 23) and will fail to build. Always use:
> ```bash
> JAVA_HOME=/home/mifosu/jdk-17.0.2 ./gradlew build -x test
> ```

---

## How k8s-direct-mode Works

For components with `k8s_deploy_name` in `localdev.ini`, the patcher:

1. Runs `kubectl get deployment <name> -n <namespace> -o json` to fetch the live Deployment
2. Saves the original as a JSON backup at `~/.localdev-backups/<component>-deployment.json`
3. Modifies the Deployment spec:
   - Overrides the container image with the JDK image (e.g., `eclipse-temurin:17`)
   - Adds `command: ["java", "-jar", "<jarpath>"]`
   - Adds a `volumeMount` at `/app` in the container
   - Adds a `hostPath` volume pointing to your local project directory
4. Applies the patched manifest via `kubectl apply -f -`
5. Waits for rollout to complete

`--restore` re-applies the original JSON backup and deletes the backup file.

> **Operator reconciliation:** The in-cluster PaymentHub operator reconciles the 19 `PaymentHubDeployment`-managed components periodically and will revert k8s-direct patches to *those*. Scale it down while developing one of them:
> ```bash
> kubectl scale deployment paymenthub-ee-operator -n paymenthub --replicas=0
> # ... develop ...
> kubectl scale deployment paymenthub-ee-operator -n paymenthub --replicas=1
> ```
> This does **not** apply when patching the operator itself (`paymenthub-operator` in the table below) — its own Deployment is applied directly by `paymenthub.sh`, not reconciled by anything, so nothing reverts a patch to it.

---

## Command Reference

```bash
# Show status of all components (repo branch + patch state)
./localdev.py --status

# Complete setup: checkout repo + patch deployment
./localdev.py --setup
./localdev.py --setup --component importer-rdbms   # single component

# Clone repositories (components with checkout_enabled = true)
./localdev.py --checkout
./localdev.py --checkout --component channel

# Pull latest changes for existing repos
./localdev.py --update
./localdev.py --update --component channel

# Preview what would be changed without modifying anything
./localdev.py --dry-run
./localdev.py --dry-run --component importer-rdbms

# Patch deployments only (no checkout)
./localdev.py
./localdev.py --component importer-rdbms

# Restore all deployments from backups
./localdev.py --restore
./localdev.py --restore --component importer-rdbms

# Use a custom config file
./localdev.py --config /path/to/custom.ini
```

---

## Build Loop

```bash
cd ~/ph-ee-importer-rdbms
# ... edit Java files ...
JAVA_HOME=/home/mifosu/jdk-17.0.2 ./gradlew build -x test
kubectl delete pod -n paymenthub -l app=paymenthub-ee-importer-rdbms
kubectl logs -f -n paymenthub -l app=paymenthub-ee-importer-rdbms
```

---

## localdev.ini Configuration

### Component Modes

| Fields present | Mode | Effect |
|---------------|------|--------|
| `k8s_deploy_name` | k8s-direct | Patches live Kubernetes Deployment + hostPath mount |
| `checkout_enabled` only | checkout-only | Clones/updates repo; no deployment patching |

The operator itself (`paymenthub-operator`) uses plain k8s-direct mode too — its Deployment is applied directly by `paymenthub.sh`, not by itself, so there's no reconciler to fight the patch.

### Configuration Parameters

| Parameter | Required | Description |
|-----------|----------|-------------|
| `[general].gazelle-home` | Yes | Root path to your mifos-gazelle clone |
| `k8s_deploy_name` | k8s-direct | Kubernetes Deployment name (`kubectl get deployments -n paymenthub`) |
| `k8s_namespace` | k8s-direct | Namespace of the Deployment (default: `paymenthub`) |
| `app_type` | No | `springboot` (default) |
| `image` | springboot | JDK container image, e.g. `eclipse-temurin:17` |
| `jarpath` | springboot | Path to JAR inside container, e.g. `/app/build/libs/app.jar` |
| `hostpath` | k8s-direct | Local filesystem path mounted at `/app` inside the container |
| `checkout_enabled` | No | `true` to enable automatic repo clone/update |
| `reponame` | If checkout | Git URL (HTTPS or SSH) |
| `branch_or_tag` | No | Branch, tag, or commit SHA (default: `main`) |
| `checkout_to_dir` | No | Directory to clone into (default: `$HOME`) |

### Variable Expansion

- Environment variables: `$HOME`, `$USER`, etc.
- Custom variables: `${gazelle-home}` references the `[general]` section

### Adding k8s-direct patching to a checkout-only component

```ini
[my-component]
k8s_deploy_name = paymenthub-ee-my-component   # verify with: kubectl get deployments -n paymenthub
k8s_namespace   = paymenthub
app_type        = springboot
image           = eclipse-temurin:17
jarpath         = /app/build/libs/my-component.jar
hostpath        = ${HOME}/my-component-repo
checkout_enabled = true
reponame        = https://github.com/openMF/my-component.git
branch_or_tag   = dev
checkout_to_dir = ${HOME}
```

---

## Configured Components

| Section | Mode | Checkout branch | k8s Deployment name |
|---------|------|-----------------|---------------------|
| `paymenthub-operator` | k8s-direct | main | `paymenthub-ee-operator` |
| `channel` | k8s-direct | dev | `paymenthub-ee-connector-channel` |
| `bulk-processor` | k8s-direct | dev | `paymenthub-ee-bulk-processor` |
| `mock-payment` | k8s-direct | dev | `paymenthub-ee-connector-mock-payment-schema` |
| `operations-web` | k8s-direct | dev | `ph-ee-operations-web` — not yet renamed upstream; the two candidate replacement repos (`paymenthub-ee-operationsui-react`, `paymenthub-ee-operationsui-angular`) are scaffold-only |
| `importer-rdbms` | k8s-direct | dev | `paymenthub-ee-importer-rdbms` |
| `ams-mifos` | k8s-direct | dev | `paymenthub-ee-connector-ams-mifosx` |
| `connector-mojaloop` | k8s-direct | dev | `paymenthub-ee-connector-mojaloop` |
| `bill-pay` | k8s-direct | dev | `paymenthub-ee-p2g` |
| `connector-bulk` | checkout-only | dev | — |
| `operations-app` | checkout-only | dev | — (repo renamed/merged into `paymenthub-ee-bff`) |
| `identity-account-mapper` | checkout-only | dev | — (repo renamed to `paymenthub-ee-account-mapper`) |
| `zeebe-ops` | checkout-only | dev | — (repo still `ph-ee-zeebe-ops`) |
| `connector-mccbs` | checkout-only | dev | — (separate operator; repo still `ph-ee-connector-mccbs`) |
| `connector-gsma` | checkout-only | dev | — (repo renamed to `paymenthub-ee-connector-mm-gsma`) |
| `integration-test` | checkout-only | dev | — (test suite; now a module of `paymenthub-ee-e2e-tests`, shared with `mock-payment`) |
| `notifications` | checkout-only | dev | — |

---

## Running the Operator From a Local Build

The operator (`paymenthub-operator`) is set up in `localdev.ini` exactly like any other k8s-direct component — its own Deployment is applied directly by `paymenthub.sh`, not reconciled by anything, so there's no need to scale anything down first:

```bash
cd ~/mifos-gazelle/src/utils/localdev
./localdev.py --setup --component paymenthub-operator   # checkout + patch

cd ~/paymenthub-ee-k8s-operators/paymenthub-operator
./gradlew bootJar
kubectl delete pod -n paymenthub -l app=paymenthub-ee-operator   # pick up the new JAR

kubectl logs -f -n paymenthub -l app=paymenthub-ee-operator

# When done
cd ~/mifos-gazelle/src/utils/localdev
./localdev.py --restore --component paymenthub-operator
```

---

## Troubleshooting

### `namespaces "paymenthub" not found` / `deployments.apps "<name>" not found`
PaymentHub hasn't been deployed to this cluster yet — `--setup`/`--dry-run` patch an *existing* Deployment, they don't create one. Deploy it first (see the Quick Start prerequisite above):
```bash
cd ~/mifos-gazelle
./run.sh -m deploy -a paymenthub
```

### Changes not taking effect
```bash
# Verify the JAR was built
ls -lh ~/your-project/build/libs/

# Check hostPath is mounted in the running pod
kubectl get pod -n paymenthub -l app=your-component -o yaml | grep -A5 hostPath

# Check startup logs
kubectl logs -n paymenthub -l app=your-component
```

### Build fails with Java version error
```bash
# Use Java 17 explicitly — system Java may be newer
JAVA_HOME=/home/mifosu/jdk-17.0.2 ./gradlew build -x test
```

### Pod in CrashLoopBackOff after patching
```bash
kubectl describe pod -n paymenthub -l app=your-component
kubectl logs -n paymenthub -l app=your-component

# Verify the JAR exists inside the container
kubectl exec -n paymenthub deployment/your-component -- ls -la /app/build/libs/
```

Common causes:
- Wrong JAR filename in `jarpath` — check `build.gradle` for the actual artifact name
- JAR not yet built — run `JAVA_HOME=/home/mifosu/jdk-17.0.2 ./gradlew build -x test`
- `hostpath` directory does not exist on the node

### Patch reverted by operator
The in-cluster PaymentHub operator reconciles Deployments and will overwrite patches. Scale it down:
```bash
kubectl scale deployment paymenthub-ee-operator -n paymenthub --replicas=0
```

### Restore fails
```bash
# Check backup exists
ls ~/.localdev-backups/

# Manual restore
kubectl apply -f ~/.localdev-backups/<component>-deployment.json
rm ~/.localdev-backups/<component>-deployment.json
```

### Configuration changes not taking effect
When using hostPath mounts, the Spring Boot JAR contains the compiled YAML configuration. Editing `application.yaml` alone is not sufficient — rebuild the JAR:
```bash
JAVA_HOME=/home/mifosu/jdk-17.0.2 ./gradlew build -x test
kubectl delete pod -n paymenthub -l app=your-component
```
ConfigMap changes do NOT take effect when using hostPath mounts — the in-JAR config takes precedence.

### Permission denied on hostPath
```bash
chmod 755 ~/your-project
chmod 644 ~/your-project/build/libs/*.jar
```

---

## Notes

- **Single-node only:** `hostPath` is node-specific. This tooling is designed for single-node k3s local development.
- **After operator reconcile:** k8s-direct patches may be overwritten. Scale down the operator or re-run `./localdev.py --component <name>` (run `--restore` first if backup already exists).
- **Remote debugging:** Add JVM debug flags to the command in the patched deployment, then `kubectl port-forward deployment/your-component 5005:5005 -n paymenthub`.
