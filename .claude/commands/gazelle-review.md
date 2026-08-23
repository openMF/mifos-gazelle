Review the Gazelle-specific conventions in the current branch's changed files and report any violations.

## What to Check

First, get the list of changed files on this branch:
```
git diff dev...HEAD --name-only
```

Read each changed `.sh` file. Then check for each of the following categories. Report findings as a checklist with PASS / WARN / FAIL per item.

---

### 1. Logging — no raw echo for user-facing output

All user-visible output must use functions from `src/utils/logger.sh`. Raw `echo` is only acceptable for internal variable capture or heredocs.

**Allowed functions:** `log_section`, `log_step`, `log_ok`, `log_banner`, `log_error`, `log_warn`, `log_with_verbose_check`, `log_with_level`, `log_failed`

**Violation pattern:** `echo "Deploying..."` or `echo "ERROR:..."` without routing through logger functions.

**Why:** `GAZ-285` was a set of bugs caused by logging that bypassed the logger — it produced inconsistent output and missed colour coding and file logging.

---

### 2. kubectl/helm via run_as_user

In deployer scripts (files under `src/deployer/`), all `kubectl` and `helm` invocations must be wrapped in `run_as_user "..."`. Direct invocation drops the non-root user context that `run.sh` establishes.

**Exception:** Operator controller scripts under `src/deployer/operators/*/controllers/` may call `kubectl` directly — they run in their own process context.

**Violation pattern:** `kubectl apply ...` or `helm install ...` called bare in a deployer script.

---

### 3. Error checking after critical commands

After any `run_as_user "..."` call that is not piped or captured, there must be a `check_command_execution $? "<description>"` call immediately after. One-liner chains (e.g. `run_as_user "..." || true`) are acceptable if the failure is intentionally ignored.

**Violation pattern:** `run_as_user "kubectl apply ..."` with no subsequent `check_command_execution` and no explicit `|| true`.

---

### 4. Idempotency guard in deploy functions

Every `deploy_<component>()` function must check whether the component is already running before deploying:
```bash
if is_app_running "$COMPONENT_NAMESPACE"; then
  if [[ "$redeploy" == "false" ]]; then
    echo "    Already deployed — skipping."
    return 0
  fi
fi
```
Without this guard, re-running `./run.sh -a all` will tear down and redeploy a healthy component unnecessarily.

---

### 5. deployer.sh dispatch registration

If a new deployer script is added (`src/deployer/<name>.sh`), verify that:
- It is sourced near the top of `src/deployer/deployer.sh`
- Its app name appears in the `deploy_apps()` case statement
- Its app name appears in the `delete_apps()` case statement

Cross-reference: read `src/deployer/deployer.sh` and look for the new component name.

---

### 6. Config values via crudini, not hardcoded

Namespace names, repo URLs, branches, and domain names must come from config variables (set by `crudini --get` in `commandline.sh`) — not hardcoded strings in deployer scripts.

**Allowed:** `$MIFOSX_NAMESPACE`, `$GAZELLE_DOMAIN`, `$PH_NAMESPACE`
**Violation pattern:** `kubectl create namespace paymenthub` or `helm install ... my-domain.local`

Check `src/commandline/commandline.sh` to verify that any new config variables introduced in the changed files are actually loaded there.

---

### 7. Namespace variable naming convention

New component namespace variables must follow the pattern `${COMPONENT_UPPER}_NAMESPACE`, e.g. `MIFOSX_NAMESPACE`, `PH_NAMESPACE`, `VNEXT_NAMESPACE`. They must be exported or declared at the commandline.sh level, not local to deployer functions.

---

### 8. Operator pattern compliance

If changes are in `src/deployer/operators/<name>/`:
- `deploy-operator.sh` must have `parse_args()`, `show_help()`, and a `main()` that validates `kubectl` and `jq`
- `controllers/reconcile.sh` must export `reconcile()` taking `cr_name namespace config_file`
- `controllers/reconcile.sh` must have `update_status()` using `kubectl patch ... --subresource=status`
- The operator must handle the `status` subcommand in its main dispatch
- The reconcile loop must not poll faster than 30s

Compare structure against `src/deployer/operators/mastercard/` as the reference.

---

## Output Format

Report in this structure:

```
## Gazelle Convention Review

### Files Reviewed
- list changed .sh files

### Results

| # | Check | Status | File:Line | Detail |
|---|-------|--------|-----------|--------|
| 1 | No raw echo | PASS | — | — |
| 2 | run_as_user | FAIL | src/deployer/foo.sh:42 | bare kubectl apply |
...

### Summary
X checks passed, Y warnings, Z failures.

### Required Fixes (if any)
- specific actionable fix for each FAIL
```

If there are no changed `.sh` files on this branch compared to `dev`, say so and exit.
