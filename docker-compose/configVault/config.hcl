storage "file" {
  path = "/vault/file"
}

listener "tcp" {
  address = "0.0.0.0:8200"
  tls_cert_file = "/vault/keys/vault.crt"
  tls_key_file  = "/vault/keys/vault.key"
}

ui = false

api_addr = "https://vault.localhost"
cluster_addr = "https://vault-server:8201"

# Настройки для работы с префиксом
path_prefix = "/vault"


default_lease_ttl = "24h"
max_lease_ttl     = "876000h"