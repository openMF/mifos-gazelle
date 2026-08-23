Generate the full boilerplate for a new Mifos Gazelle plugin component named **$ARGUMENTS**.

## Context

Mifos Gazelle deploys Digital Public Goods (DPGs) to Kubernetes. Each component follows a consistent pattern:
- A deployer script at `src/deployer/<name>.sh` exporting `deploy_<name>()` and sourced by `deployer.sh`
- A config.ini section `[<name>]` with `enabled`, `namespace`, `repo`, `branch`
- An operator directory at `src/deployer/operators/<name>/` following the Mastercard pattern
- The deployer.sh dispatch table updated to include the new component

The existing Mastercard operator at `src/deployer/operators/mastercard/` is the reference implementation.

## What to Generate

Read these files first to understand conventions:
- `src/deployer/deployer.sh` — to see the dispatch table in `deploy_apps()` and `delete_apps()`
- `src/deployer/mifosx.sh` — for the deployer script pattern
- `src/deployer/operators/mastercard/deploy-operator.sh` — for the operator entrypoint pattern
- `src/deployer/operators/mastercard/controllers/reconcile.sh` — for the reconcile controller pattern
- `src/utils/logger.sh` — for the logging functions to use
- `config/config.ini` — to see existing section format

Then generate the following files. Write them to disk — do not just show them.

### 1. `src/deployer/$ARGUMENTS.sh`

A deployer script following mifosx.sh conventions:
- Shebang: `#!/usr/bin/env bash`
- One-line comment header: `# $ARGUMENTS.sh -- Mifos Gazelle deployer script for $ARGUMENTS`
- A `deploy_$ARGUMENTS()` function that:
  - Calls `log_section "Deploying $ARGUMENTS"`
  - Checks `is_app_running "$${ARGUMENTS^^}_NAMESPACE"` for idempotency
  - Calls `delete_resources_in_namespace_matching_pattern "$${ARGUMENTS^^}_NAMESPACE"` when redeploying
  - Calls `create_namespace "$${ARGUMENTS^^}_NAMESPACE"`
  - Calls `log_banner "$ARGUMENTS Deployed"` on success
  - Uses `log_step` / `log_ok` around each discrete step
  - Uses `run_as_user` for all kubectl and helm commands
  - Calls `check_command_execution $? "<description>"` after critical commands
- A `teardown_$ARGUMENTS()` function that calls `delete_resources_in_namespace_matching_pattern`
- A `status_$ARGUMENTS()` function that runs `kubectl get pods -n "$${ARGUMENTS^^}_NAMESPACE"`

### 2. `src/deployer/operators/$ARGUMENTS/deploy-operator.sh`

An operator entrypoint following the Mastercard pattern at `src/deployer/operators/mastercard/deploy-operator.sh`:
- `parse_args()` handling `-c|--config`, `-h|--help`, and `deploy|undeploy|status` subcommands
- `show_help()` with usage information
- `deploy_operator()`, `undeploy_operator()`, `status_operator()` functions
- `main()` entry point that validates the config file and kubectl/jq prerequisites

### 3. `src/deployer/operators/$ARGUMENTS/controllers/reconcile.sh`

A reconcile controller following `src/deployer/operators/mastercard/controllers/reconcile.sh`:
- `log_info()`, `log_warn()`, `log_error()` functions using `[$(date ...)] LEVEL:` format
- `reconcile()` function taking `cr_name`, `namespace`, `config_file` params
- `ensure_namespace()`, `cleanup_resources()`, `update_status()` functions
- `watch_resources()` polling loop with 30s sleep
- `main()` entry point with arg parsing and prerequisite checks

### 4. `src/deployer/operators/$ARGUMENTS/crd.yaml`

A Kubernetes CRD for the operator's custom resource:
- `apiVersion: apiextensions.k8s.io/v1`
- `kind: CustomResourceDefinition`
- Singular/plural/shortname based on component name
- `spec.versions[0].schema.openAPIV3Schema` with at minimum: `enabled` (bool), `replicas` (int), `namespace` (string) under `.spec`
- Status subresource with `phase` field

### 5. Config section to add to `config/config.ini`

Print (don't write) the INI section to add — it should follow the format of existing sections. The user will add this manually. Example shape:
```
[$ARGUMENTS]
enabled = false
namespace = $ARGUMENTS
repo = https://github.com/mifos/$ARGUMENTS
branch = main
```

### 6. Changes needed in `deployer.sh`

Print (don't write) the exact lines to add to `deploy_apps()` and `delete_apps()` case statements, and the `source` line to add at the top of `deployer.sh`. The user will apply these manually.

## Conventions to Follow

- All logging via `log_section`, `log_step`, `log_ok`, `log_banner`, `log_error`, `log_warn` from `src/utils/logger.sh` — never raw `echo` for user-facing output
- All kubectl/helm via `run_as_user "..."` — never invoked directly
- Namespace variable: `${ARGUMENTS^^}_NAMESPACE` (uppercase component name + `_NAMESPACE`)
- Config variables read via `crudini --get` in `commandline.sh`, not hardcoded in deployer scripts
- Operator reconcile loop uses 30s sleep between polls
- Operator main validates `kubectl` and `jq` are present before starting

After generating the files, summarize what was written and what the user needs to do manually (the config.ini section and deployer.sh changes).
