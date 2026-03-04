# Local Development Tools for Payment Hub EE

## Overview

`src/utils/localdev/` contains tools for rapidly iterating on Payment Hub EE Java and webapp components without rebuilding Docker images or pushing to a registry.

**The Problem:** Normal testing of Java changes requires: edit → build JAR → build Docker image → push to registry → update Helm chart → redeploy. This is slow.

**The Solution:** `localdev.py` patches the Helm chart `deployment.yaml` files to mount your local project directory directly into the running Kubernetes pod via a `hostPath` volume. You rebuild the JAR locally and restart the pod — no Docker build required.

### Files

| File | Purpose |
|------|---------|
| `localdev.py` | Main Python script — patches Helm chart `deployment.yaml` files and manages repo checkouts |
| `localdev.ini` | Configuration defining which components to patch and where your local repos live |
| `pre-commit.sh` | Git hook to block accidental commits of dev-patched files |
| `install-git-protection.sh` | Installs `pre-commit.sh` as a git hook |

---

## Quick Start

```bash
cd ~/mifos-gazelle/src/utils/localdev

# 1. Edit localdev.ini — update hostpath and checkout_to_dir for your machine
nano localdev.ini

# 2. Install git protection (recommended)
./install-git-protection.sh

# 3. Check what will happen
./localdev.py --status

# 4. Checkout repos and patch deployments in one command
./localdev.py --setup

# 5. Build the JAR for a component
cd ~/ph-ee-bulk-processor
./gradlew clean build -x test

# 6. Restart the pod
kubectl delete pod -n paymenthub -l app=ph-ee-bulk-processor

# 7. When done developing, restore original deployments
cd ~/mifos-gazelle/src/utils/localdev
./localdev.py --restore
```

---

## Component Types

`localdev.py` supports three component types via the `app_type` config field.

### 1. `springboot` (default)

Java Spring Boot applications. The patcher:
- Overrides the container image with a JDK image (e.g., `eclipse-temurin:17`)
- Adds `command: ["java", "-jar", "/app/build/libs/your-app.jar"]`
- Adds a `volumeMount` at `/app` in the container
- Adds a `hostPath` volume pointing to your local project directory

Your local project's entire directory tree is mounted at `/app`, so the JAR at `build/libs/*.jar` is available inside the container.

**Build and iterate:**
```bash
cd ~/ph-ee-connector-channel
./gradlew clean build -x test
kubectl delete pod -n paymenthub -l app=ph-ee-connector-channel
kubectl logs -f -n paymenthub -l app=ph-ee-connector-channel
```

### 2. `webapp`

Static web applications served by nginx (Angular, React, etc.). The patcher:
- Keeps the original nginx image unchanged
- Does NOT add a `java -jar` command (nginx runs as the default CMD)
- Adds a `volumeMount` at `/usr/share/nginx/html`
- Adds a `hostPath` volume pointing to your local dist directory

**Build and iterate:**
```bash
cd ~/ph-ee-operations-web
npm run build
# Changes are live immediately — no pod restart needed for static files
# (if the volume is already mounted; otherwise restart the pod)
kubectl delete pod -n paymenthub -l app=ph-ee-operations-web
```

### 3. Operator-managed (no `directory` key)

Some components (e.g., `connector-mccbs`) are deployed via a Kubernetes operator, not a Helm chart. For these:
- `localdev.py` performs only the git checkout step
- No `deployment.yaml` patching occurs
- You configure local dev by applying a custom CR manifest:

```bash
kubectl apply -f src/operators/mastercard/config/samples/mastercard-cbs-localdev.yaml
```

---

## Command Reference

```bash
# Show status of all components (repo branch + patch state)
./localdev.py --status

# Complete setup: checkout repos + patch deployments
./localdev.py --setup
./localdev.py --setup --component bulk-processor   # single component

# Clone repositories (checkout_enabled = true components)
./localdev.py --checkout
./localdev.py --checkout --component channel

# Pull latest changes for existing repos
./localdev.py --update
./localdev.py --update --component channel

# Preview what would be changed without modifying anything
./localdev.py --dry-run

# Patch deployments only (no checkout)
./localdev.py
./localdev.py --component bulk-processor

# Restore all deployments from backups
./localdev.py --restore
./localdev.py --restore --component bulk-processor

# Check which deployment files are git-protected
./localdev.py --check-git-status

# Use a custom config file
./localdev.py --config /path/to/custom.ini

# Debug mode — see detailed YAML parsing decisions
DEBUG_PATCH=true ./localdev.py --component bulk-processor
```

---

## localdev.ini Configuration

### Structure

```ini
[general]
gazelle-home = $HOME/mifos-gazelle

[component-name]
# Required for springboot
directory    = ${gazelle-home}/repos/ph_template/helm/ph-ee-engine/component-name
image        = eclipse-temurin:17
app_type     = springboot
jarpath      = /app/build/libs/your-app.jar
hostpath     = ${HOME}/your-local-repo

# Required for webapp
directory    = ${gazelle-home}/repos/ph_template/helm/ph-ee-engine/component-name
app_type     = webapp
hostpath     = ${HOME}/your-local-repo/dist

# Required for operator-managed (no directory key)
app_type     = springboot   # (ignored, but harmless)

# Optional: automatic git checkout
checkout_enabled = true
reponame         = https://github.com/openMF/repo.git
branch_or_tag    = mifos-v2.0.0
checkout_to_dir  = ${HOME}
```

### Configuration Parameters

| Parameter | Required | Description |
|-----------|----------|-------------|
| `[general].gazelle-home` | Yes | Root path to your mifos-gazelle clone |
| `directory` | Yes (except operator-managed) | Path to Helm chart dir containing `templates/deployment.yaml` |
| `app_type` | No | `springboot` (default) or `webapp` |
| `image` | springboot only | JDK container image, e.g. `eclipse-temurin:17` |
| `jarpath` | springboot only | Path to JAR inside the container, e.g. `/app/build/libs/app.jar` |
| `hostpath` | Yes | Local filesystem path to mount. For webapp, point to the `dist/` directory |
| `checkout_enabled` | No | `true` to enable automatic repo clone/update |
| `reponame` | If checkout_enabled | Git URL (HTTPS or SSH) |
| `branch_or_tag` | No | Branch, tag, or commit SHA (default: `main`) |
| `checkout_to_dir` | No | Directory to clone into (default: `$HOME`) |

### Variable Expansion

- Environment variables: `$HOME`, `$USER`, etc.
- Custom variables: `${gazelle-home}` references the `[general]` section

---

## Configured Components

The following components are pre-configured in `localdev.ini`:

| Section | App Type | Checkout | Notes |
|---------|----------|----------|-------|
| `channel` | springboot | enabled | `ph-ee-connector-channel` |
| `bulk-processor` | springboot | disabled | `ph-ee-bulk-processor` — enable if needed |
| `connector-bulk` | springboot | enabled | `ph-ee-connector-bulk` |
| `mock-payment` | springboot | enabled | `ph-ee-connector-mock-payment-schema` |
| `operations-app` | springboot | enabled | `ph-ee-operations-app` |
| `operations-web` | webapp | enabled | `ph-ee-operations-web` — Angular app, nginx |
| `importer-rdbms` | springboot | enabled | `ph-ee-importer-rdbms` |
| `identity-account-mapper` | springboot | disabled | Enable if modifying mapper |
| `ams-mifos` | springboot | enabled | `ph-ee-connector-ams-mifos` |
| `connector-mojaloop` | springboot | enabled | `ph-ee-connector-mojaloop-java` |
| `zeebe-ops` | springboot | enabled | `ph-ee-zeebe-ops` |
| `connector-mccbs` | operator-managed | enabled | Mastercard CBS — no Helm chart |

To disable a component, set `checkout_enabled = false` or comment out its entire section.

---

## What the Patcher Does

### SpringBoot: Before and After

**Before:**
```yaml
containers:
  - name: ph-ee-bulk-processor
    image: "{{ .Values.image }}"
    imagePullPolicy: "{{ .Values.imagePullPolicy }}"
    volumeMounts:
      - name: config-volume
        mountPath: /app/config
volumes:
  - name: config-volume
    configMap:
      name: bulk-processor-config
```

**After:**
```yaml
containers:
  - name: ph-ee-bulk-processor
    image: "eclipse-temurin:17"  # this is the JDK to use
    #image: "{{ .Values.image }}"  # commented out to allow hostpath local dev/test
    imagePullPolicy: "{{ .Values.imagePullPolicy }}"
    command: ["java", "-jar", "/app/build/libs/ph-ee-processor-bulk-2.0.0.mifos-SNAPSHOT.jar"]
    volumeMounts:
      - name: config-volume
        mountPath: /app/config
      - name: local-code
        mountPath: /app
volumes:
  - name: config-volume
    configMap:
      name: bulk-processor-config
  - name: local-code
    hostPath:
      path: /home/yourusername/ph-ee-bulk-processor
      type: Directory
```

### Backup and Git Protection

- A backup is saved as `_deployment.yaml.backup` (in the same `templates/` directory)
- The patched file is marked with `git update-index --skip-worktree` to prevent accidental commits
- `--restore` reverses both: restores from backup, removes skip-worktree, deletes backup file
- If a backup already exists, the component is considered already-patched and skipped (use `--restore` first to re-patch)

---

## Git Protection

Three layers prevent accidentally committing dev-patched files:

### 1. Skip-Worktree (automatic)
Applied automatically when `localdev.py` patches a file:
```bash
# Check status
./localdev.py --check-git-status

# Manually manage
git update-index --skip-worktree path/to/deployment.yaml
git update-index --no-skip-worktree path/to/deployment.yaml
git ls-files -v | grep ^S   # Lists all skip-worktree files
```

### 2. Pre-Commit Hook
`install-git-protection.sh` installs a hook that blocks commits containing:
- `hostPath:` configurations
- Absolute paths like `/home/username/`
- Dev markers like `# add this for local dev test`

### 3. Backup Files
`_deployment.yaml.backup` files let you always recover the original:
```bash
./localdev.py --restore
```

To bypass the hook intentionally:
```bash
git commit --no-verify   # Use with caution
```

---

## Typical Workflow

```bash
# One-time setup
cd ~/mifos-gazelle/src/utils/localdev
./install-git-protection.sh
nano localdev.ini        # Set your hostpath and checkout_to_dir values
./localdev.py --setup    # Clone repos + patch deployments

# Deploy to cluster (via run.sh or helm upgrade)
# ...cluster must be running before pod restarts matter...

# Development loop
cd ~/ph-ee-bulk-processor
# ...edit Java files...
./gradlew clean build -x test
kubectl delete pod -n paymenthub -l app=ph-ee-bulk-processor
kubectl logs -f -n paymenthub -l app=ph-ee-bulk-processor

# Pull upstream changes
cd ~/mifos-gazelle/src/utils/localdev
./localdev.py --update --component bulk-processor

# When done
./localdev.py --restore
```

---

## Troubleshooting

### Changes not taking effect
```bash
# Check JAR was built in the expected location
ls -lh ~/your-project/build/libs/

# Verify hostPath is configured in the running deployment
kubectl get pod -n paymenthub -l app=your-component -o yaml | grep -A5 hostPath

# Check logs for startup errors
kubectl logs -n paymenthub -l app=your-component
```

### Permission denied on hostPath
```bash
chmod 755 ~/your-project
chmod 644 ~/your-project/build/libs/*.jar
```

### Git still shows modified files
```bash
./localdev.py --check-git-status
git update-index --skip-worktree path/to/deployment.yaml
git ls-files -v | grep deployment.yaml   # 'S' prefix = protected
```

### Pod in CrashLoopBackOff after patching
```bash
# Check events and logs
kubectl describe pod -n paymenthub -l app=your-component
kubectl logs -n paymenthub -l app=your-component

# Verify the JAR exists at the expected path
kubectl exec -n paymenthub deployment/your-component -- ls -la /app/build/libs/
```

Common causes:
- Wrong JAR filename in `jarpath` — check `build.gradle` for actual artifact name
- JAR hasn't been built yet — run `./gradlew clean build -x test`
- `hostpath` doesn't exist on the node — verify the directory exists

### Clone failed
```bash
# HTTPS repos — ensure credentials configured
git config --global credential.helper store

# SSH repos — ensure SSH key configured
ssh -T git@github.com

# Verify URL in localdev.ini
grep reponame localdev.ini
```

### Webapp not serving updated files
```bash
# Verify the build output exists
ls -la ~/ph-ee-operations-web/dist/web-app/

# Check the pod is using your hostPath
kubectl describe pod -n paymenthub -l app=ph-ee-operations-web | grep -A5 "Volumes:"

# Rebuild
cd ~/ph-ee-operations-web && npm run build
kubectl delete pod -n paymenthub -l app=ph-ee-operations-web
```

### Configuration changes not taking effect
When using hostPath mounts, the JAR contains the compiled configuration (Spring Boot YAML files). Editing `application.yaml` alone is not enough — you must rebuild the JAR:
```bash
cd ~/ph-ee-bulk-processor
./gradlew clean build -x test
kubectl delete pod -n paymenthub -l app=ph-ee-bulk-processor
```
ConfigMap updates do NOT take effect when using hostPath — the in-JAR config takes precedence.

---

## Notes

- **Multi-node clusters:** `hostPath` is node-specific. This tooling is designed for single-node k3s local clusters. For multi-node setups, you'd need NFS or similar shared storage.
- **After `helm upgrade`:** Helm overwrites patched `deployment.yaml` files. Re-run `./localdev.py` after any helm upgrade.
- **Non-Java components:** Adjust `app_type`, `image`, and `jarpath` for other runtimes (Node.js, Python, etc.).
- **Remote debugging:** Modify the command in the patched deployment to add JVM debug flags, then `kubectl port-forward deployment/your-component 5005:5005 -n paymenthub`.
