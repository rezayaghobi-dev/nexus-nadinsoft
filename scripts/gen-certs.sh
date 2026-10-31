#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source .env
mkdir -p certs
mkcert -cert-file certs/"$NEXUS_DOMAIN".pem -key-file certs/"$NEXUS_DOMAIN"-key.pem "$NEXUS_DOMAIN"
grep -q "$NEXUS_DOMAIN" /etc/hosts || echo "127.0.0.1 $NEXUS_DOMAIN" | sudo tee -a /etc/hosts
