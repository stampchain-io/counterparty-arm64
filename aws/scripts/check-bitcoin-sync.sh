#!/bin/bash
# Script to check Bitcoin node sync status

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
source "$REPO_DIR/scripts/common.sh"

# Default values
HOST="localhost"
PORT="8332"
USER=""
PASS=""
VERBOSE=false

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        --host)
        HOST="$2"
        shift
        shift
        ;;
        --port)
        PORT="$2"
        shift
        shift
        ;;
        --user)
        USER="$2"
        shift
        shift
        ;;
        --pass)
        PASS="$2"
        shift
        shift
        ;;
        --verbose)
        VERBOSE=true
        shift
        ;;
        --help)
        echo "Usage: check-bitcoin-sync.sh [OPTIONS]"
        echo "Options:"
        echo "  --host HOST              Bitcoin RPC host (default: localhost)"
        echo "  --port PORT              Bitcoin RPC port (default: 8332)"
        echo "  --user USER              Bitcoin RPC username"
        echo "  --pass PASS              Bitcoin RPC password"
        echo "  --verbose                Display detailed information"
        echo "  --help                   Show this help message"
        exit 0
        ;;
        *)
        echo "Unknown option: $key"
        exit 1
        ;;
    esac
done

# Check dependencies
check_dependencies curl jq

# Check if credentials are provided
if [ -z "$USER" ] || [ -z "$PASS" ]; then
    # Try to extract from bitcoin.conf if it exists
    if [ -f "$HOME/.bitcoin/bitcoin.conf" ]; then
        log_info "Extracting credentials from bitcoin.conf..."
        USER=$(grep -E "^rpcuser=" "$HOME/.bitcoin/bitcoin.conf" | cut -d= -f2)
        PASS=$(grep -E "^rpcpassword=" "$HOME/.bitcoin/bitcoin.conf" | cut -d= -f2)
    fi
    
    # If we still don't have credentials
    if [ -z "$USER" ] || [ -z "$PASS" ]; then
        log_error "Bitcoin RPC credentials not provided. Use --user and --pass options."
        exit 1
    fi
fi

# Function to make RPC call
bitcoin_rpc() {
    local method="$1"
    local params="$2"
    
    if [ -z "$params" ]; then
        params="[]"
    fi
    
    curl -s --user "$USER:$PASS" --data-binary "{\"jsonrpc\":\"1.0\",\"id\":\"curl\",\"method\":\"$method\",\"params\":$params}" -H "content-type: text/plain;" http://$HOST:$PORT/
}

# Get blockchain info
log_info "Querying Bitcoin node at $HOST:$PORT..."
BLOCKCHAIN_INFO=$(bitcoin_rpc "getblockchaininfo")

if [ $? -ne 0 ] || echo "$BLOCKCHAIN_INFO" | grep -q "error"; then
    log_error "Failed to connect to Bitcoin node. Please check your connection and credentials."
    if echo "$BLOCKCHAIN_INFO" | grep -q "error"; then
        ERROR_MSG=$(echo "$BLOCKCHAIN_INFO" | jq -r '.error.message')
        log_error "Error message: $ERROR_MSG"
    fi
    exit 1
fi

# Extract sync information
CURRENT_BLOCKS=$(echo "$BLOCKCHAIN_INFO" | jq -r '.result.blocks')
HEADERS=$(echo "$BLOCKCHAIN_INFO" | jq -r '.result.headers')
VERIFICATION_PROGRESS=$(echo "$BLOCKCHAIN_INFO" | jq -r '.result.verificationprogress')
IS_INITIAL_BLOCK_DOWNLOAD=$(echo "$BLOCKCHAIN_INFO" | jq -r '.result.initialblockdownload')
FORMATTED_PROGRESS=$(echo "$VERIFICATION_PROGRESS * 100" | bc -l | xargs printf "%.2f")

# Print status
log_info "Bitcoin Node Sync Status:"
log_info "  Current Block Height: $CURRENT_BLOCKS"
log_info "  Chain Headers Height: $HEADERS"
log_info "  Sync Progress: $FORMATTED_PROGRESS%"

if [ "$IS_INITIAL_BLOCK_DOWNLOAD" = "true" ]; then
    log_warning "  Status: SYNCING (Initial Block Download in progress)"
elif [ "$CURRENT_BLOCKS" -lt "$HEADERS" ]; then
    log_warning "  Status: SYNCING (Downloading new blocks)"
else
    log_success "  Status: SYNCHRONIZED (Chain is up to date)"
fi

# Get network info if verbose mode is enabled
if [ "$VERBOSE" = "true" ]; then
    NETWORK_INFO=$(bitcoin_rpc "getnetworkinfo")
    NET_CONNECTIONS=$(echo "$NETWORK_INFO" | jq -r '.result.connections')
    VERSION=$(echo "$NETWORK_INFO" | jq -r '.result.version')
    PROTOCOL=$(echo "$NETWORK_INFO" | jq -r '.result.protocolversion')
    
    log_info "Additional Information:"
    log_info "  Bitcoin Version: $VERSION"
    log_info "  Protocol Version: $PROTOCOL"
    log_info "  Network Connections: $NET_CONNECTIONS"
    
    MEMPOOL_INFO=$(bitcoin_rpc "getmempoolinfo")
    MEMPOOL_SIZE=$(echo "$MEMPOOL_INFO" | jq -r '.result.size')
    MEMPOOL_BYTES=$(echo "$MEMPOOL_INFO" | jq -r '.result.bytes')
    MEMPOOL_MB=$(echo "scale=2; $MEMPOOL_BYTES / 1024 / 1024" | bc)
    
    log_info "  Mempool Transactions: $MEMPOOL_SIZE"
    log_info "  Mempool Size: $MEMPOOL_MB MB"
    
    UPTIME_INFO=$(bitcoin_rpc "uptime")
    UPTIME_SECONDS=$(echo "$UPTIME_INFO" | jq -r '.result')
    UPTIME_DAYS=$(echo "scale=2; $UPTIME_SECONDS / 86400" | bc)
    
    log_info "  Node Uptime: $UPTIME_DAYS days"
fi

# Estimate time remaining for sync
if [ "$IS_INITIAL_BLOCK_DOWNLOAD" = "true" ]; then
    # We can estimate time remaining if we know the sync progress
    BLOCKS_REMAINING=$((HEADERS - CURRENT_BLOCKS))
    
    if [ $BLOCKS_REMAINING -gt 0 ]; then
        log_info "Sync Information:"
        log_info "  Blocks Remaining: $BLOCKS_REMAINING"
        
        # Try to get a timing estimate using the blockchain info
        PROGRESS_LEFT=$(echo "1 - $VERIFICATION_PROGRESS" | bc -l)
        PROGRESS_DONE=$(echo "$VERIFICATION_PROGRESS" | bc -l)
        
        if [ "$(echo "$PROGRESS_DONE > 0.01" | bc -l)" -eq 1 ]; then
            # Get the state of the chain 30 minutes ago
            UPTIME=$(bitcoin_rpc "uptime" | jq -r '.result')
            
            if [ $UPTIME -gt 1800 ]; then
                # We'll estimate based on blocks synced per hour
                CHAINSTATE_DIR="$HOME/.bitcoin/chainstate"
                if [ -d "$CHAINSTATE_DIR" ]; then
                    CURRENT_TIME=$(date +%s)
                    STATE_FILES=$(find "$CHAINSTATE_DIR" -type f -mmin -30 | wc -l)
                    
                    if [ $STATE_FILES -gt 0 ]; then
                        # Rough estimate based on recent sync speed
                        SPEED=$(echo "scale=2; $CURRENT_BLOCKS / $PROGRESS_DONE" | bc -l)
                        TOTAL_BLOCKS=$(echo "scale=0; $SPEED" | bc -l)
                        BLOCKS_PER_HOUR=$(echo "scale=2; $SPEED * $PROGRESS_DONE / ($UPTIME / 3600)" | bc -l)
                        
                        if [ "$(echo "$BLOCKS_PER_HOUR > 0" | bc -l)" -eq 1 ]; then
                            HOURS_LEFT=$(echo "scale=2; $BLOCKS_REMAINING / $BLOCKS_PER_HOUR" | bc -l)
                            DAYS_LEFT=$(echo "scale=2; $HOURS_LEFT / 24" | bc -l)
                            
                            log_info "  Estimated Sync Speed: $BLOCKS_PER_HOUR blocks/hour"
                            
                            if [ "$(echo "$HOURS_LEFT > 24" | bc -l)" -eq 1 ]; then
                                log_info "  Estimated Time Remaining: $DAYS_LEFT days"
                            else
                                log_info "  Estimated Time Remaining: $HOURS_LEFT hours"
                            fi
                        fi
                    fi
                fi
            fi
        fi
    fi
fi

# Print a simple one-line status for scripts
if [ "$IS_INITIAL_BLOCK_DOWNLOAD" = "true" ] || [ "$CURRENT_BLOCKS" -lt "$HEADERS" ]; then
    echo "SYNCING:$FORMATTED_PROGRESS%"
    exit 2
else
    echo "SYNCHRONIZED:100.00%"
    exit 0
fi