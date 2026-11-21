#!/bin/bash
set -e

DOMAIN="${DOMAIN:-uat.inquran.com}"
APP_PORT=4321 # Astro default port
USER_NAME="nislam"

echo "Configuring Nginx for $DOMAIN..."

CONFIG_FILE="/etc/nginx/conf.d/$DOMAIN.conf"

if [ -f "$CONFIG_FILE" ]; then
    echo "Updating existing Nginx configuration..."
    sudo mv "$CONFIG_FILE" "$CONFIG_FILE.bak_$(date +%s)"
fi

echo "Creating new Nginx configuration..."

echo 'proxy_cache_path /var/cache/nginx levels=1:2 keys_zone=my_cache:10m max_size=1g inactive=7d use_temp_path=off;' | sudo tee /etc/nginx/conf.d/cache.conf > /dev/null

sudo tee /etc/nginx/conf.d/security.conf > /dev/null << 'SEC_EOF'
# Real IP configuration for Cloudflare
set_real_ip_from 173.245.48.0/20;
set_real_ip_from 103.21.244.0/22;
set_real_ip_from 103.22.200.0/22;
set_real_ip_from 103.31.4.0/22;
set_real_ip_from 141.101.64.0/18;
set_real_ip_from 108.162.192.0/18;
set_real_ip_from 190.93.240.0/20;
set_real_ip_from 188.114.96.0/20;
set_real_ip_from 197.234.240.0/22;
set_real_ip_from 198.41.128.0/17;
set_real_ip_from 162.158.0.0/15;
set_real_ip_from 104.16.0.0/13;
set_real_ip_from 104.24.0.0/14;
set_real_ip_from 172.64.0.0/13;
set_real_ip_from 131.0.72.0/22;
set_real_ip_from 2400:cb00::/32;
set_real_ip_from 2606:4700::/32;
set_real_ip_from 2803:f800::/32;
set_real_ip_from 2405:b500::/32;
set_real_ip_from 2405:8100::/32;
set_real_ip_from 2a06:98c0::/29;
set_real_ip_from 2c0f:f248::/32;
real_ip_header CF-Connecting-IP;

# Map to identify abusive headless scrapers
map \$http_user_agent \$is_abusive_scraper {
    default 0;
    ~*Lightpanda 1;
}

# Rate and connection limit zones per authentic client IP
limit_conn_zone \$binary_remote_addr zone=addr_conn:10m;
limit_req_zone \$binary_remote_addr zone=addr_req:10m rate=30r/s;
SEC_EOF
CACHE_DEF=""

SSL_CONFIG=""
if [ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
    echo "SSL Certificates found. Enabling HTTPS in config..."
    SSL_CONFIG="
    listen 443 ssl;
    listen [::]:443 ssl ipv6only=on;
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;
"
fi

sudo tee "$CONFIG_FILE" > /dev/null <<EOF
$CACHE_DEF

server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name $DOMAIN www.$DOMAIN;

    # Abusive scraper mitigation
    if (\$is_abusive_scraper) {
        return 429;
    }

    # Gzip Compression
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types text/plain text/css text/xml application/json application/javascript application/rss+xml application/atom+xml image/svg+xml;

    # Buffer Configurations
    large_client_header_buffers 4 64k;
    client_header_buffer_size 64k;
    proxy_buffer_size 128k;
    proxy_buffers 4 256k;
    proxy_busy_buffers_size 256k;

    # Security Headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "no-referrer-when-downgrade" always;
    add_header Content-Security-Policy "default-src 'self' http: https: data: blob: 'unsafe-inline'" always;

    # Direct static file serving from client build
    root /home/$USER_NAME/inquran-app/dist/client;

    # Static assets: served directly from disk with fallback to Node
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot|webmanifest|json|txt)$ {
        try_files \$uri @node;
        expires 1y;
        access_log off;
        add_header Cache-Control "public, max-age=31536000, immutable";
    }

    # Proxy for Supabase
    location ^~ /supabase/ {
        rewrite ^/supabase/(.*) /\$1 break;
        proxy_pass http://127.0.0.1:8000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$http_x_forwarded_proto;

        proxy_connect_timeout 3s;
        proxy_read_timeout 30s;
        proxy_next_upstream error timeout http_502 http_504;
        proxy_next_upstream_tries 3;

        # Enable caching for DB (1 Week for static Quran data)
        proxy_cache my_cache;
        proxy_cache_valid 200 7d;
        proxy_cache_use_stale error timeout updating http_500 http_502 http_503 http_504;
        proxy_ignore_headers Cache-Control;
        add_header X-Cache-Status \$upstream_cache_status;
    }

    location / {
        try_files \$uri @node;
    }

    location @node {
        limit_conn addr_conn 30;
        limit_req zone=addr_req burst=50 nodelay;

        proxy_pass http://127.0.0.1:$APP_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$http_x_forwarded_proto;

        proxy_connect_timeout 3s;
        proxy_read_timeout 30s;
        proxy_next_upstream error timeout http_502 http_504;
        proxy_next_upstream_tries 3;

        # Enable caching
        proxy_cache my_cache;
        proxy_cache_use_stale error timeout http_500 http_502 http_503 http_504;
        proxy_cache_valid 200 302 5m;
        proxy_cache_valid 404 1m;
        add_header X-Cache-Status \$upstream_cache_status;
    }

    # Cloudflare-aware HTTPS Redirect
    if (\$http_x_forwarded_proto = "http") {
        return 301 https://\$host\$request_uri;
    }

    # SSL Config
    $SSL_CONFIG
}
EOF

# Remove default configs
if [ -f /etc/nginx/conf.d/default.conf ]; then
    sudo mv /etc/nginx/conf.d/default.conf /etc/nginx/conf.d/default.conf.bak
fi
if [ -f /etc/nginx/sites-enabled/default ]; then
    sudo rm /etc/nginx/sites-enabled/default
fi

sudo nginx -t
sudo systemctl enable nginx
sudo systemctl restart nginx

if [ "$SKIP_SSL" != "true" ]; then
    echo "Installing Certbot..."
    sudo apt-get install -y certbot python3-certbot-nginx

    echo "Obtaining SSL Certificate..."
    # Request certificate
    sudo certbot certonly --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "admin@inquran.com" || echo "Certbot failed, ignoring to continue deployment."

    # Need to re-run config generation to inject the new SSL config if it was successful.
    if [ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
        echo "Certs obtained! Re-running script to inject SSL configuration..."
        export SKIP_SSL=true
        exec $0
    fi

    echo "Enabling Certbot Auto-Renewal..."
    sudo systemctl enable --now certbot.timer

    echo "Nginx configured with Let's Encrypt SSL for $DOMAIN."
else
    echo "Nginx configured."
fi
