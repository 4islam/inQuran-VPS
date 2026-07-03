# inQuran VPS Deploy

Infrastructure-as-code for deploying [inQuran.com](https://inquran.com) to self-hosted VPS infrastructure.

## Architecture

| Server | Role | IP |
|---|---|---|
| Staging | `uat.inquran.com` | `159.69.12.202` |
| Production | `inquran.com` | `142.132.160.191` |

Both servers run:
- **Nginx** — reverse proxy + SSL termination (Let's Encrypt)
- **PM2** — process manager for the Astro Node.js app
- **Self-hosted Supabase** — full Postgres + PostgREST + Auth stack via Docker

## Quick Start

### 1. Set up secrets

```bash
cp deploy/secrets.env.template ~/.inquran-secrets
chmod 600 ~/.inquran-secrets
# Edit ~/.inquran-secrets with real values
```

### 2. Deploy to staging

```bash
./deploy/release.sh staging
```

### 3. Deploy to production (runs staging first)

```bash
./deploy/release.sh production
```

### 4. Force a full DB wipe + reseed

```bash
./deploy/release.sh staging --full-reseed
./deploy/release.sh production --full-reseed
```

## Scripts

| Script | Runs On | Purpose |
|---|---|---|
| `release.sh` | Local Mac | **Main entry point** — orchestrates the full pipeline |
| `deploy_app.sh` | Remote VPS | Blue/green app deploy via symlink + PM2 reload |
| `seed_db.sh` | Remote VPS | DB migrations + seeding (idempotent or full reseed) |
| `smoke_test.sh` | Remote VPS | Health checks — verifies app, Nginx, Supabase, data |
| `setup_nginx.sh` | Remote VPS | First-time Nginx config + SSL certificates |
| `deploy_supabase.sh` | Remote VPS | First-time Supabase Docker stack setup |
| `bootstrap_ubuntu.sh` | Remote VPS | First-time OS setup (Node, Docker, PM2, UFW) |
| `switch_cloudflare.sh` | Local Mac | Switches Cloudflare DNS A records |

## Release Pipeline

```
[1] Deploy app → STAGING  (blue/green, zero downtime)
[2] Seed DB   → STAGING   (idempotent by default)
[3] Smoke tests on STAGING (fails fast before touching production)
        ↓ abort if staging fails
[4] Deploy app → PRODUCTION (blue/green, zero downtime)
[5] Seed DB   → PRODUCTION  (idempotent by default)
[6] Smoke tests on PRODUCTION
        ↓ auto-rollback if production fails
[7] Switch Cloudflare DNS → Production VPS
[8] Final public health check via https://inquran.com
```

## Provisioning a Fresh Server

```bash
# 1. Bootstrap OS (run as root on the new server)
ssh root@<NEW_SERVER_IP> "bash -s" < deploy/bootstrap_ubuntu.sh

# 2. Set up Supabase Docker stack
ssh nislam@<NEW_SERVER_IP> "bash -s" < deploy/deploy_supabase.sh

# 3. Configure Nginx for the domain
ssh nislam@<NEW_SERVER_IP> "DOMAIN=inquran.com bash -s" < deploy/setup_nginx.sh

# 4. Deploy the app
./deploy/release.sh staging  # or production
```
