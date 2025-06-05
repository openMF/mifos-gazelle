# Mifos Gazelle Deployment Guide

[![Mifos](https://img.shields.io/badge/Mifos-Gazelle-blue)](https://github.com/openMF/mifos-gazelle)

> Deployment utilities for MifosX, Payment Hub EE (PH-EE), and Mojaloop vNext ( December  2024 )

## Table of Contents
- [Goal](#goal-of-mifos-gazelle)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Deployment Options](#deployment-options)
- [Application Deployment Modes](#application-deployment-modes)
- [Cleanup](#cleanup)
- [What to do next](#what-to-do-next)
- [Accessing Deployed Applications](#accessing-deployed-applications-dpgs)
  - [Mojaloop vNext](#accessing-mojaloop-vnext)
  - [Payment Hub](#accessing-payment-hub-EE)
  - [MifosX](#accessing-mifosx)
- [ Adding tenants to MifosX](#adding-tenants-to-mifosx)
- [Running helm test](#helm-test)
- [Development Status](#development-status)
- [Known Issues](#known-issues)
- [Version Information](#version-information)


## Goal of Mifos Gazelle
The aim of Mifos Gazelle is to provide a trivially simple installation and configuration mechanism for DPGs as part of a DPI construct.  Initially this is focussed on Mifos applications for Core-Banking and Payment Orchestration and the Mojaloop vNext financial transactions switch. The idea is to create a rapidly deployable , understandable and cheap integration to serve as a showcase and a laboratory environment to enable others to build further on these DPI projects. As the project continues we have a roadmap of additional DPGs, demo cases and other features we want to implement, along with looking at how it could be used for production in-cloud and on-premise deployments.

IMPORTANT NOTE: As Mifos-Gazelle is a deployment tool we make no statements or opinions on the base DPGs in terms of applicability, security etc we recommend all adopters read DPG base documentation to make their own assessment of these. Likewise at the moment for v1.0.0. release we recommend use solely for development, test and demonstration purposes as security assessment and hardening of Mifos Gazelle regardless of the base DPGs status has not occurred yet.

## Gazelle features (benefits)
- Mifos Gazelle installs each or all 3 DPGs in a reliable , repeatable way using simple bash scripts. 
- The bash scripts are designed to enable developers to understand and modify the configuration of each or all products.
- Enables installation of all 3 products is quick 15 mins or less with reasonable hardware
Fully functioning MifosX , with the addition of tools to simply add additional tenants
Fully functioning vNext (beta1) with integrated demo and test environment, admin UI and pre-loaded demo data
Installed and partially configured PHEE with deployed Web Client(note: see limitations under development status)


## Prerequisites
Before proceeding with the deployment, ensure your system meets the following requirements:

- Ubuntu 22.04 or 24.04 LTS operating systems
- x86_64 architecture
- 32GB RAM minimum
- 30GB+ free space in home directory
- Non-root user with sudo privileges

Note regarding memory use : 
1. If you are installing just MifosX or just vNext then much less memory is required.

## Quick Start
logged in as non-root user e.g. mifosu user 
```bash
# Navigate to home directory
cd $HOME

# For Installations of the latest release clone the repository (master branch)
git clone --branch master https://github.com/openMF/mifos-gazelle.git

Or

# For Installations of the latest development path clone the repository (dev branch)
git clone --branch dev https://github.com/openMF/mifos-gazelle.git


# Enter the project directory
cd mifos-gazelle

# Deploy all components (MifosX, vNext, and PH-EE)
sudo ./run.sh -u $USER -m deploy -d true -a all
```

## Deployment Options

| Option | Description | Values |
|--------|-------------|---------|
| `-h` | Display help message | - |
| `-u` | Non-root user for deployment | Current user (`$USER`) |
| `-m` | Execution mode | `deploy`, `cleanapps`, `cleanall` |
| `-d` | Verbose output | `true`, `false` |
| `-a` | Applications to deploy | `all`, `vnext`, `mifosx`, `phee` |


## What to do next 
After the run.sh has finished and ```kubectl get pods -A``` shows all pods and containers running then MifosGazelle has finished installing and is ready for use and testing.  Here are some suggestions for what to do next
- Install the k9s kubernetes utility using ``` ~/mifos-gazelle/src/utils/install-k9s.sh ``` then start k9s with ``` ~/local/bin/k9s ```
- Examine the running MifosX database using ``` ~/mifos-gazelle/src/utils/mysql-client-mifos.sh ```
- Examine the running PaymentHub database using  ``` ~/mifos-gazelle/src/utils/mysql-client-mifos.sh -h operationsmysql.paymenthub.svc.cluster.local -p ethieTieCh8ahv -u root -d mysql ```
- Access the deployed applications and consoles for MifosX, vNext and PaymentHub EE see [Accessing Deployed Applications](#accessing-deployed-applications) then browse to http://mifos.mifos.gazelle.test or http://vnextadmin.mifos.gazelle.test or  http://ops.mifos.gazelle.test
- Consult the documentation for the DPGs 
  - vNext using the adminUI and sample account lookup, quotes and transfers : https://github.com/mojaloop/platform-shared-tools/blob/main/packages/deployment/docker-compose-apps/README.md#login-to-the-mojaloop-vnext-admin-ui
  - MifosX for core banking : https://docs.mifos.org/core-banking-and-embedded-finance/core-banking
  - PaymentHub EE : https://mifos.gitbook.io/docs
- if you haven't already join the mifos-gazelle channel on the Mifos Slack at https://mifos.slack.com 

## Application Deployment Modes

Choose specific components to deploy using the `-a` flag:

```bash
# Deploy only Mojaloop vNext
sudo ./run.sh -u $USER -m deploy -a vnext

# Deploy only MifosX
sudo ./run.sh -u $USER -m deploy -a mifosx

# Deploy only Payment Hub EE
sudo ./run.sh -u $USER -m deploy -a phee
```

## Cleanup

Remove deployed components:

```bash
# Remove everything including Kubernetes server
sudo ./run.sh -u $USER -m cleanall

# Remove all applications from the Kubernetes server  
sudo ./run.sh -u $USER -m cleanapps

# Remove specific components
sudo ./run.sh -u $USER -m cleanapps -a mifosx  # Remove MifosX
sudo ./run.sh -u $USER -m cleanapps -a phee    # Remove PaymentHub EE
sudo ./run.sh -u $USER -m cleanapps -a vnext   # Remove vNext switch
```

## Accessing Deployed Applications (DPGs) 
Add the following entries to your hosts file on the laptop/desktop system where your web browser is running where <VM-IP> (without the angle brackets) is the IP of the server or VM where Mifos Gazelle has been deployed. If your browser is running on Linux or MacOS then all hosts entries go on one line , if your browser is running on Windows then you need a separate line for each entry. 

Once you have added the hosts below for the DPGs you can access consoles with
- MifosX : http://mifos.mifos.gazelle.test
- vNext : http://vnextadmin.mifos.gazelle.test 
- PaymentHub EE: http://ops.mifos.gazelle.test 


### vNext host Configuration
```bash
# Linux/MacOS (/etc/hosts) 
<VM-IP>  vnextadmin elasticsearch.mifos.gazelle.test kibana.mifos.gazelle.test mongoexpress.mifos.gazelle.test kafkaconsole.mifos.gazelle.test fspiop.mifos.gazelle.test bluebank.mifos.gazelle.test greenbank.mifos.gazelle.test 

# Windows (C:\Windows\System32\drivers\etc\hosts)
<VM-IP> vnextadmin.mifos.gazelle.test
<VM-IP> elasticsearch.mifos.gazelle.test
<VM-IP> kibana.mifos.gazelle.test
<VM-IP> mongoexpress.mifos.gazelle.test
<VM-IP> kafkaconsole.mifos.gazelle.test
<VM-IP> fspiop.mifos.gazelle.test
<VM-IP> bluebank.mifos.gazelle.test
<VM-IP> greenbank.mifos.gazelle.test
```

### Payment Hub EE host Configuration

```bash
# Linux/MacOS (/etc/hosts)
<VM-IP> ops.mifos.gazelle.test kibana-phee.mifos.gazelle.test zeebe-operate.mifos.gazelle.test 

# Windows (C:\Windows\System32\drivers\etc\hosts)
<VM-IP> ops.mifos.gazelle.test
<VM-IP> kibana-phee.mifos.gazelle.test
<VM-IP> zeebe-operate.mifos.gazelle.test 

```
### Accessing MifosX
By default the Mifos Gazelle installation only loads the "default" tenant into the database even though greenbank and bluebank are configured into the web client so when logging into Mifos use the default tenant and the default user=mifos and password=password.  See [ Adding tenants to MifosX](#adding-tenants-to-mifosx) for instructions on adding tenants to MifosX database. To change the options for tenants in the web client , modify the FINERACT_PLATFORM_TENANTS_IDENTIFIER in ../src/repos/mifosx/kubernbetes/web-app-deployment.yaml file and redeploy the mifosx app using the Mifos Gazelle run.sh and the -a flag. 

#### Host Configuration

```bash
# Linux/MacOS (/etc/hosts)
<VM-IP> fineract.mifos.gazelle.test mifos.mifos.gazelle.test

# Windows (C:\Windows\System32\drivers\etc\hosts)
<VM-IP> mifos.mifos.gazelle.test
<VM-IP> fineract.mifos.gazelle.test
```

## Helm test
Note the Payment Hub Helm tests are being reconfigured as we continue to work on end to end integration flows, therefore you may get significant errors due to naming at this present point in time (prior to the reconfiguration exercise though they were reporting 90%+ success).
Helm tests are currently enabled/disabled in the config/ph_values.yaml file , look for integration_tests. To execute the helm tests run 
```bash
helm test phee 
```
then examine the logfiles using either k9s or 
```bash
kubectl logs -n paymenthub ph-ee-integration-test-gazelle
```
You can access the results by copying them from the pod to the /tmp directory of the server machine or VM using the script below.  This will place the results into a directory similar to mydir.SzSauX i.e. of the form /tmp/mydir.XXXXXX. You will need to copy this directory from the server/VM to your desktop/laptop to browse the results , look for the subdirectory of tests/test/index.html as the top level for your browser. Note that the pod will time-out after 90 mins and you will need to remove the ph-ee-integration-test-gazelle pod before running helm test phee again. 
```bash
~/mifos-gazelle/src/utils/copy-report-from-pod.sh 
``` 

## Adding tenants to MifosX 
By default MifosGazelle deploys MifosX with a single tenant called "default"
the process to add tenants to a MifosGazelle deployed MifosX deployment is a 2 part process 
1. modify the example tenant configuration file mifos-gazelle/config/mifos-tenant-config.csv for your chosen tenant names 
2. apply the example tenant configuration to add the new tenants by running (for example) ``` mifos-gazelle/src/utils/utils/update-mifos-tenants.sh -f ./config/mifos-tenant-config.csv ```
3. in k9s locate and kill the fineract-server process in the MifosX namespace (use ```ctrl-k ``` from k9s) it will automatically be restarted by kubernetes. 
When fineract-server is restarted the new tenants schemas tables and artefacts will be created. You can check the progress of the schema generation by looking at the fineract-server pod logs.  Still using k9s, again locate the new fineract-server pod and press  ```l``` for logs when that pod is highlighted.  
4. Once the new fineract-server pod has finished creating the new schema , you can test this by logging in to the MifosX web-client using that tenant. 

## Development Status
Please note that limitations here are entirely those of the Mifos Gazelle configuration, and should not at all be interpreted as issues with the maturity or functionality of the deployed DPGs.  
- Currently PH-EE operations-web UI https://ops.mifos.gazelle.test can access batches and transfers and can create and send batches to bulk. It is not yet clear that the batches are correctly processed on the back end, this of course is being worked on. 
-  ph-ee-integration-test docker image on dockerhub uses the tag  v1.6.2-gazelle and corresponds to the v1.6.2-gazelle branch of the v1.6.2 integration-test repo.  The helm tests as deployed by Gazelle reports approx 90% pass rate. 
- PaymentHub EE v 1.13.0 is being provisioned by Mifos Gazelle and this is set in the config.sh script prior to deployment. This document defines all the sub chart releases that comprise the v1.13.0 release https://mifos.gitbook.io/docs/payment-hub-ee/release-notes/v1.13.0
- There is a lot of tidying up to do once this is better tested, e.g. debug statements to remove and lots of redundant env vars to remove as well as commented out code to remove. 
- It should be straightforward to integrate the Kubernetes operator work ( https://github.com/openMF/mifos-operators ) into this simplified single node deployment and this is planned for a future release 
- vNext Beta1 functions and is tested on ARM64 there is a limitation on Raspberry Pi 4 (or less) with MongoDB due to requirement for ARMv8.2A. Whilst it is untested vNext Beta1 and its associated infrastructure layer deployed by Mifos Gazelle should "just work"  Use ```sudo ./run.sh -u <user> -m deploy -a vnext ``` on a clean install to try. In the future it should be straightforward and is planned to have MifosX and PaymentHub EE also working on ARM and Raspberry PI
- reducing memory usage for demo and test is a high priority project, it is anticipated that the 3 initial DPGs can all run on 16GB or less (i.e. about  50% of the current prerequisite ) 
- The performance testing is still WIP and not fully operational 


## Known Issues
- Currently testing is limited to only systems and environments that meet the pre-requisites 
- Only single instance/node deployment currently supported , there is no reason for this except it is all that is currently tested. 
- Some cleanup is likely needed (debug statements, redundant environment variables) but as some of this is in use that will happen in future releases
- PaymentHub EE Kubernetes operator has been developed and will be integrated in future releases
- Updated Operations web integration pending (pending in PH-EE too - https://github.com/openMF/ph-ee-operations-web/pull/98 and https://github.com/openMF/ph-ee-operations-web/pull/99 )
- as part of Gazelle development the helm tests databases , tenants etc are being reconfigured and consequently helm tests are likely to report high failure rate 
- PaymentHub EE integration with vNext and MifosX is not complete (no end-to-end txns yet) => Operations-Web UI is limited in function
- demonstration data is not currently loaded for MifosX (but this is readily available)
- The postman tests provided by the individual DPGs have not yet been fully adapted to the Mifos Gazelle deployment environment, again this will happen in future releases in a structure fashion. 
- There are some issues on older (Intel/Opteron) hardware with nginx, MongoDB  and ElasticSearch. 
- Reminder Mifos Gazelle deployment of the 3 DPGs is *not at all secure*. (Note this is true no matter of the security status of the underlying DPGs). Security will necessarily become a major focus as we look to more production ready deployments in future releases. 

## Version Information

### MifosX Components
- **Core Banking Platform**: 
  - Image: `openmf/fineract:develop`
  - Version: Latest development version
- **Web Client**: 
  - Uses the same container as Core Banking Platform

### Mojaloop vNext
- **Version**: vNext Beta1
- **Details**: See [vNext Beta1 Release Documentation](https://github.com/mojaloop/platform-shared-tools/blob/beta1/README.md)

### PaymentHub EE Components
Base version: v1.13.0
> For standard components and subcharts, refer to [PaymentHub EE v1.13.0 Documentation](https://mifos.gitbook.io/docs/payment-hub-ee/release-notes/v1.13.0)

Custom component versions:
- **Environment Template**:
  - Image: `docker.io/openmf/ph-ee-env-template:v1.13.0-gazelle`
- **Integration Tests**:
  - Image: `docker.io/openmf/ph-ee-integration-test:v1.6.2-gazelle`
- **Operations Web**:
  - Image: `docker.io/openmf/openmf/ph-ee-operations-web:dev1`


