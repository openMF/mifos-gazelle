# Mifos Gazelle v2.0.0 Release Notes

## Major New Features

- **Raspberry Pi Support** - Full and stable Raspberry Pi deployment onto a Pi5 16GB with all components deployed
- **Payment Hub v2.0.0 preview** - Extensive Updates to Payment Hub EE with a pre-release view, including upgraded UI, tested workflows, GovStack support
- **config.ini** - Config.ini supported to add configurations to deployments and enable demo setups
- **Reduced Memory Utilization** - All components now require less than 16GB memory
- **Data Generation and Population** - for MifosX and PaymentHub EE and VNext to allow for demos
- **Mastercard CBS Connector Demo** - A demo version of the Mastercard CBS Connector which can be configured to connect to the Mastercard Sandbox instance
- **Updated version of the k9s kubernetes utility automatically installed** - in ~/local/bin/k9s 
- **Support for installation to local or remote clusters** - support included for deployment to remote clusters
- **Demo Creator** - Standalone Demo Creator which allows for the creation of demos using Mifos Gazelle components [Mifos Gazelle Demo Creator](https://github.com/openMF/mifos-gazelle-demo-creator)
- **Demo Runtime** - Standalone Demo Runtime environment that allows guided navigation in demos with Mifos Gazelle components [Mifos Gazelle Demo Runtime](https://github.com/openMF/mifos-gazelle-demo-runtime)
- **Significant Documentation** - New updated documentation for Bulk operations, GovStack Operation, Mastercard CBS Demo, PHEE Releases, Raspberry Pi, Postman collections.


## Noteable changes
- fixes binami issues
- dockerhub ratelimiting workaround/enhancements
- Simplified and re-organised deployment scripts supporting modularity
- Updated Kubernetes to v1.35

## MifosX Components

### Fineract: v1.12.0
- Image built outside of Mifos infrastructure
- Exact history and status difficult to determine

### Mifos Web App
- **Version**: v250621
- Image built outside of Mifos infrastructure
- Exact history and status difficult to determine

---

## PaymentHub EE Components (-mifos-2.0.0)

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

## Tickets

EPIC: [GAZ-29 - release 2.0.0](https://mifosforge.jira.com/browse/GAZ-29)<br>
Gazelle Scope: (note Payment Hub tickets are independantly logged)<br>
[GAZ-12 - Need to update and test all PaymentHub pipelines and image publishing](https://mifosforge.jira.com/browse/GAZ-12)<BR>
[GAZ-17 - Profile/Demo Creator](https://mifosforge.jira.com/browse/GAZ-17)<br>
[GAZ-20 - Update BPMN Handling](https://mifosforge.jira.com/browse/GAZ-20)<br>
[GAZ-22 - Update Mifos Gazelle to later version of PaymentHub EE](https://mifosforge.jira.com/browse/GAZ-22)<br>
[GAZ-27 - Mifos Gazelle Runtime GUI v1.0](https://mifosforge.jira.com/browse/GAZ-27)<br>
[GAZ-72 - Update openMF/mifos-gazelle repo to follow best practice may25](https://mifosforge.jira.com/browse/GAZ-72)<br>
[GAZ-129 - BUG:rel1.1.0 Raspberry Pi not working correctly on deployment](https://mifosforge.jira.com/browse/GAZ-129)<br>
[GAZ-185 - Improve Gazelle Deployment reliability across resource constrained environments](https://mifosforge.jira.com/browse/GAZ-185)<br>
[GAZ-186 - rename *bulk* charts consistently in ph-ee-env-template and Gazelle](https://mifosforge.jira.com/browse/GAZ-186)<br>
[GAZ-212 - ensure all paymenthub components that need zeebe-gw have correct wait..](https://mifosforge.jira.com/browse/GAZ-212)<br>
[GAZ-218 - remove prometheus installation from Mifos Gazelle 1.2.0](https://mifosforge.jira.com/browse/GAZ-218)<br>
[GAZ-219 - refactor and simplify Mifos Gazelle scripts undr /src](https://mifosforge.jira.com/browse/GAZ-219)<br>
[GAZ-220 - remove microk8s install code from mifos gazelle scripts](https://mifosforge.jira.com/browse/GAZ-220)<br>
[GAZ-221 - ensure Mifos Gazelle deploys to local or remote cluster](https://mifosforge.jira.com/browse/GAZ-221)<br>
[GAZ-223 - update Mifos Gazelle and MifosX, PHEE to use bitnamilegacy docker repo](https://mifosforge.jira.com/browse/GAZ-223)<br>
[GAZ-224 - ensure Mifos Gazelle can only use a non-root user for deployment](https://mifosforge.jira.com/browse/GAZ-224)<br>
[GAZ-225 - Remove Mifos Gazelle -v flag for k8s version](https://mifosforge.jira.com/browse/GAZ-225)<br>
[GAZ-232 - Need to enable local testing and development of Mifos Gazelle components such as PHEE](https://mifosforge.jira.com/browse/GAZ-232)<br>
[GAZ-233 - Integrate C4GT operations web updates into gazelle environment](https://mifosforge.jira.com/browse/GAZ-233)<br>
[GAZ-234 - build docker images for all PHEE mifos-v2.0.0](https://mifosforge.jira.com/browse/GAZ-234)<br>
[GAZ-235 - update mock-payment-schema to JDK17](https://mifosforge.jira.com/browse/GAZ-235)<br>
[GAZ-239 - Integrate Demo Creator and Runtime into latest release Gazelle Documentation](https://mifosforge.jira.com/browse/GAZ-239)<br>
[GAZ-240 - Update Test to most practical Kubernetes/K3s release](https://mifosforge.jira.com/browse/GAZ-240)<br>
[GAZ-241 - Documentation Review update and tidy](https://mifosforge.jira.com/browse/GAZ-241)<br>
[GAZ-242 - Testing and fixes in preperation for releases](https://mifosforge.jira.com/browse/GAZ-242)<br>
[GAZ-243 - finalise the documenting of the Mastercard Integration into Gazelle](https://mifosforge.jira.com/browse/GAZ-243)<br>
[GAZ-244 - Doucment the pre-release of PHEE incorporated(release component)](https://mifosforge.jira.com/browse/GAZ-244)<br>
[GAZ-259 - Improve deployment resilience](https://mifosforge.jira.com/browse/GAZ-259)<br>
[GAZ-260 - BUG:Can't login to current web-app on safari and chrome browsers](https://mifosforge.jira.com/browse/GAZ-260)<br>

## Recognition of Significant Contributors

<br>
Mifos would like to recognise the significant contributions of the following contributors to this release:

 - Tom Daly - [tdaly61](https://github.com/tdaly61)
 - Devarsh Shah - [devarsh10](https://github.com/devarsh10)
 - Yash Sharma - [yashsharma127](https://github.com/yashsharma127)
 - Pranav Deshmukh - [pranav-deshmukh](https://github.com/pranav-deshmukh)
 - Dipan Dhali - [dipandhali2021](https://github.com/dipandhali2021)
 - Abhinav Kumar - [abhinav-1305](https://github.com/abhinav-1305)
 - David Higgins - [DavidH-1](https://github.com/DavidH-1)

<BR>
<BR>
<BR>


# Mifos Gazelle v1.1.0 Release Notes

## Major New Features

- **ARM64 Support** - Full support for ARM64 architecture
- **End-to-End Payment Demonstration** - Complete payment flow from a customer in a Mifos Tenant (Greenbank)  to a customer in another Mifos Tenant (Bluebank)  using PHEE, Mifos X, and vNext
- **Enhanced Observability** - Includes Camunda workflows with Camunda Operate
- **Reduced Memory Utilization** - All components now require less than 24GB memory
- **Default tenants greenbank and bluebank automatically configured** - for MifosX and PaymentHub EE 
- **Automatic demonstration data is generated and synchronised** - across all components (see the script in src/utils/data-loading directory)
- **recent version of the k9s kubernetes utility automatically installed** - in ~/local/bin/k9s 


## Noteable changes
- greenbank and bluebank (testing toolkit endpoints) are no longer automatically deployed, having been replaced by the configured customers and tenants in the Mifos core banking.
- a number of paymenthub EE components have been moved to SpringBoot 2.6.x and to JDK 17 for improved future maintenance
- PaymentHub EE dependant libraries e.g. ph-ee-connector-common have been now published to Mifos JFrog Artifactory 
- helm charts and BPMN diagrams under ph-ee-env-labs helm charts are  no longer used for configuring Paymenthub EE which simplifies depoyment and maintenance. 
---

## MifosX Components

### Fineract: v1.11.0
- Image built outside of Mifos infrastructure
- Exact history and status difficult to determine

### Mifos Web App
- **Version**: `dockerhub openmf/web-app:dev-dc1f82e`
- Image built outside of Mifos infrastructure
- Exact history and status difficult to determine

---

## PaymentHub EE Components (-gazelle-1.1.0)

### Core Components

**ph-ee-env-template: v1.13.0-gazelle-1.1.0**
- Base version: v1.13.0
- Reference: [v1.13.0 Release Notes](https://mifos.gitbook.io/docs/payment-hub-ee/release-notes/v1.13.0)

**ph-ee-connector-channel: v1.11.0-gazelle-1.1.0**
- Base version: v1.11.0

**ph-ee-importer-rdbms: v1.13.1-gazelle-1.1.0**
- Base version: v1.13.1

**ph-ee-operations-app: v1.17.1-gazelle-1.1.0**
- Base version: v1.17.1

**ph-ee-zeebe-ops: v1.4.0-gazelle-1.1.0**
- Base version: v1.4.0

**ph-ee-bulk-processor: v1.12.1-gazelle-1.1.0**
- Base version: v1.12.1
- Part of the `connector_bulk` subchart of the `ph-ee-engine` helm parent chart

**ph-ee-connector-bulk: v1.1.0**
- Part of the `ph-ee-connector` subchart of the `ph-ee-engine` helm parent chart

**ph-ee-notifications: v1.4.0-gazelle-1.1.0**
- Base version: v1.4.0

**ph-ee-connector-ams-mifos: v1.7.0-gazelle-v1.1.0**
- Base version: v1.7.0

**ph-ee-identity-account-mapper: v1.6.0-gazelle-1.1.0**
- Base version: v1.6.0

**ph-ee-connector-mock-payment-schema: v1.6.0-gazelle-1.1.0**
- Base version: v1.6.0

**ph-ee-integration-test: v1.6.0-gazelle-1.1.0**
- Base version: v1.6.2

### Master Branch Components

**ph-ee-operations-web: gazelle-1.1.0**
- Base: master branch
- Unlike most other PHEE components (based on PaymentHub EE v1.13.0), this component is based on master and is several commits ahead

**ph-ee-connector-mojaloop-java: gazelle-v1.1.0**
- Base: master branch
- Unlike most other PHEE components (based on PaymentHub EE v1.13.0), this component is several commits ahead of master

### Common Components

**ph-ee-connector-common: v1.8.1-gazelle**
- Base version: v1.8.1
- No functional updates in gazelle version
- Available in Mifos JFrog artifactory repository
- Migrated to JDK17
- Other PHEE components updated to use this version where Java and Spring Boot versions allow
- Additional versions available at: http://mifos.jfrog.io

---

## Components Not Currently Deployed

The following components are not deployed in Mifos Gazelle 1.1.0 and do not yet have ARM images published:

- **ph-ee-importer-es**: v1.14.0
- **ph-ee-connector-slcb**: v1.5.0
- **ph-ee-exporter**: v1.2.0
- **ph-ee-connector-ams-paygops**: v1.6.1
- **ph-ee-connector-ams-pesa**: v1.3.1
- **ph-ee-connector-mpesa**: v1.7.0
- **ph-ee-connector-gsma-mm**: v1.3.0
- **message-gateway**: v1.2.0
- **ph-ee-vouchers**: v1.3.0, v1.3.1
- **ph-ee-connector-crm**: v1.1.0
- **ph-ee-bill-pay**: v1.1.0
- **ph-ee-env-labs**: Not used in Gazelle 1.1.0