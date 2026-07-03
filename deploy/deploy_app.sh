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

if [ -f .env ]; then
    echo "Loading .env variables into environment..."
    set -a
    source .env
    set +a
fi

echo "Building Astro project..."
get_env_value() {
    local var_name="$1"
    if [ -n "${!var_name}" ]; then
        echo "${!var_name}"
    elif [ -f .env ]; then
        grep "^${var_name}=" .env | cut -d '=' -f 2-
    fi
}

GA_KEY_VAL=$(get_env_value PUBLIC_GA_KEY)
if [ -z "$GA_KEY_VAL" ]; then
    GA_KEY_VAL="GTM-M85MWKH7"
fi

# Build without tests for faster, safer deployments on staging/prod
echo "Running build..."
PUBLIC_GA_KEY="$GA_KEY_VAL" ASTRO_ADAPTER=node npx astro build

# PM2 logic
echo "Copying PM2 configuration..."
cp "$SCRIPT_DIR/ecosystem.config.cjs" "$RELEASE_DIR/" 2>/dev/null || cat > "$RELEASE_DIR/ecosystem.config.cjs" <<EOF
module.exports = {
    apps: [{
        name: '$APP_NAME',
        script: './dist/server/entry.mjs',
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

echo "Pruning old releases (keeping 5)..."
cd "$RELEASES_DIR"
# List by modification time (newest first), skip the first 5, and delete the rest
ls -1t | tail -n +6 | xargs -d '\n' rm -rf -- 2>/dev/null || true

echo "✅ Zero-Downtime Deployment complete! Current release: $TIMESTAMP"
