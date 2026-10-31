# Nexus Repository Manager behind an nginx TLS Reverse Proxy

Containerised deployment of Sonatype Nexus Repository (Community Edition) with nginx as a TLS-terminating reverse proxy. The stack uses a locally trusted certificate and a local domain, and is defined entirely as code with Docker Compose.

## Table of Contents

1. [Overview](#1-overview)
2. [Architecture](#2-architecture)
3. [Prerequisites](#3-prerequisites)
4. [Repository Structure](#4-repository-structure)
5. [Configuration](#5-configuration)
6. [Deployment](#6-deployment)
7. [Verification](#7-verification)
8. [Operations](#8-operations)
9. [Troubleshooting](#9-troubleshooting)
10. [Security Notes](#10-security-notes)
11. [Accessing from Other Machines](#11-accessing-from-other-machines)

---

## 1. Overview

| Item | Value |
|------|-------|
| Application | Sonatype Nexus Repository, Community Edition |
| Nexus image | `sonatype/nexus3:3.97.3` (pinned) |
| Reverse proxy | `nginx:stable-alpine` |
| Domain | `nexus.work.local` (configurable) |
| TLS | Certificate issued by a local mkcert CA |
| Orchestration | Docker Compose |

Design goals:

- **Reproducible.** Image versions are pinned and all configuration lives in version control.
- **Single source of truth.** The domain is defined once in `.env` and propagated to the certificate script, the nginx configuration and the hosts entry.
- **Minimal exposure.** Only nginx publishes ports on the host. Nexus is reachable only through the proxy.

## 2. Architecture

```
                      Docker network: nexus_default
                 ┌──────────────────────────────────────┐
 Browser ──443──▶│  nginx  ──── HTTP :8081 ────▶  nexus │
 Browser ──80───▶│  (TLS)                               │
   (redirect)    └──────────────────────────────────────┘
                                                  │
                                         volume: nexus_nexus-data
```

- nginx terminates TLS on port 443 and redirects HTTP (port 80) to HTTPS.
- nginx forwards requests to the `nexus` service on port 8081 over the internal Docker network.
- Nexus data is stored in the named volume `nexus_nexus-data`, which avoids host file-permission issues (Nexus runs as UID 200).
- nginx starts only after the Nexus health check passes.

## 3. Prerequisites

| Requirement | Notes |
|-------------|-------|
| Docker Engine and Docker Compose v2 | Verify with `docker compose version` |
| [mkcert](https://github.com/FiloSottile/mkcert) | Creates the local CA and certificate |
| `libnss3-tools` | Required so mkcert can register the CA with Chrome and Firefox |
| `sudo` access | Needed once, to add the hosts entry |
| Free ports 80 and 443 | Check with `sudo ss -tlnp \| grep -E ':80 \|:443 '` |
| At least 4 GB of RAM | Recommended for Nexus |

Install the local CA once per machine, then restart the browser:

```bash
mkcert -install
```

## 4. Repository Structure

```
.
├── compose.yaml                 # Service definitions
├── .env                         # Non-secret configuration (images, domain)
├── .gitignore                   # Excludes certs/
├── nginx/
│   └── nexus.conf.template      # nginx config, rendered at container start
├── scripts/
│   └── gen-certs.sh             # Certificate and hosts-entry generation
└── certs/                       # Generated at deploy time, not versioned
```

## 5. Configuration

All settings are in `.env`:

| Variable | Description | Example |
|----------|-------------|---------|
| `NEXUS_IMAGE` | Nexus image and pinned tag | `sonatype/nexus3:3.97.3` |
| `NGINX_IMAGE` | nginx image and tag | `nginx:stable-alpine` |
| `NEXUS_DOMAIN` | Hostname used for the certificate, hosts entry and nginx | `nexus.work.local` |

### How the nginx template works

nginx renders `nginx/nexus.conf.template` when the container starts. Variables written as `${NEXUS_DOMAIN}` are replaced with the container's environment values. nginx's own variables, such as `$host` and `$scheme`, are left unchanged.

Key behaviour of the configuration:

| Directive | Purpose |
|-----------|---------|
| `return 301 https://$host$request_uri` | Redirects all HTTP traffic to HTTPS |
| `ssl_protocols TLSv1.2 TLSv1.3` | Permits modern TLS versions only |
| `client_max_body_size 0` | Removes the upload size limit, which is required for large artifacts |
| `proxy_pass http://nexus:8081` | Forwards requests to the Nexus container |
| `X-Forwarded-*` headers | Preserve the original host, client IP and protocol for Nexus |
| `proxy_read_timeout 300s` | Allows long-running requests to complete |

## 6. Deployment

```bash
# 1. Generate the certificate and add the hosts entry (prompts for sudo once)
./scripts/gen-certs.sh

# 2. Validate the compose file and the nginx configuration
docker compose config -q
docker compose run --rm --no-deps nginx nginx -t

# 3. Start the stack
docker compose up -d
```

Nexus needs one to two minutes to initialise. Follow progress with:

```bash
docker compose logs -f nexus
docker compose ps        # nexus should report "healthy"
```

### First login

Retrieve the generated administrator password:

```bash
docker compose exec -T nexus cat /nexus-data/admin.password; echo
```

Open `https://nexus.work.local` and sign in as `admin`. The setup wizard asks you to set a new password. Nexus deletes the password file once the password has been changed.

## 7. Verification

| Check | Command | Expected result |
|-------|---------|-----------------|
| Hostname resolves | `getent hosts nexus.work.local` | `127.0.0.1 nexus.work.local` |
| HTTPS works with a trusted certificate | `curl -I https://nexus.work.local` | `HTTP/1.1 200 OK` |
| HTTP redirects to HTTPS | `curl -I http://nexus.work.local` | `301` with an `https://` location |
| Containers are running | `docker compose ps` | nexus `healthy`, nginx `Up` |
| Nexus status API | `curl -s https://nexus.work.local/service/rest/v1/status` | HTTP 200 |

## 8. Operations

### Start, stop and inspect

```bash
docker compose up -d           # start
docker compose down            # stop (data is kept)
docker compose logs -f nginx   # follow nginx logs
docker compose logs -f nexus   # follow Nexus logs
```

### Change the domain

1. Edit `NEXUS_DOMAIN` in `.env`.
2. Run `./scripts/gen-certs.sh` to create a new certificate and hosts entry.
3. Run `docker compose up -d --force-recreate nginx`.

### Upgrade Nexus

1. Review the Sonatype release notes and take a backup (see below).
2. Update the tag in `NEXUS_IMAGE` in `.env`.
3. Run `docker compose pull && docker compose up -d`.

### Backup and restore

Stop Nexus before copying its data to keep the backup consistent.

```bash
docker compose stop nexus
docker run --rm \
  -v nexus_nexus-data:/data:ro \
  -v "$PWD":/backup \
  alpine tar czf /backup/nexus-data-$(date +%F).tar.gz -C /data .
docker compose start nexus
```

To restore, extract the archive into an empty `nexus_nexus-data` volume with the same approach in reverse.

### Full reset

> **Warning:** this permanently deletes all Nexus data, including repositories, users and settings.

```bash
docker compose down -v
docker compose up -d
```

## 9. Troubleshooting

| Symptom | Likely cause | Resolution |
|---------|--------------|------------|
| nginx restarts continuously | Syntax error in the rendered configuration | Run `docker compose logs nginx` and `docker compose run --rm --no-deps nginx nginx -t`. Check `nginx/nexus.conf.template` for stray characters, such as a backslash before a semicolon |
| "Not secure" warning in the browser | The mkcert CA is not trusted by the browser | Run `mkcert -install`, make sure `libnss3-tools` is installed, then fully restart the browser |
| `curl` reports a certificate error | The CA is missing from the system trust store | Run `mkcert -install` |
| Host cannot be resolved | Missing hosts entry | Run `./scripts/gen-certs.sh` or add `127.0.0.1 nexus.work.local` to `/etc/hosts` |
| `bind: address already in use` | Another service uses port 80 or 443 | Stop that service, or change the published ports in `compose.yaml` |
| Pull fails with a timeout | Docker Hub connectivity | Retry the pull. Docker keeps completed layers |
| Image tag not found | The tag does not exist on Docker Hub | Pin the release tag (for example `3.97.3`) or the image digest |
| Login fails with the generated password | Copy and paste error, or the password was already changed | Print it with a trailing newline (see [First login](#first-login)). If the file no longer exists, the password has been changed |
| Health check errors in the Nexus log | The built-in repository health check cannot reach the internet | These can be ignored in an offline or restricted environment |

## 10. Security Notes

- **Local CA.** The mkcert root key (`rootCA-key.pem`, in the directory shown by `mkcert -CAROOT`) can issue certificates trusted by this machine. Keep it private and never commit it.
- **Private key.** `certs/` contains the server private key and is excluded from version control by `.gitignore`.
- **Anonymous access.** Disable anonymous access in the Nexus setup wizard unless it is explicitly required.
- **Administrator credentials.** Change the generated password on first login, and store the new one in a password manager.
- **Exposure.** Nexus publishes no host ports. All traffic passes through nginx.
- **HSTS.** Nexus sends a `Strict-Transport-Security` header, so browsers will refuse plain HTTP for this domain after the first HTTPS visit.
- **Certificate validity.** The certificate is valid until 31 January 2029. Regenerate it with `./scripts/gen-certs.sh` before it expires.

## 11. Accessing from Other Machines

By default the hosts entry points to `127.0.0.1`, so the service is reachable from the deploying machine only. To use it from another machine:

1. Add `<server-LAN-IP> nexus.work.local` to that machine's hosts file, or create a DNS record.
2. Copy `rootCA.pem` from the directory shown by `mkcert -CAROOT` and import it as a trusted authority on that machine. Never copy `rootCA-key.pem`.
3. Allow inbound TCP ports 80 and 443 on the server's firewall.
