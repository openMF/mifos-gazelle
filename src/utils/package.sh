#!/usr/bin/env bash

# Define variables for the charts
SCRIPT_DIR=$( cd $(dirname "$0") ; pwd )
APPS_DIR="$( cd $(dirname "$SCRIPT_DIR")/../repos ; pwd )"
echo "APPS_DIR is $APPS_DIR"
echo "this script is WIP ......"
exit 1 

PARENT_CHART_NAME="ph-ee-gazelle"
PARENT_CHART_PATH="$APPS_DIR"
ENGINE_CHART_PATH="../ph-ee-engine"
COMMON_CHART_PATH="../common"
OUTPUT_DIR="APPS_DIR/packaged-charts"

# Function to check if a directory has changes in its git repo
has_changes() {
    local dir="$1"
    cd "$dir" || exit 1

    # Fetch latest changes and compare the HEAD
    git fetch --quiet
    local changes=$(git diff HEAD origin/$(git rev-parse --abbrev-ref HEAD) --stat)

    # Check if the working directory is clean
    local status=$(git status --porcelain)
    if [ -n "$changes" ] || [ -n "$status" ]; then
        return 0 # Changes exist
    else
        return 1 # No changes
    fi
}

# Create output directory if it doesn't exist
mkdir -p "$OUTPUT_DIR"

# Package the 'ph-ee-engine' chart if there are changes
echo "Checking for changes in 'ph-ee-engine' chart..."
if has_changes "$ENGINE_CHART_PATH"; then
    echo "Changes detected in 'ph-ee-engine'. Updating dependencies and packaging..."
    helm dependency update "$ENGINE_CHART_PATH"
    helm package "$ENGINE_CHART_PATH" --destination "$OUTPUT_DIR"

    if [ $? -eq 0 ]; then
        echo "ph-ee-engine chart has been successfully packaged."
    else
        echo "Failed to package the ph-ee-engine chart."
        exit 1
    fi
else
    echo "No changes detected in 'ph-ee-engine'. Skipping packaging."
fi

# Package the 'common' chart if there are changes
echo "Checking for changes in 'common' chart..."
if has_changes "$COMMON_CHART_PATH"; then
    echo "Changes detected in 'common'. Updating dependencies and packaging..."
    helm dependency update "$COMMON_CHART_PATH"
    helm package "$COMMON_CHART_PATH" --destination "$OUTPUT_DIR"

    if [ $? -eq 0 ]; then
        echo "common chart has been successfully packaged."
    else
        echo "Failed to package the common chart."
        exit 1
    fi
else
    echo "No changes detected in 'common'. Skipping packaging."
fi

# Package the parent 'ph-ee-gazelle' chart if there are changes
echo "Checking for changes in parent 'ph-ee-gazelle' chart..."
if has_changes "$PARENT_CHART_PATH"; then
    echo "Changes detected in '$PARENT_CHART_NAME'. Updating dependencies and packaging..."
    helm dependency update "$PARENT_CHART_PATH"
    helm package "$PARENT_CHART_PATH" --destination "$OUTPUT_DIR"

    if [ $? -eq 0 ]; then
        echo "Parent chart '$PARENT_CHART_NAME' has been successfully packaged."
        echo "You can find the packages in the '$OUTPUT_DIR' directory."
    else
        echo "Failed to package the parent chart."
        exit 1
    fi
else
    echo "No changes detected in '$PARENT_CHART_NAME'. Skipping packaging."
fi
