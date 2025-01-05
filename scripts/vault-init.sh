#!/bin/sh
# /vault/scripts/vault-init.sh

set -e

# Считываем переменные из файла localhost.env
if [ -f "/vault/.env" ]; then
  # Создаем временный файл без лишних символов
  sed 's/\r$//' /vault/.env | sed '/^\s*$/d' > /tmp/.env.cleaned

  # Удаляем лишние пробелы и переходы на новую строку внутри значений
  sed -i 's/^[ \t]*//;s/[ \t]*$//' /tmp/.env.cleaned

  # Загружаем переменные с интерполяцией
  set -a
  . /tmp/.env.cleaned
  set +a

  # Удаляем временный файл
  rm /tmp/.env.cleaned
fi

# Проверяем, что переменные установлены


UNSEAL_KEYS_FILE="/vault/keys/unseal-keys.json"
CERT_DIR="/vault/keys"
CERT_FILE="$CERT_DIR/vault.crt"
KEY_FILE="$CERT_DIR/vault.key"
USER_INFO_FILE="/vault/keys/user-info.json"

# Функция для генерации самоподписанного сертификата
generate_self_signed_cert() {
  echo "Генерация самоподписанного SSL-сертификата..."
  mkdir -p "$CERT_DIR"
  openssl req -new -newkey rsa:2048 -days 365 -nodes -x509 \
    -subj "/C=RU/ST=YourRegion/L=YourCity/O=YourOrganization/OU=YourDepartment/CN=${SERVER_IP}" \
    -keyout "$KEY_FILE" \
    -out "$CERT_FILE"
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

# Функция для разблокировки Vault
unseal_vault() {
  echo "Разблокировка Vault с ключом: $1"
  vault operator unseal "$1"
  echo "Ключ разблокировки применен."
}

# Проверка, инициализирован ли Vault
init_status=$(vault status -format=json | jq -r '.initialized')

if [ "$init_status" = "true" ]; then
  echo "Vault уже инициализирован. Переходим к разблокировке."

  # Проверка наличия файла с ключами разблокировки
  if [ -f "$UNSEAL_KEYS_FILE" ]; then
    # Считывание ключей разблокировки из файла
    UNSEAL_KEY_1=$(jq -r '.unseal_keys_b64[0]' "$UNSEAL_KEYS_FILE")
    UNSEAL_KEY_2=$(jq -r '.unseal_keys_b64[1]' "$UNSEAL_KEYS_FILE")
    UNSEAL_KEY_3=$(jq -r '.unseal_keys_b64[2]' "$UNSEAL_KEYS_FILE")

    # Разблокировка Vault
    unseal_vault "$UNSEAL_KEY_1"
    unseal_vault "$UNSEAL_KEY_2"
    unseal_vault "$UNSEAL_KEY_3"
  else
    echo "Ошибка: Файл с ключами разблокировки не найден. Невозможно разблокировать Vault."
    exit 1
  fi
else
  echo "Инициализация Vault..."

  # Инициализация Vault и сохранение ключей разблокировки и корневого токена
  init_output=$(vault operator init -format=json -key-shares=5 -key-threshold=3)

  # Проверка успешности инициализации
  if echo "$init_output" | jq -e . >/dev/null 2>&1; then
    echo "Vault успешно инициализирован."
  else
    echo "Ошибка при инициализации Vault:"
    echo "$init_output"
    exit 1
  fi

  # Сохранение ключей разблокировки и корневого токена в файл
  mkdir -p "$(dirname "$UNSEAL_KEYS_FILE")"
  echo "$init_output" > "$UNSEAL_KEYS_FILE"
  chmod 600 "$UNSEAL_KEYS_FILE"

  # Извлечение ключей разблокировки
  UNSEAL_KEY_1=$(echo "$init_output" | jq -r '.unseal_keys_b64[0]')
  UNSEAL_KEY_2=$(echo "$init_output" | jq -r '.unseal_keys_b64[1]')
  UNSEAL_KEY_3=$(echo "$init_output" | jq -r '.unseal_keys_b64[2]')

  # Разблокировка Vault
  unseal_vault "$UNSEAL_KEY_1"
  unseal_vault "$UNSEAL_KEY_2"
  unseal_vault "$UNSEAL_KEY_3"

  echo "Vault разблокирован и готов к использованию."
fi

# Экспорт VAULT_TOKEN для дальнейших команд
export VAULT_TOKEN=$(jq -r '.root_token' "$UNSEAL_KEYS_FILE")

VAULT_ADDR=${VAULT_ADDR}
CONFIG_FILE="/vault/scripts/certificates-config.yaml"
TEMP_DIR="/tmp/certs"
SSL_BASE_DIR="/vault/ssl"

# Функция для проверки необходимых инструментов
check_requirements() {
    command -v vault >/dev/null 2>&1 || { echo "vault требуется, но не установлен."; exit 1; }
    command -v yq >/dev/null 2>&1 || { echo "yq требуется, но не установлен."; exit 1; }
    command -v jq >/dev/null 2>&1 || { echo "jq требуется, но не установлен."; exit 1; }
}

# Функция для создания директории, если она не существует
ensure_directory() {
    local dir=$1
    mkdir -p "$dir"
    chmod 750 "$dir"
}

# Функция для проверки действительности существующего сертификата
is_cert_valid() {
    local cert_path=$1
    if [ ! -f "$cert_path" ]; then
        return 1
    fi

    # Получение даты истечения сертификата в формате epoch
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

# Функция для генерации сертификата для сервиса
generate_certificate() {
    local service=$1
    local config=$2

    echo "Генерация сертификата для $service..."

    # Извлечение значений из конфигурации
    local common_name=$(echo "$config" | yq eval ".services.$service.common_name" -)
    local cert_path=$(echo "$config" | yq eval ".services.$service.cert_path" -)
    local cert_file=$(echo "$config" | yq eval ".services.$service.cert_file" -)
    local key_file=$(echo "$config" | yq eval ".services.$service.key_file" -)
    local ca_file=$(echo "$config" | yq eval ".services.$service.ca_file" -)
    local ttl=$(echo "$config" | yq eval ".services.$service.ttl" -)
    local keystore_password=$(echo "$config" | yq eval ".services.$service.keystore_password" -)
    local truststore_password=$(echo "$config" | yq eval ".services.$service.truststore_password" -)

    # Проверка наличия паролей для keystore и truststore
    local has_keystore_password=false
    local has_truststore_password=false

    if [ -n "$keystore_password" ]; then
        has_keystore_password=true
    fi

    if [ -n "$truststore_password" ]; then
        has_truststore_password=true
    fi

    # Преобразование alt_names в строку с разделителями запятой
    local alt_names=$(echo "$config" | yq eval ".services.$service.alt_names[]" - | tr '\n' ',' | sed 's/,$//')

    # Создание временной директории для сервиса
    local temp_service_dir="$TEMP_DIR/$service"
    ensure_directory "$temp_service_dir"

    # Проверка наличия существующего сертификата
    local final_dir="$SSL_BASE_DIR/$service"
    ensure_directory "$final_dir"

    if [ -f "$final_dir/$cert_file" ] && [ -f "$final_dir/$key_file" ] && [ -f "$final_dir/$ca_file" ]; then
        echo "Сертификат для $service уже существует в $final_dir, пропускаем генерацию."
        return
    fi

    # Генерация сертификата с помощью Vault PKI
    vault write -format=json pki/issue/bitdive \
        common_name="$common_name" \
        alt_names="$alt_names" \
        ttl="$ttl" > "$temp_service_dir/cert.json"

    # Проверка успешности генерации
    if [ $? -ne 0 ]; then
        echo "Ошибка при генерации сертификата через Vault PKI."
        exit 1
    fi

    # Извлечение сертификата и ключа
    jq -r '.data.certificate' "$temp_service_dir/cert.json" > "$temp_service_dir/$cert_file"
    jq -r '.data.private_key' "$temp_service_dir/cert.json" > "$temp_service_dir/$key_file"
    jq -r '.data.issuing_ca' "$temp_service_dir/cert.json" > "$temp_service_dir/$ca_file"

    # Копирование в конечную директорию
    cp "$temp_service_dir/$cert_file" "$final_dir/$cert_file"
    cp "$temp_service_dir/$key_file" "$final_dir/$key_file"
    cp "$temp_service_dir/$ca_file" "$final_dir/$ca_file"

    chmod 600 "$final_dir/$key_file"       # Только чтение и запись для владельца
    chmod 644 "$final_dir/$cert_file"      # Чтение для всех пользователей
    chmod 644 "$final_dir/$ca_file"        # Чтение для всех пользователей
    chmod 755 "$final_dir"

    # Проверка необходимости создания keystore и truststore
    if [[ "$service" == "postgres-client-keycloak" || "$service" == "keycloak-https" ]]; then
        echo "Создание keystore.jks и truststore.jks для $service..."

        # Параметры для keystore
        local keystore_file="$final_dir/keystore.jks"
        local alias="$service"
        local p12_file="$final_dir/$service.p12"

        # Создание PKCS#12 файла, если существует keystore_password
        if $has_keystore_password; then
            openssl pkcs12 -export \
                -inkey "$final_dir/$key_file" \
                -in "$final_dir/$cert_file" \
                -certfile "$final_dir/$ca_file" \
                -out "$p12_file" \
                -name "$alias" \
                -password pass:"$keystore_password"

            if [ $? -ne 0 ]; then
                echo "Ошибка при создании PKCS#12 файла для $service."
                exit 1
            fi

            # Импорт PKCS#12 в JKS keystore
            keytool -importkeystore \
                -srckeystore "$p12_file" \
                -srcstoretype PKCS12 \
                -srcstorepass "$keystore_password" \
                -destkeystore "$keystore_file" \
                -deststoretype JKS \
                -deststorepass "$keystore_password" \
                -alias "$alias" \
                -noprompt

            if [ $? -ne 0 ]; then
                echo "Ошибка при создании keystore.jks для $service."
                exit 1
            fi

            # Удаление временного PKCS#12 файла
            rm -f "$p12_file"

            # Установка прав доступа для keystore.jks
            chmod 644 "$keystore_file"

            echo "keystore.jks создан в $keystore_file"
        fi

        # Создание truststore, если существует truststore_password
        if $has_truststore_password; then
            local truststore_file="$final_dir/truststore.jks"
            keytool -importcert \
                -alias "$service-ca" \
                -file "$final_dir/$ca_file" \
                -keystore "$truststore_file" \
                -storepass "$truststore_password" \
                -noprompt

            if [ $? -ne 0 ]; then
                echo "Ошибка при создании truststore.jks для $service."
                exit 1
            fi

            chmod 644 "$truststore_file"

            echo "truststore.jks создан в $truststore_file"
        fi
    fi

    echo "Сертификаты для $service сгенерированы в $final_dir"
}

# Функция для мониторинга сертификатов и обновления их при необходимости
monitor_certificates() {
    local config=$1

    while true; do
        echo "Проверка сертификатов на наличие обновлений..."
        local services=$(echo "$config" | yq eval '.services | keys | .[]' -)

        for service in $services; do
            local cert_file="$SSL_BASE_DIR/$service/$(echo "$config" | yq eval ".services.$service.cert_file" -)"

            if [ -f "$cert_file" ]; then
                # Проверка даты истечения сертификата
                expiry_date=$(openssl x509 -enddate -noout -in "$cert_file" | cut -d= -f2)
                expiry_epoch=$(date -d "$expiry_date" +%s)
                current_epoch=$(date +%s)
                days_until_expiry=$(( (expiry_epoch - current_epoch) / 86400 ))

                if [ "$days_until_expiry" -lt 30 ]; then
                    echo "Сертификат для $service истекает через $days_until_expiry дней. Обновляем..."
                    generate_certificate "$service" "$config"
                else
                    echo "Сертификат для $service действителен еще $days_until_expiry дней."
                fi
            else
                echo "Сертификат для $service не найден. Генерация нового сертификата..."
                generate_certificate "$service" "$config"
            fi
        done

        # Ожидание 24 часа перед следующей проверкой
        sleep 86400
    done
}

# Функция для создания политики pki-user
create_pki_policy() {
    if ! vault policy list | grep -qw "pki-user"; then
        echo "Создание политики pki-user..."
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
        echo "Политика pki-user создана."
    else
        echo "Политика pki-user уже существует."
    fi
}

# Функция для создания политики transit-user
create_transit_policy() {
    if ! vault policy list | grep -qw "transit-user"; then
        echo "Создание политики transit-user..."
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
        echo "Политика transit-user создана."
    else
        echo "Политика transit-user уже существует."
    fi
}

# Функция для создания политики kv-user
create_kv_policy() {
    if ! vault policy list | grep -qw "kv-user"; then
        echo "Создание политики kv-user..."
        cat <<EOF > /tmp/kv-user.hcl
path "secret/data-encryption-key" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "secret/metadata/data-encryption-key" {
  capabilities = ["list"]
}
EOF
        vault policy write kv-user /tmp/kv-user.hcl
        echo "Политика kv-user создана."
    else
        echo "Политика kv-user уже существует."
    fi
}

# Функция для настройки Auth, Политик и Пользователей в Vault
configure_vault_auth_policies_users() {
    # Включение метода аутентификации userpass, если он не включен
    if ! vault auth list -format=json | jq -e '.["userpass/"]' >/dev/null; then
        echo "Включение метода аутентификации userpass..."
        vault auth enable userpass
    else
        echo "Метод аутентификации userpass уже включен."
    fi

    # Создание политик
    create_pki_policy
    create_transit_policy
    create_kv_policy

    # Проверка и создание пользователя
    if [ ! -f "$USER_INFO_FILE" ]; then
        echo "Создание пользователя..."
        USERNAME="${VAULT_LOGIN}"
        PASSWORD="${VAULT_PASSWORD}"

        vault write auth/userpass/users/$USERNAME \
            password="$PASSWORD" \
            policies="pki-user,transit-user,kv-user"

        # Сохранение информации о пользователе
        cat <<EOF > "$USER_INFO_FILE"
{
  "username": "$USERNAME",
  "password": "$PASSWORD",
  "policies": ["pki-user", "transit-user", "kv-user"]
}
EOF
        echo "Пользователь $USERNAME создан с политиками pki-user, transit-user, kv-user."
    else
        echo "Пользователь уже существует. Файл с информацией о пользователе найден."
    fi
}

# Функция для настройки Secret Engines (PKI и Transit) в Vault
configure_vault_secrets_engines() {
    # Включение PKI Secret Engine, если он не включен
    if ! vault secrets list -format=json | jq -e '.["pki/"]' >/dev/null; then
        echo "Включение PKI Secret Engine..."
        vault secrets enable pki
    else
        echo "PKI Secret Engine уже включен."
    fi

    # Проверка и генерация корневого сертификата
    if ! vault read pki/config/ca >/dev/null 2>&1; then
        echo "Генерация корневого сертификата..."
        vault write pki/root/generate/internal \
            common_name="bitdive" \
            ttl="87600h" \
            private_key_format="pkcs8"
    else
        echo "Корневой сертификат уже существует."
    fi

    # Настройка URL для PKI
    current_issuing_cert=$(vault read -field=issuing_certificates pki/config/urls 2>/dev/null || echo "")
    desired_issuing_cert="$VAULT_ADDR/v1/pki/ca"
    current_crl_dp=$(vault read -field=crl_distribution_points pki/config/urls 2>/dev/null || echo "")
    desired_crl_dp="$VAULT_ADDR/v1/pki/crl"

    if [ "$current_issuing_cert" != "$desired_issuing_cert" ] || [ "$current_crl_dp" != "$desired_crl_dp" ]; then
        echo "Настройка URL для PKI..."
        vault write pki/config/urls \
            issuing_certificates="$desired_issuing_cert" \
            crl_distribution_points="$desired_crl_dp"
    else
        echo "URL для PKI уже настроены."
    fi

    # Проверка и создание роли 'bitdive'
    if ! vault read pki/roles/bitdive >/dev/null 2>&1; then
        echo "Создание роли 'bitdive'..."
        vault write pki/roles/bitdive \
            allowed_domains="bitdive.local,localhost" \
            allow_subdomains=true \
            allow_glob_domains=true \
            allow_any_name=true \
            enforce_hostnames=false \
            max_ttl="720h"
    else
        echo "Роль 'bitdive' уже существует."
    fi

    # Включение Transit Secret Engine, если он не включен
    if ! vault secrets list -format=json | jq -e '.["transit/"]' >/dev/null; then
        echo "Включение Transit Secret Engine..."
        vault secrets enable transit
    else
        echo "Transit Secret Engine уже включен."
    fi

    # Проверка и создание ключей для Transit
    if ! vault read transit/keys/encryption-key >/dev/null 2>&1; then
        echo "Создание 'encryption-key' для Transit..."
        vault write -f transit/keys/encryption-key type=aes256-gcm96 exportable=true auto_rotate_period=24h
    else
        echo "'encryption-key' для Transit уже существует."
    fi

    if ! vault read transit/keys/signing-key >/dev/null 2>&1; then
        echo "Создание 'signing-key' для Transit..."
        vault write -f transit/keys/signing-key type=ecdsa-p256 exportable=true auto_rotate_period=24h
    else
        echo "'signing-key' для Transit уже существует."
    fi
}

# Функция для настройки KV Secret Engine и сохранения статического ключа
configure_vault_kv_secret_engine() {
    # Включение KV Secret Engine по пути secret/, если он не включенvault write -f transit/keys/signing-key
    if ! vault secrets list -format=json | jq -e '.["secret/"]' >/dev/null; then
        echo "Включение KV Secret Engine по пути secret/..."
        vault secrets enable -path=secret kv
    else
        echo "KV Secret Engine уже включен по пути secret/."
    fi

    # Проверка и сохранение статического ключа в KV
    if ! vault kv get secret/data-encryption-key >/dev/null 2>&1; then
        echo "Создание статического ключа для шифрования данных в KV..."
        # Генерация случайного ключа
        GENERATED_KEY=$(openssl rand -base64 32)
        vault kv put secret/data-encryption-key key="$GENERATED_KEY"
    else
        echo "Статический ключ для шифрования данных уже существует в KV."
    fi
}



# Основная функция
main() {

    check_requirements
    ensure_directory "$TEMP_DIR"
    ensure_directory "$SSL_BASE_DIR"

    # Генерация certificates-config.yaml.template из шаблона
    envsubst < /vault/scripts/certificates-config.yaml.template > "$CONFIG_FILE"

    # Чтение конфигурации
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "Ошибка: Файл конфигурации не найден по пути $CONFIG_FILE"
        exit 1
    fi

    config=$(cat "$CONFIG_FILE")

    # Настройка Auth, Политик и Пользователей
    configure_vault_auth_policies_users

    # Настройка Secret Engines (PKI и Transit)
    configure_vault_secrets_engines

    # Настройка KV Secret Engine и сохранение статического ключа
    configure_vault_kv_secret_engine

    # Первоначальная генерация сертификатов
    services=$(echo "$config" | yq eval '.services | keys | .[]' -)
    for service in $services; do
        cert_file="$SSL_BASE_DIR/$service/$(echo "$config" | yq eval ".services.$service.cert_file" -)"
        if is_cert_valid "$cert_file"; then
            echo "Сертификат для $service действителен. Пропуск генерации."
        else
            if [ -f "$cert_file" ]; then
                echo "Сертификат для $service истекает или недействителен. Генерация нового сертификата..."
            else
                echo "Сертификат для $service не найден. Генерация нового сертификата..."
            fi
            generate_certificate "$service" "$config"
        fi
    done

    # Запуск мониторинга сертификатов в фоновом режиме
    monitor_certificates "$config" &
}

# Выполнение основной функции
main "$@"
