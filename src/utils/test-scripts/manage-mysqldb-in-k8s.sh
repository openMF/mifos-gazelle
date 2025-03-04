#!/bin/bash

# Default MySQL connection credentials
MYSQL_USER="root"
MYSQL_PASSWORD="ethieTieCh8ahv"
MYSQL_HOST="mysql.infra.svc.cluster.local"
MYSQL_DATABASE="mysql"
MYSQL_IMAGE="mysql:5.6"
OPERATION="connect"
OUTPUT_FILE=""

# Help function
show_help() {
    echo "Usage: $0 [options]"
    echo "Manage MySQL instance in Kubernetes cluster"
    echo ""
    echo "Options:"
    echo "  -u, --user        MySQL username (default: $MYSQL_USER)"
    echo "  -p, --password    MySQL password"
    echo "  -h, --host        MySQL host (default: $MYSQL_HOST)"
    echo "  -d, --database    MySQL database (default: $MYSQL_DATABASE)"
    echo "  -o, --operation   Operation to perform: connect|export|import (default: connect)"
    echo "  -f, --file        File name for import/export operations"
    echo "  --help           Show this help message"
    echo ""
    echo "Examples:"
    echo "  Connect:  $0 -d mydatabase"
    echo "  Export:   $0 -o export -d mydatabase -f backup.sql"
    echo "  Import:   $0 -o import -d mydatabase -f backup.sql"
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
        -d|--database)
            MYSQL_DATABASE="$2"
            shift 2
            ;;
        -o|--operation)
            OPERATION="$2"
            shift 2
            ;;
        -f|--file)
            OUTPUT_FILE="$2"
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

# Validate operation
case $OPERATION in
    connect|export|import)
        ;;
    *)
        echo "Error: Invalid operation '$OPERATION'. Must be connect, export, or import."
        exit 1
        ;;
esac

# Validate file parameter for import/export
if [[ "$OPERATION" != "connect" && -z "$OUTPUT_FILE" ]]; then
    echo "Error: File parameter (-f) is required for import/export operations"
    exit 1
fi

# Function to construct the base kubectl run command
get_kubectl_base_cmd() {
    echo "kubectl run mysql-client --rm -it --image=${MYSQL_IMAGE} --restart=Never"
}

# Function to execute the command
execute_command() {
    local CMD="$1"
    echo "Executing command:"
    # Show command with masked password
    echo "${CMD//-p${MYSQL_PASSWORD}/-p********}"
    echo "---"
    eval "${CMD}"
}

# Handle different operations
case $OPERATION in
    connect)
        CMD="$(get_kubectl_base_cmd) -- mysql -h ${MYSQL_HOST} -u ${MYSQL_USER} -p${MYSQL_PASSWORD} ${MYSQL_DATABASE}"
        execute_command "${CMD}"
        ;;
    export)
        CMD="$(get_kubectl_base_cmd) -- mysqldump -h ${MYSQL_HOST} -u ${MYSQL_USER} -p${MYSQL_PASSWORD} ${MYSQL_DATABASE} > ${OUTPUT_FILE}"
        execute_command "${CMD}"
        echo "Database exported to ${OUTPUT_FILE}"
        ;;
    import)
        if [[ ! -f "$OUTPUT_FILE" ]]; then
            echo "Error: Import file ${OUTPUT_FILE} does not exist"
            exit 1
        fi
        CMD="$(get_kubectl_base_cmd) -- mysql -h ${MYSQL_HOST} -u ${MYSQL_USER} -p${MYSQL_PASSWORD} ${MYSQL_DATABASE} < ${OUTPUT_FILE}"
        execute_command "${CMD}"
        echo "Database imported from ${OUTPUT_FILE}"
        ;;
esac