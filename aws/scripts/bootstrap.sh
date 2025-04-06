#!/bin/bash
# Bootstrap script for Counterparty ARM64 EC2 instance
# This script is downloaded and executed by the minimal UserData script

# Parse parameters
BITCOIN_VERSION=${1:-"26.0"}
COUNTERPARTY_BRANCH=${2:-"develop"}
COUNTERPARTY_TAG=${3:-""}
NETWORK_PROFILE=${4:-"mainnet"}
GITHUB_TOKEN=${5:-""}

# Logging functions
log_info() {
    echo "[INFO] $1"
}

log_warning() {
    echo "[WARNING] $1"
}

log_error() {
    echo "[ERROR] $1"
}

log_success() {
    echo "[SUCCESS] $1"
}

# Install basic dependencies 
log_info "Installing basic dependencies..."
apt-get update && apt-get upgrade -y
apt-get install -y apt-transport-https ca-certificates curl software-properties-common git jq htop iotop xfsprogs bc

# Fix for aws-cli in Ubuntu 24.04
if ! command -v aws &> /dev/null; then
  if [ "$(lsb_release -cs)" = "noble" ]; then
    # Use alternative method for Ubuntu 24.04
    curl "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o "awscliv2.zip"
    apt-get install -y unzip
    unzip -q awscliv2.zip
    ./aws/install
    rm -rf aws awscliv2.zip
  else
    # Try standard method for older Ubuntu versions
    apt-get install -y awscli || echo "Warning: Could not install awscli package"
  fi
fi

# Add Docker repository with improved error handling
mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o docker.gpg
if [ -f docker.gpg ]; then
  gpg --dearmor -o /etc/apt/keyrings/docker.gpg docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
  apt-get update
  
  # Install Docker
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
else
  echo "Failed to download Docker GPG key, using alternative method"
  # Alternative Docker installation using snap as fallback
  apt-get install -y snapd
  snap install docker
fi

# Add ubuntu user to docker group
usermod -aG docker ubuntu

# Mount the ST1 volume
mkdir -p /bitcoin-data

# Find the correct device for the attached volume (NVMe naming can vary)
DATA_DEVICE=""
for dev in /dev/nvme*n1; do
  if [ -e "$dev" ] && ! grep -q "$dev" /etc/fstab && [ "$dev" != "/dev/nvme0n1" ]; then
    DATA_DEVICE="$dev"
    echo "Found data device: $DATA_DEVICE"
    break
  fi
done

# If NVMe device wasn't found, try traditional naming
if [ -z "$DATA_DEVICE" ] && [ -e "/dev/xvdf" ]; then
  DATA_DEVICE="/dev/xvdf"
  echo "Found data device: $DATA_DEVICE"
fi

if [ -z "$DATA_DEVICE" ]; then
  echo "Error: Could not find data volume device"
  # Use a fallback directory if volume can't be found
  mkdir -p /bitcoin-data-local
  ln -sf /bitcoin-data-local /bitcoin-data
else
  # Format the volume if needed
  if ! blkid "$DATA_DEVICE"; then
    echo "Formatting $DATA_DEVICE with XFS filesystem"
    mkfs.xfs -f "$DATA_DEVICE"
  fi
  
  # Mount the volume
  echo "Mounting $DATA_DEVICE to /bitcoin-data"
  mount "$DATA_DEVICE" /bitcoin-data || {
    echo "Mount failed, attempting to force format and mount"
    mkfs.xfs -f "$DATA_DEVICE"
    mount "$DATA_DEVICE" /bitcoin-data
  }
  
  # Add to fstab for persistence
  if ! grep -q "$DATA_DEVICE" /etc/fstab; then
    echo "$DATA_DEVICE /bitcoin-data xfs defaults,nofail 0 2" >> /etc/fstab
  fi
fi

# Set permissions and create necessary directories
mkdir -p /bitcoin-data/docker
mkdir -p /bitcoin-data/bitcoin
mkdir -p /bitcoin-data/counterparty
mkdir -p /bitcoin-data/repo
chown -R ubuntu:ubuntu /bitcoin-data
chmod -R 755 /bitcoin-data

# Configure Docker to use the volume
mkdir -p /etc/docker
cat > /etc/docker/daemon.json << 'EOF'
{
  "data-root": "/bitcoin-data/docker",
  "storage-driver": "overlay2",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "50m",
    "max-file": "2"
  }
}
EOF

# Ensure Docker can access the directory
chmod 711 /bitcoin-data/docker

# Restart Docker service
systemctl restart docker
systemctl enable docker

# Create symlink for docker-compose command for compatibility
if [ -f "/usr/libexec/docker/cli-plugins/docker-compose" ] && [ ! -f "/usr/bin/docker-compose" ]; then
  ln -s /usr/libexec/docker/cli-plugins/docker-compose /usr/bin/docker-compose
  chmod +x /usr/bin/docker-compose
fi

# Clone counterparty-arm64 repository with retry logic
cd /home/ubuntu
REPO_URL="https://github.com/stampchain-io/counterparty-arm64.git"

# Optional GitHub token for private repository access
if [ ! -z "$GITHUB_TOKEN" ]; then
  echo "GitHub token detected, will use for repository access"
fi

MAX_RETRIES=3

for i in $(seq 1 $MAX_RETRIES); do
  echo "Cloning repository (attempt $i of $MAX_RETRIES)..."
  
  if [ -n "$GITHUB_TOKEN" ]; then
    # Use token for private repository
    echo "Using GitHub token for private repository access"
    REPO_WITH_TOKEN="https://${GITHUB_TOKEN}@github.com/stampchain-io/counterparty-arm64.git"
    git clone $REPO_WITH_TOKEN && break
  else
    # Try public access
    git clone $REPO_URL && break
  fi
  
  if [ $i -eq $MAX_RETRIES ]; then
    echo "Failed to clone repository after $MAX_RETRIES attempts"
    echo "If this is a private repository, please provide a GitHubToken parameter"
    exit 1
  fi
  
  echo "Clone failed. Retrying in 5 seconds..."
  sleep 5
done

# Clone Counterparty Core as well
echo "Cloning Counterparty Core repository..."
mkdir -p /bitcoin-data/repo
chown -R ubuntu:ubuntu /bitcoin-data/repo
cd /bitcoin-data/repo

# Clone Counterparty Core - this is a public repo but could be changed
COUNTERPARTY_REPO_URL="https://github.com/CounterpartyXCP/counterparty-core.git"

if [ -n "$GITHUB_TOKEN" ]; then
  # Use token for private repository - just in case it becomes private
  COUNTERPARTY_REPO_WITH_TOKEN="https://${GITHUB_TOKEN}@github.com/CounterpartyXCP/counterparty-core.git"
  sudo -u ubuntu git clone $COUNTERPARTY_REPO_WITH_TOKEN
else
  # Use public URL
  sudo -u ubuntu git clone $COUNTERPARTY_REPO_URL
fi

chown -R ubuntu:ubuntu /home/ubuntu/counterparty-arm64

# Create symbolic link for counterparty-node pointing to the docker directory
ln -sf /home/ubuntu/counterparty-arm64/docker /home/ubuntu/counterparty-node

# Ensure entrypoint script is available and executable in system path
cp /home/ubuntu/counterparty-arm64/docker/bitcoin-entrypoint.sh /usr/local/bin/
chmod +x /usr/local/bin/bitcoin-entrypoint.sh

chown -R ubuntu:ubuntu /home/ubuntu/counterparty-node

# Make sure all Bitcoin-data directories have correct permissions
echo "Ensuring proper directory permissions..."
chown -R ubuntu:ubuntu /bitcoin-data
chmod -R 755 /bitcoin-data
sudo -u ubuntu mkdir -p /bitcoin-data/repo/counterparty-core

# Run setup script - retry logic in case of network issues
echo "Running setup script..."
su - ubuntu -c "cd counterparty-arm64 && chmod +x scripts/setup.sh && scripts/setup.sh --bitcoin-version '$BITCOIN_VERSION' --counterparty-branch '$COUNTERPARTY_BRANCH' --data-dir '/bitcoin-data' --platform 'aws'" || {
  echo "Setup script failed on first attempt. Waiting 30 seconds and retrying..."
  sleep 30
  # Reset permissions and try again
  chown -R ubuntu:ubuntu /bitcoin-data
  chmod -R 755 /bitcoin-data
  su - ubuntu -c "cd counterparty-arm64 && scripts/setup.sh --bitcoin-version '$BITCOIN_VERSION' --counterparty-branch '$COUNTERPARTY_BRANCH' --data-dir '/bitcoin-data' --platform 'aws'"
}

# Create bitcoin.conf file with optimized settings for initial sync
mkdir -p /bitcoin-data/bitcoin/.bitcoin
cat << 'EOF' > /bitcoin-data/bitcoin/.bitcoin/bitcoin.conf
# Bitcoin Core configuration file - Created by CloudFormation template with optimizations

# Explicitly set the data directory
datadir=/bitcoin/.bitcoin

# RPC Settings
rpcuser=rpc
rpcpassword=rpc
rpcallowip=0.0.0.0/0
rpcbind=0.0.0.0
server=1
listen=1
addresstype=legacy
txindex=1
prune=0

# Performance Optimizations
dbcache=6000
maxmempool=300
maxconnections=25
blocksonly=1
mempoolfullrbf=1
assumevalid=000000000000000000053b17c1c2e1ea8a965a6240ede8ffd0729f7f2e77283e
par=8

# ZMQ Settings
zmqpubrawtx=tcp://0.0.0.0:9332
zmqpubhashtx=tcp://0.0.0.0:9332
zmqpubsequence=tcp://0.0.0.0:9332
zmqpubrawblock=tcp://0.0.0.0:9333
EOF
chmod 600 /bitcoin-data/bitcoin/.bitcoin/bitcoin.conf
chown -R ubuntu:ubuntu /bitcoin-data/bitcoin/.bitcoin

# Create symbolic link to scripts in the home directory
ln -sf /home/ubuntu/counterparty-arm64/scripts/check-sync-status.sh /home/ubuntu/check-sync-status.sh
chmod +x /home/ubuntu/check-sync-status.sh

# Update docker-compose.yml to use pre-built Docker Hub images
echo "Updating docker-compose.yml to use Docker Hub images..."

# Create config directory if it doesn't exist
mkdir -p /home/ubuntu/.counterparty-arm64

# Create a config.env file for Docker Compose with Docker Hub image references
# Using printf to avoid heredoc YAML parsing issues
printf "%s\n" \
  "# Counterparty ARM64 Configuration" \
  "# Generated on $(date)" \
  "COUNTERPARTY_DOCKER_DATA=/bitcoin-data" \
  "COUNTERPARTY_REPO=/bitcoin-data/repo/counterparty-core" \
  "BITCOIN_VERSION=$BITCOIN_VERSION" \
  "COUNTERPARTY_BRANCH=$COUNTERPARTY_BRANCH" \
  "COUNTERPARTY_TAG=$COUNTERPARTY_TAG" \
  "NETWORK_PROFILE=$NETWORK_PROFILE" \
  "" \
  "# Docker Hub images" \
  "DOCKERHUB_IMAGE_BITCOIND=xcparty/bitcoind-arm64" \
  "DOCKERHUB_IMAGE_COUNTERPARTY=xcparty/counterparty-core-arm64" \
  > /home/ubuntu/.counterparty-arm64/config.env
chown -R ubuntu:ubuntu /home/ubuntu/.counterparty-arm64

# Create .env file for docker-compose
cp /home/ubuntu/.counterparty-arm64/config.env /home/ubuntu/counterparty-node/.env
chown ubuntu:ubuntu /home/ubuntu/counterparty-node/.env

# Build Bitcoin image locally with entrypoint script
cd /home/ubuntu/counterparty-arm64/docker
cp bitcoin-entrypoint.sh /usr/local/bin/
chmod +x /usr/local/bin/bitcoin-entrypoint.sh
docker build -t bitcoind:arm64-local -f Dockerfile.bitcoind .

# Pull Counterparty image
docker pull xcparty/counterparty-core-arm64:$COUNTERPARTY_BRANCH
docker tag xcparty/counterparty-core-arm64:$COUNTERPARTY_BRANCH counterparty/counterparty:local

# Start Bitcoin and Counterparty services
echo "Starting services with profile $NETWORK_PROFILE..."
cd /home/ubuntu/counterparty-node && docker compose --profile $NETWORK_PROFILE up -d

# We don't need a cron job to start Counterparty - we'll start it directly
# Counterparty will start alongside Bitcoin as long as Bitcoin is running

# Wait for Bitcoin to start and verify it's using the correct data directory
echo "Waiting for Bitcoin to initialize..."
sleep 15

# Check if Bitcoin is running and using the correct data directory
BITCOIN_CONTAINER=$(docker ps --format "{{.Names}}" | grep -E "bitcoind" | head -1)
if [ -n "$BITCOIN_CONTAINER" ]; then
  echo "Bitcoin container $BITCOIN_CONTAINER is running"
  # Run check-sync-status.sh to verify initial sync is starting
  su - ubuntu -c "/home/ubuntu/check-sync-status.sh"
else
  echo "WARNING: Bitcoin container not running, check logs for errors"
fi

echo "Deployment completed. Bitcoin and Counterparty services are now starting."
echo "Check status with: ~/check-sync-status.sh"
echo "Deploy time: $(date -u) UTC" 
echo "Build version: bootstrap-$(date +%s)"

# Copy scripts to the home directory for easier access
cp /home/ubuntu/counterparty-arm64/aws/scripts/check-sync-status.sh /home/ubuntu/
cp /home/ubuntu/counterparty-arm64/scripts/common.sh /home/ubuntu/
chmod +x /home/ubuntu/check-sync-status.sh
chown ubuntu:ubuntu /home/ubuntu/check-sync-status.sh /home/ubuntu/common.sh

# Set up system maintenance and security scripts
echo "[INFO] Setting up system maintenance and security scripts..."

# Set up system-maintenance.sh
cp /home/ubuntu/counterparty-arm64/aws/scripts/system-maintenance.sh /usr/local/bin/
chmod +x /usr/local/bin/system-maintenance.sh

# Set up unattended-upgrades
echo "[INFO] Setting up unattended-upgrades for automatic security updates..."
cp /home/ubuntu/counterparty-arm64/aws/scripts/setup-unattended-upgrades.sh /usr/local/bin/
chmod +x /usr/local/bin/setup-unattended-upgrades.sh
/usr/local/bin/setup-unattended-upgrades.sh

# Set up security check script
cp /home/ubuntu/counterparty-arm64/aws/scripts/security-check.sh /usr/local/bin/
chmod +x /usr/local/bin/security-check.sh

# Add weekly cron job for system maintenance
echo "# Weekly system maintenance job for Counterparty ARM64" > /etc/cron.d/counterparty-maintenance
echo "# Run at 3:30 AM every Sunday" >> /etc/cron.d/counterparty-maintenance
echo "30 3 * * 0 root /usr/local/bin/system-maintenance.sh > /dev/null 2>&1" >> /etc/cron.d/counterparty-maintenance
echo "# Run security check at 4:30 AM every Monday" >> /etc/cron.d/counterparty-maintenance
echo "30 4 * * 1 root /usr/local/bin/security-check.sh > /dev/null 2>&1" >> /etc/cron.d/counterparty-maintenance

# Set up log rotation
echo "[INFO] Setting up log rotation..."
cp /home/ubuntu/counterparty-arm64/aws/scripts/counterparty-logrotate.conf /etc/logrotate.d/counterparty
chmod 644 /etc/logrotate.d/counterparty

# Force run logrotate once to make sure it works
logrotate -f /etc/logrotate.d/counterparty

# Copy monitoring scripts for disk usage and bitcoin sync
cp /home/ubuntu/counterparty-arm64/aws/scripts/check-disk-usage.sh /usr/local/bin/
cp /home/ubuntu/counterparty-arm64/aws/scripts/monitor-bitcoin.sh /usr/local/bin/
cp /home/ubuntu/counterparty-arm64/aws/scripts/disk-usage-analysis.sh /usr/local/bin/
chmod +x /usr/local/bin/check-disk-usage.sh /usr/local/bin/monitor-bitcoin.sh /usr/local/bin/disk-usage-analysis.sh

# Add daily cron job for disk usage monitoring
echo "# Daily monitoring jobs for Counterparty ARM64" > /etc/cron.d/counterparty-monitoring
echo "# Check disk usage at 2:00 AM daily" >> /etc/cron.d/counterparty-monitoring
echo "0 2 * * * root /usr/local/bin/check-disk-usage.sh > /dev/null 2>&1" >> /etc/cron.d/counterparty-monitoring
echo "# Check Bitcoin sync status at 6:00 AM daily" >> /etc/cron.d/counterparty-monitoring
echo "0 6 * * * root /usr/local/bin/monitor-bitcoin.sh --host localhost --port 8332 --user rpc --pass rpc > /dev/null 2>&1" >> /etc/cron.d/counterparty-monitoring

# Set up basic SSH hardening
echo "[INFO] Applying basic SSH security hardening..."
if [ -f /etc/ssh/sshd_config ]; then
    # Disable root login
    sed -i 's/^#PermitRootLogin yes/PermitRootLogin no/g' /etc/ssh/sshd_config
    # Use Protocol 2 only
    if ! grep -q "^Protocol 2" /etc/ssh/sshd_config; then
        echo "Protocol 2" >> /etc/ssh/sshd_config
    fi
    # Restart SSH to apply changes - only if not in the middle of setup
    if systemctl is-active --quiet sshd; then
        systemctl restart sshd
    fi
fi

echo "Deployment completed. Bitcoin and Counterparty services are now starting."
echo "Check status with: ~/check-sync-status.sh"
echo "Deploy time: $(date -u +'%Y-%m-%d %H:%M:%S UTC')"
echo "Build version: bootstrap-$(date -u +%s)"