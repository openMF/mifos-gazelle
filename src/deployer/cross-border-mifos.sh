#!/usr/bin/env bash
# cross-border-mifos.sh -- Deploy the Mifos fork of the GovStack cross-border payment web app

set -euo pipefail

CROSS_BORDER_REPO="${CROSS_BORDER_REPO:-$HOME/sandbox-usecase-cross-border-payment}"
MANIFEST_DIR="$CROSS_BORDER_REPO/k8s"

if [[ ! -d "$MANIFEST_DIR" ]]; then
  echo "ERROR: manifest directory not found: $MANIFEST_DIR"
  echo "       Clone the repo or set CROSS_BORDER_REPO to its location."
  exit 1
fi

echo "Deploying cross-border-mifos from $MANIFEST_DIR"

kubectl apply -f "$MANIFEST_DIR/namespace.yaml"
kubectl apply -f "$MANIFEST_DIR/deployment.yaml"
kubectl apply -f "$MANIFEST_DIR/service.yaml"
kubectl apply -f "$MANIFEST_DIR/ingress.yaml"

kubectl rollout restart deployment/cross-border-mifos -n cross-border-mifos
kubectl rollout status deployment/cross-border-mifos -n cross-border-mifos

echo "Done — https://cross-border.mifos.sandbox.govstack.global"
