# Mojafos is moving to mifos-gazelle 

## Notes : 
- the mojafos dev branch is going to be the basis of the new mifos-gazelle utilities
- the dev branch should contain a deployable version of the Mifosx deplpyed via local kubernetes manifests , (mojaloop) vNext Beta1 also from kubernetes manifests and a simplified held deployment of PHEE

## status
- the tom-dev1 branch in the git history is being merged into mojafos dev branch and then used as stated above as the basis for mifos-gazelle
- all renaming to mifos-gazelle will happen in the mifos-gazelle repo
- at the very start of Aug 2024 the Mojafos repo will be deprecated and all work go into mifos-gazelle
- currently with PR https://github.com/openMF/mojafos/pull/56 these are the major  simplifications going into Mojafos dev

PHEE: 
    - simplified phee helm deployment, the operations-web UI is accessible via hostname ops.local BUT the application docker image currently has hardcoded URLs which mean that it will not currently work.  The operations-web image is being debugged to remove these but timeline is unknown.  postman collections should work against the operations-web UI
    - this deployment relies upon the c4gt-gazelle-dev branch of the ph-ee-template repo
    
MifosX (i,e, fineract and web-app deloyment)
    - generated kubernetes manifests from the mifosx-docker mariadb/docker-compose.yml have been stored under apps in the Mojafos repo and are now used by Mojafos to deploy MifosX via dockerhub images produced by fynarfin pipelines (see deployer.sh)
    - use the hostname mifos.local to access the web-app
    - currently there are undiagnosed CORS errors logging into the page 
    - the deployment uses the existing Mojafos deployed mysql database in the infra namespace
    - currently hardcoded to deploy only one instance
    - tested with sudo ./run.sh -m deploy  -u azureuser -e local -d -a fin -f 1 

General
    - there is still much testing to do, the CORS issue initially needs solving
    - there is a lot of tidying up to do once this is better tested, e.g. debug statements to remove and lots of redundant env vars to remove as well as commented out code to remove. 
    - there have been no changes to the infrastructure or vNext installs all work really has been around PHEE and MifosX 
    - this deployment relies almost but not quite entirely on non vendor specific deployment artifacts and assumes right now single instance local deployment.
    - it should be straightforward to integrate the kubernetes operator work into this simplified single node deployment
    