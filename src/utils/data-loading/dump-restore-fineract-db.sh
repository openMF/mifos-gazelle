#!/bin/bash

# Variables
BASE_DIR="$(cd "$(dirname "$0")"/../../..; pwd)"
CONFIG_DIR="$BASE_DIR/config"
NAMESPACE="infra"
POD_NAME="postgres-0"
PG_USER="postgres"
PG_PASSWORD="postgrespw"
# Fineract databases (tenant store + default + the three demo tenants).
FIN_DBS="fineract_tenants fineract_default greenbank bluebank redbank"
DUMP_FILE="$CONFIG_DIR/fineract-db-dump-$(date +%Y%m%d%H%M%S).sql"
RESTORE_FILE="$CONFIG_DIR/fineract-db-dump-final.sql" # includes redbank

# psql/pg_dump run inside the postgres pod as the superuser.
pg_exec() { kubectl exec -n "$NAMESPACE" "$POD_NAME" -- env PGPASSWORD="$PG_PASSWORD" "$@"; }
pg_exec_i() { kubectl exec -i -n "$NAMESPACE" "$POD_NAME" -- env PGPASSWORD="$PG_PASSWORD" "$@"; }

# Dump each Fineract database. --create --clean --if-exists makes each dump
# self-contained and idempotent on restore (DROP DATABASE IF EXISTS + CREATE +
# \connect + schema + data), so restoring is safe whether or not the DB exists.
dump_databases() {
  echo "Dumping Fineract databases from pod $POD_NAME (ns $NAMESPACE) to $DUMP_FILE"
  : > "$DUMP_FILE"
  for db in $FIN_DBS; do
    echo "  -> dumping $db"
    if ! pg_exec pg_dump -U "$PG_USER" -h 127.0.0.1 --create --clean --if-exists -d "$db" >> "$DUMP_FILE"; then
      echo "Error: Failed to dump database $db."
      exit 1
    fi
  done
  echo "Database dump saved to $DUMP_FILE"
}

# Restore all Fineract databases from the committed dump. The dump drops and
# recreates each database, so any pre-existing (e.g. initdb-created) copies are
# replaced. Fineract must NOT be connected during restore (mifosx.sh deletes the
# old pod before this step).
restore_databases() {
  echo "Terminating any active connections to the Fineract databases..."
  for db in $FIN_DBS; do
    pg_exec psql -U "$PG_USER" -h 127.0.0.1 -d postgres -c \
      "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$db' AND pid <> pg_backend_pid();" \
      > /dev/null 2>&1
  done

  echo "Restoring Fineract databases from $RESTORE_FILE ..."
  if ! pg_exec_i psql -v ON_ERROR_STOP=1 -U "$PG_USER" -h 127.0.0.1 -d postgres < "$RESTORE_FILE"; then
    echo "Error: Failed to restore databases."
    exit 1
  fi
  echo "Database restore completed from $RESTORE_FILE"
}

# Drop all Fineract user databases (leaves the postgres/template system DBs).
remove_databases() {
  echo "Removing Fineract databases in pod $POD_NAME (ns $NAMESPACE)..."
  for db in $FIN_DBS; do
    pg_exec psql -U "$PG_USER" -h 127.0.0.1 -d postgres -c \
      "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$db' AND pid <> pg_backend_pid();" \
      > /dev/null 2>&1
    echo "  -> dropping $db"
    pg_exec psql -U "$PG_USER" -h 127.0.0.1 -d postgres -c "DROP DATABASE IF EXISTS \"$db\";"
  done
  echo "Database removal completed"
}

# Parse command information
while getopts ":drhR" opt; do
  case $opt in
    d) dump_databases;;
    r) restore_databases;;
    R) remove_databases;;
    h)
      echo "Usage: $0 [-d] (dump) [-r] (restore) [-R] (remove) [-h] (help)"
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
  echo "Usage: $0 [-d] (dump) [-r] (restore) [-R] (remove) [-h] (help)"
  exit 1
fi
