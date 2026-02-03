#!/usr/bin/env bash
# core.sh -- functions that are core to the deployer script(s)

#------------------------------------------------------
# Function : is_app_running
# Description: Check if the application is deployed by 
# verifying the number of "Ready" pods in a namespace
#------------------------------------------------------
function is_app_running() {
    local namespace="$1"
    local min_pods=2
    
    # Validate inputs
    [[ -z "$namespace" ]] && {
        logWithVerboseCheck "$debug" error "Namespace missing: namespace=$namespace"
        return 1
    }
    
    # Debug: Print namespace and minimum pods
    logWithVerboseCheck "$debug" debug "Checking for at least $min_pods pods, all Ready, in namespace $namespace"
    
    # Check if namespace exists
    local namespace_check
    namespace_check=$(run_as_user "kubectl get namespace \"$namespace\" -o name")
    local namespace_exit_code=$?
    logWithVerboseCheck "$debug" debug "Namespace check exit code: $namespace_exit_code, output: [$namespace_check]"
    [[ $namespace_exit_code -ne 0 ]] && {
        logWithVerboseCheck "$debug" error "Namespace $namespace does not exist or is inaccessible"
        return 1
    }
    
    local raw_output
    raw_output=$(run_as_user "kubectl get pod -n \"$namespace\" --no-headers -o wide")
    local exit_code=$?

    # Strip any lines that look like debug/command echo (e.g., "DEBUG Running as ...")
    pod_list=$(echo "$raw_output" | grep -v 'DEBUG' | grep -v "kubectl" || true)
    
    # Count total pods and ready pods
    total_pods=$(echo "$pod_list" | grep -c '^')
    # Modified to count pods where READY column shows all containers ready (e.g., 1/1, 2/2)
    # Match patterns like 1/1, 2/2, etc. where both numbers are the same and non-zero
    ready_count=$(echo "$pod_list" | awk '{split($2,a,"/"); if(a[1]==a[2] && a[1]>0) print}' | grep -c '^')

    # Debug: Print kubectl exit code, pod list, total pods, and ready count
    logWithVerboseCheck "$debug" debug "kubectl exit code: $exit_code, pod list: [$pod_list], total pods: $total_pods, ready pods: $ready_count"

    # Temporary debugging - always output for mifosx namespace
    if [[ "$namespace" == "mifosx" ]]; then
        echo "DEBUG is_app_running($namespace): total_pods=$total_pods, ready_count=$ready_count, min_pods=$min_pods" >&2
    fi
    
    # Check if command failed
    [[ $exit_code -ne 0 ]] && {
        logWithVerboseCheck "$debug" error "Failed to retrieve pods in namespace $namespace"
        return 1
    }
    
    # Check if there are enough pods and all are Ready
    if [[ $total_pods -ge $min_pods && $ready_count -ge $min_pods ]]; then
        logWithVerboseCheck "$debug" debug "Found $total_pods pods, all Ready, in namespace $namespace, meeting minimum of $min_pods"
        return 0
    else
        logWithVerboseCheck "$debug" debug "Check failed: $total_pods pods, $ready_count Ready, in namespace $namespace (requires at least $min_pods pods, all Ready)"
        return 1
    fi
} # end of is_app_running

function wait_for_pods_ready() {
    echo "    wait_for_pods_ready function is triggered"
    local namespace="$1"
    echo "    Waiting for "$namespace" to be stable..."

    if [ $? -ne 0 ]; then
      echo -e "${RED} $namespace failed to stabilize. Exiting.${RESET}"
      exit 1
    fi
    STABLE_COUNT=0
    
    while [ $STABLE_COUNT -lt 3 ]; do
      NOT_READY=$(run_as_user "kubectl get pods -n \"$namespace\" --no-headers" | awk '{split($2,a,"/"); if(a[1]!=a[2] || a[1]==0) print}')

      if [ -z "$NOT_READY" ]; then
        STABLE_COUNT=$((STABLE_COUNT + 1))
        echo "✅ All pods ready. Stable count: $STABLE_COUNT"
      else
        STABLE_COUNT=0
        echo "❌ Some pods not ready. Waiting..."
      fi
      sleep 60
    done
    echo "🎉 All pods are stable and running."
}
#------------------------------------------------------------------------------
# Function : createIngressSecret
# Description: Creates a self-signed TLS cert with multiple SANs and stores it as a Kubernetes secret.
# Parameters:
#   $1 - Namespace
#   $2 - Primary domain name (CN)
#   $3 - Secret name
#   $4 - Comma-separated SAN list (optional) - e.g. "ops.example.com,api.example.com,*.example.com"
#------------------------------------------------------------------------------
function createIngressSecret {
    local namespace="$1"
    local primary_domain="$2"
    local secret_name="$3"
    local sans="$4"
    local key_dir="$k8s_user_home/.ssh"

    mkdir -p "$key_dir"

    # Convert comma-separated SANs → OpenSSL format
    local san_config="DNS.1 = $primary_domain"
    local index=2
    if [[ -n "$sans" ]]; then
        IFS=',' read -ra san_list <<< "$sans"
        for san in "${san_list[@]}"; do
            # Trim whitespace from san
            san=$(echo "$san" | xargs)
            san_config="${san_config}"$'\n'"DNS.${index} = ${san}"
            ((index++))
        done
    fi

    echo "🔐 Creating TLS secret '$secret_name' in namespace '$namespace'"
    echo "   Primary domain (CN): $primary_domain"
    echo "   SAN list (count: $((index-1))):"
    echo "$san_config" | sed 's/^/     /'

    # Generate private key
    openssl genrsa -out "$key_dir/$primary_domain.key" 2048 >/dev/null 2>&1

    # Set proper ownership and permissions on the key
    chown "$k8s_user":"$k8s_user" "$key_dir/$primary_domain.key"
    chmod 600 "$key_dir/$primary_domain.key"

    # Generate certificate with SANs
    openssl req -x509 -new -nodes \
        -key "$key_dir/$primary_domain.key" \
        -sha256 -days 365 \
        -out "$key_dir/$primary_domain.crt" \
        -subj "/CN=$primary_domain" \
        -extensions v3_req \
        -config <(
            cat <<EOF
[req]
distinguished_name=req_distinguished_name
x509_extensions=v3_req
prompt=no

[req_distinguished_name]
CN=$primary_domain

[v3_req]
subjectAltName=@alt_names
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth

[alt_names]
${san_config}
EOF
        ) >/dev/null 2>&1

    # Set proper ownership and permissions on the certificate
    chown "$k8s_user":"$k8s_user" "$key_dir/$primary_domain.crt"
    chmod 644 "$key_dir/$primary_domain.crt"

    # Verify the certificate was created correctly
    echo "   Verifying certificate..."
    if openssl x509 -in "$key_dir/$primary_domain.crt" -noout -text | grep -q "Subject Alternative Name"; then
        echo "   ✓ Certificate created successfully with SANs:"
        openssl x509 -in "$key_dir/$primary_domain.crt" -noout -text | grep -A 20 "Subject Alternative Name" | sed -n '/Subject Alternative Name/,/X509v3/p' | head -n -1 | sed 's/^/     /'
    else
        echo "   ⚠ Warning: Certificate created but no SANs found!"
    fi

    # Create/replace TLS secret
    # Check if we're already running as k8s_user or if we need to use run_as_user
    if [ "$(whoami)" = "$k8s_user" ]; then
        # Already the correct user, run kubectl directly
        kubectl -n "$namespace" delete secret "$secret_name" --ignore-not-found >/dev/null 2>&1

        if kubectl -n "$namespace" create secret tls "$secret_name" \
            --cert="$key_dir/$primary_domain.crt" \
            --key="$key_dir/$primary_domain.key" >/dev/null 2>&1; then
            echo "   ✓ Secret '$secret_name' created in namespace '$namespace'"
        else
            echo "   ✗ Failed to create secret '$secret_name'"
            return 1
        fi
    else
        # Running as different user (e.g., root), use run_as_user wrapper
        run_as_user "kubectl -n \"$namespace\" delete secret \"$secret_name\" --ignore-not-found" >/dev/null 2>&1

        if run_as_user "kubectl -n \"$namespace\" create secret tls \"$secret_name\" --cert=\"$key_dir/$primary_domain.crt\" --key=\"$key_dir/$primary_domain.key\"" >/dev/null 2>&1; then
            echo "   ✓ Secret '$secret_name' created in namespace '$namespace'"
        else
            echo "   ✗ Failed to create secret '$secret_name'"
            return 1
        fi
    fi
}


#------------------------------------------------------------------------------
# Function : manageElasticSecrets
# Description: Creates or deletes Elasticsearch related Kubernetes secrets.
# Parameters:
#   $1 - Action: "create" or "delete"
#   $2 - Namespace where the secrets are managed
#   $3 - Directory containing the .p12 certificate file
#------------------------------------------------------------------------------
function manageElasticSecrets {
    local action="$1"
    local namespace="$2"
    local certdir="$3" # location of the .p12 and .pem files 
    local password="XVYgwycNuEygEEEI0hQF"

    # Verify input parameters
    if [ -z "$action" ] || [ -z "$namespace" ] || [ -z "$certdir" ]; then
        echo " ** Error: Missing required parameters (action, namespace, certdir)"
        return 1
    fi

    # Verify certdir exists and is readable
    if [ ! -d "$certdir" ] || [ ! -r "$certdir/elastic-certificates.p12" ]; then
        echo " ** Error: certdir $certdir does not exist or elastic-certificates.p12 is not readable"
        return 1
    fi

    # Create a temporary directory owned by k8s_user
    local temp_dir
    temp_dir=$(mktemp -d -p "/tmp" "elastic_secrets_XXXXXX") || { echo " ** Error: Failed to create temporary directory"; return 1; }
    chown "$k8s_user":"$k8s_user" "$temp_dir" || { echo " ** Error: Failed to change ownership of $temp_dir"; rm -rf "$temp_dir"; return 1; }
    chmod 700 "$temp_dir" || { echo " ** Error: Failed to set permissions on $temp_dir"; rm -rf "$temp_dir"; return 1; }

    # Check if k8s_user can access certdir
    if ! su - "$k8s_user" -c "test -r '$certdir/elastic-certificates.p12'" 2>/dev/null; then
        # Copy certificates to temp_dir
        cp "$certdir/elastic-certificates.p12" "$temp_dir/elastic-certificates.p12" || { echo " ** Error: Failed to copy certificates"; rm -rf "$temp_dir"; return 1; }
        chown "$k8s_user":"$k8s_user" "$temp_dir/elastic-certificates.p12" || { echo " ** Error: Failed to change ownership of copied certificates"; rm -rf "$temp_dir"; return 1; }
        chmod 600 "$temp_dir/elastic-certificates.p12" || { echo " ** Error: Failed to set permissions on copied certificates"; rm -rf "$temp_dir"; return 1; }
        certdir="$temp_dir"
    fi

    if [ "$action" = "create" ]; then
        # Convert certificates
        if ! openssl pkcs12 -nodes -passin pass:'' -in "$certdir/elastic-certificates.p12" -out "$temp_dir/elastic-certificate.pem" >/dev/null 2>&1; then
            echo " ** Error: Failed to convert p12 to pem"
            rm -rf "$temp_dir"
            return 1
        fi
        if ! openssl x509 -outform der -in "$temp_dir/elastic-certificate.pem" -out "$temp_dir/elastic-certificate.crt" >/dev/null 2>&1; then
            echo " ** Error: Failed to convert pem to crt"
            rm -rf "$temp_dir"
            return 1
        fi

        # Ensure generated files are owned by k8s_user
        if ! chown "$k8s_user":"$k8s_user" "$temp_dir/elastic-certificate.pem" "$temp_dir/elastic-certificate.crt"; then
            echo " ** Error: Failed to change ownership of generated certificate files"
            rm -rf "$temp_dir"
            return 1
        fi
        if ! chmod 600 "$temp_dir/elastic-certificate.pem" "$temp_dir/elastic-certificate.crt"; then
            echo " ** Error: Failed to set permissions on generated certificate files"
            rm -rf "$temp_dir"
            return 1
        fi

        # Verify k8s_user can access generated files
        if ! su - "$k8s_user" -c "test -r '$temp_dir/elastic-certificate.pem' && test -r '$temp_dir/elastic-certificate.crt'" 2>/dev/null; then
            echo " ** Error: $k8s_user cannot read generated certificate files"
            rm -rf "$temp_dir"
            return 1
        fi

        # Create secrets
        local secret_output
        secret_output=$(run_as_user "kubectl create secret generic elastic-certificates --namespace=\"$namespace\" --from-file=\"$certdir/elastic-certificates.p12\"" 2>&1)
        if [ $? -ne 0 ]; then
            echo " ** Error creating elastic-certificates secret: $secret_output"
            rm -rf "$temp_dir"
            return 1
        fi

        secret_output=$(run_as_user "kubectl create secret generic elastic-certificate-pem --namespace=\"$namespace\" --from-file=\"$temp_dir/elastic-certificate.pem\"" 2>&1)
        if [ $? -ne 0 ]; then
            echo " ** Error creating elastic-certificate-pem secret: $secret_output"
            rm -rf "$temp_dir"
            return 1
        fi

        secret_output=$(run_as_user "kubectl create secret generic elastic-certificate-crt --namespace=\"$namespace\" --from-file=\"$temp_dir/elastic-certificate.crt\"" 2>&1)
        if [ $? -ne 0 ]; then
            echo " ** Error creating elastic-certificate-crt secret: $secret_output"
            rm -rf "$temp_dir"
            return 1
        fi

        secret_output=$(run_as_user "kubectl create secret generic elastic-credentials --namespace=\"$namespace\" --from-literal=password=\"$password\" --from-literal=username=elastic" 2>&1)
        if [ $? -ne 0 ]; then
            echo " ** Error creating elastic-credentials secret: $secret_output"
            rm -rf "$temp_dir"
            return 1
        fi

        local encryptionkey="MMFI5EFpJnib4MDDbRPuJ1UNIRiHuMud_r_EfBNprx7qVRlO7R"
        secret_output=$(run_as_user "kubectl create secret generic kibana --namespace=\"$namespace\" --from-literal=encryptionkey=$encryptionkey" 2>&1)
        if [ $? -ne 0 ]; then
            echo " ** Error creating kibana secret: $secret_output"
            rm -rf "$temp_dir"
            return 1
        fi

        rm -rf "$temp_dir"  # Clean up on success

    elif [ "$action" = "delete" ]; then
        local secrets=("elastic-certificates" "elastic-certificate-pem" "elastic-certificate-crt" "elastic-credentials" "kibana")
        local all_success=true

        for secret in "${secrets[@]}"; do
            local delete_output
            delete_output=$(run_as_user "kubectl delete secret $secret --namespace=\"$namespace\" --ignore-not-found=true" 2>&1)
            if [ $? -ne 0 ] && [[ ! "$delete_output" =~ "not found" ]]; then
                echo " ** Warning: Failed to delete secret $secret: $delete_output"
                all_success=false
            fi
            # echo "DEBUG removed secret $secret in namespace $namespace ok" 
        done

        if [ "$all_success" = false ]; then
            rm -rf "$temp_dir"
            return 1
        fi
        rm -rf "$temp_dir"

    else
        echo " ** Error: Invalid action. Use 'create' or 'delete'."
        rm -rf "$temp_dir"
        return 1
    fi
}

#------------------------------------------------------------------------------
# Function to update FQDN in YAML files (Helm values or Kubernetes manifests)
# Example usage:
#   update_fqdn "values.yaml" "hostname.mifos.gazelle.test" "hostname.newdomain.com"
# Note: the k8s .svc.cluster.local addresses are not changed
#------------------------------------------------------------------------------
update_fqdn() {
  local file="$1"
  local old_fqdn="$2"
  local new_fqdn="$3"

  if [[ -z "$file" || -z "$old_fqdn" || -z "$new_fqdn" ]]; then
    echo "Usage: update_fqdn <file> <old_fqdn> <new_fqdn>"
    return 1
  fi

  if [[ ! -f "$file" ]]; then
    echo "Error: File not found: $file"
    return 1
  fi

#   echo "Processing: $file"
#   echo "Replacing:"
#   echo "  - $old_fqdn  →  $new_fqdn"
#   echo "  - *.local → $new_fqdn (excluding *.svc.cluster.local)"
#   echo

  perl -pi -e '
    next if /\.svc\.cluster\.local/;

    s/\b([a-zA-Z0-9.-]+)\.'"$old_fqdn"'\b/$1.'"$new_fqdn"'/g;
  ' "$file"

}

# update_fqdn() {
#     local file="$1"
#     local old_fqdn="$2"
#     local new_fqdn="$3"
    
#     [ ! -f "$file" ] && echo "Error: File not found" && return 1
#     perl -pi -e "s/\\b([a-zA-Z0-9.-]+)\\.$old_fqdn\\b/\$1.$new_fqdn/g" "$file"

# }

#------------------------------------------------------------------------------
# Function to update all YAML files in a directory structure
# Example:
#   update_fqdn_batch "mydir" "mifos.gazelle.test" "newdomain.com"
#------------------------------------------------------------------------------
update_fqdn_batch() {
    local directory="$1"
    local old_fqdn="$2"
    local new_fqdn="$3"
    
    find "$directory" -type f \( -name "*.yaml" -o -name "*.yml" \) | while read -r file; do
        #echo "Processing: $file"
        update_fqdn "$file" "$old_fqdn" "$new_fqdn"
        #echo "---"
    done
}

#------------------------------------------------------------------------------
# Standalone function to ensure Helm dependencies are up to date
# Can be called from any function that needs to manage Helm chart dependencies
# Parameters:
#   $1 - Path to the Helm chart directory
#------------------------------------------------------------------------------
function ensure_helm_dependencies() {
  local chartPath=$1
  local chartName=$(basename "$chartPath")
  
  echo "    ensuring dependencies for $chartName chart"
  
  if [[ -f "$chartPath/Chart.lock" && -s "$chartPath/Chart.lock" ]]; then
    # Count entries in Chart.lock and compare with .tgz files in charts/
    local expected=$(grep -c "name:" "$chartPath/Chart.lock")
    local actual=$(find "$chartPath/charts" -maxdepth 1 -name '*.tgz' 2>/dev/null | wc -l)
    
    if [[ $actual -ge $expected && $expected -gt 0 ]]; then
      run_as_user "cd $chartPath && helm dep build" >> /dev/null 2>&1
    else
      run_as_user "cd $chartPath && helm dep update" >> /dev/null 2>&1
    fi
  else
    run_as_user "cd $chartPath && helm dep update" >> /dev/null 2>&1
  fi
}
