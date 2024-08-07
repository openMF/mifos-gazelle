# Mojafos is moving to mifos-gazelle 

## Notes : 
- the mojafos td-dev1 branch is the basis of the new mifos-gazelle utilities
- the interim mifos-gazelle branch c4gt1 contains a deployable version of the Mifosx app which is deployed via local kubernetes manifests , (mojaloop) vNext Beta1 also from kubernetes manifests and a simplified helm deployment of PHEE

## status
- all renaming to mifos-gazelle will happen in the mifos-gazelle repo in a non dev branch before merging to dev and of course the later release to main/master branch
- at the very start of Aug 2024 the Mojafos repo will be deprecated and all work go into mifos-gazelle (this repo) 

## What is in the c4gt branch of mifos-gazelle compared to Mojafos dev branch
PHEE: 
    - simplified phee helm deployment, the operations-web UI is accessible via hostname ops.local BUT the application docker image currently has hardcoded URLs which mean that it will not currently work.  The operations-web image is being debugged to remove these but timeline is unknown.  postman collections should work against the operations-web UI and the rest of PHEE and Mifos
    - this deployment relies upon the c4gt-gazelle-dev branch of the ph-ee-template repo
    
MifosX (i,e, fineract and web-app deloyment)
    - Mifos fineract and the Mifos Web application is now deployed from the kubernetes manifests which are stored in the mifos-gazelle_1 branch of the https://github.com/openMF/mifosx-docker.git repository (see kubernetes/manifets subdir). The mifos-gazelle depoyer.sh script automatically clones and deploys this repo (see the example usage below )
    - use the hostname mifos.local to access the web-app
    - the deployment uses the existing Mojafos deployed mysql database in the infra namespace
    - you need to add mifos.local to your local hosts file against the IP of the VM where MifosX is deployed 9see examples in the main mifos-gazelle readme) 
    - currently hardcoded to deploy only one instance of the web app and one of fineract. 
    - example usage  sudo ./run.sh -m deploy  -u azureuser -e local -d -a fin -f 1 

General
    - there is a lot of tidying up to do once this is better tested, e.g. debug statements to remove and lots of redundant env vars to remove as well as commented out code to remove. 
    - there have been no changes to the infrastructure or vNext installs all work really has been around PHEE and MifosX 
    - this deployment relies almost but not quite entirely on non vendor specific deployment artifacts and assumes right now single instance local deployment.
    - it should be straightforward to integrate the kubernetes operator work into this simplified single node deployment
    