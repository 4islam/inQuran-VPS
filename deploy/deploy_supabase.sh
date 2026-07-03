#!/bin/bash
set -e

echo "Deploying Supabase Docker Stack..."

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

    # Generate Anon and Service Role JWTs using the new secret
    # Supabase uses HS256 for JWTs
    cat << 'EOF' > generate_jwts.js
const crypto = require('crypto');
const secret = process.argv[2];

function createJWT(role) {
  const header = Buffer.from(JSON.stringify({ alg: 'HS256', typ: 'JWT' })).toString('base64url');
  const payload = Buffer.from(JSON.stringify({ role: role, iss: 'supabase', iat: Math.floor(Date.now() / 1000), exp: Math.floor(Date.now() / 1000) + (10 * 365 * 24 * 60 * 60) })).toString('base64url');
  const signature = crypto.createHmac('sha256', secret).update(header + '.' + payload).digest('base64url');
  return header + '.' + payload + '.' + signature;
}

console.log(createJWT('anon'));
console.log(createJWT('service_role'));
EOF

    KEYS=$(node generate_jwts.js "$JWT_SECRET")
    ANON_KEY=$(echo "$KEYS" | head -n 1)
    SERVICE_ROLE_KEY=$(echo "$KEYS" | tail -n 1)
    rm generate_jwts.js

    # Update .env
    sed -i "s/POSTGRES_PASSWORD=your-super-secret-and-long-postgres-password/POSTGRES_PASSWORD=${POSTGRES_PASSWORD}/" .env
    sed -i "s/JWT_SECRET=your-super-secret-jwt-token-with-at-least-32-characters-long/JWT_SECRET=${JWT_SECRET}/" .env
    sed -i "s/ANON_KEY=your-anon-key/ANON_KEY=${ANON_KEY}/" .env
    sed -i "s/SERVICE_ROLE_KEY=your-service-role-key/SERVICE_ROLE_KEY=${SERVICE_ROLE_KEY}/" .env
    sed -i "s|SITE_URL=http://localhost:3000|SITE_URL=https://uat.inquran.com|" .env
    
    echo "Generated secure keys."
fi

echo "Pulling Docker images..."
docker compose pull

echo "Starting Supabase Stack..."
docker compose up -d

echo "Supabase deployment initiated."
