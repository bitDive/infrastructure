#!/bin/bash
set -e

# ============================================================
#  BitDive Infrastructure — automatic deployment
#  Usage:  bash deploy.sh [TARGET_FOLDER]
#  Default clones to ./bitdive-infrastructure
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log()  { echo -e "${GREEN}[✔]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✖]${NC} $1"; exit 1; }
info() { echo -e "${CYAN}[→]${NC} $1"; }

# ---------- Password generation ----------
generate_password() {
    local length=${1:-24}
    # Use openssl if available, otherwise /dev/urandom, otherwise $RANDOM
    if command -v openssl &>/dev/null; then
        openssl rand -base64 "$length" | tr -dc 'A-Za-z0-9' | head -c "$length"
    elif [ -e /dev/urandom ]; then
        cat /dev/urandom | tr -dc 'A-Za-z0-9' | head -c "$length"
    else
        # Fallback for Windows without openssl
        local pw=""
        local chars='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
        for i in $(seq 1 "$length"); do
            pw+="${chars:RANDOM%${#chars}:1}"
        done
        echo "$pw"
    fi
}

generate_token_secret() {
    if command -v openssl &>/dev/null; then
        openssl rand -base64 32
    else
        generate_password 32 | base64 2>/dev/null || generate_password 44
    fi
}

# ---------- Dependency check ----------
info "Checking dependencies..."

if ! command -v git &>/dev/null; then
    err "git not found. Install git: https://git-scm.com/"
fi

if ! command -v docker &>/dev/null; then
    err "docker not found. Install Docker: https://docs.docker.com/get-docker/"
fi

if command -v docker-compose &>/dev/null; then
    DC="docker-compose"
elif docker compose version &>/dev/null 2>&1; then
    DC="docker compose"
else
    err "docker-compose not found. Install Docker Compose: https://docs.docker.com/compose/install/"
fi

log "Dependencies OK (git, docker, $DC)"

# ============================================================
#  STEP 1: Clone repository
# ============================================================
TARGET_DIR="${1:-bitdive-infrastructure}"
REPO_URL="https://github.com/bitDive/infrastructure.git"

echo ""
info "Step 1/6 — Cloning $REPO_URL → $TARGET_DIR"

if [ -d "$TARGET_DIR" ]; then
    warn "Folder $TARGET_DIR already exists. Updating (git pull)..."
    cd "$TARGET_DIR"
    git pull || warn "git pull failed, continuing with current version"
else
    git clone "$REPO_URL" "$TARGET_DIR"
    cd "$TARGET_DIR"
fi

log "Repository ready: $(pwd)"

# ============================================================
#  STEP 2: Navigate to docker-compose
# ============================================================
echo ""
info "Step 2/6 — Navigating to docker-compose folder"

cd docker-compose || err "docker-compose folder not found!"
log "Working directory: $(pwd)"

# ============================================================
#  STEP 3: Generate .env with random passwords
# ============================================================
echo ""
info "Step 3/6 — Generating .env with new passwords"

# Generate unique passwords
PASS_POSTGRES=$(generate_password 20)
PASS_CLICKHOUSE=$(generate_password 20)
PASS_CLICKHOUSE_PG=$(generate_password 20)
USER_MINIO=$(generate_password 16)
PASS_MINIO=$(generate_password 20)
USER_KEYCLOAK="admin"
PASS_KEYCLOAK=$(generate_password 20)
PASS_KC_KEYSTORE=$(generate_password 20)
PASS_KC_TRUSTSTORE=$(generate_password 20)
PASS_JAVA_KEYSTORE=$(generate_password 20)
PASS_JAVA_TRUSTSTORE=$(generate_password 20)
USER_VAULT="vault_admin"
PASS_VAULT=$(generate_password 20)
SECRET_TOKEN=$(generate_token_secret)

# Backup if .env already exists
if [ -f .env ]; then
    cp .env ".env.backup.$(date +%Y%m%d_%H%M%S)"
    warn "Old .env saved as backup"
fi

cat > .env << ENVEOF
SERVER_IP=127.0.0.1
SERVER_NAME=localhost

URL_FRONT_SYSTEM=https://\${SERVER_NAME}

# Vault Configuration
VAULT_ADDR=https://127.0.0.1:8200
VAULT_ADDR_CONTAINER=https://vault-server:8200

# PostgreSQL Configuration
POSTGRES_USER=citizix_user
POSTGRES_PASSWORD=${PASS_POSTGRES}
POSTGRES_DB=data-bitdive
POSTGRES_HOST=postgres-bitdive
POSTGRES_PORT=5432

# ClickHouse Configuration
CLICKHOUSE_USER=user_ch
CLICKHOUSE_PASSWORD=${PASS_CLICKHOUSE}
CLICKHOUSE_HOST=clickhouse-bitdive
CLICKHOUSE_DB=bitdive
CLICKHOUSE_PORT=8445

CLICKHOUSE_PG_USER_PASSWORD=${PASS_CLICKHOUSE_PG}

# MinIO Configuration
MINIO_ROOT_USER=${USER_MINIO}
MINIO_ROOT_PASSWORD=${PASS_MINIO}
MINIO_DOMAIN=http://\${SERVER_NAME}/minio
MINIO_CONSOLE_ADDRESS=:9001
MINIO_ENDPOINT=http://minio:9000

# Keycloak Configuration
KEYCLOAK_DB_USERNAME=\${POSTGRES_USER}
KEYCLOAK_DB_PASSWORD=\${POSTGRES_PASSWORD}
KEYCLOAK_ADMIN=${USER_KEYCLOAK}
KEYCLOAK_ADMIN_PASSWORD=${PASS_KEYCLOAK}
KEYCLOAK_HTTP_ENABLED=false
KEYCLOAK_HTTP_SSL_PORT=8443
KEYCLOAK_KEY_STORE_PASSWORD=${PASS_KC_KEYSTORE}
KEYCLOAK_TRUST_STORE_PASSWORD=${PASS_KC_TRUSTSTORE}
JAVA_KEYSTORE_PASSWORD=${PASS_JAVA_KEYSTORE}
JAVA_TRUSTSTORE_PASSWORD=${PASS_JAVA_TRUSTSTORE}
KEYCLOAK_DB_URL=jdbc:postgresql://\${POSTGRES_HOST}:\${POSTGRES_PORT}/keycloak?ssl=true&sslmode=verify-full&&sslfactory=org.postgresql.ssl.DefaultJavaSSLFactory

TOKEN_SECRET=${SECRET_TOKEN}

# Vault User Credentials
VAULT_LOGIN=${USER_VAULT}
VAULT_PASSWORD=${PASS_VAULT}

# Vault Certificates Configuration
VAULT_CERT_DB_COMMON_NAME=\${POSTGRES_USER}
VAULT_CERT_DB_ALT_NAME=\${POSTGRES_HOST}
VAULT_CERT_DB_TTL=24h
VAULT_CERT_DB_CH_COMMON_NAME=clickhouse
VAULT_CERT_DB_CH_ALT_NAME=\${CLICKHOUSE_HOST}
VAULT_CERTIFICATION_DB_CH_TTL=24h

VAULT_CERT_SERVICE_COMMON_NAME=file-acceptor.bitdive
VAULT_CERT_SERVICE_COMMON_NAME_FILE_ACCEPTOR=file-acceptor.\${SERVER_NAME}
VAULT_CERT_SERVICE_ALT_NAMES_FILE_ACCEPTOR=file-acceptor.\${SERVER_NAME}
VAULT_CERT_SERVICE_ALT_NAMES=\${SERVER_IP}
VAULT_CERT_SERVICE_TTL=24h
KEYCLOAK_FRONTEND_URL_NOT_SSL=https://\${SERVER_IP}:8999
KEYCLOAK_FRONTEND_URL=https://\${SERVER_NAME}:8999
VAULT_CERT_KEYCLOAK_COMMON_NAME=\${SERVER_IP}
VAULT_CERT_KEYCLOAK_ALT_NAME=\${SERVER_IP}
VAULT_CERT_KEYCLOAK_TTL=24h

KEYCLOAK_CONTAINER=https://keycloak:\${KEYCLOAK_HTTP_SSL_PORT}/keyCloak
# Keycloak Realm URL
KEYCLOAK_REALM_URL=\${KEYCLOAK_CONTAINER}/realms/bitdive/protocol/openid-connect/certs
KEYCLOAK_REALM_URL_NOT_SSL=http://keycloak:8080/realms/bitdive/protocol/openid-connect/certs

# Frontend Configuration
REACT_APP_API_URL=https://\${SERVER_NAME}/monitoring-api
REACT_APP_KEYCLOAK_URL=https://\${SERVER_NAME}/keyCloak/
REACT_APP_KEYCLOAK_REALM=bitdive
REACT_APP_KEYCLOAK_CLIENT_ID=react-client
GENERATE_SOURCEMAP=false
REACT_APP_BASE_URL=https://\${SERVER_NAME}/

APP_EMAIL_SMTP_HOST=smtp.zoho.eu
APP_EMAIL_SMTP_PORT=587

APP_EMAIL_SMTP_ALERT_USER=
APP_EMAIL_SMTP_ALERT_PASSWORD=
APP_EMAIL_SMTP_ALERT_EMAIL=

APP_EMAIL_SMTP_INFORMATION_USER=
APP_EMAIL_SMTP_INFORMATION_PASSWORD=
APP_EMAIL_SMTP_INFORMATION_EMAIL=

TOTAL_PROCESS_MEMORY=4g
ENVEOF

log ".env created with new passwords"
echo ""
echo "  ┌──────────────────────────────────────────────────────┐"
echo "  │  Generated credentials (save these!):                │"
echo "  ├──────────────────────────────────────────────────────┤"
echo "  │  PostgreSQL password : ${PASS_POSTGRES}"
echo "  │  ClickHouse password : ${PASS_CLICKHOUSE}"
echo "  │  ClickHouse PG pass  : ${PASS_CLICKHOUSE_PG}"
echo "  │  MinIO user          : ${USER_MINIO}"
echo "  │  MinIO password      : ${PASS_MINIO}"
echo "  │  Keycloak admin      : ${USER_KEYCLOAK}"
echo "  │  Keycloak password   : ${PASS_KEYCLOAK}"
echo "  │  Vault login         : ${USER_VAULT}"
echo "  │  Vault password      : ${PASS_VAULT}"
echo "  │  Token secret        : ${SECRET_TOKEN}"
echo "  └──────────────────────────────────────────────────────┘"
echo ""

# ============================================================
#  STEP 4: Start Vault
# ============================================================
info "Step 4/6 — Starting Vault"

$DC up -d vault
log "Vault started. Waiting 30 seconds for initialization..."

for i in $(seq 30 -1 1); do
    printf "\r  ⏳ %2d seconds remaining..." "$i"
    sleep 1
done
echo ""
log "Vault ready"

# ============================================================
#  STEP 5: Initialize SSL for databases
# ============================================================
echo ""
info "Step 5/6 — Starting init-db-ssl (SSL certificate setup)"

$DC up -d init-db-ssl
log "init-db-ssl started. Waiting 40 seconds..."

for i in $(seq 40 -1 1); do
    printf "\r  ⏳ %2d seconds remaining..." "$i"
    sleep 1
done
echo ""
log "init-db-ssl completed"

# ============================================================
#  STEP 6: Start all remaining services
# ============================================================
echo ""
info "Step 6/6 — Starting all services (init-container-ssl)"

$DC up -d init-container-ssl
log "All services started!"

# ============================================================
#  Summary
# ============================================================
echo ""
echo "=========================================================="
echo -e "${GREEN}  ✅  BitDive successfully deployed!${NC}"
echo "=========================================================="
echo ""
echo "  Service access:"
echo "    Frontend      : https://localhost"
echo "    Keycloak      : https://localhost/keyCloak"
echo "    MinIO Console : https://localhost/minio"
echo "    Flink Load    : https://localhost/flink-load"
echo "    PostgreSQL    : localhost:5432"
echo ""
echo "  Keycloak login  : ${USER_KEYCLOAK} / ${PASS_KEYCLOAK}"
echo "  MinIO login     : ${USER_MINIO} / ${PASS_MINIO}"
echo ""
echo "  Full .env: $(pwd)/.env"
echo "=========================================================="
