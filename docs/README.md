# NEEDS UPDATING FOR MIFOS-GAZELLE 


# A Deployable Package for Mifos/Fineract, Payment Hub EE, and Mojaloop (Mifos-gazelle)

## Pre-requisites
Make sure you have the following before you go through this guide.
- You should be running Ubuntu 20.04 LTS on the machine where you are running this script
- 32GB of RAM
- 30GB+ free space in your home directory

# Quick Start
> NOTE: The deployment made by this script is meant for demo purposes and not for production

## Clone the repository
To use Mifos-gazelle, you need to clone the repository to be able to run the software scripts.
Clone the repository into a directory of your choice.
After cloning the repository,  you need to change the directory into the cloned repository.
``` 
git clone https://github.com/openMF/mifos-gazelle.git
```

Inside the directory run the following command to execute the script.

```bash
sudo ./run.sh -u $USER -m deploy -d true -a all -f 1 -e local
```
### Options
- `-u` This is used to pass in the user the script should use to execute it's commands. The value passed in is `$USER` which the current user of the shell
- `-m` This option specifies the mode in which the script should execute. The available values are 
    - `deploy` - Deploy applications
    - `cleanapps` - Undo what deploy did and clean up all application resources without removing kubernetes infrastructure
    - `cleanall` - Undo what deploy did and clean up all resources including kubernetes infrastructure
- `-d` This flag tells the sccript whether to execute in verbose mode or not. The available values are :
    - true - Output should provide as much information as possible
    - false - Output should not be minimal
- `-a` This flag  tells the script in which mode the depoloyment should be made. It is an optional flag therefore if it is not provided,the default deployment mode is all apps
- `-f` This flag specifies the number of fineract instances to deployed. If not specified, the default number of instances is 2
- `-e` This flag specifies the environment into which the applications should be deployed. If not specified, it will deploy into k3s locally.


# App Deployment Modes -a
There are three modes of deployment currently supported by Mifos-gazelle. This is relevant for the -a option
- Only Mojaloop `moja`
- Only Fineract `fin`
- Only Payment Hub `ph`
- All Apps `all`


# Target Environment -e
You can set the environment into which the applications should be deployed by setting the -e argument at the point of executing the script.

To use a remote kubernetes cluster, use the value `remote` and to create a local k8s cluster, use `local`
>Currently the tool is only tested on local kubernetes deployments but work is being done to test it on 


After  the script has successfully executed it will print the following output

```
========================================================================
Thank you for installing Mojaloop, Paymenthub and Fineract using Mifos-gazelle
========================================================================


TESTING
sudo ./run -u $USER -m test ml #For testing mojaloop
sudo ./run -u $USER -m test ph #For testing payment hub
sudo ./run -u $USER -m test fin #For testing fineract



CHECK DEPLOYMENTS USING kubectl
kubectl get pods -n mojaloop #For testing mojaloop
kubectl get pods -n paymenthub #For testing paymenthub
kubectl get pods -n fineract-n #For testing fineract. n is a number of a fineract instance


Copyright © 2023 The Mifos Initiative
```

# RUNNING THE POSTMAN COLLECTIONS
Detailed instructions for configuring your deployment to execute Postman collections against the Mifos-Gazelle can be found [here](./)


# USING THE DEPLOYED APPS

## Accessing Mojaloop
The Mifos-gazelle scripts add the required host names to the 127.0.0.1 entry in the /etc/hosts of the "install system" i.e. the system where mifos-gazelle is run. To access Mojaloop from beyond this system it is necessary to:-

ensure that http / port 80 is accessible on the install system. For instance if mifos-gazelle has installed Mojaloop onto a VM in the cloud then it will be necessary to ensure that the cloud network security rules allow inbound traffic on port 80 to that VM.

## MacOs and Linux
add the hosts listed below to an entry for the external/public ip address of that install system in the /etc/hosts file of the laptop you are using.
For example if Mojaloop vNext is installed on a cloud VM with a public IP of 192.168.56.100 Then add an entry to your laptop's /etc/hosts similar to ...
```bash
192.168.56.100  vnextadmin.local elasticsearch.local kibana.local mongoexpress.local kafkaconsole.local fspiop.local bluebank.local greenbank.local mifos.local 
```

You should now be able to browse or curl to Mojaloop vNext admin url using http://vnextadmin you can also access the deloyed instances of the Mojaloop testing toolkit at http://bluebank.local and http://greenbank.local or access the mongo and kafka consoles.

## Windows
- open Notepad
- Right click on Notepad and then Run as Administrator.
- allow this app to make changes to your device? type Yes.
- In Notepad, choose File then Open C:\Windows\System32\drivers\etc\hosts or click the address bar at the top and paste in the path and choose Enter. If you don’t see the host file in the /etc directory then select All files from the File name: drop-down list, then click on the hosts file.
- Add the IP from your VM or system and then add a host from the list of required hosts (see example below)
- flush your DNS cache. Click the Windows button and search command prompt, in the command prompt:-
```bash
ipconfig /flushdns
```
Note you can only have one host per line so on windows 10 your hosts file should look something like:

```bash
192.168.56.100 vnextadmin.local
192.168.56.100 elasticsearch.local
192.168.56.100 kibana.local
192.168.56.100 mongoexpress.local
192.168.56.100 kafkaconsole.local
192.168.56.100 fspiop.local
192.168.56.100 bluebank.local
192.168.56.100 greenbank.local
```

## Accessing Paymenthub

To access paymenthub, you would follow a similar set of instructions just like for accessing mojaloop. 

## MacOs and Linux
add the hosts listed below to an entry for the external/public ip address of that install system in the /etc/hosts file of the laptop you are using.
For example if Paymenthub is installed on a cloud VM with a public IP of 192.168.56.100 Then add an entry to your laptop's /etc/hosts similar to ...

```bash
192.168.56.100 ops.sandbox.mifos.io
```

You should now be able to browse or curl to Paymenthub Operations Web portal url using http://ops.sandbox.mifos.io .

## Windows
- open Notepad
- Right click on Notepad and then Run as Administrator.
- allow this app to make changes to your device? type Yes.
- In Notepad, choose File then Open C:\Windows\System32\drivers\etc\hosts or click the address bar at the top and paste in the path and choose Enter. If you don’t see the host file in the /etc directory then select All files from the File name: drop-down list, then click on the hosts file.
- Add the IP from your VM or system and then add a host from the list of required hosts (see example below)
- flush your DNS cache. Click the Windows button and search command prompt, in the command prompt:-
```bash
ipconfig /flushdns
```
Note you can only have one host per line so on windows 10 your hosts file should look something like:

```bash
192.168.56.100 ops.sandbox.mifos.io
```

# Accessing Fineract
To access the fineract instances you just deployed using mifos-gazelle, you will needs to make similar edits to your hosts file configuration of your computer.

## MacOs and Linux
add the hosts listed below to an entry for the external/public ip address of that install system in the /etc/hosts file of the laptop you are using.
For example if one of the instances of fineract is installed on a cloud VM with a public IP of 192.168.56.100 Then add an entry to your laptop's /etc/hosts similar to ...

```bash
192.168.56.100 mifos.local # TBD 
```
Notice the 1 at the begining of the host name. This is automatically prepended at the begining of a fineract instance's host names to form it's ingress domain name.

If you set the number of fineract instances to 3, you would have domains ranging from `1-xxx.sandbox.fynarfin.io` to `3-xxx.fynarfin.io`

After editing your hosts config with the number of fineract instances you deployed, you should now be able to browse or curl to Community App url using http://1-communityapp.sandbox.fynarfin.io and fineract at http://1-fynams.sandbox.fynarfin.io

## Windows
- open Notepad
- Right click on Notepad and then Run as Administrator.
- allow this app to make changes to your device? type Yes.
- In Notepad, choose File then Open C:\Windows\System32\drivers\etc\hosts or click the address bar at the top and paste in the path and choose Enter. If you don’t see the host file in the /etc directory then select All files from the File name: drop-down list, then click on the hosts file.
- Add the IP from your VM or system and then add a host from the list of required hosts (see example below)
- flush your DNS cache. Click the Windows button and search command prompt, in the command prompt:-
```bash
ipconfig /flushdns
```
Note you can only have one host per line so on windows 10 your hosts file should look something like:

```bash
192.168.56.100 1-communityapp.sandbox.fynarfin.io 
192.168.56.100 1-fynams.sandbox.fynarfin.io
```
# Clean Up

To tear down the infrastructure and all installed apps. You can run this command.

```bash
sudo ./run.sh -u $USER -m cleanall -d true -e local
```

This will delete all resources in the created namespaces and if the kubernetes cluster is `k3s` it will delete it as well.

Please note that cleaning up the resources will take some time.

## CONTRIBUTION

Find the contributing guidelines [here](./CONTRIBUTING.md)

## CONCLUSION

This tool is intended to simplify the deployment process for Payment Hub EE, Mojaloop and Fineract for testing purposes.





