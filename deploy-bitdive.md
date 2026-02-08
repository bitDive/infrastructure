# Deploy BitDive Infrastructure

## Step 1: Clone the repository

Clone the repository and navigate to the project folder:

```bash
git clone https://github.com/bitDive/infrastructure.git
cd infrastructure/docker-compose
```

## Step 2: Generate .env file with new passwords

Create a `.env` file in the `docker-compose` folder. Generate random secure passwords (at least 20 characters, letters + digits) for each of the following fields:

- `POSTGRES_PASSWORD`
- `CLICKHOUSE_PASSWORD`
- `CLICKHOUSE_PG_USER_PASSWORD`
- `MINIO_ROOT_USER`
- `MINIO_ROOT_PASSWORD`
- `KEYCLOAK_ADMIN_PASSWORD`
- `KEYCLOAK_KEY_STORE_PASSWORD`
- `KEYCLOAK_TRUST_STORE_PASSWORD`
- `JAVA_KEYSTORE_PASSWORD`
- `JAVA_TRUSTSTORE_PASSWORD`
- `VAULT_PASSWORD`
- `TOKEN_SECRET` (base64, 32 bytes)

Use the following template for all other values:

```env
SERVER_IP=127.0.0.1
SERVER_NAME=localhost

URL_FRONT_SYSTEM=https://${SERVER_NAME}

# Vault Configuration
VAULT_ADDR=https://127.0.0.1:8200
VAULT_ADDR_CONTAINER=https://vault-server:8200

# PostgreSQL Configuration
POSTGRES_USER=citizix_user
POSTGRES_PASSWORD=<GENERATE>
POSTGRES_DB=data-bitdive
POSTGRES_HOST=postgres-bitdive
POSTGRES_PORT=5432

# ClickHouse Configuration
CLICKHOUSE_USER=user_ch
CLICKHOUSE_PASSWORD=<GENERATE>
CLICKHOUSE_HOST=clickhouse-bitdive
CLICKHOUSE_DB=bitdive
CLICKHOUSE_PORT=8445

CLICKHOUSE_PG_USER_PASSWORD=<GENERATE>

# MinIO Configuration
MINIO_ROOT_USER=<GENERATE>
MINIO_ROOT_PASSWORD=<GENERATE>
MINIO_DOMAIN=http://${SERVER_NAME}/minio
MINIO_CONSOLE_ADDRESS=:9001
MINIO_ENDPOINT=http://minio:9000

# Keycloak Configuration
KEYCLOAK_DB_USERNAME=${POSTGRES_USER}
KEYCLOAK_DB_PASSWORD=${POSTGRES_PASSWORD}
KEYCLOAK_ADMIN=admin
KEYCLOAK_ADMIN_PASSWORD=<GENERATE>
KEYCLOAK_HTTP_ENABLED=false
KEYCLOAK_HTTP_SSL_PORT=8443
KEYCLOAK_KEY_STORE_PASSWORD=<GENERATE>
KEYCLOAK_TRUST_STORE_PASSWORD=<GENERATE>
JAVA_KEYSTORE_PASSWORD=<GENERATE>
JAVA_TRUSTSTORE_PASSWORD=<GENERATE>
KEYCLOAK_DB_URL=jdbc:postgresql://${POSTGRES_HOST}:${POSTGRES_PORT}/keycloak?ssl=true&sslmode=verify-full&&sslfactory=org.postgresql.ssl.DefaultJavaSSLFactory

TOKEN_SECRET=<GENERATE base64 32 bytes>

# Vault User Credentials
VAULT_LOGIN=vault_admin
VAULT_PASSWORD=<GENERATE>

# Vault Certificates Configuration
VAULT_CERT_DB_COMMON_NAME=${POSTGRES_USER}
VAULT_CERT_DB_ALT_NAME=${POSTGRES_HOST}
VAULT_CERT_DB_TTL=24h
VAULT_CERT_DB_CH_COMMON_NAME=clickhouse
VAULT_CERT_DB_CH_ALT_NAME=${CLICKHOUSE_HOST}
VAULT_CERTIFICATION_DB_CH_TTL=24h

VAULT_CERT_SERVICE_COMMON_NAME=file-acceptor.bitdive
VAULT_CERT_SERVICE_COMMON_NAME_FILE_ACCEPTOR=file-acceptor.${SERVER_NAME}
VAULT_CERT_SERVICE_ALT_NAMES_FILE_ACCEPTOR=file-acceptor.${SERVER_NAME}
VAULT_CERT_SERVICE_ALT_NAMES=${SERVER_IP}
VAULT_CERT_SERVICE_TTL=24h
KEYCLOAK_FRONTEND_URL_NOT_SSL=https://${SERVER_IP}:8999
KEYCLOAK_FRONTEND_URL=https://${SERVER_NAME}:8999
VAULT_CERT_KEYCLOAK_COMMON_NAME=${SERVER_IP}
VAULT_CERT_KEYCLOAK_ALT_NAME=${SERVER_IP}
VAULT_CERT_KEYCLOAK_TTL=24h

KEYCLOAK_CONTAINER=https://keycloak:${KEYCLOAK_HTTP_SSL_PORT}/keyCloak
KEYCLOAK_REALM_URL=${KEYCLOAK_CONTAINER}/realms/bitdive/protocol/openid-connect/certs
KEYCLOAK_REALM_URL_NOT_SSL=http://keycloak:8080/realms/bitdive/protocol/openid-connect/certs

# Frontend Configuration
REACT_APP_API_URL=https://${SERVER_NAME}/monitoring-api
REACT_APP_KEYCLOAK_URL=https://${SERVER_NAME}/keyCloak/
REACT_APP_KEYCLOAK_REALM=bitdive
REACT_APP_KEYCLOAK_CLIENT_ID=react-client
GENERATE_SOURCEMAP=false
REACT_APP_BASE_URL=https://${SERVER_NAME}/

APP_EMAIL_SMTP_HOST=smtp.zoho.eu
APP_EMAIL_SMTP_PORT=587

APP_EMAIL_SMTP_ALERT_USER=
APP_EMAIL_SMTP_ALERT_PASSWORD=
APP_EMAIL_SMTP_ALERT_EMAIL=

APP_EMAIL_SMTP_INFORMATION_USER=
APP_EMAIL_SMTP_INFORMATION_PASSWORD=
APP_EMAIL_SMTP_INFORMATION_EMAIL=

TOTAL_PROCESS_MEMORY=4g
```

After creating the file, print all generated passwords to the user.

## Step 3: Start Vault

Start Vault and wait 30 seconds for initialization:

```bash
docker-compose up -d vault
sleep 30
```

## Step 4: Initialize database SSL

Start SSL certificate setup and wait 40 seconds:

```bash
docker-compose up -d init-db-ssl
sleep 40
```

## Step 5: Start all services

Start all remaining services:

```bash
docker-compose up -d init-container-ssl
```

## Result

After all steps are completed, the services are available at:

- **Frontend**: https://localhost
- **Keycloak**: https://localhost/keyCloak
- **MinIO Console**: https://localhost/minio
- **PostgreSQL**: localhost:5432
