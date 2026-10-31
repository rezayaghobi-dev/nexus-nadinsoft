# Docker Registries on Nexus

This document describes the two Docker registries provided by the Nexus instance and how to use them. It extends the main [README](../README.md).

## Overview

| Registry | Domain | Nexus repository | Type | Connector port | Purpose |
|----------|--------|------------------|------|----------------|---------|
| Registry 1 | `registry-1.work.local` | `registry-1` | Proxy | 8082 | Pull-through cache of the ArvanCloud Docker mirror (`https://docker.arvancloud.ir`) |
| Registry 2 | `registry-2.work.local` | `registry-2` | Hosted | 8083 | Local registry for the organisation's own images |

- **Proxy (read-only).** The first pull of an image is fetched from the remote mirror and stored in Nexus. Later pulls are served locally. Pushing to a proxy repository is not possible.
- **Hosted (read-write).** Images are pushed to and pulled from Nexus directly.

Each registry is exposed on its own domain through nginx, which terminates TLS and forwards requests to the matching Nexus connector port. Nexus does not publish these ports on the host.

```
docker client ──443──▶ nginx ──8082──▶ nexus (registry-1, proxy) ──▶ docker.arvancloud.ir
                         └────8083──▶ nexus (registry-2, hosted)
```

## Configuration

The settings live in `.env`:

| Variable | Value |
|----------|-------|
| `REGISTRY_1_DOMAIN` | `registry-1.work.local` |
| `REGISTRY_2_DOMAIN` | `registry-2.work.local` |
| `REGISTRY_1_PORT` | `8082` |
| `REGISTRY_2_PORT` | `8083` |
| `REGISTRY_1_REMOTE_URL` | `https://docker.arvancloud.ir` |

Related files:

| File | Role |
|------|------|
| `nginx/nexus.conf.template` | One server block per domain, rendered at container start |
| `nginx/proxy.conf` | Shared proxy settings, including unlimited upload size and a 900 s timeout for large image layers |
| `scripts/gen-certs.sh` | Issues one certificate covering all three domains and adds the hosts entries |
| `scripts/setup-nexus.sh` | Enables the Docker Bearer Token realm, creates the proxy repository and the hosted repository through the Nexus REST API |

## Setup

Run these steps once, after the stack is up and the admin password has been changed.

```bash
# 1. Certificate and hosts entries for all three domains (prompts for sudo)
./scripts/gen-certs.sh

# 2. Apply the nginx and compose changes
docker compose up -d

# 3. Create the repositories (prompts for the Nexus admin password)
./scripts/setup-nexus.sh

# 4. Let the Docker daemon load the local CA, once per machine
sudo systemctl restart docker
```

`setup-nexus.sh` is idempotent: it skips repositories that already exist. To change a repository's type or remote URL, delete the repository in Nexus first and run the script again.

## Usage

### Registry 1: proxy (pull only)

```bash
docker login registry-1.work.local -u <user>

# Official images need the library/ prefix
docker pull registry-1.work.local/library/alpine:latest

# Other images use their normal namespace
docker pull registry-1.work.local/<namespace>/<image>:<tag>
```

### Registry 2: hosted (push and pull)

```bash
docker login registry-2.work.local -u <user>

docker tag <image>:<tag> registry-2.work.local/<name>/<image>:<tag>
docker push registry-2.work.local/<name>/<image>:<tag>
docker pull registry-2.work.local/<name>/<image>:<tag>
```

## Verification

| Check | Result |
|-------|--------|
| Remote mirror reachable (`curl -I https://docker.arvancloud.ir/v2/`) | HTTP 401 with a bearer challenge, as expected for a registry |
| `docker login` to both registries | Login Succeeded |
| Pull `library/alpine` through registry-1 | Downloaded, image visible under Browse in Nexus |
| Push to registry-1 | Rejected with `404 Not Found`, as expected for a proxy |
| Push and pull `test/nginx` on registry-2 | Successful, digests match |

## Troubleshooting

| Symptom | Likely cause | Resolution |
|---------|--------------|------------|
| Certificate error on `docker login` | The Docker daemon has not loaded the mkcert CA | Run `mkcert -install`, then `sudo systemctl restart docker` |
| `unauthorized` or HTTP 401 | Docker Bearer Token realm is inactive, or the login expired | Re-run `./scripts/setup-nexus.sh`, check Security > Realms in Nexus, then run `docker login` again |
| Push to registry-1 fails with 404 | Registry 1 is a proxy and is read-only | Push to registry-2 instead |
| Pull from registry-1 fails or times out | The remote mirror is unreachable from the server | Check `curl -I https://docker.arvancloud.ir/v2/` and `docker compose logs nexus` |
| Pull of an official image fails on registry-1 | Missing `library/` prefix | Use `registry-1.work.local/library/<image>` |
| HTTP 502 from nginx | Nexus is still starting | Wait for `docker compose ps` to report nexus as healthy |
| Host not found | Missing hosts entry | Run `./scripts/gen-certs.sh` |

## Security Notes

- `docker login` stores credentials unencrypted in `~/.docker/config.json` by default. Configure a Docker credential helper on shared machines.
- Use the admin account only for setup. For daily work, create dedicated Nexus users with roles limited to the relevant repository.
- The proxy repository fetches content from a third-party mirror. Treat cached images like any external image and scan them before use in production.
- Docker clients on other machines must trust the mkcert root CA and resolve both domains. See the main README for the steps.
