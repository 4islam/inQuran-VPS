#!/bin/bash
# =============================================================================
# release.sh — inQuran Deployment Orchestrator
#
# Runs LOCALLY on your Mac. SSHes into servers to execute sub-scripts.
#
# Usage:
#   ./deploy/release.sh staging               # Deploy to staging only
#   ./deploy/release.sh production            # Full staging → production pipeline
#   ./deploy/release.sh staging --full-reseed # Full DB wipe + reseed on staging
#   ./deploy/release.sh production --full-reseed # Full reseed on both envs
#
# Prerequisites:
#   - ~/.inquran-secrets exists (see deploy/secrets.env.template)
#   - SSH agent is running with your key loaded: ssh-add ~/.ssh/id_ed25519
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
TARGET="${1:-}"
FULL_RESEED="false"
for arg in "$@"; do
    if [ "$arg" = "--full-reseed" ]; then
        FULL_RESEED="true"
    fi
done

if [ -z "$TARGET" ] || { [ "$TARGET" != "staging" ] && [ "$TARGET" != "production" ]; }; then
    echo "Usage: $0 <staging|production> [--full-reseed]"
    echo ""
    echo "  staging     — Deploy app + seed DB on staging only"
    echo "  production  — Full pipeline: staging first, then production, then Cloudflare"
    echo ""
    echo "  --full-reseed  — Wipe DB and reseed all data (use for schema resets)"
    exit 1
fi

# ---------------------------------------------------------------------------
# Load secrets
# ---------------------------------------------------------------------------
SECRETS_FILE="$HOME/.inquran-secrets"
if [ ! -f "$SECRETS_FILE" ]; then
    echo "❌ Secrets file not found: $SECRETS_FILE"
    echo "   Copy deploy/secrets.env.template to ~/.inquran-secrets and fill in values."
    exit 1
fi
source "$SECRETS_FILE"

# Validate required secrets
: "${STAGING_HOST:?Missing STAGING_HOST in ~/.inquran-secrets}"
: "${PROD_HOST:?Missing PROD_HOST in ~/.inquran-secrets}"
: "${CF_ZONE_ID:?Missing CF_ZONE_ID in ~/.inquran-secrets}"
: "${CF_TOKEN:?Missing CF_TOKEN in ~/.inquran-secrets}"
: "${PROD_DOMAIN:?Missing PROD_DOMAIN in ~/.inquran-secrets}"
: "${SSH_USER:?Missing SSH_USER in ~/.inquran-secrets}"

# Derive staging domain from prod domain (uat. prefix)
STAGING_DOMAIN="uat.${PROD_DOMAIN}"

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
PREV_PROD_IP=""

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
section() { echo ""; echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; echo "  $*"; echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; }
log()     { echo "  [release] $*"; }
ok()      { echo "  [release] ✅ $*"; }
fail()    { echo "  [release] ❌ $*" >&2; }

# ---------------------------------------------------------------------------
# Upload deploy scripts to a server
# ---------------------------------------------------------------------------
upload_scripts() {
    local HOST="$1"
    log "Uploading deploy scripts to $HOST..."
    ssh -A -o StrictHostKeyChecking=accept-new "$SSH_USER@$HOST" "mkdir -p ~/deploy"
    scp -q "$DEPLOY_DIR/deploy_app.sh" \
           "$DEPLOY_DIR/seed_db.sh" \
           "$DEPLOY_DIR/smoke_test.sh" \
           "$SSH_USER@$HOST:~/deploy/"
    ssh "$SSH_USER@$HOST" "chmod +x ~/deploy/*.sh"
    ok "Scripts uploaded to $HOST."
}

# ---------------------------------------------------------------------------
# Deploy app on a server (blue/green, no downtime)
# ---------------------------------------------------------------------------
deploy_app() {
    local HOST="$1"
    local ENV_LABEL="$2"
    local DOMAIN_FOR_ENV="$3"
    local ENV_UPPER; ENV_UPPER=$(echo "$ENV_LABEL" | tr '[:lower:]' '[:upper:]')
    section "[$ENV_UPPER] Deploying App (Blue/Green)"
    upload_scripts "$HOST"
    ssh -A "$SSH_USER@$HOST" "DOMAIN=$DOMAIN_FOR_ENV bash ~/deploy/deploy_app.sh"
    ok "App deployed on $HOST."
}

# ---------------------------------------------------------------------------
# Seed DB on a server
# ---------------------------------------------------------------------------
seed_db() {
    local HOST="$1"
    local ENV_LABEL="$2"
    local ENV_UPPER; ENV_UPPER=$(echo "$ENV_LABEL" | tr '[:lower:]' '[:upper:]')
    section "[$ENV_UPPER] Seeding Database (FULL_RESEED=$FULL_RESEED)"
    ssh "$SSH_USER@$HOST" "FULL_RESEED=$FULL_RESEED bash ~/deploy/seed_db.sh"
    ok "DB seeded on $HOST."
}

# ---------------------------------------------------------------------------
# Run smoke tests on a server
# ---------------------------------------------------------------------------
smoke_test() {
    local HOST="$1"
    local ENV_LABEL="$2"
    local ENV_UPPER; ENV_UPPER=$(echo "$ENV_LABEL" | tr '[:lower:]' '[:upper:]')
    section "[$ENV_UPPER] Running Smoke Tests"
    if ! ssh "$SSH_USER@$HOST" "bash ~/deploy/smoke_test.sh"; then
        fail "Smoke tests FAILED on $HOST ($ENV_LABEL)!"
        return 1
    fi
    ok "All smoke tests passed on $HOST."
}

# ---------------------------------------------------------------------------
# Get current Cloudflare IP (for rollback)
# ---------------------------------------------------------------------------
get_cloudflare_ip() {
    curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records?name=$PROD_DOMAIN&type=A" \
        -H "Authorization: Bearer $CF_TOKEN" \
        -H "Content-Type: application/json" | grep -o '"content":"[^"]*' | head -n 1 | cut -d'"' -f4
}

# ---------------------------------------------------------------------------
# Switch Cloudflare DNS
# ---------------------------------------------------------------------------
switch_cloudflare() {
    local IP="$1"
    local LABEL="$2"
    section "Switching Cloudflare DNS → $IP ($LABEL)"
    bash "$DEPLOY_DIR/switch_cloudflare.sh" "$PROD_DOMAIN" "$IP"
    ok "Cloudflare DNS updated → $IP."
}

# ---------------------------------------------------------------------------
# Rollback production
# ---------------------------------------------------------------------------
rollback_prod() {
    echo ""
    echo "  🔴 ======================================================"
    echo "  🔴  ROLLING BACK PRODUCTION"
    echo "  🔴 ======================================================"
    echo ""

    # Rollback PM2 to previous release on prod server
    log "Rolling back PM2 on production..."
    ssh "$SSH_USER@$PROD_HOST" "
        cd ~/deployments/inquran/releases
        PREV_RELEASE=\$(ls -1t | sed -n '2p')
        if [ -n \"\$PREV_RELEASE\" ]; then
            echo \"  Rolling back to: \$PREV_RELEASE\"
            ln -sfn \"\$(pwd)/\$PREV_RELEASE\" ~/inquran-app
            cd ~/inquran-app
            pm2 reload ecosystem.config.cjs --update-env && pm2 save
        else
            echo '  No previous release to roll back to.'
        fi
    " || true

    # Rollback Cloudflare if we have a previous IP
    if [ -n "$PREV_PROD_IP" ]; then
        log "Reverting Cloudflare DNS to previous IP: $PREV_PROD_IP..."
        switch_cloudflare "$PREV_PROD_IP" "ROLLBACK"
    else
        log "No previous Cloudflare IP saved — DNS not reverted."
    fi

    fail "Deployment ROLLED BACK. Check server logs."
    exit 1
}

# ---------------------------------------------------------------------------
# MAIN FLOW
# ---------------------------------------------------------------------------
TARGET_UPPER=$(echo "$TARGET" | tr '[:lower:]' '[:upper:]')
echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║   inQuran Release Pipeline — $TIMESTAMP   ║"
echo "║   Target: $TARGET_UPPER                                      ║"
echo "╚══════════════════════════════════════════════════════╝"

# ── STAGING PHASE ────────────────────────────────────────────
deploy_app  "$STAGING_HOST" "staging" "$STAGING_DOMAIN"
seed_db     "$STAGING_HOST" "staging"
if ! smoke_test "$STAGING_HOST" "staging"; then
    fail "Staging smoke tests failed. Aborting — production was NOT touched."
    exit 1
fi

ok "Staging is healthy ✅"

if [ "$TARGET" = "staging" ]; then
    section "Done!"
    echo "  Staging deployment complete."
    echo "  Run with 'production' to continue to production."
    exit 0
fi

# ── PRODUCTION PHASE ─────────────────────────────────────────
section "Preparing Production Deployment"

# Save current Cloudflare IP so we can revert if needed
PREV_PROD_IP=$(get_cloudflare_ip || echo "")
log "Current production Cloudflare IP: ${PREV_PROD_IP:-unknown}"

# Trap errors to trigger rollback
trap rollback_prod ERR

deploy_app  "$PROD_HOST" "production" "$PROD_DOMAIN"
seed_db     "$PROD_HOST" "production"

if ! smoke_test "$PROD_HOST" "production"; then
    rollback_prod
fi

# All good — flip DNS
switch_cloudflare "$PROD_HOST" "PRODUCTION"

# Final public health check (via Cloudflare, real URL)
section "Final Public Health Check"
log "Waiting 10s for DNS to propagate through Cloudflare..."
sleep 10

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 "https://$PROD_DOMAIN/" || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
    ok "https://$PROD_DOMAIN/ returned HTTP 200. Production is LIVE! 🎉"
else
    fail "https://$PROD_DOMAIN/ returned HTTP $HTTP_CODE. DNS may still be propagating — check manually."
fi

# Disable the ERR trap since we're done
trap - ERR

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║  ✅  RELEASE COMPLETE                                ║"
echo "║     $TIMESTAMP                            ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
