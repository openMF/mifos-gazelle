#!/bin/bash

# utility script to create TLS secrets for Kubernetes ingress using Let's Encrypt

set -e

# Function to print usage information
usage() {
    echo "Usage: $0 [-d domain_name] [-s secret_name] [-n namespace] [-e email]"
    echo "  -d domain_name   Specify the domain name (required)"
    echo "  -s secret_name   Specify the secret name (default: tls-secret)"
    echo "  -n namespace     Specify the namespace (default: default)"
    echo "  -e email        Specify your email address for Let's Encrypt validation"
    exit 1
}

# Parse command-line options
while getopts ":d:s:n:e:" opt; do
    case "$opt" in
        d) domain_name="$OPTARG" ;;
        s) secret_name="$OPTARG" ;;
        n) namespace="$OPTARG" ;;
        e) email="$OPTARG" ;;
        \?) usage ;;
    esac
done

# Check if required options are provided
if [[ -z "$domain_name" || -z "$email" ]]; then
    echo "Error: Domain name and email address are required. Use -d and -e options."
    usage
fi

# Default values
secret_name=${secret_name:-"tls-secret"}
namespace=${namespace:-"default"}

# Create a temporary directory for certificates
tmp_dir=$(mktemp -d)
echo "tmp dir is $tmp_dir"

# Generate a CSR (Certificate Signing Request)
openssl req -newkey rsa:2048 -nodes -keyout "$tmp_dir/domain.key" -out "$tmp_dir/domain.csr" -subj "/CN=$domain_name"

# Obtain the Let's Encrypt certificate
#certbot certonly --agree-tos --email "$email" -d "$domain_name" -n --manual --preferred-challenges http --manual-auth-hook "echo 'Press Enter to continue:' && read" --manual-cleanup-hook "rm -rf $tmp_dir/certbot" -o "$tmp_dir"
#certbot certonly --agree-tos --email "$email" -d "$domain_name" -n --manual --preferred-challenges http --manual-auth-hook "echo 'Press Enter to continue:' && read" --manual-cleanup-hook "rm -rf $tmp_dir/certbot" -d "$tmp_dir"
#--config-dir "/etc/letsencrypt" --work-dir "/var/lib/letsencrypt" --logs-dir "/var/log/letsencrypt"

sudo certbot certonly --agree-tos --email "$email" -d "$domain_name" -n --manual \
       --preferred-challenges http --manual-auth-hook "echo 'Press Enter to continue:' && read" \
       --manual-cleanup-hook "rm -rf $tmp_dir/certbot" \
       --config-dir "/etc/letsencrypt" \
       --work-dir "/var/lib/letsencrypt" \
       --logs-dir "/var/log/letsencrypt"

# Verify the certificate
openssl x509 -in "$tmp_dir/cert.pem" -noout -text

# Create the Kubernetes TLS secret
kubectl create secret tls "$secret_name" --cert="$tmp_dir/cert.pem" --key="$tmp_dir/privkey.pem" -n "$namespace"

echo "Let's Encrypt certificate and secret '$secret_name' created successfully in namespace '$namespace'."

# Clean up the temporary directory
rm -rf "$tmp_dir"