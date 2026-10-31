#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source .env
DOMAINS=("$NEXUS_DOMAIN" "$REGISTRY_1_DOMAIN" "$REGISTRY_2_DOMAIN")
mkdir -p certs
mkcert -cert-file certs/"$NEXUS_DOMAIN".pem -key-file certs/"$NEXUS_DOMAIN"-key.pem "${DOMAINS[@]}"
for d in "${DOMAINS[@]}"; do
  grep -qw "$d" /etc/hosts || echo "127.0.0.1 $d" | sudo tee -a /etc/hosts
done
