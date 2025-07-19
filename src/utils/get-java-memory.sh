#!/bin/bash

# Check if kubectl is installed
if ! command -v kubectl &> /dev/null; then
    echo "Error: kubectl is not installed."
    exit 1
fi

# Check if bc is installed
if ! command -v bc &> /dev/null; then
    echo "Error: bc is not installed. Please install it (e.g., 'sudo apt install bc')."
    exit 1
fi

# Get current namespace
NAMESPACE=$(kubectl config view --minify --output 'jsonpath={..namespace}')
NAMESPACE=${NAMESPACE:-default}
echo "Scanning pods in namespace: $NAMESPACE"
echo "----------------------------------------"

# Get all pods in the current namespace
PODS=$(kubectl get pods -n "$NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')

# Check if any pods were found
if [ -z "$PODS" ]; then
    echo "No pods found in namespace $NAMESPACE."
    exit 0
fi

# Function to convert bytes to MB
bytes_to_mb() {
    local bytes=$1
    echo "scale=2; $bytes / 1048576" | bc
}

# Iterate over each pod
while IFS= read -r POD; do
    # Check if PID 1 is a Java process
    JAVA_CHECK=$(kubectl exec -n "$NAMESPACE" "$POD" -- sh -c 'if [ -f /proc/1/cmdline ]; then cat /proc/1/cmdline | grep -q java && echo "java"; else ps -p 1 | grep java && echo "java"; fi' 2>/dev/null)
    
    if [ "$JAVA_CHECK" = "java" ]; then
        # Run jcmd with PID 1 to get VM flags
        JCMD_OUTPUT=$(kubectl exec -n "$NAMESPACE" "$POD" -- jcmd 1 VM.flags 2>/dev/null)
        
        # Check if jcmd returned valid data
        if [ $? -eq 0 ] && [ -n "$JCMD_OUTPUT" ]; then
            # Extract memory-related flags
            MEMORY_FLAGS=$(echo "$JCMD_OUTPUT" | grep -oE '\-XX:(InitialHeapSize|MaxHeapSize|SoftMaxHeapSize|MinHeapSize|MaxNewSize|NewSize|OldSize|MinHeapDeltaBytes|NonNMethodCodeHeapSize|NonProfiledCodeHeapSize|ProfiledCodeHeapSize|ReservedCodeCacheSize)=[0-9]+' | sort)
            if [ -n "$MEMORY_FLAGS" ]; then
                echo "Pod: $POD (Java PID: 1)"
                echo "Memory Parameters (MB):"
                echo "$MEMORY_FLAGS" | while IFS= read -r line; do
                    flag=$(echo "$line" | cut -d'=' -f1 | sed 's/^-XX://')
                    value=$(echo "$line" | cut -d'=' -f2)
                    if [[ "$value" =~ ^[0-9]+$ ]]; then
                        mb=$(bytes_to_mb "$value")
                        printf "  %s:%s MB\n" "$flag" "$mb"
                    fi
                done
                echo "----------------------------------------"
            fi
        fi
    fi
done <<< "$PODS"