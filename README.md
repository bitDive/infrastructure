# BitDive Docker Compose Configuration

This repository contains a Docker Compose setup for deploying the BitDive environment. It includes the following services:

- **Vault**: A secrets management system.
- **PostgreSQL**: A database server with SSL configuration.
- **MinIO**: An object storage service.
- **Keycloak**: An identity and access management system.
- **Monitoring API**: A service for monitoring application performance.
- **Flink Load**: A service for loading data to MinIO.
- **File Acceptor**: A service for accepting and processing files.
- **Frontend**: A React-based frontend for the BitDive application.


## URL
https://bitdive.io/

## Prerequisites

Ensure that you have the following installed on your system:

- Docker (v20.10+)
- Docker Compose (v1.29+)

## Environment Variables

Before starting the services, create a `.env` file in the root directory with the following variables:

```env
SERVER_IP=127.0.0.1
SERVER_NAME=localhost

URL_FRONT_SYSTEM=https://${SERVER_NAME}
#http://${SERVER_NAME}:3000

# Vault Configuration
VAULT_ADDR=https://127.0.0.1:8200
VAULT_ADDR_CONTAINER=https://vault-server:8200

# PostgreSQL Configuration
POSTGRES_USER=citizix_user
POSTGRES_PASSWORD=your_postgres_password
POSTGRES_DB=data-bitdive
POSTGRES_HOST=postgres-bitdive
POSTGRES_PORT=5432

# MinIO Configuration
MINIO_ROOT_USER=your_minio_user
MINIO_ROOT_PASSWORD=your_minio_passwor
MINIO_DOMAIN=http://${SERVER_NAME}/minio
MINIO_CONSOLE_ADDRESS=:9001
MINIO_ENDPOINT=http://minio:9000

# Keycloak Configuration
KEYCLOAK_DB_USERNAME=${POSTGRES_USER}
KEYCLOAK_DB_PASSWORD=${POSTGRES_PASSWORD}
KEYCLOAK_ADMIN=your_keycloak_user
KEYCLOAK_ADMIN_PASSWORD=your_keycloak_password
KEYCLOAK_HTTP_ENABLED=false
KEYCLOAK_HTTP_SSL_PORT=8443
KEYCLOAK_KEY_STORE_PASSWORD=your-keycloak-keystore-password
KEYCLOAK_TRUST_STORE_PASSWORD=your-keycloak-truststore-password
JAVA_KEYSTORE_PASSWORD=your-keystore-password
JAVA_TRUSTSTORE_PASSWORD=your-truststore-password
KEYCLOAK_DB_URL=jdbc:postgresql://${POSTGRES_HOST}:${POSTGRES_PORT}/keycloak?ssl=true&sslmode=verify-full&&sslfactory=org.postgresql.ssl.DefaultJavaSSLFactory

# Vault User Credentials
VAULT_LOGIN=username
VAULT_PASSWORD=password123

# Vault Certificates Configuration
VAULT_CERT_DB_COMMON_NAME=${POSTGRES_USER}
VAULT_CERT_DB_ALT_NAME=${POSTGRES_HOST}
VAULT_CERT_DB_TTL=24h
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

# Keycloak Realm URL
KEYCLOAK_REALM_URL=https://keycloak:${KEYCLOAK_HTTP_SSL_PORT}/realms/bitdive/protocol/openid-connect/certs
KEYCLOAK_REALM_URL_NOT_SSL=http://keycloak:8080/realms/bitdive/protocol/openid-connect/certs

# Frontend Configuration
REACT_APP_API_URL=https://${SERVER_NAME}/monitoring-api
REACT_APP_KEYCLOAK_URL=https://${SERVER_NAME}/keyCloak/
REACT_APP_KEYCLOAK_REALM=bitdive
REACT_APP_KEYCLOAK_CLIENT_ID=react-client
GENERATE_SOURCEMAP=false
```

## Usage
### Step 0: Need to be replaced with your values
```bash
SERVER_IP=127.0.0.1
SERVER_NAME=localhost

POSTGRES_PASSWORD=your_postgres_password

MINIO_ROOT_USER=your_minio_user
MINIO_ROOT_PASSWORD=your_minio_password

KEYCLOAK_ADMIN=your_keycloak_user
KEYCLOAK_ADMIN_PASSWORD=your_keycloak_password

KEYCLOAK_KEY_STORE_PASSWORD=your-keycloak-keystore-password
KEYCLOAK_TRUST_STORE_PASSWORD=your-keycloak-truststore-password

JAVA_KEYSTORE_PASSWORD=your-keystore-password
JAVA_TRUSTSTORE_PASSWORD=your-truststore-password

VAULT_LOGIN=your_vault_login
VAULT_PASSWORD=your_vault_password
```
### Step 1: Start Vault

Run the following command to start the Vault service:

```bash
docker-compose up -d vault
```

Wait until Vault is fully initialized.

### Step 2: Initialize Database SSL

Run the following command to set up SSL for the PostgreSQL service:

```bash
docker-compose up init-db-ssl
```

Wait until the process completes.

### Step 3: Start All Services

Finally, start all remaining services with:

```bash
docker-compose up init-container-ssl
```

## Accessing the Services

- **PostgreSQL**: Accessible on port `5432`.
- **Keycloak**: [https://localhost/keyCloak](https://localhost/keyCloak)
- **Frontend**: [http://localhost](http://localhost)
- **flink-load**: [http://localhost/flink-load](http://localhost/flink-load)
  
## Configuring Keycloak
https://bitdive.io/docs/keycloak-configuration/
## Notes

- Logs and data are persisted in the `./vault` and `./postgresql` directories.
- Make sure to replace placeholder values in the `.env` file with actual secrets before starting the services.
- If you encounter any issues, verify that all required ports are free and that Docker Compose is up-to-date.

## Troubleshooting

- **Vault does not start**: Ensure that the configuration file exists in the `./configVault` directory and is correctly configured.
- **PostgreSQL SSL issues**: Verify that the certificates in `./vault/ssl/postgres-server` are correctly configured and have proper permissions.
- **MinIO access issues**: Ensure that the `MINIO_ROOT_USER` and `MINIO_ROOT_PASSWORD` in `.env` match the configured values.

## Restarting Services After Configuration Changes

If you've made changes to the configuration files (nginx, docker-compose.yml, or .env), you need to restart the affected services:

### For MinIO configuration changes:
```bash
# Stop and remove containers
docker-compose down

# Rebuild and start services
docker-compose up -d minio nginx

# Or restart all services
docker-compose up -d
```

### For nginx configuration changes only:
```bash
# Restart just nginx
docker-compose restart nginx
```

After restarting, MinIO console will be available at: [https://localhost/minio](https://localhost/minio)
