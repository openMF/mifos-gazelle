# SETTING UP POSTMAN COLLECTIONS

We have a bash script `postman_setup.sh` under the [scripts](../scripts/post_installation.sh) directory that you can run to skip through the steps 1 and 5. 
To run the script, you can do the following:
Go to the directory where the script is located and run the following command:
```bash
sudo chmod +x postman_setup.sh
```
Then run the script:
```bash
sudo ./postman_setup.sh <IP_OF_YOUR_VM/IP_OF_YOUR_INGRESS> -o <true/false>
```

The `-o` flag is optional and is used to override the existing host entry in /etc/hosts file. If you want to override the existing host entry, then you can pass `true` as the value of the flag, otherwise you can pass `false`.

## Step 1: Adding Hosts
Add the following hosts to your host file on your system:

`Mojaloop Hosts`
```bash
IP_OF_YOUR_VM/IP_OF_YOUR_INGRESS vnextadmin.local elasticsearch.local kibana.local mongoexpress.local kafkaconsole.local fspiop.local bluebank.local greenbank.local mifos.local
```

`PaymentHub Hosts`
```bash
IP_OF_YOUR_VM/IP_OF_YOUR_INGRESS ops.local ops-bk.local bulk-connector.local messagegateway.local minio.local ams-mifos.local bill-pay.local channel.local channel-gsma.local crm.local mockpayment.local mojaloop.local identity-mapper.local analytics.local vouchers.local zeebeops.local notifications.local
```

`Fineract Hosts`
```bash
IP_OF_YOUR_VM/IP_OF_YOUR_INGRESS mifos.local
```

NOTE: If you want detailed steps on how to configure your hosts, you may go through the `USING THE DEPLOYED APPS` section of the [README](./README.md).

## Step 2: Downloading Postman
You can download postman from [this](https://www.postman.com/downloads) link.

## Step 3: Importing Collections
After downloading, open postman, go to collections. Then click on `import` and open the file: `src/mojafos/deployer/apps/ph_template/PostmanCollections/Payment Hub.json`.

NOTE: This directory and file appears only after you have run the installation, if you need to import the collections without running the deployment, then you can download from [here](https://raw.githubusercontent.com/openMF/ph-ee-env-template/master/PostmanCollections/Payment%20Hub.json).


## Step 4: Importing Environment
To import the environment for running the collection, you can go to Environments, then click on Import and then open the file `src/mojafos/deployer/apps/ph_template/PostmanCollections/Environment/PHEE_G2P_Demo.postman_environment.json`
NOTE: You may need to change some of the environment variables if the hosts are different.

## Step 5: Upload the BPMN Diagrams
To run the APIs, such as, for example `Batch Transactions`, you need to have all the BPMN diagrams loaded into your zeebe ops.
For that you can do the following steps:
Browse to the directory `src/mojafos/deployer/apps/ph_env_labs/orchestration/feel`. Here you can all of the BPMN diagrams that are required to run the APIs. 
Now, you can go to the folder `Zeebe Operations APIs` under the imported Postman Collection and find the API for uploading BPMN diagrams, i.e, `Upload BPMN` with route `{{ZeebeOpsHostName}}/zeebe/upload`.
You can pass in the `.bpmn` files into the `file` parameter of form-data and upload the required diagrams to zeebe.

## Step 6: Setup Complete
After following the above steps correctly, you'll be able to run the postman collections smoothly.
