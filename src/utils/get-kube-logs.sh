#!/bin/bash

# Set variables
NAMESPACE="paymenthub"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_DIR="/tmp/kube_logs_${TIMESTAMP}"
INTEGRATION_REPORT_DIR="integration_report"
TEST_POD_PREFIX="g2p-sandbox-test-gov"

# Function to check if kubectl is available
check_kubectl() {
    if ! command -v kubectl &> /dev/null; then
        echo "kubectl is not installed. Please install kubectl first."
        exit 1
    fi
}

# Function to check if namespace exists
check_namespace() {
    if ! kubectl get namespace "$NAMESPACE" &> /dev/null; then
        echo "Namespace $NAMESPACE does not exist."
        exit 1
    fi
}

# Function to copy integration report
copy_integration_report() {
    echo "Copying integration report..."
    TEST_POD=$(kubectl get pods -n "$NAMESPACE" | grep "$TEST_POD_PREFIX" | cut -d " " -f1)
    
    if [ -z "$TEST_POD" ]; then
        echo "No test pod found with prefix $TEST_POD_PREFIX"
        return 1
    fi
    
    mkdir -p "$INTEGRATION_REPORT_DIR"
    kubectl cp "$NAMESPACE/$TEST_POD:/ph-ee-connector-integration-test/build" "$INTEGRATION_REPORT_DIR/test-report"
    
    if [ $? -eq 0 ]; then
        echo "Successfully copied integration report to $INTEGRATION_REPORT_DIR/test-report"
    else
        echo "Failed to copy integration report"
    fi
}

# Function to collect logs from all pods
collect_logs() {
    echo "Collecting logs from all pods in namespace $NAMESPACE..."
    
    # Create unique directory for this run
    mkdir -p "$LOG_DIR"
    echo "Logs will be saved in: $LOG_DIR"
    
    # Create a summary file
    SUMMARY_FILE="$LOG_DIR/_summary.txt"
    echo "Log Collection Summary - $(date)" > "$SUMMARY_FILE"
    echo "Namespace: $NAMESPACE" >> "$SUMMARY_FILE"
    echo "----------------------------------------" >> "$SUMMARY_FILE"
    
    # Get all pods and collect logs
    kubectl get pods -n "$NAMESPACE" --no-headers | while read -r pod_line; do
        pod=$(echo "$pod_line" | cut -d " " -f1)
        pod_status=$(echo "$pod_line" | awk '{print $3}')
        containers=$(kubectl get pod "$pod" -n "$NAMESPACE" -o jsonpath='{.spec.containers[*].name}')
        
        echo "Collecting logs from pod: $pod"
        echo "Pod: $pod - Status: $pod_status" >> "$SUMMARY_FILE"
        
        for container in $containers; do
            log_file="$LOG_DIR/${pod}_${container}.log"
            echo "  Container: $container - Log file: $log_file" >> "$SUMMARY_FILE"
            
            echo "--------------------------------------------------------------------" > "$log_file"
            echo "Pod: $pod - Container: $container" >> "$log_file"
            echo "Status: $pod_status" >> "$log_file"
            echo "Timestamp: $(date)" >> "$log_file"
            echo "--------------------------------------------------------------------" >> "$log_file"
            echo "" >> "$log_file"
            
            kubectl logs -n "$NAMESPACE" "$pod" -c "$container" >> "$log_file" 2>&1
        done
        echo "" >> "$SUMMARY_FILE"
    done
    
    # Create a tar archive of all logs
    tar_file="/tmp/kube_logs_${TIMESTAMP}.tar.gz"
    tar -czf "$tar_file" -C "/tmp" "kube_logs_${TIMESTAMP}"
    
    echo "----------------------------------------" >> "$SUMMARY_FILE"
    echo "Log collection completed at $(date)" >> "$SUMMARY_FILE"
    echo "Logs have been collected in: $LOG_DIR"
    echo "Logs have been archived to: $tar_file"
}

# Main execution
main() {
    check_kubectl
    check_namespace
    
    copy_integration_report
    collect_logs
    
    echo "Script execution completed!"
    echo "Log directory: $LOG_DIR"
    echo "Log archive: /tmp/kube_logs_${TIMESTAMP}.tar.gz"
}

# Run the script
main