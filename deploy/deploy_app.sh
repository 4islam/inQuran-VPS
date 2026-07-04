#!/bin/bash
set -e

# Configuration
REPO_URL="git@github.com:4islam/inQuran-astro.git"
BASE_DIR="$HOME/deployments/inquran"
RELEASES_DIR="$BASE_DIR/releases"
SHARED_ENV_FILE="$BASE_DIR/.env"
APP_DIR="$HOME/inquran-app" # This will act as the 'current' symlink
APP_NAME="inquran-astro"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
RELEASE_DIR="$RELEASES_DIR/$TIMESTAMP"

echo "Starting Zero-Downtime Deployment for $APP_NAME..."
mkdir -p "$RELEASES_DIR"

echo "Cloning repository into release directory: $RELEASE_DIR"
# Ensure github known host is added
mkdir -p ~/.ssh
ssh-keyscan github.com >> ~/.ssh/known_hosts 2>/dev/null
git clone "$REPO_URL" "$RELEASE_DIR"
cd "$RELEASE_DIR"

echo "Installing dependencies..."
npm install

# Link or copy shared .env
if [ -f "$SHARED_ENV_FILE" ]; then
    echo "Linking shared .env..."
    ln -s "$SHARED_ENV_FILE" .env
elif [ -f "$APP_DIR/.env" ] && [ ! -L "$APP_DIR" ]; then
    # Legacy migration: copy .env from old directory if it wasn't a symlink yet
    echo "Migrating .env from legacy app dir..."
    cp "$APP_DIR/.env" "$SHARED_ENV_FILE"
    ln -s "$SHARED_ENV_FILE" .env
fi

# ---------------------------------------------------------------------------
# Ensure lanes.sqlite is available in the shared base dir.
# The file is excluded from git (~70MB), so we download it on demand.
# Validation uses Linux stat with a macOS fallback so the script can also
# be run locally for testing.
# ---------------------------------------------------------------------------
LANES_URL="https://raw.githubusercontent.com/naveedulislam/lan/master/lexicon.sqlite"
LANES_SHARED="$BASE_DIR/lanes.sqlite"
LANES_MIN_SIZE=60000000  # 60MB threshold — a valid file is ~70MB

get_file_size() {
    stat -c%s "$1" 2>/dev/null || stat -f%z "$1" 2>/dev/null || echo 0
}

LANES_SIZE=0
if [ -f "$LANES_SHARED" ]; then
    LANES_SIZE=$(get_file_size "$LANES_SHARED")
fi

if [ "$LANES_SIZE" -lt "$LANES_MIN_SIZE" ]; then
    echo "lanes.sqlite missing or too small ($LANES_SIZE bytes) — downloading..."
    curl -L --fail -o "$LANES_SHARED" "$LANES_URL"
    LANES_SIZE=$(get_file_size "$LANES_SHARED")
    if [ "$LANES_SIZE" -lt "$LANES_MIN_SIZE" ]; then
        echo "⚠️  Warning: lanes.sqlite download may be incomplete (size: $LANES_SIZE bytes)."
        echo "   Lane's Lexicon features will be degraded but the app will continue."
        rm -f "$LANES_SHARED"  # Remove bad file so next deploy retries
    else
        echo "✅ lanes.sqlite downloaded successfully ($LANES_SIZE bytes)."
    fi
else
    echo "lanes.sqlite already valid ($LANES_SIZE bytes). Skipping download."
fi

# Link lanes.sqlite into the release data dir if the shared copy is present
if [ -f "$LANES_SHARED" ]; then
    echo "Linking lanes.sqlite..."
    mkdir -p data
    ln -s "$LANES_SHARED" data/lanes.sqlite
fi


if [ -f .env ]; then
    echo "Loading .env variables into environment..."
    set -a
    source .env
    set +a
fi

# ---------------------------------------------------------------------------
# Resolve correct PUBLIC_SUPABASE_URL for this environment.
# PUBLIC_* vars are baked into the compiled JS at build time, so they MUST
# be set correctly before building — they cannot be changed at runtime.
#
# DOMAIN can be passed by release.sh (e.g. DOMAIN=inquran.com).
# If not set, infer it from the Nginx config or fall back to the .env value.
# ---------------------------------------------------------------------------
SUPABASE_DOCKER_DIR="$HOME/supabase/docker"

if [ -z "${DOMAIN:-}" ]; then
    # Try to detect the domain from Nginx conf filenames
    DOMAIN=$(ls /etc/nginx/conf.d/*.conf 2>/dev/null | grep -v 'cache\|bak' | head -1 | xargs basename | sed 's/.conf//' || echo "")
fi

if [ -n "${DOMAIN:-}" ]; then
    SUPABASE_URL="https://${DOMAIN}/supabase"
    echo "Detected domain: $DOMAIN — setting PUBLIC_SUPABASE_URL=$SUPABASE_URL"
else
    # Fallback: use value already in .env
    SUPABASE_URL=$(grep '^PUBLIC_SUPABASE_URL=' .env 2>/dev/null | cut -d= -f2 || echo "")
    echo "No DOMAIN set — using PUBLIC_SUPABASE_URL from .env: $SUPABASE_URL"
fi

# Also read ANON_KEY from the local Supabase instance (source of truth, prevents cross-wiring)
ANON_KEY=""
if [ -f "$SUPABASE_DOCKER_DIR/.env" ]; then
    ANON_KEY=$(grep '^ANON_KEY=' "$SUPABASE_DOCKER_DIR/.env" | cut -d= -f2)
    echo "Loaded ANON_KEY from local Supabase instance."
fi

# Build without tests for faster, safer deployments on staging/prod
echo "Running build..."
export PUBLIC_GA_KEY="$GA_KEY_VAL"
# PUBLIC_SUPABASE_URL is used by the browser-side Supabase client (correct: public domain)
export PUBLIC_SUPABASE_URL="$SUPABASE_URL"
# SUPABASE_SSR_URL is used by server-side (SSR) Supabase fetches.
# Always point to the local Kong gateway directly to avoid Cloudflare caching
# SSR API calls (which caused topics to show 0 results when CF cached an empty response).
export SUPABASE_SSR_URL="http://127.0.0.1:8000"
if [ -n "$ANON_KEY" ]; then
    export PUBLIC_SUPABASE_ANON_KEY="$ANON_KEY"
fi
ASTRO_ADAPTER=node npx astro build

# ---------------------------------------------------------------------------
# Post-build SSR patch: rewrite the public Supabase URL in server chunks to
# point directly at the local Kong gateway (http://127.0.0.1:8000).
#
# Why: The app's supabase.ts uses PUBLIC_SUPABASE_URL (baked at build time as
# https://DOMAIN/supabase). When SSR routes use this client, requests flow
# through Cloudflare, which can serve stale cached responses (e.g., empty []
# for distinct_topics before permissions were applied). By pointing SSR
# directly at Kong, we bypass Cloudflare entirely for server-side fetches
# while the browser-side client still uses the public HTTPS URL correctly.
# ---------------------------------------------------------------------------
if [ -n "${SUPABASE_URL:-}" ] && [ -d "dist/server" ]; then
    echo "Patching SSR server chunks: replacing '$SUPABASE_URL' → 'http://127.0.0.1:8000'..."
    find dist/server -name '*.mjs' \
        -exec sed -i "s|${SUPABASE_URL}|http://127.0.0.1:8000|g" {} +
    echo "✅ SSR URL patch applied."
fi

# PM2 logic
echo "Copying PM2 configuration..."
cp "$SCRIPT_DIR/ecosystem.config.cjs" "$RELEASE_DIR/" 2>/dev/null || cat > "$RELEASE_DIR/ecosystem.config.cjs" <<EOF
module.exports = {
    apps: [{
        name: '$APP_NAME',
        script: './dist/server/entry.mjs',
        cwd: '$APP_DIR',
        env: {
            PORT: 4321,
            HOST: '127.0.0.1'
        }
    }]
};
EOF

echo "Locating entry file..."
ENTRY_FILE=$(find dist -type f \( -name "entry.mjs" -o -name "index.mjs" -o -name "server.mjs" \) 2>/dev/null | head -n 1)

if [ -n "$ENTRY_FILE" ]; then
    sed -i "s|script: '.*'|script: './$ENTRY_FILE'|" ecosystem.config.cjs
fi

echo "Updating symlink..."
# If $APP_DIR exists and is a directory (legacy), move it out of the way
if [ -d "$APP_DIR" ] && [ ! -L "$APP_DIR" ]; then
    echo "Legacy directory found at $APP_DIR. Renaming to $APP_DIR.backup..."
    mv "$APP_DIR" "$APP_DIR.backup_$(date +"%Y%m%d")"
fi

# Create symlink securely
ln -sfn "$RELEASE_DIR" "$APP_DIR"

# Change into the symlinked directory so PM2 runs with the correct path
cd "$APP_DIR"

if pm2 describe $APP_NAME > /dev/null 2>&1; then
    echo "App is already running. Performing zero-downtime reload..."
    pm2 reload ecosystem.config.cjs --update-env
else
    echo "Starting app for the first time..."
    pm2 start ecosystem.config.cjs --update-env
fi
pm2 save

# ---------------------------------------------------------------------------
# Auto-configure Nginx if no config exists for this domain
# ---------------------------------------------------------------------------
NGINX_CONF="/etc/nginx/conf.d/${DOMAIN:-inquran.com}.conf"
if [ -n "${DOMAIN:-}" ] && [ ! -f "$NGINX_CONF" ]; then
    echo "No Nginx config found for $DOMAIN — creating one..."
    sudo rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
    sudo tee "$NGINX_CONF" > /dev/null << NGINXEOF

server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name ${DOMAIN} www.${DOMAIN};

    gzip on; gzip_vary on; gzip_proxied any; gzip_comp_level 6;
    gzip_types text/plain text/css text/xml application/json application/javascript;

    large_client_header_buffers 4 64k;
    client_header_buffer_size 64k;
    proxy_buffer_size 128k;
    proxy_buffers 4 256k;
    proxy_busy_buffers_size 256k;

    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;

    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$ {
        proxy_pass http://127.0.0.1:4321;
        expires 1y; access_log off;
        add_header Cache-Control "public";
    }

    location ^~ /supabase/ {
        rewrite ^/supabase/(.*) /\$1 break;
        proxy_pass http://127.0.0.1:8000;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$http_x_forwarded_proto;
    }

    location / {
        proxy_pass http://127.0.0.1:4321;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$http_x_forwarded_proto;
    }

    if (\$http_x_forwarded_proto = "http") {
        return 301 https://\$host\$request_uri;
    }
}
NGINXEOF
    sudo nginx -t && sudo systemctl reload nginx && echo "Nginx configured and reloaded for $DOMAIN"
fi

echo "Pruning old releases (keeping 5)..."
cd "$RELEASES_DIR"
# List by modification time (newest first), skip the first 5, and delete the rest
ls -1t | tail -n +6 | xargs -d '\n' rm -rf -- 2>/dev/null || true

echo "✅ Zero-Downtime Deployment complete! Current release: $TIMESTAMP"
