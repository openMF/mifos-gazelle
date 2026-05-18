#!/bin/bash
# OpenSPP Database Initialization Script
# Initializes PostgreSQL database for OpenSPP

set -e

OPENSPP_NAMESPACE="${OPENSPP_NAMESPACE:-openspp}"
OPENSPP_DB_NAME="${OPENSPP_DB_NAME:-openspp}"
OPENSPP_DB_USER="${OPENSPP_DB_USER:-openspp}"
OPENSPP_DB_PASSWORD="${OPENSPP_DB_PASSWORD:-openspp}"
POSTGRESQL_SERVICE="postgresql.infra.svc.cluster.local"
POSTGRESQL_PORT="5432"

echo "Initializing OpenSPP database..."
echo "  Database: $OPENSPP_DB_NAME"
echo "  User: $OPENSPP_DB_USER"
echo "  Namespace: $OPENSPP_NAMESPACE"

# Create a pod to run psql commands in the Kubernetes cluster
kubectl run openspp-db-init \
  --image=postgres:16-alpine \
  --namespace="$OPENSPP_NAMESPACE" \
  --rm -it \
  --restart=Never \
  --env="PGPASSWORD=root" \
  -- \
  sh -c "
    # Wait for PostgreSQL to be ready
    echo 'Waiting for PostgreSQL to be ready...'
    until psql -h $POSTGRESQL_SERVICE -U postgres -c 'SELECT 1' >/dev/null 2>&1; do
      sleep 2
    done
    echo 'PostgreSQL is ready.'

    # Create database if not exists
    psql -h $POSTGRESQL_SERVICE -U postgres -tc \"SELECT 1 FROM pg_database WHERE datname = '$OPENSPP_DB_NAME'\" | grep -q 1 || \
    psql -h $POSTGRESQL_SERVICE -U postgres -c \"CREATE DATABASE $OPENSPP_DB_NAME;\"
    echo 'Database $OPENSPP_DB_NAME created.'

    # Create user if not exists
    psql -h $POSTGRESQL_SERVICE -U postgres -tc \"SELECT 1 FROM pg_user WHERE usename = '$OPENSPP_DB_USER'\" | grep -q 1 || \
    psql -h $POSTGRESQL_SERVICE -U postgres -c \"CREATE USER $OPENSPP_DB_USER WITH PASSWORD '$OPENSPP_DB_PASSWORD';\"
    echo 'User $OPENSPP_DB_USER created.'

    # Grant privileges
    psql -h $POSTGRESQL_SERVICE -U postgres -c \"GRANT ALL PRIVILEGES ON DATABASE $OPENSPP_DB_NAME TO $OPENSPP_DB_USER;\"
    echo 'Privileges granted.'

    # Enable PostGIS extension (required by OpenSPP)
    psql -h $POSTGRESQL_SERVICE -U $OPENSPP_DB_USER -d $OPENSPP_DB_NAME -c 'CREATE EXTENSION IF NOT EXISTS postgis;' || true
    echo 'PostGIS extension enabled.'

    echo 'OpenSPP database initialization complete.'
  "

echo "✓ OpenSPP database initialized successfully"
