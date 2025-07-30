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

create_readonly_policy() {
  if ! vault policy list | grep -qw "readonly-params"; then
    echo "Создание политики readonly-params..."
    cat >/tmp/readonly-params.hcl <<'EOF'
# читать экспортированные Transit-ключи
path "transit/export/encryption-key/encryption-key" { capabilities = ["read"] }
path "transit/export/signing-key/signing-key"       { capabilities = ["read"] }
# (добавьте другие read-пути при необходимости)
EOF
    vault policy write readonly-params /tmp/readonly-params.hcl
    rm /tmp/readonly-params.hcl
  else
    echo "Политика readonly-params уже существует."
  fi
}

create_readonly_token_role() {
  if ! vault read auth/token/roles/readonly-infinite >/dev/null 2>&1; then
    echo "Создаём token-role readonly-infinite (бессрочные токены)..."
    vault write auth/token/roles/readonly-infinite \
         allowed_policies="readonly-params" \
         orphan=true                \
         period=0                   \
         token_explicit_max_ttl=0
  else
    echo "token-role readonly-infinite уже существует."
  fi
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

    # Флаги наличия паролей
    local has_keystore_password=false
    local has_truststore_password=false
    [ -n "$keystore_password" ]    && has_keystore_password=true
    [ -n "$truststore_password" ]  && has_truststore_password=true

    # alt_names как CSV
    local alt_names
    alt_names=$(echo "$config" | yq eval ".services.$service.alt_names[]" - | paste -sd ',' -)

    # Подготовка директорий
    local temp_service_dir="$TEMP_DIR/$service"
    ensure_directory "$temp_service_dir"
    local final_dir="$SSL_BASE_DIR/$service"
    ensure_directory "$final_dir"

    # Если сертификаты уже есть — выходим
    if [[ -f "$final_dir/$cert_file" && -f "$final_dir/$key_file" && -f "$final_dir/$ca_file" ]]; then
        echo "Сертификат для $service уже существует в $final_dir, пропускаем генерацию."
        return 0
    fi

    # Генерация через Vault PKI
    vault write -format=json pki/issue/bitdive \
        common_name="$common_name" \
        alt_names="$alt_names" \
        ttl="$ttl" > "$temp_service_dir/cert.json"

    # Извлечение в файлы
    jq -r '.data.certificate' "$temp_service_dir/cert.json" > "$temp_service_dir/$cert_file"
    jq -r '.data.private_key' "$temp_service_dir/cert.json" > "$temp_service_dir/$key_file"
    jq -r '.data.issuing_ca'  "$temp_service_dir/cert.json" > "$temp_service_dir/$ca_file"

    # Скопировать в финальную директорию
    cp "$temp_service_dir/$cert_file" "$final_dir/"
    cp "$temp_service_dir/$key_file"  "$final_dir/"
    cp "$temp_service_dir/$ca_file"   "$final_dir/"

    # Права доступа
    chmod 600 "$final_dir/$key_file"
    chmod 644 "$final_dir/$cert_file" "$final_dir/$ca_file"
    chmod 755 "$final_dir"

    # Создание keystore/truststore JKS для Keycloak
    if [[ "$service" == "postgres-client-keycloak" || "$service" == "keycloak-https" ]]; then
        echo "Создание keystore.jks и truststore.jks для $service..."

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
            echo "keystore.jks создан: $final_dir/keystore.jks"
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
            echo "truststore.jks создан: $trust_jks"
        fi
    fi

    # *** Блок создания SMTP-truststore (Zoho) ***
    if [[ "$service" == "smtp-zoho" ]] && $has_truststore_password; then
        local tmp_pem="$final_dir/smtp-zoho.pem"

        # Скачиваем все сертификаты с сервера Zoho и сохраняем в smtp-zoho.pem
        openssl s_client -connect smtp.zoho.eu:465 -showcerts </dev/null \
          | awk '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/' \
          > "$tmp_pem"

        # Проверим, что файл не пустой
        if [[ -s "$tmp_pem" ]]; then
          echo "Файл smtp-zoho.pem успешно создан и содержит сертификаты."
        else
          echo "Ошибка: smtp-zoho.pem пуст или не создан."
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

create_token_issuer_policy() {
  if ! vault policy list | grep -qw "token-issuer"; then
    echo "Создание политики token-issuer..."
    cat >/tmp/token-issuer.hcl <<'EOF'
#  ==========  AppRole  ==========
path "auth/approle/role/readonly-role/role-id"   { capabilities = ["read"] }
path "auth/approle/role/readonly-role/secret-id" { capabilities = ["update"] }

#  ==========  service-токены  ==========
path "auth/token/create"                         { capabilities = ["create", "update"] }
path "auth/token/create/readonly-infinite"       { capabilities = ["create", "update"] }
EOF
    vault policy write token-issuer /tmp/token-issuer.hcl
    rm /tmp/token-issuer.hcl
  else
    echo "Политика token-issuer уже существует."
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

# Разрешаем создание, чтение и удаление записей
path "secret/data/credentials-bit-dive/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# Разрешаем просмотр метаданных
path "secret/metadata/credentials-bit-dive/*" {
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

    create_readonly_policy
    create_readonly_token_role
    create_token_issuer_policy

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
            policies="pki-user,transit-user,kv-user,token-issuer"

        # Сохранение информации о пользователе
cat <<EOF > "$USER_INFO_FILE"
{
  "username": "$USERNAME",
  "password": "$PASSWORD",
  "policies": ["pki-user", "transit-user", "kv-user", "token-issuer"]
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
            ttl="876000h" \
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
            max_ttl="875999h"
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
