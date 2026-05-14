# Kubernetes manifests for use by mifos-gazelle 
The kubernetes manifests in this directory are now manually maintained by the Mifos Gazelle devs, but were originally created using the "kompose" utility and used the mifosx-docker/mariadb/docker-compose.yml as input src.   

# use / testing 
- see the mifos-gazelle readme for full instructions on deployment and testing 

## Notes
- These yaml files are intended to be maintained as part of the mifos-gazelle deployment tools 
- As mifos-gazelle is intended to reduce the resources needed to run MifosX, PHEE and (mojaloop) VNext the generated yamls for deploying MariaDB have been removed from this directory and are not maintained because mifos-gazelle uses combined and shared infrastructure services including the mysql database.
- ingress.yaml's have been added, and currently assume nginx ingress and ingressClassName
