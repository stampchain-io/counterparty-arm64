#!/bin/bash
# Script to adjust Bitcoin configuration after initial sync is complete
# This will change settings from initial sync optimization to running mode optimization

# Locate repository and common.sh
REPO_DIR="/home/ubuntu/counterparty-arm64"
COMMON_SH="$REPO_DIR/scripts/common.sh"

# Source common functions
if [ -f "$COMMON_SH" ]; then
    source "$COMMON_SH"
else
    # For development environments, try relative path
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [ -f "$SCRIPT_DIR/common.sh" ]; then
        source "$SCRIPT_DIR/common.sh"
    else
        echo "Error: Could not find common.sh"
        exit 1
    fi
fi

# Check Docker status
if ! docker ps &>/dev/null; then
    log_error "Unable to execute docker commands. Is Docker running?"
    exit 1
fi

# Get Bitcoin container name
BITCOIN_CONTAINER=$(docker ps --format "{{.Names}}" | grep -E "bitcoind.*1$" | head -1)
if [ -z "$BITCOIN_CONTAINER" ]; then
    log_error "No Bitcoin container found. Make sure containers are running."
    exit 1
fi

log_info "Found Bitcoin container: $BITCOIN_CONTAINER"

# Get blockchain synchronization status
BLOCKCHAIN_INFO=$(docker exec $BITCOIN_CONTAINER bitcoin-cli -conf=/bitcoin/.bitcoin/bitcoin.conf getblockchaininfo 2>/dev/null)
if [ -z "$BLOCKCHAIN_INFO" ]; then
    log_error "Failed to get blockchain info. Is Bitcoin running?"
    exit 1
fi

VERIFICATION_PROGRESS=$(echo "$BLOCKCHAIN_INFO" | jq -r '.verificationprogress')
FORMATTED_PROGRESS=$(printf "%.2f" $(echo "$VERIFICATION_PROGRESS * 100" | bc -l))

log_info "Current sync progress: $FORMATTED_PROGRESS%"

# Check if sync is complete
if (( $(echo "$VERIFICATION_PROGRESS < 0.9999" | bc -l) )); then
    log_warning "Bitcoin is still syncing. This script should only be run after sync is complete."
    log_info "Current progress: $FORMATTED_PROGRESS%"
    read -p "Continue anyway? (y/n): " CONTINUE
    if [[ "$CONTINUE" != "y" && "$CONTINUE" != "Y" ]]; then
        exit 1
    fi
else
    log_success "Bitcoin sync is complete. Optimizing for running node configuration."
fi

# Create optimized config for running node (post-sync)
CONFIG_CONTENT="# Bitcoin Core configuration file - Optimized for running node
# Updated on $(date)

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

# Performance Optimizations for Running Node
dbcache=2000
maxmempool=300
maxconnections=50
blocksonly=0
mempoolfullrbf=1
par=4

# ZMQ Settings
zmqpubrawtx=tcp://0.0.0.0:9332
zmqpubhashtx=tcp://0.0.0.0:9332
zmqpubsequence=tcp://0.0.0.0:9332
zmqpubrawblock=tcp://0.0.0.0:9333
"

# Create a temporary file
TMP_CONFIG_FILE="/tmp/bitcoin.conf"
echo "$CONFIG_CONTENT" > "$TMP_CONFIG_FILE"

# Copy to the container
docker cp "$TMP_CONFIG_FILE" $BITCOIN_CONTAINER:/bitcoin/.bitcoin/bitcoin.conf

# Set proper permissions
docker exec $BITCOIN_CONTAINER chmod 600 /bitcoin/.bitcoin/bitcoin.conf

# Also update the config in the host volume
if [ -d "/bitcoin-data/bitcoin/.bitcoin" ]; then
    log_info "Updating config in host volume..."
    echo "$CONFIG_CONTENT" > "/bitcoin-data/bitcoin/.bitcoin/bitcoin.conf"
    chmod 600 "/bitcoin-data/bitcoin/.bitcoin/bitcoin.conf"
fi

# Update environment variables in docker-compose if possible
COMPOSE_FILE="/home/ubuntu/counterparty-node/docker-compose.yml"
if [ -f "$COMPOSE_FILE" ]; then
    log_info "Updating docker-compose.yml..."
    sed -i 's/DB_CACHE=6000/DB_CACHE=2000/g' "$COMPOSE_FILE"
    sed -i 's/BLOCKSONLY=1/BLOCKSONLY=0/g' "$COMPOSE_FILE"
    sed -i 's/MAXCONNECTIONS=25/MAXCONNECTIONS=50/g' "$COMPOSE_FILE"
    sed -i 's/PARALLEL_BLOCKS=8/PARALLEL_BLOCKS=4/g' "$COMPOSE_FILE"
fi

# Restart Bitcoin container
log_info "Restarting Bitcoin container to apply changes..."
docker restart $BITCOIN_CONTAINER

log_success "Optimization completed. Bitcoin is now configured for normal operation."
log_info "Monitor with: ~/check-sync-status.sh"

# Create a cron job to check sync status periodically
if ! crontab -l | grep -q "check-sync-status.sh"; then
    log_info "Setting up daily sync status check..."
    (crontab -l 2>/dev/null; echo "0 6 * * * /home/ubuntu/check-sync-status.sh > /home/ubuntu/sync-status.log 2>&1") | crontab -
    log_success "Cron job added to check sync status daily at 6:00 AM"
fi

exit 0