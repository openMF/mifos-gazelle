# SETTING UP POSTMAN COLLECTIONS FOR MIFOS-GAZELLE (WIP)

*LIMITATION:  These instructions are currently only for Payment Hub EE 

We have a bash script `postman_setup.sh` under the [src](../src/utils/) directory that you can run to skip through the steps 1 and 5. 
To run the script, you can do the following:
Go to the directory where the script is located and run the following command:

Then run the script:
```bash
sudo ./postman_setup.sh <IP_OF_YOUR_VM/IP_OF_YOUR_INGRESS> -o <true/false>
```

The `-o` flag is optional and is used to override the existing host entry in /etc/hosts file. If you want to override the existing host entry, then you can pass `true` as the value of the flag, otherwise you can pass `false`.

NOTE: This script is intended to be run on a Linux system, specifically Ubuntu 22.04 or 24.02 If you are running on a different system, you can follow the steps below to setup the postman collections.

## Step 1: Adding Hosts

NOTE: See the detailed steps on how to configure your hosts, in the `ACCESSING DEPLOYED APPLICATIONS` section of the [MIFOS-GAZELLE-README](MIFOS-GAZELLE-README.md).

## Step 2: Downloading Postman
You can download postman from [this](https://www.postman.com/downloads) link.

## Step 3: Importing Collections
After downloading, open postman, go to collections. Then click on `import` and open the file: `repos/ph_template/PostmanCollections/Payment Hub.json`.

NOTE: This directory and file appears only after you have run the installation, if you need to import the collections without running the deployment, then you can download from [here](https://raw.githubusercontent.com/openMF/ph-ee-env-template/master/PostmanCollections/Payment%20Hub.json).

NOTE: `openMF/ph-ee-env-template` predates the `ph-ee-` → `paymenthub-ee-` repo rename and Gazelle no longer clones it (its Helm chart was vendored directly into `src/deployer/helm/paymenthub-infra/`) — verify this link still resolves, or locate the current home of the Postman collections, before relying on it.


## Step 4: Importing Environment
To import the environment for running the collection, you can go to Environments, then click on Import and then open the file `repos/ph_template/PostmanCollections/Environment/PHEE_G2P_Demo.postman_environment.json`.

NOTE: You may need to change some of the environment variables if the hosts are different.


## Step 5: Setup Complete
After following the above steps correctly, you'll be able to run the postman collections smoothly.
