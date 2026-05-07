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

# Deploy only vNext and the underlying infrastructure services 
sudo ./run.sh -u $USER -m deploy -d true -a vNext 
```

> **Reminder**: currently Mifos Gazelle deployments including those of vNext Beta1 are  not intended for production use.

## Mifos Gazelle vNext deployment features
- **Realistic Environment**: Runs a complete Kubernetes stack for realistic testing
- **Simple Deployment**: Requires minimal command execution
- **Quick Setup**: Deploys in approximately 5-10 minutes with proper configuration
- **Automation-friendly**: Scripts can be integrated with CI/CD pipelines
- **Resource Efficient**: Optimized resource usage for testing environments
- **vNext only**: using the -a flag on the Mifos Gazelle installer 

## Tested Environments
- the Mifos Gazelle vNext Beta install has been tested on Ubuntu 20.04 and 22.04 LTS on x86_64 or ARM64:
  - Bare metal servers
  - Virtual machines (VirtualBox, Parallels, UTM, QEMU)
  - Cloud instances (AWS, GCP, Azure, etc.)

## Prerequisites
As listed in the main Mifos Gazelle README.md but additionally this has been tested against 
- Ubuntu 20.04 or 22.04 LTS 
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

# For ARM64 systems only
sudo ./ttk-interim-fix.sh

# Deploy vNext only 
sudo ./run.sh -u $USER -m deploy -d true -a vnext 
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
2. Ubuntu version: Tested only on Ubuntu 20.04 and 22.04 LTS
3. Kubernetes: Currently supports k3s , this will be updated as Mifos Gazelle works across a wider variety of Kubernetes clusters e.g. EKS,AKS,GKE etc 
4. Logging: Log format improvements planned for better CI/CD integration
5. DNS Configuration: Domain name configuration feature pending implementation localhosts is used currently
6. Endpoint Testing: Automated service validation to be implemented

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
- For vNext Beta 1 issues, reach out to the Mojaloop Development Community.