#!/usr/bin/env bash 

#SRC=$HOME/debug/integration/ph-ee-integration-test
DEST="/ph-ee-connector-integration-test" 
POD="ph-ee-integration-test-gazelle"

# Create a unique directory in /tmp
unique_dir=$(mktemp -d /tmp/mydir.XXXXXX)
echo "savings reports to $unique_dir"

# copy reports from pod 
kubectl cp $POD:$DEST/cucumber-report "$unique_dir/cucumber-report"
kubectl cp $POD:$DEST/cucumber.json "$unique_dir/cucumber.json" 
kubectl cp $POD:$DEST/build/reports  "$unique_dir"

# k exec -it tomtest -- ./gradlew test -Dcucumber.filter.tags="@gov and not @ext"