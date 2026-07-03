#!/bin/bash
set -e

DOMAIN=${1:-uat.inquran.com}
USER_NAME="nislam"

echo "=============================================="
echo "BOOTSTRAPPING UBUNTU VPS FOR: $DOMAIN"
echo "=============================================="

# 1. Update system and install dependencies
echo "--- Step 1: Updating System & Installing Dependencies ---"
apt-get update -y
apt-get upgrade -y
apt-get install -y git curl docker.io nginx ufw build-essential

# 2. Configure UFW Firewall (Standard web ports, no Cloudflare strictness yet)
echo "--- Step 2: Configuring Firewall (UFW) ---"
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

# 3. Create user if doesn't exist
echo "--- Step 3: Setting up user '$USER_NAME' ---"
if ! id "$USER_NAME" &>/dev/null; then
    adduser --disabled-password --gecos "" $USER_NAME
    usermod -aG sudo $USER_NAME
    usermod -aG docker $USER_NAME
    echo "$USER_NAME ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/$USER_NAME
    
    # Copy SSH keys from root
    mkdir -p /home/$USER_NAME/.ssh
    if [ -f /root/.ssh/authorized_keys ]; then
        cp /root/.ssh/authorized_keys /home/$USER_NAME/.ssh/
        chown -R $USER_NAME:$USER_NAME /home/$USER_NAME/.ssh
        chmod 700 /home/$USER_NAME/.ssh
        chmod 600 /home/$USER_NAME/.ssh/authorized_keys
    fi
fi

# 4. Install Node 22 & PM2 globally
echo "--- Step 4: Installing Node.js 22 & PM2 ---"
if ! command -v node &> /dev/null; then
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
    apt-get install -y nodejs
    npm install -g pm2
    
    # Setup PM2 startup script for nislam
    env PATH=$PATH:/usr/bin /usr/lib/node_modules/pm2/bin/pm2 startup systemd -u $USER_NAME --hp /home/$USER_NAME
fi

# 5. Enable services
systemctl enable docker
systemctl start docker
systemctl enable nginx

# 6. Ensure directories exist
mkdir -p /home/$USER_NAME/deploy
chown -R $USER_NAME:$USER_NAME /home/$USER_NAME/deploy

echo "=============================================="
echo "✅ BOOTSTRAP COMPLETE!"
echo "You can now log in as: $USER_NAME"
echo "=============================================="
