#!/bin/sh
# /vault/custom-entrypoint.sh

set -e

# Set variables for path prefix
export VAULT_UI_PATH_PREFIX="/vault"
export VAULT_API_PATH_PREFIX="/vault"
export VAULT_CLUSTER_ADDR="https://vault-server:8201"
export VAULT_REDIRECT_ADDR="https://localhost/vault"

# Read variables from localhost.env file
if [ -f "/vault/.env" ]; then
  export $(grep -v '^#' /vault/localhost.env | xargs)
fi

UNSEAL_KEYS_FILE="/vault/keys/unseal-keys.json"
USER_INFO_FILE="/vault/keys/user-info.json"
CERT_DIR="/vault/keys"
CERT_FILE="$CERT_DIR/vault.crt"
KEY_FILE="$CERT_DIR/vault.key"

# Function to generate a self-signed certificate
generate_self_signed_cert() {
  echo "Generating self-signed SSL certificate..."
  mkdir -p "$CERT_DIR"
  openssl req -new -newkey rsa:2048 -days 365 -nodes -x509 \
    -subj "/C=RU/ST=YourRegion/L=YourCity/O=bit.dive/OU=YourDepartment/CN=${SERVER_IP}" \
    -keyout "$KEY_FILE" \
    -out "$CERT_FILE" \
    -addext "subjectAltName = DNS:keycloak"
  echo "Self-signed certificate and key have been generated."
}

# Check if certificate and key exist
if [ ! -f "$CERT_FILE" ] || [ ! -f "$KEY_FILE" ]; then
  echo "SSL certificate or key not found. Generating self-signed certificates..."
  generate_self_signed_cert
else
  echo "SSL certificate and key found."
fi

# Start Vault server in background
vault server -config=/vault/config/config.hcl &

# Wait for Vault server to start
echo "Waiting for Vault server to start..."
while ! nc -z localhost 8200; do
  sleep 0.1
done
echo "Vault server started."

# Run Vault initialization script
/vault/scripts/vault-init.sh

# Infinite loop to keep the container running
tail -f /dev/null
