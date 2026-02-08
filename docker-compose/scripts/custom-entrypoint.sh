#!/bin/sh
# /vault/custom-entrypoint.sh

set -e

# Run Vault initialization script
/vault/scripts/vault-init.sh

# Keep the container running
tail -f /dev/null