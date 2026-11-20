# Local Development Tools for Payment Hub EE

## Contents

- [Overview](#overview)
- [Quick Start](#quick-start)
- [Reading `--status`](#reading---status)
- [How CR mode Works](#how-cr-mode-works)
- [How k8s-direct mode Works](#how-k8s-direct-mode-works)
- [Command Reference](#command-reference)
- [Build Loop](#build-loop)
- [Working From Forks](#working-from-forks)
- [localdev.ini Configuration](#localdevini-configuration)
- [Configured Components](#configured-components)
- [Running the Operator From a Local Build](#running-the-operator-from-a-local-build)
- [Troubleshooting](#troubleshooting)
- [Notes](#notes)

---

## Overview

`src/utils/localdev/` contains tools for iterating on Payment Hub EE Java components without rebuilding Docker images or pushing to a registry.

**The Problem:** Normal testing of Java changes requires: edit → build JAR → build Docker image → push to registry → redeploy. This is slow.

**The Solution:** `localdev.py` mounts your local project directory into the running pod via a `hostPath` volume. You rebuild the JAR locally and restart the pod — no Docker build required.

All PHEE components are **operator-managed**: the PaymentHub Kubernetes operator deploys them from `PaymentHubDeployment` CRs in `src/deployer/operators/paymenthub/config/cr/`. `localdev.py` sets `spec.localDev` on a component's CR, and the operator renders the hostPath Deployment itself. The operator keeps it on every reconcile, so there's nothing to scale down and nothing gets reverted ([CR mode](#how-cr-mode-works)). The operator's own Deployment has no CR, so it's patched directly ([k8s-direct mode](#how-k8s-direct-mode-works)).

> **Naming note:** the services now live in `openMF/paymenthub-ee-*` repos (some consolidated: `paymenthub-ee-data-pipeline` holds importer-rdbms, importer-es and zeebe-ops). Always verify Deployment names with `kubectl get deployments -n paymenthub`.

### Files

| File | Purpose |
|------|---------|
| `localdev.py` | Main script — patches Deployments and manages repo checkouts |
| `localdev.ini` | Configuration: which components to patch, your fork owner and branches |
| `fork-phee-repos.sh` | Forks the openMF `paymenthub-ee-*` repos to your account and sets up local clones (see [Working From Forks](#working-from-forks)) |

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

# 2. Clone the repo / switch to your branch (branch_or_tag in localdev.ini)
./localdev.py --update --component importer-rdbms

# 3. Build the JAR (Java 21)
cd ~/paymenthub-ee-data-pipeline/importer-rdbms
./gradlew bootJar

# 4. Run your JAR in the cluster (sets spec.localDev on the CR)
cd ~/mifos-gazelle/src/utils/localdev
./localdev.py --setup --component importer-rdbms
# after each rebuild:
./localdev.py --restart --component importer-rdbms

# 5. When done, go back to the image
cd ~/mifos-gazelle/src/utils/localdev
./localdev.py --restore --component importer-rdbms
```

> **Java version:** the `paymenthub-ee-*` repos target Java 21 (`eclipse-temurin:21` at runtime). Check `java -version`, or set `JAVA_HOME` to a JDK 21, before building.

---

## Reading `--status`

```
  ── deployable  (run your build in the cluster) ──────────────────────────────
  COMPONENT            BRANCH                                   UPSTREAM   RUNNING
  paymenthub-operator  ⚠️  PHEE-455-operator-localdev (ini: dev)  1 behind   🔧 local JAR  (direct)
  channel              ✅ dev                                   current    📦 image dev-4252b33
```

| Column | Value | Meaning |
|--------|-------|---------|
| BRANCH | `✅ dev` | The clone is on the `branch_or_tag` set in `localdev.ini` |
| | `⚠️  <branch> (ini: dev)` | The clone is on another branch. Normal while you work on a ticket. Set `branch_or_tag` to the branch if you want `--update` to stay on it |
| | `❌ not cloned` | Run `--checkout` |
| UPSTREAM | `N behind` / `current` | Commits on `upstream/<base_branch>` that aren't in your branch. Uses the last fetch; `--update` fetches |
| RUNNING | `🔧 local JAR (CR)` | Your build, through `spec.localDev` on the CR ([CR mode](#how-cr-mode-works)). Webapps show `local files` |
| | `🔧 local JAR (direct)` | Your build, through a direct Deployment patch ([k8s-direct mode](#how-k8s-direct-mode-works)) |
| | `📦 image <tag>` | The registry image |
| | `… (stale backup — run --clean-backups)` | A k8s-direct backup is left over after a redeploy put the image back |
| | `⚠️  reverted → …` | A backup exists but the Deployment no longer runs your build |

Components under **checkout only** have no Deployment to patch, so they have no RUNNING column.

---

## How CR mode Works

For a component whose `k8s_deploy_name` has a `PaymentHubDeployment` CR (every PHEE service), `localdev.py`:

1. Resolves the host path and the boot jar, as k8s-direct mode does.
2. Sets `spec.localDev` on the CR with `kubectl patch --type merge`:
   ```yaml
   spec:
     localDev:
       enabled: true
       hostPath: /home/you/paymenthub-ee-data-pipeline/importer-rdbms
       jarPath: /app/build/libs/importer-rdbms.jar   # springboot
       image: eclipse-temurin:21                     # from localdev.ini
       # mountPath: /usr/share/nginx/html            # webapp: no jarPath, image kept
   ```
3. Waits for the operator to re-render the Deployment, which then carries the annotation `paymenthub.mifos.org/local-dev: <hostPath>`, and for the rollout.

The operator renders the same Deployment it always does (env vars, ConfigMaps, probes, Services, Ingress). For a springboot component it swaps the image for the JDK image, runs `java -jar <jarPath>`, and mounts the host directory at `/app`. A webapp keeps its image and has the directory mounted over nginx's html root. Reconciles keep it that way.

- `--restore` removes `spec.localDev`, and the operator puts the image back. There are no backup files.
- `--restart` deletes the pod and waits for the replacement to be Ready. Use it after rebuilding the jar. Don't use `kubectl rollout restart`: the operator removes its annotation on the next reconcile, which restarts the pod a second time.

**The operator only honours `spec.localDev` when it runs with `LOCALDEV_ENABLED=true`.** `paymenthub.sh` sets that on local clusters (`environment = local`, k3s or Colima) and never on remote ones. If it isn't set, `localdev.py` warns you, and the operator logs that it's ignoring the field. On a cluster deployed before this change, either redeploy PaymentHub or run:
```bash
kubectl apply -f ~/mifos-gazelle/src/deployer/operators/paymenthub/config/crd/paymenthub-ee-CustomResourceDefinition.yaml
kubectl set env deployment/paymenthub-ee-operator -n paymenthub LOCALDEV_ENABLED=true
```
This also needs an operator build that includes PHEE-455 (openMF/paymenthub-ee-k8s-operators). Until a published image has it, run the operator from a local build ([below](#running-the-operator-from-a-local-build)).

A full redeploy (`./run.sh -m deploy`) reapplies the CR files with `kubectl apply`, which keeps a `localDev` that `localdev.py` added. `cleanapps` deletes the CRs, so a fresh deploy starts on images.

---

## How k8s-direct mode Works

Used for components without a `PaymentHubDeployment` CR, which in practice means the operator itself. The patcher:

1. Runs `kubectl get deployment <name> -n <namespace> -o json` to fetch the live Deployment
2. Saves the original as a JSON backup at `~/.localdev-backups/<component>-deployment.json`
3. Modifies the Deployment spec:
   - Overrides the container image with the JDK image (e.g., `eclipse-temurin:21`)
   - Adds `command: ["java", "-jar", "<jarpath>"]`
   - Adds a `volumeMount` at `/app` in the container
   - Adds a `hostPath` volume pointing to your local project directory
4. Applies the patched manifest via `kubectl apply -f -`
5. Waits for rollout to complete

`--restore` re-applies the original JSON backup and deletes the backup file.

Nothing reconciles the operator's own Deployment (`paymenthub.sh` applies it directly), so a direct patch to it stays. A direct patch to a CR-managed component would be reverted by the operator, which is why those use CR mode.

---

## Command Reference

```bash
# Show status of all components (repo branch + patch state)
./localdev.py --status

# Complete setup: checkout repo + patch deployment
./localdev.py --setup
./localdev.py --setup --component importer-rdbms   # single component

# Clone missing repositories (components with checkout_enabled = true)
./localdev.py --checkout
./localdev.py --checkout --component channel

# Fetch, switch to branch_or_tag (created from upstream/<base_branch> if new),
# fast-forward. Never pushes, merges or rebases; won't switch over uncommitted changes.
./localdev.py --update
./localdev.py --update --component channel

# Preview what would be changed without modifying anything
./localdev.py --dry-run
./localdev.py --dry-run --component importer-rdbms

# Patch deployments only (no checkout)
./localdev.py
./localdev.py --component importer-rdbms

# Back to the image (CR mode removes spec.localDev; k8s-direct restores its backup)
./localdev.py --restore
./localdev.py --restore --component importer-rdbms

# Pick up a rebuilt jar (deletes the pod, waits for the new one to be Ready)
./localdev.py --restart --component importer-rdbms

# Delete k8s-direct backups whose Deployment a redeploy has already put back on the image
./localdev.py --clean-backups

# Use a custom config file
./localdev.py --config /path/to/custom.ini
```

---

## Build Loop

```bash
cd ~/paymenthub-ee-data-pipeline/importer-rdbms
# ... edit Java files ...
./gradlew bootJar          # Java 21
~/mifos-gazelle/src/utils/localdev/localdev.py --restart --component importer-rdbms
kubectl logs -f -n paymenthub -l app=paymenthub-ee-importer-rdbms
```

---

## Working From Forks

openMF branch protection blocks new branches on the `paymenthub-ee-*` repos, so
work happens in personal forks. One-off setup:

```bash
gh auth login                      # once; add `-s workflow` so fork syncs can include CI changes
src/utils/localdev/fork-phee-repos.sh            # prompts for the fork owner (default: your gh login)
src/utils/localdev/fork-phee-repos.sh -h         # options: owner/org, clone dir, repo subset, ssh/https
```

Each clone then has `origin` = your fork and `upstream` = openMF (HTTPS, push
URL set to `DISABLED`). localdev.py builds the same remotes from `[general]`
(`fork_owner`, `upstream_owner`, `git_protocol`); `LOCALDEV_FORK_OWNER` overrides
`fork_owner` without editing the ini.

Per ticket:

1. Set `branch_or_tag` in the component's section to your branch name
2. `./localdev.py --update --component <name>` — creates the branch from `upstream/dev` if it's new
3. Build (`./gradlew bootJar`), then `./localdev.py --setup --component <name>`
4. Commit; push to your fork and open the PR against openMF `dev`
5. `./localdev.py --restore --component <name>`

---

## localdev.ini Configuration

### Component Modes

| Fields present | Mode | Effect |
|---------------|------|--------|
| `k8s_deploy_name`, with a `PaymentHubDeployment` CR of that name | CR | Sets `spec.localDev`; the operator renders the hostPath Deployment |
| `k8s_deploy_name`, no CR | k8s-direct | Patches the live Kubernetes Deployment + hostPath mount |
| `checkout_enabled` only | checkout-only | Clones/updates repo; no deployment patching |

The mode is picked at run time by checking whether the CR exists. The operator itself (`paymenthub-operator`) has no CR, so it uses k8s-direct mode.

### Configuration Parameters

| Parameter | Required | Description |
|-----------|----------|-------------|
| `[general].gazelle-home` | Yes | Root path to your mifos-gazelle clone |
| `[general].fork_owner` | No | GitHub user/org holding your forks: `auto` (default, your `gh` login), a name, or `none` to clone upstream directly |
| `[general].upstream_owner` | No | Upstream owner (default: `openMF`) |
| `[general].git_protocol` | No | `ssh` (default) or `https`, for `origin` |
| `checkout_to_dir` | No | Directory to clone into (default: `$HOME`; set in `[general]` or per section) |
| `base_branch` | No | Upstream branch new work branches are cut from (default: `dev`; `[general]` or per section) |
| `k8s_deploy_name` | k8s-direct | Kubernetes Deployment name (`kubectl get deployments -n paymenthub`) |
| `k8s_namespace` | k8s-direct | Namespace of the Deployment (default: `paymenthub`) |
| `app_type` | No | `springboot` (default) or `webapp` |
| `image` | springboot | JDK container image, e.g. `eclipse-temurin:21` |
| `hostpath` | No | Local path mounted at `/app` (default: `<checkout_to_dir>/<repo>[/<module>]`) |
| `jarpath` | No | Path to JAR inside the container. Default: the boot jar auto-detected in `<hostpath>/build/libs` (`*-plain.jar` ignored, newest wins) |
| `checkout_enabled` | No | `true` to enable automatic repo clone/update |
| `repo` | If checkout | Repo name, e.g. `paymenthub-ee-connector-channel`; URLs come from `[general]` |
| `reponame` | — | Full git URL instead of `repo`, for repos that aren't forked (no `upstream` remote) |
| `module` | No | Subdirectory of a multi-module repo that holds the service |
| `branch_or_tag` | No | Your working branch or a tag (default: `base_branch`) |

Sections sharing one repo (`importer-rdbms`/`zeebe-ops`/`importer-es`,
`mock-payment`/`integration-test`) share one working tree, so give them the same
`branch_or_tag`.

### Variable Expansion

- Environment variables: `$HOME`, `$USER`, etc.
- Custom variables: `${gazelle-home}` references the `[general]` section

### Adding k8s-direct patching to a checkout-only component

```ini
[my-component]
k8s_deploy_name = paymenthub-ee-my-component   # verify with: kubectl get deployments -n paymenthub
k8s_namespace   = paymenthub
app_type        = springboot
image           = eclipse-temurin:21
checkout_enabled = true
repo            = paymenthub-ee-my-component
branch_or_tag   = dev
```

---

## Configured Components

| Section | Repo (`module`) | k8s Deployment name |
|---------|-----------------|---------------------|
| `paymenthub-operator` | `paymenthub-ee-k8s-operators` (`paymenthub-operator`) | `paymenthub-ee-operator` |
| `channel` | `paymenthub-ee-connector-channel` | `paymenthub-ee-connector-channel` |
| `bulk-processor` | `paymenthub-ee-bulk-processor` | `paymenthub-ee-bulk-processor` |
| `connector-bulk` | `paymenthub-ee-connector-bulk` | `paymenthub-ee-connector-bulk` |
| `mock-payment` | `paymenthub-ee-e2e-tests` (`mock-payment-schema`) | `paymenthub-ee-connector-mock-payment-schema` |
| `operations-app` | `paymenthub-ee-bff` | `paymenthub-ee-bff` |
| `operationsui-react` | `paymenthub-ee-operationsui-react` (`dist`, webapp) | `paymenthub-ee-operationsui-react` |
| `importer-rdbms` | `paymenthub-ee-data-pipeline` (`importer-rdbms`) | `paymenthub-ee-importer-rdbms` |
| `zeebe-ops` | `paymenthub-ee-data-pipeline` (`zeebe-ops`) | `paymenthub-ee-zeebe-ops` |
| `importer-es` | `paymenthub-ee-data-pipeline` (`importer-es`) | `paymenthub-ee-importer-es` (CR disabled by default) |
| `identity-account-mapper` | `paymenthub-ee-account-mapper` | `paymenthub-ee-account-mapper` |
| `ams-mifos` | `paymenthub-ee-connector-ams-mifosx` | `paymenthub-ee-connector-ams-mifosx` |
| `connector-mojaloop` | `paymenthub-ee-connector-mojaloop` | `paymenthub-ee-connector-mojaloop` |
| `notifications` | `paymenthub-ee-notifications` | `paymenthub-ee-notifications` |
| `vouchers` | `paymenthub-ee-vouchers` | `paymenthub-ee-vouchers` |
| `bill-pay` | `paymenthub-ee-p2g` (`p2g`) | `paymenthub-ee-p2g` |
| `connector-gsma` | `paymenthub-ee-connector-mm-gsma` | `paymenthub-ee-connector-mm-gsma` (CR disabled by default) |
| `integration-test` | `paymenthub-ee-e2e-tests` (`integration-test`) | — checkout only (test suite) |
| `auth`, `core`, `dpg-core`, `connector-ams-paygops`, `connector-crm`, `connector-mpesa`, `connector-slcb`, `operationsui-angular` | `paymenthub-ee-<section>` | — checkout only |
| `connector-mccbs` | `ph-ee-connector-mccbs` (`reponame`, not forked) | — separate operator |

---

## Running the Operator From a Local Build

The operator (`paymenthub-operator`) is set up in `localdev.ini` exactly like any other k8s-direct component — its own Deployment is applied directly by `paymenthub.sh`, not reconciled by anything, so there's no need to scale anything down first:

```bash
cd ~/mifos-gazelle/src/utils/localdev
./localdev.py --setup --component paymenthub-operator   # checkout + patch

cd ~/paymenthub-ee-k8s-operators/paymenthub-operator
./gradlew bootJar
~/mifos-gazelle/src/utils/localdev/localdev.py --restart --component paymenthub-operator   # pick up the new JAR

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
# paymenthub-ee-* repos target Java 21
java -version
./gradlew bootJar
```

### Pod in CrashLoopBackOff after patching
```bash
kubectl describe pod -n paymenthub -l app=your-component
kubectl logs -n paymenthub -l app=your-component

# Verify the JAR exists inside the container
kubectl exec -n paymenthub deployment/your-component -- ls -la /app/build/libs/
```

Common causes:
- A forced `jarpath` that no longer matches the built jar — remove it to use auto-detection
- JAR not yet built — run `./gradlew bootJar` (localdev refuses to patch when `build/libs` has no boot jar)
- `hostpath` directory does not exist on the node

### Component still runs its image after `localdev.py`
- **The operator ignores `spec.localDev`:** check `kubectl logs deploy/paymenthub-ee-operator -n paymenthub | grep localDev`. It needs `LOCALDEV_ENABLED=true` and an operator build with PHEE-455 (see [CR mode](#how-cr-mode-works)).
- **The CRD predates `localDev`:** the API server then drops the field. Check with `kubectl get paymenthubdeployment <name> -n paymenthub -o jsonpath='{.spec.localDev}'`, and apply the CRD from `src/deployer/operators/paymenthub/config/crd/` if it's empty.

### Restore fails (k8s-direct)
CR-mode components have no backup; `--restore` just removes `spec.localDev`. For a k8s-direct component:
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
./gradlew bootJar
~/mifos-gazelle/src/utils/localdev/localdev.py --restart --component <name>
```
Environment variables from the CR or ConfigMaps still apply and override the in-JAR `application.yaml`, as they do for the image.

### Permission denied on hostPath
```bash
chmod 755 ~/your-project
chmod 644 ~/your-project/build/libs/*.jar
```

---

## Notes

- **Single-node only:** `hostPath` is node-specific. This tooling is designed for single-node k3s local development.
- **Redeploys:** `./run.sh -m deploy` keeps CR-mode `localDev` settings, but reapplies the operator's own Deployment, which undoes a k8s-direct patch. `--status` then shows a stale backup; run `--clean-backups`, then `--setup` again.
- **Remote debugging:** Add JVM debug flags to the command in the patched deployment, then `kubectl port-forward deployment/your-component 5005:5005 -n paymenthub`.
