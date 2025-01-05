#!/bin/sh
# /vault/custom-entrypoint.sh

set -e

# Запуск скрипта инициализации Vault
/vault/scripts/vault-init.sh

# Поддержание контейнера активным
tail -f /dev/null