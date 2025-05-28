#!/bin/sh
# /vault/custom-entrypoint.sh

set -e

# Устанавливаем переменные для работы с префиксом
export VAULT_UI_PATH_PREFIX="/vault"
export VAULT_API_PATH_PREFIX="/vault"
export VAULT_CLUSTER_ADDR="https://vault-server:8201"
export VAULT_REDIRECT_ADDR="https://localhost/vault"

# Считываем переменные из файла localhost.env
if [ -f "/vault/.env" ]; then
  export $(grep -v '^#' /vault/localhost.env | xargs)
fi

UNSEAL_KEYS_FILE="/vault/keys/unseal-keys.json"
USER_INFO_FILE="/vault/keys/user-info.json"
CERT_DIR="/vault/keys"
CERT_FILE="$CERT_DIR/vault.crt"
KEY_FILE="$CERT_DIR/vault.key"

# Функция для генерации самоподписанного сертификата
generate_self_signed_cert() {
  echo "Генерация самоподписанного SSL-сертификата..."
  mkdir -p "$CERT_DIR"
  openssl req -new -newkey rsa:2048 -days 365 -nodes -x509 \
    -subj "/C=RU/ST=YourRegion/L=YourCity/O=bit.dive/OU=YourDepartment/CN=${SERVER_IP}" \
    -keyout "$KEY_FILE" \
    -out "$CERT_FILE" \
    -addext "subjectAltName = DNS:keycloak"
  echo "Самоподписанный сертификат и ключ сгенерированы."
}

# Проверка наличия сертификата и ключа
if [ ! -f "$CERT_FILE" ] || [ ! -f "$KEY_FILE" ]; then
  echo "SSL-сертификат или ключ не найдены. Генерируем самоподписанные сертификаты..."
  generate_self_signed_cert
else
  echo "SSL-сертификат и ключ найдены."
fi

# Запуск Vault-сервера в фоновом режиме
vault server -config=/vault/config/config.hcl &

# Ожидание запуска Vault-сервера
echo "Ожидание запуска Vault-сервера..."
while ! nc -z localhost 8200; do
  sleep 0.1
done
echo "Vault-сервер запущен."

# Запуск скрипта инициализации Vault
/vault/scripts/vault-init.sh

# Бесконечный цикл для удержания контейнера в активном состоянии
tail -f /dev/null
