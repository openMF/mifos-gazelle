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