#!/usr/bin/env bash

set -euo pipefail

# ==================== PATH & CONFIG ====================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CONFIG_DIR="$BASE_DIR/config"
DEFAULT_CSV="$CONFIG_DIR/mifos-tenant-config.csv"

MYSQL_NAMESPACE="infra"
MIFOSX_NAMESPACE="mifosx"
MYSQL_POD="mysql-0"
FINERACT_DEPLOYMENT="fineract-server"
UTILS_DIR="$BASE_DIR/src/utils"
FINAL_DUMP="$CONFIG_DIR/fineract-db-dump-final.sql"

CSV_FILE="$DEFAULT_CSV"
FORCE_RECREATE=0
MASTER_PASSWORD="fineract"

# ==================== HELPERS ====================

log() { echo "$@" >&2; }
error() { echo "❌ $@" >&2; exit 1; }
warning() { echo "⚠️  $@" >&2; }

usage() {
  cat << EOF
Usage: $(basename "$0") [OPTIONS]

Creates separate tenant databases and registers them in Fineract multi-tenancy.

Options:
  -f <file>     CSV file (default: $DEFAULT_CSV)
  -F            Force recreate dump
  -h            Show help

CSV Format:
tenant_id,tenant_identifier,tenant_name,tenant_timezone,db_host,db_port,db_name,db_user,db_password
EOF
  exit 1
}

get_fineract_pod() {
  kubectl get pods -n "$MIFOSX_NAMESPACE" -l app=fineract-server -o name | head -1 | sed 's/^pod\///'
}

get_encrypted_passwords() {
  local plain="$1"
  local pod=$(get_fineract_pod)
  [[ -z "$pod" ]] && error "Fineract pod not found"

  local output
  output=$(kubectl exec -n "$MIFOSX_NAMESPACE" "$pod" -- java -cp @/app/jib-classpath-file \
    org.apache.fineract.infrastructure.core.service.database.DatabasePasswordEncryptor \
    "$MASTER_PASSWORD" "$plain" 2>/dev/null)

  local db_hash=$(echo "$output" | grep "encrypted password" | cut -d: -f2- | xargs)
  local master_hash=$(echo "$output" | grep "master password hash" | cut -d: -f2- | xargs)

  [[ -z "$db_hash" || -z "$master_hash" ]] && error "Failed to encrypt password"
  echo "$db_hash:$master_hash"
}

generate_sql() {
  local sql_file="$1"

  {
    echo "USE fineract_tenants;"
    echo "START TRANSACTION;"

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

      log "✓ Creating database and registering tenant: $name ($identifier)"

      local encrypted=$(get_encrypted_passwords "$db_pass")
      local db_hash master_hash
      IFS=':' read -r db_hash master_hash <<< "$encrypted"

      cat << SQL

-- Tenant: $name ($identifier)
CREATE DATABASE IF NOT EXISTS \`$db_name\`;
DELETE FROM tenants WHERE id = $id;
DELETE FROM tenant_server_connections WHERE id = $id;

INSERT INTO tenant_server_connections
  (id, schema_name, schema_server, schema_server_port, schema_username, schema_password, auto_update, master_password_hash)
VALUES
  ($id, '$db_name', '$db_host', '$db_port', '$db_user', '$db_hash', 1, '$master_hash');

INSERT INTO tenants
  (id, identifier, name, timezone_id, joined_date, created_date, lastmodified_date, oltp_id, report_id)
VALUES
  ($id, '$identifier', '$name', '$timezone', NOW(), NOW(), NOW(), $id, $id);
SQL
    done

    echo "COMMIT;"
  } > "$sql_file"
}

apply_sql() {
  local sql_file="$1"
  log "Copying SQL to MySQL pod..."
  kubectl cp "$sql_file" "${MYSQL_NAMESPACE}/${MYSQL_POD}":/tmp/tenants.sql || error "Failed to copy SQL file to pod"

  log "Executing tenant setup SQL..."
  kubectl exec -n "$MYSQL_NAMESPACE" "$MYSQL_POD" -- bash -c "mysql -uroot -pmysqlpw fineract_tenants < /tmp/tenants.sql" || error "SQL execution failed"

  log "Cleaning up..."
  kubectl exec -n "$MYSQL_NAMESPACE" "$MYSQL_POD" -- rm -f /tmp/tenants.sql || true
  rm -f "$sql_file"

  log "✅ Tenants registered and databases created."
}


enable_liquibase() {
  log "Enabling Liquibase temporarily..."
  kubectl patch deployment "$FINERACT_DEPLOYMENT" -n "$MIFOSX_NAMESPACE" --type=json -p='[
    {"op": "add", "path": "/spec/template/spec/containers/0/env/-", "value": {"name": "FINERACT_LIQUIBASE_ENABLED", "value": "true"}}
  ]'
  kubectl rollout status deployment/"$FINERACT_DEPLOYMENT" -n "$MIFOSX_NAMESPACE" --timeout=600s
  log "✅ Liquibase completed — schemas populated."
}

disable_liquibase() {
  log "Disabling Liquibase..."
  # Get current env vars, filter out FINERACT_LIQUIBASE_ENABLED, and patch back
  local env_json=$(kubectl get deployment "$FINERACT_DEPLOYMENT" -n "$MIFOSX_NAMESPACE" -o json | \
    jq '.spec.template.spec.containers[0].env | map(select(.name != "FINERACT_LIQUIBASE_ENABLED"))')

  kubectl patch deployment "$FINERACT_DEPLOYMENT" -n "$MIFOSX_NAMESPACE" --type=json -p="[
    {\"op\": \"replace\", \"path\": \"/spec/template/spec/containers/0/env\", \"value\": $env_json}
  ]" 2>/dev/null || true
  kubectl rollout status deployment/"$FINERACT_DEPLOYMENT" -n "$MIFOSX_NAMESPACE" --timeout=300s || true
  log "✅ Liquibase disabled."
}

dump_database() {
  log "Dumping final state..."
  local dump_script="$UTILS_DIR/dump-restore-fineract-db.sh"
  if [[ -x "$dump_script" ]]; then
    bash "$dump_script" -d > /dev/null
  else
    kubectl exec -n "$MYSQL_NAMESPACE" "$MYSQL_POD" -- mysqldump -uroot -pmysqlpw --all-databases > "$FINAL_DUMP"
  fi
  local latest=$(ls -t "$CONFIG_DIR"/fineract-db-dump-*.sql 2>/dev/null | head -n1 || true)
  [[ -n "$latest" && "$latest" != "$FINAL_DUMP" ]] && mv "$latest" "$FINAL_DUMP"
  log "✅ Final dump: $FINAL_DUMP"
}

# ==================== MAIN ====================

while getopts "f:Fh" opt; do
  case $opt in
    f) CSV_FILE="$OPTARG" ;;
    F) FORCE_RECREATE=1 ;;
    h) usage ;;
    *) usage ;;
  esac
done

[[ ! -f "$CSV_FILE" ]] && error "CSV not found: $CSV_FILE"

log "=== Mifos Gazelle Tenant Setup ==="
log "CSV: $CSV_FILE"

[[ -f "$FINAL_DUMP" && $FORCE_RECREATE -eq 0 ]] && {
  warning "Final dump exists — use -F to recreate"
  exit 0
}

SQL_FILE=$(mktemp)
generate_sql "$SQL_FILE"
apply_sql "$SQL_FILE"

enable_liquibase
dump_database
disable_liquibase

log ""
log "🎉 Success! All tenants (including redbank) created and configured."
log "   Databases: greenbank, bluebank, redbank"
log "   Final dump ready: $FINAL_DUMP"