#!/bin/bash
# ---------------------------------------------------------------------------
# warmup.sh
# Reads the top URLs from indexed-urls.json and concurrently requests them
# to warm up the Cloudflare edge cache (and internal SSR cache/DB if any).
# ---------------------------------------------------------------------------
set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

log() { echo -e "${YELLOW}  [warmup]${NC} $1"; }
ok()  { echo -e "${GREEN}  [warmup] ✅ $1${NC}"; }
err() { echo -e "${RED}  [warmup] ❌ $1${NC}"; }

DOMAIN=${1:-inquran.com}
PROTOCOL="https"
URLS_FILE="indexed-urls.json"
NUM_URLS=120
CONCURRENCY=5

log "Starting cache warmup for $PROTOCOL://$DOMAIN..."

if [ ! -f "$URLS_FILE" ]; then
    err "$URLS_FILE not found in current directory. Skipping warmup."
    exit 0
fi

log "Extracting top $NUM_URLS URLs..."
# Extract the first N URLs from the JSON array, replacing the base domain with the target domain
# We use grep and sed to parse the simple JSON array format reliably without jq dependency on server
URLS=$(grep -oE '"https://[^"]+"' "$URLS_FILE" | head -n "$NUM_URLS" | sed -e 's/^"//' -e 's/"$//' | sed "s|https://inquran.com|$PROTOCOL://$DOMAIN|g")

if [ -z "$URLS" ]; then
    err "Failed to extract URLs from $URLS_FILE."
    exit 0
fi

# Count how many we actually got
COUNT=$(echo "$URLS" | wc -l | tr -d ' ')
log "Warming up $COUNT URLs with concurrency $CONCURRENCY..."

# Use xargs to run curl concurrently. 
# -s: silent
# -o /dev/null: discard output
# -w '%{http_code}': print HTTP status code
# -A: set custom user agent so analytics can ignore it if needed
echo "$URLS" | xargs -n 1 -P "$CONCURRENCY" -I {} bash -c '
    URL="{}"
    STATUS=$(curl -s -o /dev/null -w "%{http_code}" -A "inQuran-Warmup-Bot/1.0" "$URL")
    if [ "$STATUS" = "200" ]; then
        echo -e "\033[0;32m200 OK\033[0m $URL"
    else
        echo -e "\033[0;31m$STATUS\033[0m $URL"
    fi
'

ok "Cache warmup complete."
