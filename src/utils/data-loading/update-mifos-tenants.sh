#!/usr/bin/env bash

set -uo pipefail

# ==================== PATH & CONFIG ====================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CONFIG_DIR="$BASE_DIR/config"
DEFAULT_CSV="$CONFIG_DIR/mifos-tenant-config.csv"

# GAZ-305: MifosX now runs on Postgres (was MySQL/MariaDB).
POSTGRES_NAMESPACE="infra"
POSTGRES_POD="postgres-0"
POSTGRES_SUPERUSER="postgres"
POSTGRES_PASSWORD="postgrespw"
TENANTS_DB="fineract_tenants"
MIFOSX_NAMESPACE="mifosx"
FINERACT_DEPLOYMENT="fineract-server"
UTILS_DIR="$BASE_DIR/src/utils"
FINAL_DUMP="$CONFIG_DIR/fineract-db-dump-final.sql"

CSV_FILE="$DEFAULT_CSV"
FORCE_RECREATE=0
SKIP_DUMP=0
MASTER_PASSWORD="fineract"

# ==================== HELPERS ====================

log() { echo "$@" >&2; }
error() { echo "❌ $@" >&2; exit 1; }
warning() { echo "⚠️  $@" >&2; }

usage() {
  cat << EOF
Usage: $(basename "$0") [OPTIONS]

Creates separate tenant databases on Postgres and registers them in Fineract
multi-tenancy (fineract_tenants), then runs Liquibase to build each schema.

Options:
  -f <file>     CSV file (default: $DEFAULT_CSV)
  -F            Recreate dump even if one already exists
  -n            Skip the DB dump step (create + register + migrate only)
  -h            Show help

CSV Format:
tenant_id,tenant_identifier,tenant_name,tenant_timezone,db_host,db_port,db_name,db_user,db_password
EOF
  exit 1
}

get_fineract_pod() {
  kubectl get pods -n "$MIFOSX_NAMESPACE" -l app=fineract-server -o name | head -1 | sed 's/^pod\///'
}

# psql helpers -- run against the postgres pod as the superuser.
psql_run() {   # $1 = dbname; remaining args passed to psql (e.g. -c "SQL" / -tAc "SQL")
  local db="$1"; shift
  kubectl exec -n "$POSTGRES_NAMESPACE" "$POSTGRES_POD" -- \
    env PGPASSWORD="$POSTGRES_PASSWORD" psql -v ON_ERROR_STOP=1 \
      -U "$POSTGRES_SUPERUSER" -h 127.0.0.1 -d "$db" "$@"
}
psql_stdin() { # $1 = dbname; SQL read from stdin
  local db="$1"
  kubectl exec -i -n "$POSTGRES_NAMESPACE" "$POSTGRES_POD" -- \
    env PGPASSWORD="$POSTGRES_PASSWORD" psql -v ON_ERROR_STOP=1 \
      -U "$POSTGRES_SUPERUSER" -h 127.0.0.1 -d "$db"
}

# DB-AGNOSTIC (unchanged from the MySQL version): the password encryptor runs
# INSIDE the fineract pod, so it does not depend on the database engine.
get_encrypted_passwords() {
  local plain="$1"
  local pod
  pod=$(get_fineract_pod)
  [[ -z "$pod" ]] && error "Fineract pod not found"

  local output
  output=$(kubectl exec -n "$MIFOSX_NAMESPACE" "$pod" -- java -cp @/app/jib-classpath-file \
    org.apache.fineract.infrastructure.core.service.database.DatabasePasswordEncryptor \
    "$MASTER_PASSWORD" "$plain" 2>/dev/null)

  local db_hash master_hash
  db_hash=$(echo "$output" | grep "encrypted password" | cut -d: -f2- | xargs)
  master_hash=$(echo "$output" | grep "master password hash" | cut -d: -f2- | xargs)

  [[ -z "$db_hash" || -z "$master_hash" ]] && error "Failed to encrypt password"
  echo "$db_hash:$master_hash"
}

# Postgres: CREATE DATABASE cannot run inside a transaction block and has no
# "IF NOT EXISTS" for use in a wrapped script -> guard per-DB via pg_database
# and run each CREATE as its own autocommitted statement.
create_tenant_databases() {
  grep -v '^#' "$CSV_FILE" | grep -v '^$' | tail -n +2 | while IFS=, read -r id identifier name timezone db_host db_port db_name db_user db_pass; do
    db_name=$(echo "$db_name" | xargs)
    [[ -z "$db_name" ]] && continue
    if [[ "$(psql_run postgres -tAc "SELECT 1 FROM pg_database WHERE datname='${db_name}'")" == "1" ]]; then
      log "• database ${db_name} already exists"
    else
      log "✓ creating database ${db_name}"
      psql_run postgres -c "CREATE DATABASE \"${db_name}\"" || error "CREATE DATABASE ${db_name} failed"
    fi
  done
}

# Register (or re-register) each tenant in fineract_tenants. These INSERTs run
# against the tenant-store DB and CAN be wrapped in a transaction.
register_tenants() {
  {
    echo "BEGIN;"
    grep -v '^#' "$CSV_FILE" | grep -v '^$' | tail -n +2 | while IFS=, read -r id identifier name timezone db_host db_port db_name db_user db_pass; do
      id=$(echo "$id" | xargs)
      identifier=$(echo "$identifier" | xargs)
      name=$(echo "$name" | xargs)
      timezone=$(echo "$timezone" | xargs)
      db_host=$(echo "$db_host" | xargs)
      db_port=$(echo "$db_port" | xargs)
      db_name=$(echo "$db_name" | xargs)
      db_user=$(echo "$db_user" | xargs)
      db_pass=$(echo "$db_pass" | xargs)

      log "✓ registering tenant: ${name} (${identifier})"
      local encrypted db_hash master_hash
      encrypted=$(get_encrypted_passwords "$db_pass")
      IFS=':' read -r db_hash master_hash <<< "$encrypted"

      cat << SQL

-- Tenant: ${name} (${identifier})
DELETE FROM tenants WHERE id = ${id};
DELETE FROM tenant_server_connections WHERE id = ${id};

INSERT INTO tenant_server_connections
  (id, schema_name, schema_server, schema_server_port, schema_username, schema_password, auto_update, master_password_hash)
VALUES
  (${id}, '${db_name}', '${db_host}', '${db_port}', '${db_user}', '${db_hash}', 1, '${master_hash}');

INSERT INTO tenants
  (id, identifier, name, timezone_id, joined_date, created_date, lastmodified_date, oltp_id, report_id)
VALUES
  (${id}, '${identifier}', '${name}', '${timezone}', CURRENT_DATE, LOCALTIMESTAMP, LOCALTIMESTAMP, ${id}, ${id});
SQL
    done
    echo "COMMIT;"
  } | psql_stdin "$TENANTS_DB" || error "tenant registration failed"

  log "✅ Tenants registered in ${TENANTS_DB}."
}

enable_liquibase() {
  log "Enabling Liquibase temporarily..."
  kubectl set env deployment/"$FINERACT_DEPLOYMENT" -n "$MIFOSX_NAMESPACE" \
    FINERACT_LIQUIBASE_ENABLED=true >/dev/null
  # Force a restart even if the flag was already true: Fineract migrates tenants
  # only at startup, so the freshly-registered tenants need a fresh pod.
  kubectl rollout restart deployment/"$FINERACT_DEPLOYMENT" -n "$MIFOSX_NAMESPACE" >/dev/null
  kubectl rollout status deployment/"$FINERACT_DEPLOYMENT" -n "$MIFOSX_NAMESPACE" --timeout=600s
  log "✅ Liquibase completed — tenant schemas populated."
}

disable_liquibase() {
  log "Disabling Liquibase..."
  kubectl set env deployment/"$FINERACT_DEPLOYMENT" -n "$MIFOSX_NAMESPACE" \
    FINERACT_LIQUIBASE_ENABLED=false >/dev/null
  kubectl rollout status deployment/"$FINERACT_DEPLOYMENT" -n "$MIFOSX_NAMESPACE" --timeout=300s || true
  log "✅ Liquibase disabled."
}

dump_database() {
  log "Dumping final state..."
  local dump_script="$SCRIPT_DIR/dump-restore-fineract-db.sh"
  if [[ -x "$dump_script" ]]; then
    bash "$dump_script" -d > /dev/null
  else
    kubectl exec -n "$POSTGRES_NAMESPACE" "$POSTGRES_POD" -- \
      env PGPASSWORD="$POSTGRES_PASSWORD" pg_dumpall -U "$POSTGRES_SUPERUSER" -h 127.0.0.1 > "$FINAL_DUMP"
  fi
  local latest
  latest=$(ls -t "$CONFIG_DIR"/fineract-db-dump-*.sql 2>/dev/null | head -n1 || true)
  [[ -n "$latest" && "$latest" != "$FINAL_DUMP" ]] && mv "$latest" "$FINAL_DUMP"
  log "✅ Final dump: $FINAL_DUMP"
}

# ==================== MAIN ====================

while getopts "f:Fnh" opt; do
  case $opt in
    f) CSV_FILE="$OPTARG" ;;
    F) FORCE_RECREATE=1 ;;
    n) SKIP_DUMP=1 ;;
    h) usage ;;
    *) usage ;;
  esac
done

[[ ! -f "$CSV_FILE" ]] && error "CSV not found: $CSV_FILE"

log "=== Mifos Gazelle Tenant Setup (Postgres) ==="
log "CSV: $CSV_FILE"

if [[ $SKIP_DUMP -eq 0 && -f "$FINAL_DUMP" && $FORCE_RECREATE -eq 0 ]]; then
  warning "Final dump exists — use -F to recreate, or -n to skip the dump"
  exit 0
fi

create_tenant_databases
register_tenants
enable_liquibase

if [[ $SKIP_DUMP -eq 0 ]]; then
  dump_database
fi

disable_liquibase

log ""
log "🎉 Success! Tenants created and configured on Postgres."
log "   Databases: greenbank, bluebank, redbank"
[[ $SKIP_DUMP -eq 0 ]] && log "   Final dump ready: $FINAL_DUMP"
