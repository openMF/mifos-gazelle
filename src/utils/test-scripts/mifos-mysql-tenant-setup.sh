#!/bin/bash

# Default MySQL connection credentials
MYSQL_USER="root"
MYSQL_PASSWORD="ethieTieCh8ahv"
MYSQL_HOST="mysql.infra.svc.cluster.local"
MYSQL_DATABASE="fineract_tenants"
MYSQL_IMAGE="mysql:5.6"

# Default tenant configuration
TENANT_ID="2"
TENANT_IDENTIFIER="gazelle1"
TENANT_NAME="first gazelle tenant"
TENANT_TIMEZONE="Adelaide/Australia"
DB_HOST="mysql.infra.svc.cluster.local"
DB_PORT="3306"
DB_NAME="gazelle_db"
DB_USER="root"
DB_PASSWORD="ethieTieCh8ahv"
POOL_INITIAL_SIZE="5"
POOL_MAX_ACTIVE="40"
POOL_VALIDATION_INTERVAL="30000"

# Help function
show_help() {
    echo "Usage: $0 [options]"
    echo "Setup new Fineract tenant in Kubernetes MySQL instance"
    echo ""
    echo "Options:"
    echo "  -u, --user              MySQL username (default: $MYSQL_USER)"
    echo "  -p, --password          MySQL password"
    echo "  -h, --host              MySQL host (default: $MYSQL_HOST)"
    echo "  --tenant-id             Tenant ID (default: $TENANT_ID)"
    echo "  --tenant-name           Tenant name (default: $TENANT_NAME)"
    echo "  --tenant-identifier     Tenant identifier (default: $TENANT_IDENTIFIER)"
    echo "  --tenant-timezone       Tenant timezone (default: $TENANT_TIMEZONE)"
    echo "  --db-host              Database host (default: $DB_HOST)"
    echo "  --db-port              Database port (default: $DB_PORT)"
    echo "  --db-name              Database name (default: $DB_NAME)"
    echo "  --db-user              Database username (default: $DB_USER)"
    echo "  --db-password          Database password"
    echo "  --help                 Show this help message"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -u|--user)
            MYSQL_USER="$2"
            shift 2
            ;;
        -p|--password)
            MYSQL_PASSWORD="$2"
            shift 2
            ;;
        -h|--host)
            MYSQL_HOST="$2"
            shift 2
            ;;
        --tenant-id)
            TENANT_ID="$2"
            shift 2
            ;;
        --tenant-name)
            TENANT_NAME="$2"
            shift 2
            ;;
        --tenant-identifier)
            TENANT_IDENTIFIER="$2"
            shift 2
            ;;
        --tenant-timezone)
            TENANT_TIMEZONE="$2"
            shift 2
            ;;
        --db-host)
            DB_HOST="$2"
            shift 2
            ;;
        --db-port)
            DB_PORT="$2"
            shift 2
            ;;
        --db-name)
            DB_NAME="$2"
            shift 2
            ;;
        --db-user)
            DB_USER="$2"
            shift 2
            ;;
        --db-password)
            DB_PASSWORD="$2"
            shift 2
            ;;
        --help)
            show_help
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# Create SQL for tenant setup
cat << EOF > tenant_setup.sql
-- Insert into tenant_server_connections
INSERT INTO tenant_server_connections (
    id, schema_server, schema_name, schema_server_port, 
    schema_username, schema_password, auto_update 
) VALUES (
    ${TENANT_ID},
    '${DB_HOST}',
    '${DB_NAME}',
    ${DB_PORT},
    '${DB_USER}',
    '${DB_PASSWORD}',
    1
);

-- Insert into tenants
INSERT INTO tenants (
    id, identifier, name, timezone_id, joined_date, created_date,
    lastmodified_date, oltp_id, report_id
) VALUES (
    ${TENANT_ID},
    '${TENANT_IDENTIFIER}',
    '${TENANT_NAME}',
    '${TENANT_TIMEZONE}', NULL , NULL , NULL , 
    ${TENANT_ID},
    ${TENANT_ID}
);
EOF

# Function to execute the SQL
execute_sql() {
    local CMD="kubectl run mysql-client --rm -i --image=${MYSQL_IMAGE} --restart=Never -- mysql -h ${MYSQL_HOST} -u ${MYSQL_USER} -p${MYSQL_PASSWORD} ${MYSQL_DATABASE}"
    echo "Executing SQL commands..."
    cat tenant_setup.sql | eval "${CMD}"
    
    if [ $? -eq 0 ]; then
        echo "Successfully created tenant entries"
    else
        echo "Error creating tenant entries"
        exit 1
    fi
}

# Show the SQL that will be executed
echo "The following SQL will be executed:"
echo "-----------------------------------"
cat tenant_setup.sql
echo "-----------------------------------"
echo "Do you want to proceed? (y/n)"
read -r confirm

if [[ $confirm =~ ^[Yy]$ ]]; then
    execute_sql
    rm tenant_setup.sql
else
    echo "Operation cancelled"
    rm tenant_setup.sql
    exit 0
fi