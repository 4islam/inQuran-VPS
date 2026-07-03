#!/bin/bash
set -e

# DOMAIN is passed by release.sh (e.g. DOMAIN=inquran.com or uat.inquran.com)
DOMAIN="${DOMAIN:-uat.inquran.com}"
SITE_URL="https://${DOMAIN}"

echo "Deploying Supabase Docker Stack for ${DOMAIN}..."

INSTALL_DIR="/home/nislam/supabase"

if [ ! -d "$INSTALL_DIR" ]; then
    git clone --depth 1 https://github.com/supabase/supabase "$INSTALL_DIR"
fi

cd "$INSTALL_DIR/docker"

if [ ! -f .env ]; then
    cp .env.example .env

    # Generate random JWT secret (must be >= 32 chars)
    JWT_SECRET=$(node -e "console.log(require('crypto').randomBytes(32).toString('hex'))")
    POSTGRES_PASSWORD=$(node -e "console.log(require('crypto').randomBytes(24).toString('hex'))")

    # Generate Anon and Service Role JWTs signed with the new secret
    cat << 'EOF' > generate_jwts.js
const crypto = require('crypto');
const secret = process.argv[2];
function createJWT(role) {
  const header = Buffer.from(JSON.stringify({ alg: 'HS256', typ: 'JWT' })).toString('base64url').replace(/=+$/, '');
  const payload = Buffer.from(JSON.stringify({
    role, iss: 'supabase', iat: Math.floor(Date.now()/1000),
    exp: Math.floor(Date.now()/1000) + (10 * 365 * 24 * 60 * 60)
  })).toString('base64url').replace(/=+$/, '');
  const sig = crypto.createHmac('sha256', secret).update(header+'.'+payload).digest('base64url').replace(/=+$/, '');
  return header+'.'+payload+'.'+sig;
}
console.log('ANON:' + createJWT('anon'));
console.log('SVC:' + createJWT('service_role'));
EOF

    node generate_jwts.js "$JWT_SECRET" > jwt_keys.txt
    ANON_KEY=$(grep '^ANON:' jwt_keys.txt | sed 's/^ANON://')
    SERVICE_ROLE_KEY=$(grep '^SVC:' jwt_keys.txt | sed 's/^SVC://')
    rm generate_jwts.js jwt_keys.txt

    # Replace values using permissive patterns (works whether file has placeholders or demo values)
    sed -i "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=${POSTGRES_PASSWORD}|" .env
    sed -i "s|^JWT_SECRET=.*|JWT_SECRET=${JWT_SECRET}|" .env
    sed -i "s|^ANON_KEY=.*|ANON_KEY=${ANON_KEY}|" .env
    sed -i "s|^SERVICE_ROLE_KEY=.*|SERVICE_ROLE_KEY=${SERVICE_ROLE_KEY}|" .env
    sed -i "s|^SITE_URL=.*|SITE_URL=${SITE_URL}|" .env

    echo "Generated secure keys."
fi

# Always sync SITE_URL (in case domain changed or .env was pre-existing)
sed -i "s|^SITE_URL=.*|SITE_URL=${SITE_URL}|" .env
echo "SITE_URL set to: ${SITE_URL}"

echo "Pulling Docker images..."
docker compose pull

echo "Starting Supabase Stack..."
docker compose up -d

echo "Supabase deployment initiated."
