#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source .env

if [ -z "${NEXUS_ADMIN_PASSWORD:-}" ]; then
  read -rsp "Nexus admin password: " NEXUS_ADMIN_PASSWORD; echo
fi
API="https://${NEXUS_DOMAIN}/service/rest/v1"
AUTH=(-u "admin:${NEXUS_ADMIN_PASSWORD}")

repo_exists() { curl -fs "${AUTH[@]}" "$API/repositories/$1" >/dev/null; }

echo "Enabling Docker Bearer Token realm"
curl -fsS "${AUTH[@]}" -X PUT "$API/security/realms/active" \
  -H 'Content-Type: application/json' \
  -d '["NexusAuthenticatingRealm","DockerToken"]'

create_hosted() {
  local name=$1 port=$2
  if repo_exists "$name"; then echo "$name already exists, skipping"; return; fi
  curl -fsS "${AUTH[@]}" -X POST "$API/repositories/docker/hosted" \
    -H 'Content-Type: application/json' -d @- <<JSON
{
  "name": "$name",
  "online": true,
  "storage": {"blobStoreName": "default", "strictContentTypeValidation": true, "writePolicy": "allow"},
  "docker": {"v1Enabled": false, "forceBasicAuth": true, "httpPort": $port}
}
JSON
  echo "Created hosted repository $name on port $port"
}

create_proxy() {
  local name=$1 port=$2 remote=$3
  if repo_exists "$name"; then echo "$name already exists, skipping"; return; fi
  curl -fsS "${AUTH[@]}" -X POST "$API/repositories/docker/proxy" \
    -H 'Content-Type: application/json' -d @- <<JSON
{
  "name": "$name",
  "online": true,
  "storage": {"blobStoreName": "default", "strictContentTypeValidation": true},
  "proxy": {"remoteUrl": "$remote", "contentMaxAge": 1440, "metadataMaxAge": 1440},
  "negativeCache": {"enabled": true, "timeToLive": 1440},
  "httpClient": {"blocked": false, "autoBlock": true},
  "docker": {"v1Enabled": false, "forceBasicAuth": true, "httpPort": $port},
  "dockerProxy": {"indexType": "REGISTRY"}
}
JSON
  echo "Created proxy repository $name on port $port -> $remote"
}

create_proxy  registry-1 "$REGISTRY_1_PORT" "$REGISTRY_1_REMOTE_URL"
create_hosted registry-2 "$REGISTRY_2_PORT"
