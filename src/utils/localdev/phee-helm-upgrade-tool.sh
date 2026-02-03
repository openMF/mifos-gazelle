#!/bin/bash
# This script is a utility for local development of Paymenthub EE Helm charts.
# It automates the process of cleaning and rebuilding the Helm charts
# for Gazelle (parent chart) and ph-ee-engine (subchart).
# Note: this is not really needed , but is just a convenience tool to save having to cd to the ph-ee-engine chart and run 
#       helm dependency build or update and then repeat the same thing for the gazelle chart
#
# Usage:
#   ./phee-helm-upgrade-tool.sh
#
# Assumptions:
#   - The script is located in mifos-gazelle/src/utils/localdev.
#   - The Helm charts are located under mifos-gazelle/repos/ph_template/helm/.
#   - 'helm' command-line tool is installed and available in PATH.

set -euo pipefail

# --- Configuration ---
# Directory where this script resides
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Base directory of the mifos-gazelle project
GAZELLE_BASE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Helm charts directory within the ph_template repository
HELM_CHARTS_DIR="$GAZELLE_BASE_DIR/repos/ph_template/helm"

# Specific chart paths
GAZELLE_CHART_DIR="$HELM_CHARTS_DIR/gazelle"
PHEE_ENGINE_CHART_DIR="$HELM_CHARTS_DIR/ph-ee-engine"

# --- Functions ---

log_info() {
  echo "INFO: $1"
}

log_error() {
  echo "ERROR: $1" >&2
  exit 1
}

check_helm_installed() {
  if ! command -v helm &>/dev/null; then
    log_error "Helm is not installed. Please install Helm to proceed."
  fi
}

clean_chart_dependencies() {
  local chart_path="$1"
  log_info "Cleaning dependencies for chart: $chart_path"

  if [ -d "$chart_path/charts" ]; then
    log_info "Removing existing 'charts' directory: $chart_path/charts"
    rm -rf "$chart_path/charts"
  fi

  if [ -f "$chart_path/Chart.lock" ]; then
    log_info "Removing existing 'Chart.lock'' file: $chart_path/Chart.lock"
    rm -f "$chart_path/Chart.lock"
  fi
}

build_chart_dependencies() {
  local chart_path="$1"
  log_info "Building dependencies for chart: $chart_path"

  # Try 'helm dependency build' first
  if helm dependency build  --skip-refresh "$chart_path"; then
    log_info "Successfully built dependencies for $chart_path using 'helm dependency build'."
  else
    log_info "Failed to build dependencies for $chart_path using 'helm dependency build'. Attempting 'helm dependency update'..."
    # If build fails, try 'helm dependency update'
    if helm dependency update --skip-refresh "$chart_path"; then
      log_info "Successfully updated dependencies for $chart_path using 'helm dependency update'."
    else
      log_error "Failed to build or update dependencies for $chart_path. Please check your chart configuration."
    fi
  fi
}

# --- Main Script ---

log_info "Starting Helm chart upgrade utility..."

check_helm_installed

# Clean and rebuild ph-ee-engine subchart
log_info "Processing ph-ee-engine subchart..."
clean_chart_dependencies "$PHEE_ENGINE_CHART_DIR"
build_chart_dependencies "$PHEE_ENGINE_CHART_DIR"

# Clean and rebuild Gazelle parent chart
log_info "Processing Gazelle parent chart..."
clean_chart_dependencies "$GAZELLE_CHART_DIR"
build_chart_dependencies "$GAZELLE_CHART_DIR"

log_info "Helm chart dependencies cleaned and rebuilt successfully."
log_info "You can now proceed with 'helm upgrade' or 'helm install'."
