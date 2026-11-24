# Mifos Gazelle - standalone deployment of vNext Beta1

## Overview
 Mifos Gazelle enables complete stand-alone deployment of vNext Beta1 this can serve as a useful tool for focussed vNext standalone testing and experimentation. For those familiar with mini-loop installation of vNext, Mifos Gazelle provides exactly the same function with the advantage that Mifos Gazelle is under active development.    

## vNext standalone installation using Mifos Gazelle  
This is exactly the same process as for any Mifos Gazelle deployment but we use the -a flag as described in the main Mifos Gazelle README
logged in as non-root user e.g. mifosu user 
```bash
# Navigate to home directory
cd $HOME

# Clone the repository (dev branch)
git clone --branch dev https://github.com/openMF/mifos-gazelle.git

# Enter the project directory
cd mifos-gazelle

# Set up environment (one-time)
sudo ./setup-env.sh 

# Deploy only vNext and the underlying infrastructure services 
./run.sh -m deploy -d true -a vnext
```

> **Reminder**: currently Mifos Gazelle deployments including those of vNext Beta1 are  not intended for production use.

## Mifos Gazelle vNext deployment features
- **Realistic Environment**: Runs a complete Kubernetes stack for realistic testing
- **Simple Deployment**: Requires minimal command execution
- **Quick Setup**: Deploys in approximately 5-20 minutes with proper configuration
- **Automation-friendly**: Scripts can be integrated with CI/CD pipelines
- **Resource Efficient**: Optimized resource usage for testing environments
- **vNext only**: using the -a flag on the Mifos Gazelle installer 

## Tested Environments
- the Mifos Gazelle vNext Beta install has been tested on Ubuntu 22.04 and 24.04 LTS on x86_64 or ARM64: and can be run on 
  - Bare metal servers
  - Virtual machines (VirtualBox, Parallels, UTM, QEMU, WSL )
  - Cloud instances of the correct Kubernetes release (AWS, GCP, Azure, etc.)

## Prerequisites
As listed in the main Mifos Gazelle README.md but additionally this has been tested against 
- Ubuntu 22.04 or 24.04 LTS 
- x86_64 or ARM64 architecture 

## Installation Steps for vNext only installation 
to install vNext only using Mifos Gazelle 
```bash
# Navigate to home directory
cd $HOME

# Clone the repository (dev branch)
git clone --branch dev https://github.com/openMF/mifos-gazelle.git

# Enter the project directory
cd mifos-gazelle

# One-time environment setup
sudo ./setup-env.sh -u $USER

# Deploy vNext only 
./run.sh -m deploy -d true -a vnext
```

## Accessing vNext Services

### Local Access
The installation automatically configures local hostnames in `/etc/hosts` for the deployment system.

### Remote Access
To access vNext services from another machine:

1. Ensure port 80 is accessible on the deployment system
2. Add the following hostnames to the hosts file on the desktop or laptop where your browser is running:

```
<deployment-ip>  vnextadmin.mifos.gazelle.test elasticsearch.mifos.gazelle.test kibana.mifos.gazelle.test mongoexpress.mifos.gazelle.test kafkaconsole.mifos.gazelle.test fspiop.mifos.gazelle.test bluebank.mifos.gazelle.test greenbank.mifos.gazelle.test
```

### Available vNext and support infrastructure Services
- Admin Interface: http://vnextadmin.mifos.gazelle.test 
- Testing Toolkit: 
  - Blue Bank: http://bluebank.mifos.gazelle.test 
  - Green Bank: http://greenbank.mifos.gazelle.test 
- Management Consoles:
  - MongoDB Express: http://mongoexpress.mifos.gazelle.test 
  - Kafka Console: http://kafkaconsole.mifos.gazelle.test 

## Windows Users Guide

### Modifying Windows Hosts File
1. Open Notepad as Administrator
2. Navigate to: `C:\Windows\System32\drivers\etc\hosts`
3. Add entries in this format (one host per line):
```
192.168.56.100 vnextadmin.mifos.gazelle.test 
192.168.56.100 elasticsearch.mifos.gazelle.test 
192.168.56.100 kibana.mifos.gazelle.test 
192.168.56.100 mongoexpress.mifos.gazelle.test 
192.168.56.100 kafkaconsole.mifos.gazelle.test 
192.168.56.100 fspiop.mifos.gazelle.test 
192.168.56.100 bluebank.mifos.gazelle.test 
192.168.56.100 greenbank.mifos.gazelle.test 
```
4. Flush DNS cache:
```cmd
ipconfig /flushdns
```

## Known Limitations of the vNext (Beta1 Release)
1. Beta status: Mifos Gazelle currently deploys the vNext Beta1
2. Ubuntu version: Tested on Ubuntu 22.04 and 24.04 LTS
3. Kubernetes: Currently supports k3s , this will be updated as Mifos Gazelle works across a wider variety of Kubernetes clusters e.g. EKS,AKS,GKE etc 
4. Logging: Log format improvements planned for better CI/CD integration
5. DNS Configuration: Domain name configuration feature pending implementation localhosts is used currently
6. Endpoint Testing: Automated service validation to be implemented
7. Upstream status: vNext is deprecated, and Beta1 has transfer defects that affect a payer DFSP. See the next section.

## vNext status, and what it means for Payment Hub EE work

**vNext is deprecated upstream.** The Mojaloop vNext repositories Gazelle deploys from (transfers-bc, interop-apis-bc, scheduling-bc and the rest) were marked deprecated in October 2025: "no longer maintained, and no longer referenced by any releases of Mojaloop". Gazelle deploys vNext Beta1: fspiop-api-svc and the transfers-bc services at 0.5.1.

**Our position.** The switch is not a Mifos component, Payment Hub EE uses the switch as it is, and vNext defects are recorded, not fixed. Possible later options, none planned:
- use a later vNext build than Beta1 (the 0.6.x images). This means upgrading vNext as a whole, and fixes only some of the defects below
- small, narrow patches to vNext Beta1 

**Beta1 transfer defects found during PHEE-476 and PHEE-477 (November 2026):**

| Defect | Effect on a payer DFSP | In later vNext (`main`)? |
|---|---|---|
| `GET /transfers/{ID}` always answers `transferState: "COMMITTED"`, with no fulfilment | A `RECEIVED`, `RESERVED` or `ABORTED` transfer is reported committed | Still there (fspiop-api-svc 0.6.14) |
| A committed fulfil without a `fulfilment` is accepted and forwarded | A commit carries no proof | Not checked |
| 3208 "not found" is also sent when the switch can't read its own store, or before a prepare is stored | "Not found" doesn't prove the switch never had the transfer | Not checked |
| A prepare that arrives after its expiry is accepted. If no payee fulfils, it stays `RESERVED` with no expiry. A fulfil after expiry still commits | A transfer can be committed after its expiry, or hold the payer's liquidity indefinitely | The expired prepare is rejected (HTTP 400, 3101) since mid-2024. The fulfil after expiry still commits |

What works: a transfer the switch receives before its expiry, and that no payee fulfils, is aborted about a second after expiry, and the payer gets `PUT /transfers/{ID}/error` with 3303 "Transfer expired".

**How Payment Hub EE handles it:**
- **PHEE-476** (Gazelle 2.1.0 / Payment Hub EE 2.0.0 candidate):
  - The payer no longer resends the prepare. It waits until the transfer's expiry plus a grace period, both set in connector-mojaloop (`mojaloop.expiry.transfer`, `mojaloop.expiry.final-query-grace`; Gazelle uses 60 s and 30 s).
  - The grace also covers a commit that arrives a few seconds after expiry.
  - As payee, Payment Hub now sends the fulfilment.
- **PHEE-477** (follow-up):
  - Payment Hub asks the switch for a stuck transfer's status.
  - It trusts `COMMITTED` only with a fulfilment, and treats an error answering a query as inconclusive.
  - A transfer it can't resolve ends `UNKNOWN`, with the hold kept, for an operator.
  - The mapping lives in connector-mojaloop behind a switch-neutral `transferOutcome`, so a different switch, or a later vNext, changes the connector, not the BPMN.

**Testing limits on Beta1:** the payer's rejection path (error callback → hold released → `FAILED`) can't be triggered on demand. An expired prepare is committed, and changing participant endpoints or limits needs vNext admin rights with maker-checker.

## Troubleshooting
1. Verify installation success by accessing http://vnextadmin.mifos.gazelle.test 
2. Check pod status: `kubectl get pods -A or use k9s`
3. Review logs in `/tmp` directory (configurable location)
4. Watch for warning messages about pod startup times

## Usage Notes
- Scripts provide deployment guidance through console messages
- Use `-h` flag with any script for detailed usage information
- Configuration can be customized for specific needs
- Ideal for development, testing, and educational purposes
- Not suitable for production deployments

## Community Help
- Community help with deployment issues is available on the Mifos Gazelle Slack channel https://mifos.slack.com/archives/C082PNLUCRK