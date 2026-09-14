# MifosX — Pinned Image Versions

Single source of truth for the container images used by the MifosX deployment in Mifos Gazelle. **No `:latest` tags.** When adopting a new MifosX release, bump the pins here and in the referenced manifests together — see [UPGRADE-RUNBOOK.md](../../../../docs/UPGRADE-RUNBOOK.md).

Gazelle currently tracks the MifosX **25.12.25** release line.

## Application images

| Component | Image | Tag | Manifest |
|---|---|---|---|
| Fineract (core) | `openmf/fineract` | `1.14.0` | `fineract-server-deployment.yaml` |
| Web App | `openmf/web-app` | `dev-10d24b8` | `web-app-deployment.yaml` |
| Workflow Engine | `kanishksingh23/mifos-workflow` | `21082026` | `mifos-workflow-deployment.yaml` |
| Credit Bureau | `kanishksingh23/mifos-credit-bureau` | `21082026` | `credit-bureau-deployment.yaml` |
| SMS & Messaging | `openmf/message-gateway` | `dev-51abedb` | `message-gateway-deployment.yaml` |
| Loan Assessment | `kanishksingh23/mifos-x-reactive-loan-module` | `09082026` | `loan-module-deployment.yaml` |

Three of these are **built from source and pinned to a personal DockerHub namespace**, because neither the workflow engine, the credit bureau nor the loan module publishes a container image. They should move to `openmf` images once those are published. `docs/MIFOSX.md` covers the build and publish commands.

The web app is pinned to a `dev-` tag rather than the `1.12` release image because that release image is amd64-only, which breaks Gazelle's ARM64 targets. `dev-10d24b8` is the nearest multi-architecture build.

## Helper images used by initContainers

| Image | Used by | Purpose |
|---|---|---|
| `alpine:3.20` | `fineract-server` → `fetch-reporting-plugin` | Downloads and stages the Pentaho plugin and fonts |
| `postgres:16-alpine` | `fineract-server` → `enable-loan-events` | Enables the Fineract external events the loan module consumes |
| `postgres:16-alpine` | `credit-bureau` → `ensure-creditbureau-db` | Creates the `creditbureau` database if absent |
| `postgres:16-alpine` | `message-gateway` → `ensure-messagegateway-db` | Creates the `messagegateway` database if absent |
| `postgres:16-alpine` | `loan-module` → `ensure-loanrisk-db` | Creates the `loanrisk` database if absent |
| `curlimages/curl:8.10.1` | `credit-bureau` → `wait-for-fineract` | Blocks until the Fineract API answers |
| `busybox:1.36` | `mifos-workflow` → `wait-postgres`, `wait-fineract` | Blocks until PostgreSQL and Fineract are reachable |

## Non-image artefacts

| Artefact | Version | Where it is pinned |
|---|---|---|
| Pentaho reporting plugin | `MifosReportingPlugin-1.14.0` | downloaded from SourceForge by the `fetch-reporting-plugin` initContainer in `fineract-server-deployment.yaml` |

This one is not a container image, so it does not appear in any `image:` line — it is a zip fetched at pod startup. Bump it in the initContainer script when the plugin releases a version matching the Fineract in use.

## Shared infrastructure

Deployed by the `infra` chart, not by the MifosX manifests, and shared with the other DPGs.

| Component | Image | Tag | Pinned in |
|---|---|---|---|
| PostgreSQL | `bitnamilegacy/postgresql` | `16.6.0` | `src/deployer/helm/infra/values.yaml` |

Every MifosX component stores its data here: Fineract's per-tenant databases plus `mifos_flowable`, `creditbureau`, `messagegateway` and `loanrisk`.
