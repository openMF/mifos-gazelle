# Payment Hub EE — Component Release History

This document tracks the component branches and version lineage used in the Mifos Gazelle deployment of Payment Hub EE.

The working branch for the next release is **`mifos-v2.0.0`** — the placeholder branch on which future PHEE v2.0.0 versions are built.
All of the active components have now been merged into current dev branch and will be developed further from there so the mifos-v2.0.0 commit into dev aloing with this table gives traceable history of each component and their versions.
The current Gazelle deployment is based on **PHEE v1.13.3** (reference: Release Notes v1.13.1-1).

---

## Repository Naming: `ph-ee-*` → `paymenthub-ee-*`

The tables below use the `ph-ee-*` component names that were standard at the time this document was
originally written — those names are kept as-is for historical accuracy (they match the Gazelle
branch names cut at the time). Since then, the upstream `openMF` GitHub org has been renaming these
repos to a `paymenthub-ee-*` prefix, and Gazelle's own Kubernetes resource names (Deployments,
Services, CRs) have largely followed suit. The rename is a rolling effort and not every component has
moved yet, so the two names coexist in the codebase today. This table is the current (as of this
branch, September 2026) old-name → new-name mapping — treat it as a snapshot, not a permanent fact,
and re-verify against `kubectl get deployments -n paymenthub` or the upstream repo before relying on
a name in automation:

| Old name (`ph-ee-*` / legacy) | Current name | Status |
|---|---|---|
| `ph-ee-connector-channel` | `paymenthub-ee-connector-channel` | Renamed |
| `ph-ee-connector-bulk` | `paymenthub-ee-connector-bulk` | Renamed |
| `ph-ee-bulk-processor` | `paymenthub-ee-bulk-processor` | Renamed |
| `ph-ee-connector-ams-mifos` | `paymenthub-ee-connector-ams-mifosx` | Renamed |
| `ph-ee-connector-mojaloop-java` | `paymenthub-ee-connector-mojaloop` | Renamed |
| `ph-ee-identity-account-mapper` | `paymenthub-ee-account-mapper` | Renamed |
| `ph-ee-connector-mock-payment-schema` | `paymenthub-ee-e2e-tests` (module `mock-payment-schema/`) | Renamed & merged |
| `ph-ee-integration-test` | `paymenthub-ee-e2e-tests` (module `integration-test/`) | Renamed & merged |
| `ph-ee-operations-app` | `paymenthub-ee-bff` | Renamed (also absorbs the former `ph-ee-operations-g2p-service`) |
| `ph-ee-notifications` | `paymenthub-ee-notifications` | Renamed |
| `ph-ee-connector-gsma-mm` | `paymenthub-ee-connector-mm-gsma` | Renamed (no `paymenthub-ee-*` image published yet) |
| `ph-ee-vouchers` | `paymenthub-ee-vouchers` | Renamed (CR defined but disabled) |
| `ph-ee-connector-crm` | `paymenthub-ee-connector-crm` | Renamed (no `paymenthub-ee-*` image published yet) |
| `ph-ee-importer-es` | `paymenthub-ee-importer-es` | Renamed (CR defined but disabled) |
| `ph-ee-bill-pay` | `paymenthub-ee-p2g` | Renamed |
| `ph-ee-k8s-operators` | `paymenthub-ee-k8s-operators` | Renamed |
| `ph-ee-importer-rdbms` | unchanged upstream | Kubernetes Deployment renamed to `paymenthub-ee-importer-rdbms`; source repo is still `ph-ee-importer-rdbms` |
| `ph-ee-zeebe-ops` | unchanged upstream | Kubernetes Deployment renamed to `paymenthub-ee-zeebe-ops`; source repo is still `ph-ee-zeebe-ops` |
| `ph-ee-operations-web` | unchanged | Not yet renamed; `paymenthub-ee-operationsui-react` and `paymenthub-ee-operationsui-angular` exist as scaffold-only successors (no UI code migrated yet) |
| `ph-ee-connector-mccbs` | unchanged | Mastercard CBS connector — deployed by a separate operator, not yet renamed |
| `ph-ee-env-template` | retired | Its Helm chart was vendored directly into `src/deployer/helm/paymenthub-infra/`; Gazelle no longer clones this repo |
| `message-gateway` | unchanged | Never carried a `ph-ee-` prefix |
| `ph-ee-id-account-validator-impl`, `ph-ee-exporter`, `ph-ee-connector-common`, `ph-ee-connector-slcb`, `ph-ee-connector-ams-paygops`, `ph-ee-connector-ams-pesa`, `ph-ee-connector-mpesa` | unconfirmed | Not verified against current upstream repos — check `github.com/openMF` before relying on either name |

---

## Active Components (deployed by Gazelle)

| Component | Gazelle Branch | Version Lineage |
|-----------|---------------|-----------------|
| `ph-ee-connector-channel` → `paymenthub-ee-connector-channel` | `mifos-v2.0.0` | `v1.11.0-gazelle-1.1.0` + v1.12.2 + CORS fixes |
| `ph-ee-connector-bulk` → `paymenthub-ee-connector-bulk` | `mifos-v2.0.0` | `v1.1.0-gazelle-1.1.0` + PHEE v1.13.3 (tag v1.2.1) |
| `ph-ee-bulk-processor` → `paymenthub-ee-bulk-processor` | `mifos-v2.0.0` | master ≡ PHEE v1.13.3 (tag v1.13.1) |
| `ph-ee-connector-ams-mifos` → `paymenthub-ee-connector-ams-mifosx` | `mifos-v2.0.0` | `tomtest-v1.15.0` (already merged PHEE v1.13.3, tag v1.17.3) — note: shared with other users |
| `ph-ee-connector-mojaloop-java` → `paymenthub-ee-connector-mojaloop` | `mifos-v2.0.0` | tag v1.5.2 (master = v1.5.2 as at Nov 2025) |
| `ph-ee-identity-account-mapper` → `paymenthub-ee-account-mapper` | `mifos-v2.0.0` | `v1.6.0-gazelle-1.1.0` + tom-work + v1.6.2 (PHEE v1.13.3) + other fixes |
| `ph-ee-connector-mock-payment-schema` → `paymenthub-ee-e2e-tests` (module) | `mifos-v2.0.0` | `v1.6.0-gazelle-1.1.0` + v1.6.1 (PHEE v1.13.3), updated to JDK 17 |
| `ph-ee-importer-rdbms` (unchanged upstream) | `mifos-v2.0.0` | `v1.13.1-gazelle-1.1.0` + tag v1.14.2 |
| `ph-ee-operations-app` → `paymenthub-ee-bff` | `mifos-v2.0.0` | `v1.17.1-gazelle-1.1.0` + tag v1.20.2 + JDK 17 updates |
| `ph-ee-operations-web` (unchanged) | `mifos-v2.0.0` | `v1.25.0-gazelle-1.1.0` + Dipan's UI changes (`v1.26.0-gazelle-1.2.0-beta`) |
| `ph-ee-zeebe-ops` (unchanged upstream) | `mifos-v2.0.0` | `v1.4.0-gazelle-1.1.0` (v1.5.0 tag may exist but unconfirmed / likely redundant) |
| `ph-ee-env-template` (retired) | `gazelle-dev` | From `v1.13.0-gazelle-1.1.0` |
| `ph-ee-connector-gsma-mm` → `paymenthub-ee-connector-mm-gsma` | `mifos-v2.0.0` | `v1.3.0-gazelle-1.1.0` + JDK 17 migration |

---

## Library Components

| Component | Gazelle Branch | Version Lineage |
|-----------|---------------|-----------------|
| `ph-ee-id-account-validator-impl` (unconfirmed) | `mifos-v2.0.0` | `v1.1.0-gazelle-1.1.0` |

---

## Needs Verification

| Component | Notes |
|-----------|-------|
| `ph-ee-exporter` (unconfirmed) | Version/branch to be confirmed |
| `ph-ee-connector-common` (unconfirmed) | Version unclear |

---

## Not Yet Used in Gazelle

| Component | Status |
|-----------|--------|
| `ph-ee-importer-es` → `paymenthub-ee-importer-es` | Not yet used |
| `ph-ee-connector-slcb` (unconfirmed) | Not yet used |
| `ph-ee-connector-ams-paygops` (unconfirmed) | Not yet used |
| `ph-ee-connector-ams-pesa` (unconfirmed) | Not yet used |
| `ph-ee-connector-mpesa` (unconfirmed) | Not yet used |
| `ph-ee-notifications` → `paymenthub-ee-notifications` | Not yet used |
| `message-gateway` (unchanged) | Not yet used |
| `ph-ee-vouchers` → `paymenthub-ee-vouchers` | Not yet used |
| `ph-ee-connector-crm` → `paymenthub-ee-connector-crm` | Not yet used |
| `ph-ee-bill-pay` → `paymenthub-ee-p2g` | Not yet used |

---

## Notes

- **`mifos-v2.0.0` branch**: the common working branch across all active components for the next Gazelle release. Not a published PHEE release tag — it is Gazelle's integration branch layered on top of PHEE v1.13.3.
- **Version lineage format**: entries show the Gazelle baseline tag the branch was cut from, plus any upstream PHEE tags or feature branches subsequently merged in.
- **Reference**: Avik's PHEE releases spreadsheet (tags and branches for PHEE v1.13.3 / Release Notes v1.13.1-1) was used as the upstream version reference.
