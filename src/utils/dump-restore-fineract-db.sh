#!/bin/bash

# Variables
NAMESPACE="infra"
POD_NAME="mysql-0"
MYSQL_USER="root"
MYSQL_PASSWORD="mysqlpw"
DUMP_FILE="/tmp/all_databases.sql"

# Function to dump all databases
dump_databases() {
    echo "Dumping all databases from pod $POD_NAME in namespace $NAMESPACE..."
    kubectl exec -n $NAMESPACE $POD_NAME -- \
        mysqldump -u $MYSQL_USER -p$MYSQL_PASSWORD --all-databases > /tmp/all_databases.sql

    if [ $? -ne 0 ]; then
        echo "Error: Failed to dump databases."
        exit 1
    fi

    echo "Copying dump file to local machine..."
    kubectl cp $NAMESPACE/$POD_NAME:/tmp/all_databases.sql $DUMP_FILE

    if [ $? -ne 0 ]; then
        echo "Error: Failed to copy dump file to local machine."
        exit 1
    fi

    echo "Cleaning up dump file inside the pod..."
    kubectl exec -n $NAMESPACE $POD_NAME -- rm /tmp/all_databases.sql

    echo "Database dump saved to $DUMP_FILE"
}

# Function to restore all databases
restore_databases() {
    echo "Copying dump file from local machine to pod $POD_NAME in namespace $NAMESPACE..."
    kubectl cp $DUMP_FILE $NAMESPACE/$POD_NAME:/tmp/all_databases.sql

    if [ $? -ne 0 ]; then
        echo "Error: Failed to copy dump file to pod."
        exit 1
    fi

    echo "Restoring all databases from dump file..."
    kubectl exec -n $NAMESPACE $POD_NAME -- \
        sh -c "mysql -u $MYSQL_USER -p$MYSQL_PASSWORD < /tmp/all_databases.sql"

    if [ $? -ne 0 ]; then
        echo "Error: Failed to restore databases."
        exit 1
    fi

    echo "Cleaning up dump file inside the pod..."
    kubectl exec -n $NAMESPACE $POD_NAME -- rm /tmp/all_databases.sql

    echo "Database restore completed from $DUMP_FILE"
}

# Parse command-line options
while getopts "dr" opt; do
    case ${opt} in
        d )
            dump_databases
            ;;
        r )
            restore_databases
            ;;
        \? )
            echo "Usage: $0 [-d] (dump) [-r] (restore)"
            exit 1
            ;;
    esac
done

# If no options were passed, show usage
if [ $OPTIND -eq 1 ]; then
    echo "Usage: $0 [-d] (dump) [-r] (restore)"
    exit 1
fi