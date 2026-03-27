# Payment Hub EE — Component Release History

This document tracks the component branches and version lineage used in the Mifos Gazelle deployment of Payment Hub EE.

The working branch for the next release is **`mifos-v2.0.0`** — the placeholder branch on which future PHEE v2.0.0 versions are built.
All of the active components have now been merged into current dev branch and will be developed further from there so the mifos-v2.0.0 commit into dev aloing with this table gives traceable history of each component and their versions.
The current Gazelle deployment is based on **PHEE v1.13.3** (reference: Release Notes v1.13.1-1).

---

## Active Components (deployed by Gazelle)

| Component | Gazelle Branch | Version Lineage |
|-----------|---------------|-----------------|
| `ph-ee-connector-channel` | `mifos-v2.0.0` | `v1.11.0-gazelle-1.1.0` + v1.12.2 + CORS fixes |
| `ph-ee-connector-bulk` | `mifos-v2.0.0` | `v1.1.0-gazelle-1.1.0` + PHEE v1.13.3 (tag v1.2.1) |
| `ph-ee-bulk-processor` | `mifos-v2.0.0` | master ≡ PHEE v1.13.3 (tag v1.13.1) |
| `ph-ee-connector-ams-mifos` | `mifos-v2.0.0` | `tomtest-v1.15.0` (already merged PHEE v1.13.3, tag v1.17.3) — note: shared with other users |
| `ph-ee-connector-mojaloop-java` | `mifos-v2.0.0` | tag v1.5.2 (master = v1.5.2 as at Nov 2025) |
| `ph-ee-identity-account-mapper` | `mifos-v2.0.0` | `v1.6.0-gazelle-1.1.0` + tom-work + v1.6.2 (PHEE v1.13.3) + other fixes |
| `ph-ee-connector-mock-payment-schema` | `mifos-v2.0.0` | `v1.6.0-gazelle-1.1.0` + v1.6.1 (PHEE v1.13.3), updated to JDK 17 |
| `ph-ee-importer-rdbms` | `mifos-v2.0.0` | `v1.13.1-gazelle-1.1.0` + tag v1.14.2 |
| `ph-ee-operations-app` | `mifos-v2.0.0` | `v1.17.1-gazelle-1.1.0` + tag v1.20.2 + JDK 17 updates |
| `ph-ee-operations-web` | `mifos-v2.0.0` | `v1.25.0-gazelle-1.1.0` + Dipan's UI changes (`v1.26.0-gazelle-1.2.0-beta`) |
| `ph-ee-zeebe-ops` | `mifos-v2.0.0` | `v1.4.0-gazelle-1.1.0` (v1.5.0 tag may exist but unconfirmed / likely redundant) |
| `ph-ee-env-template` | `gazelle-dev` | From `v1.13.0-gazelle-1.1.0` |
| `ph-ee-connector-gsma-mm` | `mifos-v2.0.0` | `v1.3.0-gazelle-1.1.0` + JDK 17 migration |

---

## Library Components

| Component | Gazelle Branch | Version Lineage |
|-----------|---------------|-----------------|
| `ph-ee-id-account-validator-impl` | `mifos-v2.0.0` | `v1.1.0-gazelle-1.1.0` |

---

## Needs Verification

| Component | Notes |
|-----------|-------|
| `ph-ee-exporter` | Version/branch to be confirmed |
| `ph-ee-connector-common` | Version unclear |

---

## Not Yet Used in Gazelle

| Component | Status |
|-----------|--------|
| `ph-ee-importer-es` | Not yet used |
| `ph-ee-connector-slcb` | Not yet used |
| `ph-ee-connector-ams-paygops` | Not yet used |
| `ph-ee-connector-ams-pesa` | Not yet used |
| `ph-ee-connector-mpesa` | Not yet used |
| `ph-ee-notifications` | Not yet used |
| `message-gateway` | Not yet used |
| `ph-ee-vouchers` | Not yet used |
| `ph-ee-connector-crm` | Not yet used |
| `ph-ee-bill-pay` | Not yet used |

---

## Notes

- **`mifos-v2.0.0` branch**: the common working branch across all active components for the next Gazelle release. Not a published PHEE release tag — it is Gazelle's integration branch layered on top of PHEE v1.13.3.
- **Version lineage format**: entries show the Gazelle baseline tag the branch was cut from, plus any upstream PHEE tags or feature branches subsequently merged in.
- **Reference**: Avik's PHEE releases spreadsheet (tags and branches for PHEE v1.13.3 / Release Notes v1.13.1-1) was used as the upstream version reference.
