#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source .env

if [ -z "${NEXUS_ADMIN_PASSWORD:-}" ]; then
  read -rsp "Nexus admin password: " NEXUS_ADMIN_PASSWORD; echo
fi
API="https://${NEXUS_DOMAIN}/service/rest/v1"
AUTH=(-u "admin:${NEXUS_ADMIN_PASSWORD}")

echo "Enabling Docker Bearer Token realm"
curl -fsS "${AUTH[@]}" -X PUT "$API/security/realms/active" \
  -H 'Content-Type: application/json' \
  -d '["NexusAuthenticatingRealm","DockerToken"]'

create_repo() {
  local name=$1 port=$2
  if curl -fs "${AUTH[@]}" "$API/repositories/$name" >/dev/null; then
    echo "$name already exists, skipping"; return
  fi
  curl -fsS "${AUTH[@]}" -X POST "$API/repositories/docker/hosted" \
    -H 'Content-Type: application/json' -d @- <<JSON
{
  "name": "$name",
  "online": true,
  "storage": {"blobStoreName": "default", "strictContentTypeValidation": true, "writePolicy": "allow"},
  "docker": {"v1Enabled": false, "forceBasicAuth": true, "httpPort": $port}
}
JSON
  echo "Created $name on port $port"
}

create_repo registry-1 "$REGISTRY_1_PORT"
create_repo registry-2 "$REGISTRY_2_PORT"
