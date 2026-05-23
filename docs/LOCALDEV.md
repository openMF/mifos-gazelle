# Local Development Tools for Payment Hub EE

## Overview

`src/utils/localdev/` contains tools for rapidly iterating on Payment Hub EE Java and webapp components without rebuilding Docker images or pushing to a registry.

**The Problem:** Normal testing of Java changes requires: edit → build JAR → build Docker image → push to registry → redeploy. This is slow.

**The Solution:** `localdev.py` mounts your local project directory into the running pod via a `hostPath` volume. You rebuild the JAR locally and restart the pod — no Docker build required.

`localdev.py` supports **two patching modes** depending on how the component is deployed:

| Mode | When used | How it works |
|------|-----------|-------------|
| **Helm-mode** | Component has `directory` in `localdev.ini` | Patches `templates/deployment.yaml` in the Helm chart |
| **k8s-direct-mode** | Component has `k8s_deploy_name` in `localdev.ini` | Fetches the live Kubernetes Deployment, patches it, re-applies it via `kubectl apply` |

Most PHEE components in the current stack are **operator-managed** (deployed by the PaymentHub Kubernetes operator from `PaymentHubDeployment` CRs, not Helm charts). These use k8s-direct-mode.

### Files

| File | Purpose |
|------|---------|
| `localdev.py` | Main Python script — patches deployments and manages repo checkouts |
| `localdev.ini` | Configuration defining which components to patch and where your local repos live |
| `pre-commit.sh` | Git hook to block accidental commits of dev-patched files |
| `install-git-protection.sh` | Installs `pre-commit.sh` as a git hook |

---

## Quick Start

```bash
cd ~/mifos-gazelle/src/utils/localdev

# 1. Install git protection (recommended, Helm-mode only)
./install-git-protection.sh

# 2. Check current state
./localdev.py --status

# 3. Setup a specific component (checkout repo + patch deployment)
./localdev.py --setup --component importer-rdbms

# 4. Build the JAR (Java 17 required — see note below)
cd ~/ph-ee-importer-rdbms
JAVA_HOME=/home/mifosu/jdk-17.0.2 ./gradlew build -x test

# 5. Restart the pod to pick up the new JAR
kubectl delete pod -n paymenthub -l app=ph-ee-importer-rdbms

# 6. When done, restore the original deployment
cd ~/mifos-gazelle/src/utils/localdev
./localdev.py --restore --component importer-rdbms
```

> **Java version note:** PHEE components target Java 17. The system Java may be newer (e.g., 23) and will fail to build due to internal API incompatibilities. Always use:
> ```bash
> JAVA_HOME=/home/mifosu/jdk-17.0.2 ./gradlew build -x test
> ```
> Java 17 is available at `/home/mifosu/jdk-17.0.2/`.

---

## Component Types

### 1. `springboot` — Helm-mode

Components with a `directory` key in `localdev.ini`. The patcher modifies the `templates/deployment.yaml` in the Helm chart:

- Overrides the container image with a JDK image (e.g., `eclipse-temurin:17`)
- Adds `command: ["java", "-jar", "/app/build/libs/your-app.jar"]`
- Adds a `volumeMount` at `/app` in the container
- Adds a `hostPath` volume pointing to your local project directory

Backup is saved as `_deployment.yaml.backup` in the same `templates/` dir. The patched file is git-protected with `skip-worktree`.

**Build and iterate:**
```bash
cd ~/ph-ee-connector-ams-mifos
JAVA_HOME=/home/mifosu/jdk-17.0.2 ./gradlew build -x test
kubectl delete pod -n paymenthub -l app=ph-ee-connector-ams-mifos
kubectl logs -f -n paymenthub -l app=ph-ee-connector-ams-mifos
```

### 2. `webapp` — Helm-mode

Static web applications served by nginx. Only `operations-web` uses this mode. The patcher:

- Keeps the original nginx image unchanged
- Adds a `hostPath` volume pointing to your local `dist/` directory
- Adds a `volumeMount` at `/usr/share/nginx/html`

**Build and iterate:**
```bash
cd ~/ph-ee-operations-web
npm run build
kubectl delete pod -n paymenthub -l app=ph-ee-operations-web
```

### 3. `springboot` — k8s-direct-mode (operator-managed)

Components without a `directory` key but with `k8s_deploy_name` in `localdev.ini`. These are deployed by the PaymentHub operator from `PaymentHubDeployment` CRs — there is no Helm chart to patch.

The patcher:
1. Runs `kubectl get deployment <name> -n <namespace> -o json` to fetch the live Deployment
2. Saves the original as a JSON backup at `~/.localdev-backups/<component>-deployment.json`
3. Modifies the Deployment spec: overrides image, adds `command: ["java", "-jar", ...]`, adds hostPath volume + volumeMount
4. Applies the patched manifest via `kubectl apply -f -`
5. Waits for rollout to complete

`--restore` re-applies the original JSON backup and deletes the backup file.

**Build and iterate:**
```bash
cd ~/ph-ee-importer-rdbms
JAVA_HOME=/home/mifosu/jdk-17.0.2 ./gradlew build -x test
kubectl delete pod -n paymenthub -l app=ph-ee-importer-rdbms
kubectl logs -f -n paymenthub -l app=ph-ee-importer-rdbms
```

> **Operator reconciliation:** The PaymentHub operator periodically reconciles Deployments. If the operator is running in-cluster, it may revert your k8s-direct patches when it reconciles. To prevent this, scale down the in-cluster operator while developing:
> ```bash
> kubectl scale deployment ph-ee-operator -n paymenthub --replicas=0
> # ... develop ...
> kubectl scale deployment ph-ee-operator -n paymenthub --replicas=1
> ```
> Alternatively, run the operator locally (see **Running the Operator Locally** below).

### 4. `operator` — Run locally via `./gradlew run`

The `paymenthub-operator` itself can be run locally against the cluster instead of deploying it as a Docker image. See **Running the Operator Locally** below.

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

# Check which deployment files are git-protected (Helm-mode only)
./localdev.py --check-git-status

# Run the PaymentHub operator locally (see section below)
./localdev.py --run

# Use a custom config file
./localdev.py --config /path/to/custom.ini

# Debug mode — see detailed YAML parsing (Helm-mode)
DEBUG_PATCH=true ./localdev.py --component ams-mifos
```

---

## localdev.ini Configuration

### Structure

```ini
[general]
gazelle-home = $HOME/mifos-gazelle

# --- Helm-mode component ---
[ams-mifos]
directory    = ${gazelle-home}/repos/ph_template/helm/ph-ee-engine/connector-ams-mifos
app_type     = springboot
image        = eclipse-temurin:17
jarpath      = /app/build/libs/ph-ee-connector-ams-mifos-2.0.0.mifos-SNAPSHOT.jar
hostpath     = ${HOME}/ph-ee-connector-ams-mifos
checkout_enabled = true
reponame     = https://github.com/openMF/ph-ee-connector-ams-mifos.git
branch_or_tag = dev
checkout_to_dir = ${HOME}

# --- k8s-direct-mode component ---
[importer-rdbms]
k8s_deploy_name = ph-ee-importer-rdbms
k8s_namespace   = paymenthub
app_type        = springboot
image           = eclipse-temurin:17
jarpath         = /app/build/libs/importer-rdbms-2.0.0.mifos-SNAPSHOT.jar
hostpath        = ${HOME}/ph-ee-importer-rdbms
checkout_enabled = true
reponame     = git@github.com:openMF/ph-ee-importer-rdbms.git
branch_or_tag = dev
checkout_to_dir = ${HOME}

# --- checkout-only (no patch support yet) ---
[zeebe-ops]
checkout_enabled = true
reponame = https://github.com/openMF/ph-ee-zeebe-ops.git
branch_or_tag = dev
checkout_to_dir = ${HOME}
```

### Configuration Parameters

| Parameter | Required | Description |
|-----------|----------|-------------|
| `[general].gazelle-home` | Yes | Root path to your mifos-gazelle clone |
| `directory` | Helm-mode | Path to Helm chart dir containing `templates/deployment.yaml` |
| `k8s_deploy_name` | k8s-direct-mode | Kubernetes Deployment name (from `kubectl get deployments -n paymenthub`) |
| `k8s_namespace` | k8s-direct-mode | Namespace of the Deployment (default: `paymenthub`) |
| `app_type` | No | `springboot` (default) or `webapp` |
| `image` | springboot | JDK container image, e.g. `eclipse-temurin:17` |
| `jarpath` | springboot | Path to JAR inside the container, e.g. `/app/build/libs/app.jar` |
| `hostpath` | Yes (if patching) | Local filesystem path to mount at `/app` (or `/usr/share/nginx/html` for webapp) |
| `checkout_enabled` | No | `true` to enable automatic repo clone/update |
| `reponame` | If checkout_enabled | Git URL (HTTPS or SSH) |
| `branch_or_tag` | No | Branch, tag, or commit SHA (default: `main`) |
| `checkout_to_dir` | No | Directory to clone into (default: `$HOME`) |

**To enable k8s-direct-mode for a component that currently only has `checkout_enabled`**, add:
```ini
k8s_deploy_name = ph-ee-<component-name>
k8s_namespace   = paymenthub
app_type        = springboot
image           = eclipse-temurin:17
jarpath         = /app/build/libs/<artifact-name>.jar
hostpath        = ${HOME}/<repo-dir>
```

### Variable Expansion

- Environment variables: `$HOME`, `$USER`, etc.
- Custom variables: `${gazelle-home}` references the `[general]` section

---

## Configured Components

| Section | Mode | Checkout | k8s Deployment Name |
|---------|------|----------|---------------------|
| `channel` | k8s-direct | ✅ dev | `ph-ee-connector-channel` |
| `bulk-processor` | k8s-direct | ✅ dev | `ph-ee-bulk-processor` |
| `connector-bulk` | checkout-only | ✅ dev | `ph-ee-connector-bulk` |
| `mock-payment` | checkout-only | ✅ dev | `ph-ee-connector-mock-payment-schema` |
| `operations-app` | checkout-only | ✅ gaz-258 | `ph-ee-operations-app` |
| `operations-web` | Helm-mode (webapp) | ✅ dev | — |
| `importer-rdbms` | k8s-direct | ✅ dev | `ph-ee-importer-rdbms` |
| `identity-account-mapper` | checkout-only | ✅ dev | `ph-ee-identity-account-mapper` |
| `ams-mifos` | Helm-mode (springboot) | ✅ dev | — |
| `connector-mojaloop` | k8s-direct | ✅ dev | `ph-ee-connector-mojaloop-java` |
| `zeebe-ops` | checkout-only | ✅ dev | `ph-ee-zeebe-ops` |
| `connector-mccbs` | checkout-only | ✅ dev | — (separate operator) |
| `connector-gsma` | checkout-only | ✅ dev | — |
| `bill-pay` | Helm-mode (springboot) | ✅ mifos-v2.0.0 | — |
| `integration-test` | checkout-only | ✅ tomdev1 | — (test suite only) |

**checkout-only** = repo is cloned/updated but no deployment patching is configured.

To add k8s-direct-mode to a checkout-only component, see **Configuration Parameters** above. Kubernetes deployment names follow the pattern `ph-ee-<service-name>` (verify with `kubectl get deployments -n paymenthub`).

---

## What the Patcher Does

### Helm-mode: Before and After

**Before** (`templates/deployment.yaml`):
```yaml
containers:
  - name: ph-ee-connector-ams-mifos
    image: "{{ .Values.image }}"
    volumeMounts:
      - name: config-volume
        mountPath: /app/config
volumes:
  - name: config-volume
    configMap:
      name: ams-mifos-config
```

**After:**
```yaml
containers:
  - name: ph-ee-connector-ams-mifos
    image: "eclipse-temurin:17"
    command: ["java", "-jar", "/app/build/libs/ph-ee-connector-ams-mifos-2.0.0.mifos-SNAPSHOT.jar"]
    volumeMounts:
      - name: config-volume
        mountPath: /app/config
      - name: local-code
        mountPath: /app
volumes:
  - name: config-volume
    configMap:
      name: ams-mifos-config
  - name: local-code
    hostPath:
      path: /home/youruser/ph-ee-connector-ams-mifos
      type: Directory
```

### k8s-direct-mode: What Changes

The same modifications are applied — image, command, volumeMount, hostPath volume — but directly to the live Kubernetes Deployment object rather than a Helm chart file. The original Deployment spec is saved as JSON to `~/.localdev-backups/<component>-deployment.json`.

### Backup and Restore

| Mode | Backup location | How to restore |
|------|----------------|----------------|
| Helm-mode | `templates/_deployment.yaml.backup` (next to the patched file) | `./localdev.py --restore --component <name>` |
| k8s-direct-mode | `~/.localdev-backups/<component>-deployment.json` | `./localdev.py --restore --component <name>` |

In both modes, if a backup already exists the component is considered already-patched and `--setup` is skipped. Use `--restore` first to re-patch.

---

## Running the Operator Locally

Instead of patching individual Deployments, you can run the PaymentHub operator locally against the cluster. The operator reads `PaymentHubDeployment` CRs and reconciles Deployments — running it locally lets you modify operator logic without building a Docker image.

```bash
# Scale down the in-cluster operator first (avoids dual reconcilers)
kubectl scale deployment ph-ee-operator -n paymenthub --replicas=0

# Run the local operator
cd ~/mifos-gazelle/src/utils/localdev
./localdev.py --run
# (or: cd ~/mifos-operators/paymenthub-operator && ./gradlew run)

# When done, restore in-cluster operator
kubectl scale deployment ph-ee-operator -n paymenthub --replicas=1
```

`./localdev.py --run` automatically checks out the operator repo (if not already present) and reminds you to scale down the in-cluster operator. The operator repo is configured in `localdev.ini` under `[paymenthub-operator]`.

---

## Git Protection (Helm-mode)

Three layers prevent accidentally committing dev-patched Helm chart files:

### 1. Skip-Worktree (automatic)
Applied automatically when `localdev.py` patches a Helm file:
```bash
./localdev.py --check-git-status  # show status
git ls-files -v | grep ^S         # 'S' prefix = protected
```

### 2. Pre-Commit Hook
`install-git-protection.sh` installs a hook that blocks commits containing `hostPath:` or absolute paths like `/home/username/`.

### 3. Backup Files
`_deployment.yaml.backup` lets you recover the original at any time via `--restore`.

> **k8s-direct-mode** does not use git protection — the Kubernetes Deployment is patched in-cluster and the backup is stored outside the repo at `~/.localdev-backups/`.

---

## Typical Workflow

```bash
# One-time setup
cd ~/mifos-gazelle/src/utils/localdev
./install-git-protection.sh      # Helm-mode protection
./localdev.py --status           # see what's configured

# Setup a component for local dev
./localdev.py --setup --component importer-rdbms

# Build loop
cd ~/ph-ee-importer-rdbms
# ... edit Java files ...
JAVA_HOME=/home/mifosu/jdk-17.0.2 ./gradlew build -x test
kubectl delete pod -n paymenthub -l app=ph-ee-importer-rdbms
kubectl logs -f -n paymenthub -l app=ph-ee-importer-rdbms

# Pull upstream changes
cd ~/mifos-gazelle/src/utils/localdev
./localdev.py --update --component importer-rdbms

# Check status
./localdev.py --status
# importer-rdbms shows "🔒 k8s-patched"

# When done
./localdev.py --restore --component importer-rdbms
```

---

## Troubleshooting

### Changes not taking effect
```bash
# Verify the JAR was built
ls -lh ~/your-project/build/libs/

# Check hostPath is mounted in the running pod
kubectl get pod -n paymenthub -l app=your-component -o yaml | grep -A5 hostPath

# Check startup logs
kubectl logs -n paymenthub -l app=your-component
```

### Permission denied on hostPath
```bash
chmod 755 ~/your-project
chmod 644 ~/your-project/build/libs/*.jar
```

### Build fails with Java version error
```bash
# Use Java 17 explicitly
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

### k8s-direct patch reverted by operator
The in-cluster PaymentHub operator reconciles Deployments periodically and will overwrite k8s-direct patches. Scale it down while developing:
```bash
kubectl scale deployment ph-ee-operator -n paymenthub --replicas=0
```

### k8s-direct restore fails
```bash
# Check backup exists
ls ~/.localdev-backups/

# Manual restore if backup file exists but localdev.py fails
kubectl apply -f ~/.localdev-backups/<component>-deployment.json
rm ~/.localdev-backups/<component>-deployment.json
```

### Helm-mode: Git still shows modified files
```bash
./localdev.py --check-git-status
git update-index --skip-worktree path/to/deployment.yaml
```

### Webapp not serving updated files
```bash
ls -la ~/ph-ee-operations-web/dist/
kubectl describe pod -n paymenthub -l app=ph-ee-operations-web | grep -A5 "Volumes:"
cd ~/ph-ee-operations-web && npm run build
kubectl delete pod -n paymenthub -l app=ph-ee-operations-web
```

### Configuration changes not taking effect
When using hostPath mounts, the Spring Boot JAR contains the compiled YAML configuration. Editing `application.yaml` alone is not sufficient — you must rebuild the JAR:
```bash
JAVA_HOME=/home/mifosu/jdk-17.0.2 ./gradlew build -x test
kubectl delete pod -n paymenthub -l app=your-component
```
ConfigMap changes do NOT take effect when using hostPath mounts — the in-JAR config takes precedence.

---

## Notes

- **Multi-node clusters:** `hostPath` is node-specific. This tooling is designed for single-node k3s local development clusters.
- **After `helm upgrade`:** Helm overwrites Helm-mode patched `deployment.yaml` files. Re-run `./localdev.py` after any Helm upgrade.
- **After operator reconcile:** k8s-direct patches may be overwritten by the operator. Scale down the operator or re-apply with `./localdev.py --component <name>` (will skip if backup still exists — run `--restore` then re-patch).
- **Remote debugging:** Add JVM debug flags to the command in the patched deployment, then `kubectl port-forward deployment/your-component 5005:5005 -n paymenthub`.
