#!/bin/bash
set -e

DOMAIN=$1
NEW_IP=$2
# Ensure these are provided as environment variables
# CF_ZONE_ID=""
# CF_TOKEN=""

if [ -z "$DOMAIN" ] || [ -z "$NEW_IP" ] || [ -z "$CF_ZONE_ID" ] || [ -z "$CF_TOKEN" ]; then
    echo "Usage: CF_ZONE_ID=... CF_TOKEN=... $0 <domain> <new_ip>"
    exit 1
fi

echo "Switching DNS for $DOMAIN to $NEW_IP"

update_dns_record() {
    local RECORD_NAME=$1
    local IP=$2
    local TYPE="A"

    echo "Updating $RECORD_NAME to $IP..."

    # Extract ID using grep/cut to avoid needing jq installed everywhere
    local RECORD_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records?name=$RECORD_NAME&type=$TYPE" \
         -H "Authorization: Bearer $CF_TOKEN" \
         -H "Content-Type: application/json" | grep -o '"id":"[^"]*' | head -n 1 | cut -d'"' -f4)

    if [ -z "$RECORD_ID" ] || [ "$RECORD_ID" == "null" ]; then
        echo "Creating NEW Record for $RECORD_NAME..."
        RESULT=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records" \
         -H "Authorization: Bearer $CF_TOKEN" \
         -H "Content-Type: application/json" \
         --data "{\"type\":\"$TYPE\",\"name\":\"$RECORD_NAME\",\"content\":\"$IP\",\"ttl\":1,\"proxied\":true}")
    else
        echo "Updating Existing Record ($RECORD_ID)..."
        RESULT=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records/$RECORD_ID" \
         -H "Authorization: Bearer $CF_TOKEN" \
         -H "Content-Type: application/json" \
         --data "{\"type\":\"$TYPE\",\"name\":\"$RECORD_NAME\",\"content\":\"$IP\",\"ttl\":1,\"proxied\":true}")
    fi

    if echo "$RESULT" | grep -q '"success":true'; then
        echo "✅ Success: $RECORD_NAME -> $IP"
    else
        echo "❌ Failed to update $RECORD_NAME"
        echo "Response: $RESULT"
        return 1
    fi
}

update_dns_record "$DOMAIN" "$NEW_IP"
update_dns_record "www.$DOMAIN" "$NEW_IP"

echo "✅ DNS Updates Complete for $DOMAIN to $NEW_IP"
