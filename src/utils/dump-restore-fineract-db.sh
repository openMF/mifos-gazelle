#!/bin/bash

# Variables
BASE_DIR="$(cd "$(dirname "$0")"/../..; pwd)"
CONFIG_DIR="$BASE_DIR/config"
NAMESPACE="infra"
POD_NAME="mysql-0"
MYSQL_USER="root"
MYSQL_PASSWORD="mysqlpw"
DUMP_FILE="$CONFIG_DIR/fineract-db-dump-$(date +%Y%m%d%H%M%S).sql"
#RESTORE_FILE="$CONFIG_DIR/fineract-db-dump-20250318023009.sql"
RESTORE_FILE="$CONFIG_DIR/fineract-db-dump-final.sql" # includes redbank
#RESTORE_FILE="$CONFIG_DIR/fineract-db-dump.sql"

# Function to dump all databases
dump_databases() {
  echo "Dumping all databases from pod $POD_NAME in namespace $NAMESPACE to $DUMP_FILE"
  
  # Use kubectl exec to dump databases directly to the local machine
  if ! kubectl exec -n "$NAMESPACE" "$POD_NAME" -- \
    mysqldump -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" --all-databases > "$DUMP_FILE"; then
    echo "Error: Failed to dump databases."
    exit 1
  fi
  
  echo "Database dump saved to $DUMP_FILE"
}

restore_databases() {
    echo "Copying dump file from local machine to pod $POD_NAME in namespace $NAMESPACE..."
    kubectl cp $RESTORE_FILE $NAMESPACE/$POD_NAME:/tmp/all_databases.sql

    if [ $? -ne 0 ]; then
        echo "Error: Failed to copy dump file to pod."
        exit 1
    fi

    echo "Restoring all databases from dump file..."
    kubectl exec -n $NAMESPACE $POD_NAME -- \
        sh -c "mysql -u$MYSQL_USER -p$MYSQL_PASSWORD < /tmp/all_databases.sql 2>/dev/null"

    if [ $? -ne 0 ]; then
        echo "Error: Failed to restore databases."
        exit 1
    fi

    echo "Cleaning up dump file inside the pod..."
    kubectl exec -n $NAMESPACE $POD_NAME -- rm /tmp/all_databases.sql

    echo "Database restore completed from $DUMP_FILE"
}


# Function to remove all databases except system ones
remove_databases() {
  echo "Removing all databases except system ones in pod $POD_NAME in namespace $NAMESPACE..."
  
  # Verify that only system databases are left
  if [ $(kubectl exec -n "$NAMESPACE" "$POD_NAME" -- \
    sh -c "mysql -u$MYSQL_USER -p$MYSQL_PASSWORD -e 'SHOW DATABASES' 2>/dev/null | grep -v '^Database' | wc -l") -eq 3 ]; then
    echo "There are no user databaases to remove as only system databases still exist."
    exit 1
  fi

  # # Use kubectl exec to remove databases
  # if ! kubectl exec -n "$NAMESPACE" "$POD_NAME" -- \
  #   sh -c "mysql -u$MYSQL_USER -p$MYSQL_PASSWORD -e 'SHOW DATABASES' | grep -v 'information_schema\|mysql\|performance_schema' | xargs -I {} mysql -u$MYSQL_USER -p$MYSQL_PASSWORD -e 'DROP DATABASE {}'"; then
  #   echo "Error: Failed to remove databases."
  #   exit 1
  # fi
  
    # Use kubectl exec to remove databases
  if ! kubectl exec -n "$NAMESPACE" "$POD_NAME" -- \
    sh -c "mysql -u$MYSQL_USER -p$MYSQL_PASSWORD -e 'SHOW DATABASES' 2>/dev/null | grep -v 'information_schema\|mysql\|performance_schema' | xargs -I {} -t mysql -u$MYSQL_USER -p$MYSQL_PASSWORD -e 'DROP DATABASE \`{}\`'"; then
    echo "Error: Failed to remove databases."
    exit 1
  fi

  echo "Database removal completed"
}


# Parse command information
while getopts ":drthR" opt; do
  case $opt in
    d) dump_databases;;
    r) restore_databases;;
    t) truncate_databases;;
    R) remove_databases;;
    h) 
      echo "Usage: $0 [-d] (dump) [-r] (restore) [-t] (truncate) [-R] (remove) [-h] (help)"
      exit 0
      ;;
    \?) 
      echo "Invalid option: -$OPTARG"
      exit 1
      ;;
  esac
done

# If no options were passed, show usage
if [ $OPTIND -eq 1 ]; then
  echo "Usage: $0 [-d] (dump) [-r] (restore) [-h] (help)"
  exit 1
fi