#!/bin/bash

# Default MySQL connection credentials
MYSQL_USER="root"
MYSQL_PASSWORD="mysqlpw"    # plain text password , not a great idea
MYSQL_HOST="mysql.infra.svc.cluster.local"   
MYSQL_DATABASE="fineract_tenants"
MYSQL_IMAGE="mysql:5.7"

# Default tenant configuration
TENANT_ID="2"
TENANT_IDENTIFIER="gazelle1"
TENANT_NAME="tenant for Gazelle"
TENANT_TIMEZONE="Australia/Adelaide"
FINERACT_DEFAULT_TENANTDB_MASTER_PASSWORD="fineract"

DB_HOST="mysql.infra.svc.cluster.local"
DB_PORT="3306"
DB_NAME="gazelle1"
DB_USER="root"
DB_PASSWORD="mysqlpw"
DB_PASSWORD_HASH="SKf97GzTf5EWFy713F7KVhCeGpkZNhXm8QKSHqlAZSm2LKc9OY88C+nQJkHR+Z35"
FINERACT_DEFAULT_TENANTDB_MASTER_HASH='$2a$10$VGXjWns6W9j4VStQixsSCesPaHTPhGfe3kCvXxZ.5qvCkBmFPr.XW'
#POOL_INITIAL_SIZE="5"
# POOL_MAX_ACTIVE="40"
# POOL_VALIDATION_INTERVAL="30000"

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
function create_tenant_sql { 
echo "Creating the sql to seed the second tenant in /tmp/tenant_setup.sh" 
cat << EOF > /tmp/tenant_setup.sql
-- 
delete from tenants where id=2;
delete from tenant_server_connections where id=2;
-- Insert into tenant_server_connections
INSERT INTO tenant_server_connections (
    id, schema_name, schema_server, schema_server_port, 
    schema_username, schema_password, auto_update, master_password_hash
) VALUES (
    ${TENANT_ID},
    '${DB_NAME}',
    '${DB_HOST}',
    '${DB_PORT}',
    '${DB_USER}',
    '${DB_PASSWORD_HASH}',
    1,
    '${FINERACT_DEFAULT_TENANTDB_MASTER_HASH}'
);

-- Insert into tenants
INSERT INTO tenants (
    id, identifier, name, timezone_id,
    country_id, joined_date, created_date,
    lastmodified_date, oltp_id, report_id
) VALUES (
    ${TENANT_ID},
    '${TENANT_IDENTIFIER}',
    '${TENANT_NAME}',
    '${TENANT_TIMEZONE}',
    NULL, NOW(), NOW(), NOW(),
    ${TENANT_ID},
    ${TENANT_ID}
);
EOF
}


# Function to execute the SQL
execute_sql() {
    local CMD="kubectl run gazelle-mysql-client --rm -i --image=${MYSQL_IMAGE} --restart=Never -- mysql -h ${MYSQL_HOST} -u ${MYSQL_USER} -p${MYSQL_PASSWORD} ${MYSQL_DATABASE}"
    echo "Executing SQL commands..."
    cat /tmp/tenant_setup.sql | eval "${CMD}"
    
    if [ $? -eq 0 ]; then
        echo "Successfully created tenant entries"
    else
        echo "Error creating tenant entries"
        exit 1
    fi
}

# get the encrypted password and the encrypted master password 


### main ### 

echo " Updating the DB password hash  and the fineract master password hash" 
fineract_pod=`kubectl get pods -n mifosx-1 --no-headers | grep ^fineract-server | awk '{print $1}'` #assumes one pod
output=$(kubectl exec -n mifosx-1 "$fineract_pod" -- java -cp @/app/jib-classpath-file \
    org.apache.fineract.infrastructure.core.service.database.DatabasePasswordEncryptor \
    "$FINERACT_DEFAULT_TENANTDB_MASTER_PASSWORD" "$DB_PASSWORD")
echo $output 

# Extract the encrypted password and master password hash using regex
DB_PASSWORD_HASH=$(echo "$output" | grep "The encrypted password:" | sed 's/^The encrypted password: //')
FINERACT_DEFAULT_TENANTDB_MASTER_HASH=$(echo "$output" | grep "The master password hash is:" | sed 's/^The master password hash is: //')

create_tenant_sql

# Show the SQL that will be executed
echo "The following SQL will be executed:"
echo "-----------------------------------"
cat tenant_setup.sql
echo "-----------------------------------"
echo "Do you want to proceed? (y/n)"
read -r confirm

if [[ $confirm =~ ^[Yy]$ ]]; then
    execute_sql
else
    echo "Operation cancelled"
    exit 0
fi