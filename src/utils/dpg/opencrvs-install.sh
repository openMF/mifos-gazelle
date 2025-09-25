#!/usr/bin/env bash
set -euo pipefail

# # Ensure Go-based yq v4+ is installed
# if ! command -v yq &>/dev/null || ! yq --version | grep -q 'mikefarah'; then
#     echo "Installing Go-based yq..."
#     sudo wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/local/bin/yq
#     sudo chmod +x /usr/local/bin/yq
# fi

# === CONFIGURATION ===
INFRA_REPO_URL="https://github.com/opencrvs/infrastructure.git"
INFRA_DIR="infrastructure"
HOSTNAME="opencrvs.mifos.gazelle.test"
TRAEFIK_HOSTNAME="traefik.opencrvs.mifos.gazelle.test"
OPENCRVS_VERSION="v1.8.1"

# --- STEP 0: Cleanup previous OpenCRVS installation ---
echo "[0/7] Cleaning up previous OpenCRVS deployment..."

for ns in traefik opencrvs-deps-dev opencrvs-dev; do
    kubectl delete ns "$ns" --ignore-not-found
    echo "  Namespace $ns deleted."
done

echo "Cleanup complete."
echo "=== Starting OpenCRVS installation automation ==="

# --- STEP 1: Clone infrastructure repo ---
echo "[1/7] Cloning OpenCRVS infrastructure repository..."
if [ -d "$INFRA_DIR" ]; then
    echo "Infrastructure repo already exists. Deleting exiting... and Re-Cloning the updated version"
    rm -rf "$INFRA_DIR"
    git clone "$INFRA_REPO_URL"
    # git -C "$INFRA_DIR" pull
else
    git clone "$INFRA_REPO_URL"
fi


# --- STEP 2: Update hostnames and other values ---
echo "[2/7] Updating hostnames and other values..."

# Define file paths
OPENCRVS_SERVICES="$INFRA_DIR/examples/localhost/opencrvs-services/values-dev.yaml"
DEPENDENCIES="$INFRA_DIR/examples/localhost/dependencies/values-dev.yaml"

# Update hostname in both files
yq -i ".hostname = \"$HOSTNAME\"" "$OPENCRVS_SERVICES"
yq -i ".hostname = \"$HOSTNAME\"" "$DEPENDENCIES"

# Update additional fields only in opencrvs-services
yq -i '
  .service_type = "ClusterIP" |
  .client.port = 80 |
  .login.port = 80 |
  .auth.env.COUNTRY_CONFIG_URL = "http://countryconfig.opencrvs-dev.svc.cluster.local:3040"
' "$OPENCRVS_SERVICES"

echo "files updated: $OPENCRVS_SERVICES and $DEPENDENCIES"
echo "Hostnames updated in both files. service_type and ports updated in opencrvs-services only."


# --- STEP 3: Install Traefik Ingress Controller ---
echo "[3/7] Installing Traefik Ingress Controller..."
helm repo add traefik https://traefik.github.io/charts
helm repo update
helm upgrade --install traefik traefik/traefik \
    --namespace traefik \
    --create-namespace \
    -f "$INFRA_DIR/examples/localhost/traefik/values.yaml"


# --- STEP 4: Install OpenCRVS Dependencies ---
echo "[4/7] Installing OpenCRVS Dependencies..."
helm upgrade opencrvs-deps oci://ghcr.io/opencrvs/opencrvs-dependencies-chart \
    --install \
    --namespace "opencrvs-deps-dev" \
    -f "$INFRA_DIR/examples/localhost/dependencies/values-dev.yaml" \
    --create-namespace


# --- STEP 5: Install OpenCRVS Services ---
echo "[5/7] Installing OpenCRVS Services..."
helm upgrade opencrvs oci://ghcr.io/opencrvs/opencrvs-services \
    --install \
    --namespace "opencrvs-dev" \
    -f "$INFRA_DIR/examples/localhost/opencrvs-services/values-dev.yaml" \
    --create-namespace \
    --set image.tag="$OPENCRVS_VERSION" \
    --set countryconfig.image.tag="$OPENCRVS_VERSION"


# --- STEP 6: Seed Environment Data ---
echo "[6/7] Seeding environment data..."
helm template -f "$INFRA_DIR/examples/localhost/opencrvs-services/values-dev.yaml" \
    --namespace "opencrvs-dev" \
    --set image.tag="$OPENCRVS_VERSION" \
    --set data_seed.enabled=true \
    -s templates/data-seed-job.yaml \
    oci://ghcr.io/opencrvs/opencrvs-services | kubectl apply -n opencrvs-dev -f -


# --- STEP 7: Final Step Setup ---
echo "[7/7] === OpenCRVS deployment complete ==="
echo ""
echo ""
echo "Example login credentials: "
echo "Login URL: http://login.opencrvs.mifos.gazelle.test/"
echo "To login as a Field Worker (Social Worker):"
echo "Username: k.bwalya"
echo "Password: test"
echo "Code: 000000"
echo ""

echo "To login as a Local Registrar:"
echo "Username: k.mweene"
echo "Password: test"
echo "Code: 000000"
echo ""

echo "Reference: https://github.com/opencrvs/opencrvs-countryconfig/blob/develop/src/data-seeding/employees/source/default-employees.csv"

# --- Add entries to /etc/hosts ---
echo "Add entries to /etc/hosts on the host machine:"
echo "
    4.155.216.167   opencrvs.mifos.gazelle.test
                    auth.opencrvs.mifos.gazelle.test
                    register.opencrvs.mifos.gazelle.test
                    config.opencrvs.mifos.gazelle.test
                    countryconfig.opencrvs.mifos.gazelle.test
                    metabase.opencrvs.mifos.gazelle.test
                    events.opencrvs.mifos.gazelle.test
                    gateway.opencrvs.mifos.gazelle.test
                    login.opencrvs.mifos.gazelle.test
                    webhooks.opencrvs.mifos.gazelle.test
                    minio.opencrvs.mifos.gazelle.test
    "