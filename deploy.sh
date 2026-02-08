#!/bin/bash
set -e

# ============================================================
#  BitDive Infrastructure — автоматический деплой
#  Использование:  bash deploy.sh [ЦЕЛЕВАЯ_ПАПКА]
#  По умолчанию клонирует в ./bitdive-infrastructure
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

# ---------- Генерация паролей ----------
generate_password() {
    local length=${1:-24}
    # Используем openssl если есть, иначе /dev/urandom, иначе $RANDOM
    if command -v openssl &>/dev/null; then
        openssl rand -base64 "$length" | tr -dc 'A-Za-z0-9' | head -c "$length"
    elif [ -e /dev/urandom ]; then
        cat /dev/urandom | tr -dc 'A-Za-z0-9' | head -c "$length"
    else
        # Fallback для Windows без openssl
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

# ---------- Проверка зависимостей ----------
info "Проверка зависимостей..."

if ! command -v git &>/dev/null; then
    err "git не найден. Установите git: https://git-scm.com/"
fi

if ! command -v docker &>/dev/null; then
    err "docker не найден. Установите Docker: https://docs.docker.com/get-docker/"
fi

if command -v docker-compose &>/dev/null; then
    DC="docker-compose"
elif docker compose version &>/dev/null 2>&1; then
    DC="docker compose"
else
    err "docker-compose не найден. Установите Docker Compose: https://docs.docker.com/compose/install/"
fi

log "Зависимости в порядке (git, docker, $DC)"

# ============================================================
#  ШАГ 1: Клонирование репозитория
# ============================================================
TARGET_DIR="${1:-bitdive-infrastructure}"
REPO_URL="https://github.com/bitDive/infrastructure.git"

echo ""
info "Шаг 1/6 — Клонирование $REPO_URL → $TARGET_DIR"

if [ -d "$TARGET_DIR" ]; then
    warn "Папка $TARGET_DIR уже существует. Обновляем (git pull)..."
    cd "$TARGET_DIR"
    git pull || warn "git pull не удался, продолжаем с текущей версией"
else
    git clone "$REPO_URL" "$TARGET_DIR"
    cd "$TARGET_DIR"
fi

log "Репозиторий готов: $(pwd)"

# ============================================================
#  ШАГ 2: Переход в docker-compose
# ============================================================
echo ""
info "Шаг 2/6 — Переход в папку docker-compose"

cd docker-compose || err "Папка docker-compose не найдена!"
log "Рабочая директория: $(pwd)"

# ============================================================
#  ШАГ 3: Генерация .env с рандомными паролями
# ============================================================
echo ""
info "Шаг 3/6 — Генерация .env с новыми паролями"

# Генерируем уникальные пароли
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

# Резервная копия если .env уже есть
if [ -f .env ]; then
    cp .env ".env.backup.$(date +%Y%m%d_%H%M%S)"
    warn "Старый .env сохранён как бэкап"
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

log ".env создан с новыми паролями"
echo ""
echo "  ┌──────────────────────────────────────────────────────┐"
echo "  │  Сгенерированные учётные данные (сохраните!):        │"
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
#  ШАГ 4: Запуск Vault
# ============================================================
info "Шаг 4/6 — Запуск Vault"

$DC up -d vault
log "Vault запущен. Ожидание 30 секунд для инициализации..."

for i in $(seq 30 -1 1); do
    printf "\r  ⏳ Осталось %2d сек..." "$i"
    sleep 1
done
echo ""
log "Vault готов"

# ============================================================
#  ШАГ 5: Инициализация SSL для баз данных
# ============================================================
echo ""
info "Шаг 5/6 — Запуск init-db-ssl (настройка SSL сертификатов)"

$DC up -d init-db-ssl
log "init-db-ssl запущен. Ожидание 40 секунд..."

for i in $(seq 40 -1 1); do
    printf "\r  ⏳ Осталось %2d сек..." "$i"
    sleep 1
done
echo ""
log "init-db-ssl завершён"

# ============================================================
#  ШАГ 6: Запуск всех остальных сервисов
# ============================================================
echo ""
info "Шаг 6/6 — Запуск всех сервисов (init-container-ssl)"

$DC up -d init-container-ssl
log "Все сервисы запущены!"

# ============================================================
#  Итог
# ============================================================
echo ""
echo "=========================================================="
echo -e "${GREEN}  ✅  BitDive успешно развёрнут!${NC}"
echo "=========================================================="
echo ""
echo "  Доступ к сервисам:"
echo "    Frontend      : https://localhost"
echo "    Keycloak      : https://localhost/keyCloak"
echo "    MinIO Console : https://localhost/minio"
echo "    Flink Load    : https://localhost/flink-load"
echo "    PostgreSQL    : localhost:5432"
echo ""
echo "  Логин Keycloak  : ${USER_KEYCLOAK} / ${PASS_KEYCLOAK}"
echo "  Логин MinIO     : ${USER_MINIO} / ${PASS_MINIO}"
echo ""
echo "  Полный .env: $(pwd)/.env"
echo "=========================================================="
