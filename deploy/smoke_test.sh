#!/bin/bash
# =============================================================================
# smoke_test.sh — Post-deploy health checks for inQuran
#
# Runs ON the remote VPS. Returns exit code 1 if any check fails.
# Called by release.sh after each deployment.
#
# Usage:
#   bash smoke_test.sh
# =============================================================================
set -euo pipefail

SUPABASE_DOCKER_DIR="$HOME/supabase/docker"
APP_NAME="inquran-astro"
APP_PORT="${APP_PORT:-4321}"
TIMEOUT=10

PASS=0
FAIL=0

log()   { echo "  [smoke] $*"; }
check() { echo "  [smoke] 🔍 $*"; }
ok()    { echo "  [smoke] ✅ $*"; PASS=$((PASS + 1)); }
fail()  { echo "  [smoke] ❌ $*" >&2; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# 1. PM2 process is online
# ---------------------------------------------------------------------------
check "PM2 process '$APP_NAME' is online..."
PM2_STATUS=$(pm2 jlist 2>/dev/null | grep -o '"status":"[^"]*"' | grep -c '"status":"online"' || echo "0")
if [ "$PM2_STATUS" -gt 0 ]; then
    ok "PM2 process is online."
else
    fail "PM2 process '$APP_NAME' is NOT online. Run: pm2 status"
fi

# ---------------------------------------------------------------------------
# 2. App responds on local port
# ---------------------------------------------------------------------------
check "App responds on port $APP_PORT..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$TIMEOUT" "http://127.0.0.1:$APP_PORT/" || echo "000")
if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "301" ] || [ "$HTTP_CODE" = "302" ]; then
    ok "App responded with HTTP $HTTP_CODE."
else
    fail "App did not respond on port $APP_PORT (got HTTP $HTTP_CODE)."
fi

# ---------------------------------------------------------------------------
# 3. Nginx is running and returns 200
# ---------------------------------------------------------------------------
check "Nginx responds on port 80..."
NGINX_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$TIMEOUT" "http://127.0.0.1:80/" || echo "000")
if [ "$NGINX_CODE" = "200" ] || [ "$NGINX_CODE" = "301" ] || [ "$NGINX_CODE" = "302" ]; then
    ok "Nginx responded with HTTP $NGINX_CODE."
else
    fail "Nginx did not respond on port 80 (got HTTP $NGINX_CODE)."
fi

# ---------------------------------------------------------------------------
# 4. Supabase PostgREST API responds
# ---------------------------------------------------------------------------
check "Supabase PostgREST API is up..."
ANON_KEY=$(grep "^ANON_KEY=" "$SUPABASE_DOCKER_DIR/.env" 2>/dev/null | cut -d= -f2 || echo "")
if [ -z "$ANON_KEY" ]; then
    fail "Could not read ANON_KEY from $SUPABASE_DOCKER_DIR/.env"
else
    SUPA_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$TIMEOUT" \
        "http://127.0.0.1:8000/rest/v1/" \
        -H "apikey: $ANON_KEY" \
        -H "Authorization: Bearer $ANON_KEY" || echo "000")
    if [ "$SUPA_CODE" = "200" ]; then
        ok "PostgREST API responded with HTTP 200."
    else
        fail "PostgREST API did not respond (got HTTP $SUPA_CODE)."
    fi
fi

# ---------------------------------------------------------------------------
# 5. Verses table has data
# ---------------------------------------------------------------------------
check "Verses table has data..."
if [ -n "$ANON_KEY" ]; then
    VERSE_RESP=$(curl -s --max-time "$TIMEOUT" \
        "http://127.0.0.1:8000/rest/v1/verses?select=id&limit=1" \
        -H "apikey: $ANON_KEY" \
        -H "Authorization: Bearer $ANON_KEY" || echo "[]")
    if echo "$VERSE_RESP" | grep -q '"id"'; then
        ok "Verses table returned data."
    else
        fail "Verses table returned no data. Response: $VERSE_RESP"
    fi
else
    fail "Skipping verses check — no ANON_KEY."
fi

# ---------------------------------------------------------------------------
# 6. Dictionary roots table has data
# ---------------------------------------------------------------------------
check "Dictionary roots table has data..."
if [ -n "$ANON_KEY" ]; then
    DICT_RESP=$(curl -s --max-time "$TIMEOUT" \
        "http://127.0.0.1:8000/rest/v1/dictionary_roots?select=id&limit=1" \
        -H "apikey: $ANON_KEY" \
        -H "Authorization: Bearer $ANON_KEY" || echo "[]")
    if echo "$DICT_RESP" | grep -q '"id"'; then
        ok "Dictionary roots table returned data."
    else
        fail "Dictionary roots returned no data. Response: $DICT_RESP"
    fi
else
    fail "Skipping dictionary check — no ANON_KEY."
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "  [smoke] ================================"
echo "  [smoke] Results: $PASS passed, $FAIL failed"
echo "  [smoke] ================================"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
