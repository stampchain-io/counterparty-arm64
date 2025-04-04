#!/bin/bash
# Script to check Bitcoin sync status in a Counterparty Docker deployment

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Try multiple locations for common.sh
if [ -f "$HOME/common.sh" ]; then
    source "$HOME/common.sh"
elif [ -f "$SCRIPT_DIR/common.sh" ]; then
    source "$SCRIPT_DIR/common.sh"
elif [ -f "/home/ubuntu/counterparty-arm64/scripts/common.sh" ]; then
    source "/home/ubuntu/counterparty-arm64/scripts/common.sh"
else
    REPO_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
    source "$REPO_DIR/scripts/common.sh" || {
        # If common.sh is not found, define the basic logging functions
        RED='\033[0;31m'
        GREEN='\033[0;32m'
        YELLOW='\033[1;33m'
        BLUE='\033[0;34m'
        NC='\033[0m' # No Color
        
        log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
        log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
        log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
        log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
        
        log_warning "Could not find common.sh, using basic logging functions"
    }
fi

# Get Bitcoin container name
BITCOIN_CONTAINER=$(docker ps --format "{{.Names}}" | grep -E "bitcoind.*1$" | head -1)
if [ -z "$BITCOIN_CONTAINER" ]; then
    log_error "No Bitcoin container found. Make sure Docker is running and the container exists."
    exit 1
fi

log_info "Found Bitcoin container: $BITCOIN_CONTAINER"

# Check blockchain info
log_info "Checking blockchain synchronization status..."
BLOCKCHAIN_INFO=$(docker exec $BITCOIN_CONTAINER bitcoin-cli getblockchaininfo 2>/dev/null)

# Check if the command succeeded
if [ $? -ne 0 ]; then
    log_warning "Could not get blockchain info using bitcoin-cli. Trying direct RPC call..."
    BLOCKCHAIN_INFO=$(docker exec $BITCOIN_CONTAINER curl -s --user rpc:rpc --data-binary '{"jsonrpc":"1.0","id":"curl","method":"getblockchaininfo","params":[]}' -H 'content-type: text/plain;' http://127.0.0.1:8332/ 2>/dev/null)
    
    if [ -z "$BLOCKCHAIN_INFO" ]; then
        log_error "Failed to get blockchain info. Bitcoin RPC might not be accessible."
        exit 1
    fi
    
    # Extract the "result" field from the JSON response
    BLOCKCHAIN_INFO=$(echo $BLOCKCHAIN_INFO | jq .result)
else
    # bitcoin-cli output is already the result object
    BLOCKCHAIN_INFO=$(echo $BLOCKCHAIN_INFO)
fi

# Extract sync information
CURRENT_BLOCKS=$(echo "$BLOCKCHAIN_INFO" | jq -r '.blocks')
HEADERS=$(echo "$BLOCKCHAIN_INFO" | jq -r '.headers')
VERIFICATION_PROGRESS=$(echo "$BLOCKCHAIN_INFO" | jq -r '.verificationprogress')
FORMATTED_PROGRESS=$(printf "%.2f" $(echo "$VERIFICATION_PROGRESS * 100" | bc -l))

# Display the status
log_info "Bitcoin Node Sync Status:"
log_info "  Current Block Height: $CURRENT_BLOCKS"
log_info "  Chain Headers Height: $HEADERS"
log_info "  Sync Progress: $FORMATTED_PROGRESS%"

# Check if we're syncing or synchronized
if (( $(echo "$VERIFICATION_PROGRESS < 0.9999" | bc -l) )); then
    log_warning "  Status: SYNCING"
    
    # Calculate estimated time remaining if possible
    BLOCKS_REMAINING=$((HEADERS - CURRENT_BLOCKS))
    if [ $BLOCKS_REMAINING -gt 0 ]; then
        log_info "  Blocks Remaining: $BLOCKS_REMAINING"
    fi
else
    log_success "  Status: SYNCHRONIZED (Chain is up to date)"
fi

# Check if Counterparty is running
COUNTERPARTY_CONTAINER=$(docker ps --format "{{.Names}}" | grep -E "counterparty.*core.*1$" | head -1)
if [ -n "$COUNTERPARTY_CONTAINER" ]; then
    log_info "Counterparty container is running: $COUNTERPARTY_CONTAINER"
    # Show last few lines of Counterparty logs
    log_info "Recent Counterparty logs:"
    docker logs --tail 10 $COUNTERPARTY_CONTAINER
else
    log_warning "No Counterparty container found."
fi

exit 0