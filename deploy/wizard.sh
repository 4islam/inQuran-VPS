#!/bin/bash
# =============================================================================
# wizard.sh — Interactive Deployment Wizard
#
# A user-friendly wrapper for release.sh
# =============================================================================
set -euo pipefail

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE_SCRIPT="$SCRIPT_DIR/release.sh"

echo "================================================"
echo "    inQuran Astro — Deployment Wizard"
echo "================================================"
echo ""

# 1. Environment Selection
echo "Which environment would you like to deploy to?"
echo "  1) Staging    (Safe to test, updates staging only)"
echo "  2) Production (Updates staging first, then rolls to production)"
read -p "Select an option [1 or 2]: " env_choice

TARGET=""
if [ "$env_choice" = "1" ]; then
    TARGET="staging"
elif [ "$env_choice" = "2" ]; then
    TARGET="production"
else
    echo "Invalid choice. Exiting."
    exit 1
fi

# 2. Database Seeding
echo ""
echo "Do you need to perform a full database re-seed?"
echo "(This wipes the database and re-imports everything. Takes 5-10 mins)"
read -p "Full re-seed? [y/N]: " seed_choice

RESEED_FLAG=""
if [[ "$seed_choice" =~ ^[Yy]$ ]]; then
    RESEED_FLAG="--full-reseed"
fi

# 3. DNS Updates
echo ""
echo "Do you want to skip updating Cloudflare DNS?"
echo "(Useful for testing servers directly via IP before switching live traffic)"
read -p "Skip DNS? [y/N]: " dns_choice

DNS_FLAG=""
if [[ "$dns_choice" =~ ^[Yy]$ ]]; then
    DNS_FLAG="--no-dns"
fi

# Build command
CMD="\"$RELEASE_SCRIPT\" $TARGET"
if [ -n "$RESEED_FLAG" ]; then
    CMD="$CMD $RESEED_FLAG"
fi
if [ -n "$DNS_FLAG" ]; then
    CMD="$CMD $DNS_FLAG"
fi

echo ""
echo "================================================"
echo "Ready to Deploy!"
echo "Target Env  : $TARGET"
echo "Full Reseed : ${RESEED_FLAG:-No}"
echo "Skip DNS    : ${DNS_FLAG:-No}"
echo "Command     : $CMD"
echo "================================================"
echo ""

read -p "Press Enter to begin deployment or Ctrl+C to cancel..." dummy

echo ""
echo "Starting deployment..."
eval $CMD
