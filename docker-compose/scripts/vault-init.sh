#!/bin/sh
# /vault/scripts/vault-init.sh

set -e

# Read variables from localhost.env file
if [ -f "/vault/.env" ]; then
  # Create a temporary file without extra characters
  sed 's/\r$//' /vault/.env | sed '/^\s*$/d' > /tmp/.env.cleaned

  # Remove extra spaces and line breaks inside values
  sed -i 's/^[ \t]*//;s/[ \t]*$//' /tmp/.env.cleaned

  # Load variables with interpolation
  set -a
  . /tmp/.env.cleaned
  set +a

  # Remove temporary file
  rm /tmp/.env.cleaned
fi

# Verify that variables are set


UNSEAL_KEYS_FILE="/vault/keys/unseal-keys.json"
CERT_DIR="/vault/keys"
CERT_FILE="$CERT_DIR/vault.crt"
KEY_FILE="$CERT_DIR/vault.key"
USER_INFO_FILE="/vault/keys/user-info.json"

# Function to generate a self-signed certificate
generate_self_signed_cert() {
  echo "Generating self-signed SSL certificate..."
  mkdir -p "$CERT_DIR"
  openssl req -new -newkey rsa:2048 -days 365 -nodes -x509 \
    -subj "/C=RU/ST=YourRegion/L=YourCity/O=YourOrganization/OU=YourDepartment/CN=${SERVER_IP}" \
    -keyout "$KEY_FILE" \
    -out "$CERT_FILE"
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

# Function to unseal Vault
unseal_vault() {
  echo "Unsealing Vault with key: $1"
  vault operator unseal "$1"
  echo "Unseal key applied."
}

# Check if Vault is initialized
init_status=$(vault status -format=json | jq -r '.initialized')

if [ "$init_status" = "true" ]; then
  echo "Vault is already initialized. Proceeding to unseal."

  # Check if unseal keys file exists
  if [ -f "$UNSEAL_KEYS_FILE" ]; then
    # Read unseal keys from file
    UNSEAL_KEY_1=$(jq -r '.unseal_keys_b64[0]' "$UNSEAL_KEYS_FILE")
    UNSEAL_KEY_2=$(jq -r '.unseal_keys_b64[1]' "$UNSEAL_KEYS_FILE")
    UNSEAL_KEY_3=$(jq -r '.unseal_keys_b64[2]' "$UNSEAL_KEYS_FILE")

    # Unseal Vault
    unseal_vault "$UNSEAL_KEY_1"
    unseal_vault "$UNSEAL_KEY_2"
    unseal_vault "$UNSEAL_KEY_3"
  else
    echo "Error: Unseal keys file not found. Unable to unseal Vault."
    exit 1
  fi
else
  echo "Initializing Vault..."

  # Initialize Vault and save unseal keys and root token
  init_output=$(vault operator init -format=json -key-shares=5 -key-threshold=3)

  # Check if initialization was successful
  if echo "$init_output" | jq -e . >/dev/null 2>&1; then
    echo "Vault successfully initialized."
  else
    echo "Error during Vault initialization:"
    echo "$init_output"
    exit 1
  fi

  # Save unseal keys and root token to file
  mkdir -p "$(dirname "$UNSEAL_KEYS_FILE")"
  echo "$init_output" > "$UNSEAL_KEYS_FILE"
  chmod 600 "$UNSEAL_KEYS_FILE"

  # Extract unseal keys
  UNSEAL_KEY_1=$(echo "$init_output" | jq -r '.unseal_keys_b64[0]')
  UNSEAL_KEY_2=$(echo "$init_output" | jq -r '.unseal_keys_b64[1]')
  UNSEAL_KEY_3=$(echo "$init_output" | jq -r '.unseal_keys_b64[2]')

  # Unseal Vault
  unseal_vault "$UNSEAL_KEY_1"
  unseal_vault "$UNSEAL_KEY_2"
  unseal_vault "$UNSEAL_KEY_3"

  echo "Vault is unsealed and ready to use."
fi

# Export VAULT_TOKEN for subsequent commands
export VAULT_TOKEN=$(jq -r '.root_token' "$UNSEAL_KEYS_FILE")

VAULT_ADDR=${VAULT_ADDR}
CONFIG_FILE="/vault/scripts/certificates-config.yaml"
TEMP_DIR="/tmp/certs"
SSL_BASE_DIR="/vault/ssl"

# Function to check required tools
check_requirements() {
    command -v vault >/dev/null 2>&1 || { echo "vault is required but not installed."; exit 1; }
    command -v yq >/dev/null 2>&1 || { echo "yq is required but not installed."; exit 1; }
    command -v jq >/dev/null 2>&1 || { echo "jq is required but not installed."; exit 1; }
}

create_readonly_policy() {
  if ! vault policy list | grep -qw "readonly-params"; then
    echo "Creating readonly-params policy..."
    cat >/tmp/readonly-params.hcl <<'EOF'
# read exported Transit keys
path "transit/export/encryption-key/encryption-key" { capabilities = ["read"] }
path "transit/export/signing-key/signing-key"       { capabilities = ["read"] }
# (add other read paths as needed)
EOF
    vault policy write readonly-params /tmp/readonly-params.hcl
    rm /tmp/readonly-params.hcl
  else
    echo "Policy readonly-params already exists."
  fi
}

create_readonly_token_role() {
  if ! vault read auth/token/roles/readonly-infinite >/dev/null 2>&1; then
    echo "Creating token-role readonly-infinite (non-expiring tokens)..."
    vault write auth/token/roles/readonly-infinite \
         allowed_policies="readonly-params" \
         orphan=true                \
         period=0                   \
         token_explicit_max_ttl=0
  else
    echo "token-role readonly-infinite already exists."
  fi
}

# Function to create a directory if it does not exist
ensure_directory() {
    local dir=$1
    mkdir -p "$dir"
    chmod 750 "$dir"
}

# Function to check the validity of an existing certificate
is_cert_valid() {
    local cert_path=$1
    if [ ! -f "$cert_path" ]; then
        return 1
    fi

    # Get certificate expiration date in epoch format
    expiry_date=$(openssl x509 -enddate -noout -in "$cert_path" | cut -d= -f2)
    expiry_epoch=$(date -d "$expiry_date" +%s)
    current_epoch=$(date +%s)
    days_until_expiry=$(( (expiry_epoch - current_epoch) / 86400 ))

    if [ "$days_until_expiry" -lt 30 ]; then
        return 1
    else
        return 0
    fi
}

# Function to generate a certificate for a service
generate_certificate() {
    local service=$1
    local config=$2

    echo "Generating certificate for $service..."

    # Extract values from configuration
    local common_name=$(echo "$config" | yq eval ".services.$service.common_name" -)
    local cert_path=$(echo "$config" | yq eval ".services.$service.cert_path" -)
    local cert_file=$(echo "$config" | yq eval ".services.$service.cert_file" -)
    local key_file=$(echo "$config" | yq eval ".services.$service.key_file" -)
    local ca_file=$(echo "$config" | yq eval ".services.$service.ca_file" -)
    local ttl=$(echo "$config" | yq eval ".services.$service.ttl" -)
    local keystore_password=$(echo "$config" | yq eval ".services.$service.keystore_password" -)
    local truststore_password=$(echo "$config" | yq eval ".services.$service.truststore_password" -)

    # Password presence flags
    local has_keystore_password=false
    local has_truststore_password=false
    [ -n "$keystore_password" ]    && has_keystore_password=true
    [ -n "$truststore_password" ]  && has_truststore_password=true

    # alt_names as CSV
    local alt_names
    alt_names=$(echo "$config" | yq eval ".services.$service.alt_names[]" - | paste -sd ',' -)

    # Prepare directories
    local temp_service_dir="$TEMP_DIR/$service"
    ensure_directory "$temp_service_dir"
    local final_dir="$SSL_BASE_DIR/$service"
    ensure_directory "$final_dir"

    # If certificates already exist — skip
    if [[ -f "$final_dir/$cert_file" && -f "$final_dir/$key_file" && -f "$final_dir/$ca_file" ]]; then
        echo "Certificate for $service already exists in $final_dir, skipping generation."
        return 0
    fi

    # Generate via Vault PKI
    vault write -format=json pki/issue/bitdive \
        common_name="$common_name" \
        alt_names="$alt_names" \
        ttl="$ttl" > "$temp_service_dir/cert.json"

    # Extract to files
    jq -r '.data.certificate' "$temp_service_dir/cert.json" > "$temp_service_dir/$cert_file"
    jq -r '.data.private_key' "$temp_service_dir/cert.json" > "$temp_service_dir/$key_file"
    jq -r '.data.issuing_ca'  "$temp_service_dir/cert.json" > "$temp_service_dir/$ca_file"

    # Copy to final directory
    cp "$temp_service_dir/$cert_file" "$final_dir/"
    cp "$temp_service_dir/$key_file"  "$final_dir/"
    cp "$temp_service_dir/$ca_file"   "$final_dir/"

    # Set permissions
    chmod 600 "$final_dir/$key_file"
    chmod 644 "$final_dir/$cert_file" "$final_dir/$ca_file"
    chmod 755 "$final_dir"

    # Create keystore/truststore JKS for Keycloak
    if [[ "$service" == "postgres-client-keycloak" || "$service" == "keycloak-https" ]]; then
        echo "Creating keystore.jks and truststore.jks for $service..."

        # --- keystore.jks ---
        if $has_keystore_password; then
            local p12_file="$final_dir/$service.p12"
            openssl pkcs12 -export \
                -inkey "$final_dir/$key_file" \
                -in    "$final_dir/$cert_file" \
                -certfile "$final_dir/$ca_file" \
                -out   "$p12_file" \
                -name  "$service" \
                -password pass:"$keystore_password"

            keytool -importkeystore -noprompt \
                -srckeystore "$p12_file" -srcstoretype PKCS12 -srcstorepass "$keystore_password" \
                -destkeystore "$final_dir/keystore.jks" -deststorepass "$keystore_password" \
                -alias "$service"
            rm -f "$p12_file"
            chmod 644 "$final_dir/keystore.jks"
            echo "keystore.jks created: $final_dir/keystore.jks"
        fi

        # --- truststore.jks ---
        if $has_truststore_password; then
            local trust_jks="$final_dir/truststore.jks"
            keytool -importcert -noprompt \
                -alias "$service-ca" \
                -file  "$final_dir/$ca_file" \
                -keystore "$trust_jks" \
                -storepass "$truststore_password"
            chmod 644 "$trust_jks"
            echo "truststore.jks created: $trust_jks"
        fi
    fi

    # *** SMTP truststore creation block (Zoho) ***
    if [[ "$service" == "smtp-zoho" ]] && $has_truststore_password; then
        local tmp_pem="$final_dir/smtp-zoho.pem"

        # Download all certificates from the Zoho server and save to smtp-zoho.pem
        openssl s_client -connect smtp.zoho.eu:465 -showcerts </dev/null \
          | awk '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/' \
          > "$tmp_pem"

        # Verify the file is not empty
        if [[ -s "$tmp_pem" ]]; then
          echo "File smtp-zoho.pem successfully created and contains certificates."
        else
          echo "Error: smtp-zoho.pem is empty or was not created."
        fi


    fi

    echo "Certificates for $service generated in $final_dir"
}

# Function to monitor certificates and renew them when needed
monitor_certificates() {
    local config=$1

    while true; do
        echo "Checking certificates for renewal..."
        local services=$(echo "$config" | yq eval '.services | keys | .[]' -)

        for service in $services; do
            local cert_file="$SSL_BASE_DIR/$service/$(echo "$config" | yq eval ".services.$service.cert_file" -)"

            if [ -f "$cert_file" ]; then
                # Check certificate expiration date
                expiry_date=$(openssl x509 -enddate -noout -in "$cert_file" | cut -d= -f2)
                expiry_epoch=$(date -d "$expiry_date" +%s)
                current_epoch=$(date +%s)
                days_until_expiry=$(( (expiry_epoch - current_epoch) / 86400 ))

                if [ "$days_until_expiry" -lt 30 ]; then
                    echo "Certificate for $service expires in $days_until_expiry days. Renewing..."
                    generate_certificate "$service" "$config"
                else
                    echo "Certificate for $service is valid for $days_until_expiry more days."
                fi
            else
                echo "Certificate for $service not found. Generating new certificate..."
                generate_certificate "$service" "$config"
            fi
        done

        # Wait 24 hours before the next check
        sleep 86400
    done
}

# Function to create pki-user policy
create_pki_policy() {
    if ! vault policy list | grep -qw "pki-user"; then
        echo "Creating pki-user policy..."
        cat <<EOF > /tmp/pki-user.hcl
path "pki/issue/*" {
  capabilities = ["update"]
}

path "pki/cert/ca" {
  capabilities = ["read"]
}

path "pki/cert/*" {
  capabilities = ["read"]
}
EOF
        vault policy write pki-user /tmp/pki-user.hcl
        echo "Policy pki-user created."
    else
        echo "Policy pki-user already exists."
    fi
}

create_token_issuer_policy() {
  if ! vault policy list | grep -qw "token-issuer"; then
    echo "Creating token-issuer policy..."
    cat >/tmp/token-issuer.hcl <<'EOF'
#  ==========  AppRole  ==========
path "auth/approle/role/readonly-role/role-id"   { capabilities = ["read"] }
path "auth/approle/role/readonly-role/secret-id" { capabilities = ["update"] }

#  ==========  service tokens  ==========
path "auth/token/create"                         { capabilities = ["create", "update"] }
path "auth/token/create/readonly-infinite"       { capabilities = ["create", "update"] }
EOF
    vault policy write token-issuer /tmp/token-issuer.hcl
    rm /tmp/token-issuer.hcl
  else
    echo "Policy token-issuer already exists."
  fi
}

# Function to create transit-user policy
create_transit_policy() {
    if ! vault policy list | grep -qw "transit-user"; then
        echo "Creating transit-user policy..."
        cat <<EOF > /tmp/transit-user.hcl
path "transit/encrypt/encryption-key" {
  capabilities = ["update","read"]
}

path "transit/decrypt/encryption-key" {
  capabilities = ["update","read"]
}

path "transit/sign/signing-key" {
  capabilities = ["update","read"]
}

path "transit/verify/signing-key" {
  capabilities = ["update","read"]
}

path "transit/export/encryption-key/encryption-key" {
  capabilities = ["read"]
}

path "transit/export/signing-key/signing-key" {
  capabilities = ["read"]
}
path "/transit/keys/signing-key" {
  capabilities = ["read"]
}



EOF
        vault policy write transit-user /tmp/transit-user.hcl
        echo "Policy transit-user created."
    else
        echo "Policy transit-user already exists."
    fi
}

# Function to create kv-user policy
create_kv_policy() {
    if ! vault policy list | grep -qw "kv-user"; then
        echo "Creating kv-user policy..."
        cat <<EOF > /tmp/kv-user.hcl
path "secret/data-encryption-key" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "secret/metadata/data-encryption-key" {
  capabilities = ["list"]
}

# Allow creating, reading, and deleting entries
path "secret/data/credentials-bit-dive/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# Allow viewing metadata
path "secret/metadata/credentials-bit-dive/*" {
  capabilities = ["list"]
}
EOF
        vault policy write kv-user /tmp/kv-user.hcl
        echo "Policy kv-user created."
    else
        echo "Policy kv-user already exists."
    fi
}

# Function to configure Auth, Policies, and Users in Vault
configure_vault_auth_policies_users() {
    # Enable userpass authentication method if not already enabled
    if ! vault auth list -format=json | jq -e '.["userpass/"]' >/dev/null; then
        echo "Enabling userpass authentication method..."
        vault auth enable userpass
    else
        echo "Userpass authentication method is already enabled."
    fi

    create_readonly_policy
    create_readonly_token_role
    create_token_issuer_policy

    # Create policies
    create_pki_policy
    create_transit_policy
    create_kv_policy

    # Check and create user
    if [ ! -f "$USER_INFO_FILE" ]; then
        echo "Creating user..."
        USERNAME="${VAULT_LOGIN}"
        PASSWORD="${VAULT_PASSWORD}"

        vault write auth/userpass/users/$USERNAME \
            password="$PASSWORD" \
            policies="pki-user,transit-user,kv-user,token-issuer"

        # Save user information
cat <<EOF > "$USER_INFO_FILE"
{
  "username": "$USERNAME",
  "password": "$PASSWORD",
  "policies": ["pki-user", "transit-user", "kv-user", "token-issuer"]
}
EOF
        echo "User $USERNAME created with policies pki-user, transit-user, kv-user."
    else
        echo "User already exists. User information file found."
    fi
}

# Function to configure Secret Engines (PKI and Transit) in Vault
configure_vault_secrets_engines() {
    # Enable PKI Secret Engine if not already enabled
    if ! vault secrets list -format=json | jq -e '.["pki/"]' >/dev/null; then
        echo "Enabling PKI Secret Engine..."
        vault secrets enable pki
    else
        echo "PKI Secret Engine is already enabled."
    fi

    # Check and generate root certificate
    if ! vault read pki/config/ca >/dev/null 2>&1; then
        echo "Generating root certificate..."
        vault write pki/root/generate/internal \
            common_name="bitdive" \
            ttl="876000h" \
            private_key_format="pkcs8"
    else
        echo "Root certificate already exists."
    fi

    # Configure URLs for PKI
    current_issuing_cert=$(vault read -field=issuing_certificates pki/config/urls 2>/dev/null || echo "")
    desired_issuing_cert="$VAULT_ADDR/v1/pki/ca"
    current_crl_dp=$(vault read -field=crl_distribution_points pki/config/urls 2>/dev/null || echo "")
    desired_crl_dp="$VAULT_ADDR/v1/pki/crl"

    if [ "$current_issuing_cert" != "$desired_issuing_cert" ] || [ "$current_crl_dp" != "$desired_crl_dp" ]; then
        echo "Configuring URLs for PKI..."
        vault write pki/config/urls \
            issuing_certificates="$desired_issuing_cert" \
            crl_distribution_points="$desired_crl_dp"
    else
        echo "PKI URLs are already configured."
    fi

    # Check and create 'bitdive' role
    if ! vault read pki/roles/bitdive >/dev/null 2>&1; then
        echo "Creating 'bitdive' role..."
        vault write pki/roles/bitdive \
            allowed_domains="bitdive.local,localhost" \
            allow_subdomains=true \
            allow_glob_domains=true \
            allow_any_name=true \
            enforce_hostnames=false \
            max_ttl="875999h"
    else
        echo "Role 'bitdive' already exists."
    fi

    # Enable Transit Secret Engine if not already enabled
    if ! vault secrets list -format=json | jq -e '.["transit/"]' >/dev/null; then
        echo "Enabling Transit Secret Engine..."
        vault secrets enable transit
    else
        echo "Transit Secret Engine is already enabled."
    fi

    # Check and create keys for Transit
    if ! vault read transit/keys/encryption-key >/dev/null 2>&1; then
        echo "Creating 'encryption-key' for Transit..."
        vault write -f transit/keys/encryption-key type=aes256-gcm96 exportable=true auto_rotate_period=24h
    else
        echo "'encryption-key' for Transit already exists."
    fi

    if ! vault read transit/keys/signing-key >/dev/null 2>&1; then
        echo "Creating 'signing-key' for Transit..."
        vault write -f transit/keys/signing-key type=ecdsa-p256 exportable=true auto_rotate_period=24h
    else
        echo "'signing-key' for Transit already exists."
    fi
}

# Function to configure KV Secret Engine and save static key
configure_vault_kv_secret_engine() {
    # Enable KV Secret Engine at path secret/ if not already enabled
    if ! vault secrets list -format=json | jq -e '.["secret/"]' >/dev/null; then
        echo "Enabling KV Secret Engine at path secret/..."
        vault secrets enable -path=secret kv
    else
        echo "KV Secret Engine is already enabled at path secret/."
    fi

    # Check and save static key in KV
    if ! vault kv get secret/data-encryption-key >/dev/null 2>&1; then
        echo "Creating static data encryption key in KV..."
        # Generate random key
        GENERATED_KEY=$(openssl rand -base64 32)
        vault kv put secret/data-encryption-key key="$GENERATED_KEY"
    else
        echo "Static data encryption key already exists in KV."
    fi
}



# Main function
main() {

    check_requirements
    ensure_directory "$TEMP_DIR"
    ensure_directory "$SSL_BASE_DIR"

    # Generate certificates-config.yaml from template
    envsubst < /vault/scripts/certificates-config.yaml.template > "$CONFIG_FILE"

    # Read configuration
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "Error: Configuration file not found at $CONFIG_FILE"
        exit 1
    fi

    config=$(cat "$CONFIG_FILE")

    # Configure Auth, Policies, and Users
    configure_vault_auth_policies_users

    # Configure Secret Engines (PKI and Transit)
    configure_vault_secrets_engines

    # Configure KV Secret Engine and save static key
    configure_vault_kv_secret_engine

    # Initial certificate generation
    services=$(echo "$config" | yq eval '.services | keys | .[]' -)
    for service in $services; do
        cert_file="$SSL_BASE_DIR/$service/$(echo "$config" | yq eval ".services.$service.cert_file" -)"
        if is_cert_valid "$cert_file"; then
            echo "Certificate for $service is valid. Skipping generation."
        else
            if [ -f "$cert_file" ]; then
                echo "Certificate for $service is expiring or invalid. Generating new certificate..."
            else
                echo "Certificate for $service not found. Generating new certificate..."
            fi
            generate_certificate "$service" "$config"
        fi
    done

    # Start certificate monitoring in background
    monitor_certificates "$config" &
}

# Execute main function
main "$@"
