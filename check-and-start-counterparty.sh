#!/bin/bash
# check-and-start-counterparty.sh - Script to check Bitcoin sync status and start Counterparty when ready

# Source common functions
source "/home/ubuntu/common.sh"

# Load config if available 
CONFIG_DIR=${CONFIG_DIR:-/home/ubuntu/.counterparty-arm64}
if [ -f "$CONFIG_DIR/config.env" ]; then
    source "$CONFIG_DIR/config.env"
fi

# Constants 
BITCOIN_CONTAINER="bitcoind"
COUNTERPARTY_CONTAINER="counterparty-core"
BITCOIN_RPC_USER="rpc"
BITCOIN_RPC_PASSWORD="rpc"
BITCOIN_RPC_PORT="8332"
MINIMUM_SYNC=0.1  # Only start Counterparty if we're at least 10% synchronized

# Set default values for environment variables if not defined in config.env
export COUNTERPARTY_DOCKER_DATA=${COUNTERPARTY_DOCKER_DATA:-/bitcoin-data}
export COUNTERPARTY_REPO=${COUNTERPARTY_REPO:-/bitcoin-data/repo/counterparty-core}
export NETWORK_PROFILE=${NETWORK_PROFILE:-mainnet}

# Format timestamp for log
timestamp() {
  date "+%Y-%m-%d %H:%M:%S"
}

log_info "[$( timestamp )] Checking Bitcoin synchronization status..."

# Get block counts using bitcoin-cli
if docker exec $BITCOIN_CONTAINER bitcoin-cli -rpcuser=$BITCOIN_RPC_USER -rpcpassword=$BITCOIN_RPC_PASSWORD getblockchaininfo > /dev/null 2>&1; then
    # Get blockchain info using bitcoin-cli
    BLOCKCHAIN_INFO=$(docker exec $BITCOIN_CONTAINER bitcoin-cli -rpcuser=$BITCOIN_RPC_USER -rpcpassword=$BITCOIN_RPC_PASSWORD getblockchaininfo)
    BLOCKS=$(echo "$BLOCKCHAIN_INFO" | grep -oP '"blocks":\s*\K\d+')
    HEADERS=$(echo "$BLOCKCHAIN_INFO" | grep -oP '"headers":\s*\K\d+')
    VERIFICATION_PROGRESS=$(echo "$BLOCKCHAIN_INFO" | grep -oP '"verificationprogress":\s*\K[0-9\.]+')
    FORMATTED_PROGRESS=$(echo "${VERIFICATION_PROGRESS} * 100" | bc | awk '{printf "%.2f", $0}')
    
    log_info "  Current blocks: $BLOCKS"
    log_info "  Current headers: $HEADERS"
    log_info "  Sync progress: ${FORMATTED_PROGRESS}%"
    
    # Check if Counterparty is already running
    COUNTERPARTY_RUNNING=$(docker ps | grep $COUNTERPARTY_CONTAINER | wc -l)
    
    if [ "$COUNTERPARTY_RUNNING" -gt 0 ]; then
        log_success "  Counterparty container is already running."
        exit 0
    fi
    
    # Only start Counterparty if we're at least at MINIMUM_SYNC
    if (( $(echo "$VERIFICATION_PROGRESS < $MINIMUM_SYNC" | bc -l) )); then
        log_warning "  Status: SYNCING - Not starting Counterparty yet (waiting for at least ${MINIMUM_SYNC}% sync)"
        exit 0
    fi
    
    # If we got this far, Bitcoin is sufficiently synced, so start Counterparty
    log_info "Bitcoin node is sufficiently synchronized ($FORMATTED_PROGRESS%). Starting Counterparty container..."
    
    # Determine which network profile is being used
    if docker ps | grep -q "bitcoind-testnet3"; then
        NETWORK_PROFILE="testnet3"
        COUNTERPARTY_CONTAINER="counterparty-core-testne3"
    elif docker ps | grep -q "bitcoind-testnet4"; then
        NETWORK_PROFILE="testnet4"
        COUNTERPARTY_CONTAINER="counterparty-core-testne4"
    elif docker ps | grep -q "bitcoind-regtest"; then
        NETWORK_PROFILE="regtest"
        COUNTERPARTY_CONTAINER="counterparty-core-regtest"
    else
        NETWORK_PROFILE="mainnet"
        COUNTERPARTY_CONTAINER="counterparty-core"
    fi
    
    log_info "Detected network profile: $NETWORK_PROFILE, container: $COUNTERPARTY_CONTAINER"
    cd /home/ubuntu/counterparty-node && docker compose --profile $NETWORK_PROFILE up -d $COUNTERPARTY_CONTAINER
    
    # Verify Counterparty started
    sleep 5
    if [ "$(docker ps | grep $COUNTERPARTY_CONTAINER | wc -l)" -gt 0 ]; then
        log_success "Counterparty container started successfully."
    else
        log_error "Failed to start Counterparty container. Check logs with: docker logs counterparty-core"
    fi
else
    log_error "  Bitcoin container not running or RPC connection failed"
    log_info "  Checking Docker container status..."
    docker ps
    exit 1
fi
