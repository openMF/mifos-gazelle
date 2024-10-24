#!/bin/bash
# utility script to show how to create self-signed 
# TLS secrets for kubernetes ingress
# 

set -e

# Function to print usage information
usage() {
    echo "Usage: $0 [-d domain_name] [-s secret_name] [-n namespace]"
    echo "  -d domain_name   Specify the domain name (required)"
    echo "  -s secret_name   Specify the secret name (default: tls-secret)"
    echo "  -n namespace     Specify the namespace (default: default)"
    exit 1
}

# Parse command-line options
while getopts ":d:s:n:" opt; do
    case "$opt" in
        d) domain_name="$OPTARG" ;;
        s) secret_name="$OPTARG" ;;
        n) namespace="$OPTARG" ;;
        \?) usage ;;
    esac
done

# Check if domain name is provided
if [[ -z "$domain_name" ]]; then
    echo "Error: Domain name is required. Use -d option."
    usage
else 
    echo "Using domain name : $domain_name"
fi


# Default values
secret_name=${secret_name:-"tls-secret"}
namespace=${namespace:-"default"}
key_dir="$HOME/.ssh"

# Generate private key
openssl genrsa -out "$key_dir/$domain_name.key" 2048
domain_name=${domain_name:-"your_default_domain"}

# Generate self-signed certificate

openssl req -x509 -new -nodes -key "$key_dir/$domain_name.key" -sha256 -days 365 -out "$key_dir/$domain_name.crt" -subj "/CN=$domain_name" -extensions v3_req -config <(
cat <<EOF
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_req
prompt = no
[req_distinguished_name]
CN = $domain_name
[v3_req]
subjectAltName = @alt_names
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
[alt_names]
DNS.1 = $domain_name
EOF
)

# Verify the certificate
openssl x509 -in "$key_dir/$domain_name.crt" -noout -text

# Create the Kubernetes TLS secret
kubectl create secret tls "$secret_name" --cert="$key_dir/$domain_name.crt" --key="$key_dir/$domain_name.key" -n "$namespace"

echo "Self-signed certificate and secret '$secret_name' created successfully in namespace '$namespace'."