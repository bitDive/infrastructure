storage "file" {
  path = "/vault/file"
}

listener "tcp" {
  address = "0.0.0.0:8200"
  tls_cert_file = "/vault/keys/vault.crt"
  tls_key_file  = "/vault/keys/vault.key"
}

ui = true

api_addr = "https://localhost:8200"
