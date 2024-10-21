#!/usr/bin/env bash 

SRC=$HOME/debug/integration/ph-ee-integration-test
DEST="/ph-ee-connector-integration-test" 
POD=tomtest 

kubectl cp $SRC/build.gradle $POD:$DEST
kubectl cp $SRC/src/test/java/org/mifos/integrationtest/cucumber/stepdef/GSMATransferDef.java $POD:$DEST/src/test/java/org/mifos/integrationtest/cucumber/stepdef/GSMATransferDef.java

kubectl cp $SRC/src/test/java/org/mifos/integrationtest/cucumber/stepdef/GSMATransferStepDef.java $POD:$DEST/src/test/java/org/mifos/integrationtest/cucumber/stepdef/GSMATransferStepDef.java
kubectl cp $SRC/src/main/resources/application.yaml $POD:$DEST/src/main/resources/application.yaml


k exec -it tomtest -- ./gradlew test -Dcucumber.filter.tags="@gov and not @ext"
