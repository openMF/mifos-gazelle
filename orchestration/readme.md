# Orchestration Directory

This directory contains a subset of the BPMN flows from the full GovStack implementation of PaymentHub EE for BPMN. It is designed to house only the BPMNs relevant to the Mifos Gazelle PaymentHub EE deployment.

For a complete list of BPMN flows, please visit the [full repository](https://github.com/openMF/ph-ee-env-labs/tree/master/orchestration).

### Automatic Loading
Any BPMNs added to this directory will automatically be loaded by:
- **Mifos Gazelle**
- The utility script: `mifos-gazelle/src/utils/deployBpmn-gazelle.sh`

Feel free to add or modify BPMNs as needed for your implementation.