#!/bin/bash
# Script to check Bitcoin sync status in a Counterparty Docker deployment

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
    
    # Check if Docker service is running
    if command -v systemctl &>/dev/null; then
        DOCKER_STATUS=$(systemctl is-active docker)
        if [ "$DOCKER_STATUS" != "active" ]; then
            log_error "Docker service is not running (status: $DOCKER_STATUS)"
            log_info "Try starting Docker with: sudo systemctl start docker"
        fi
    fi
    exit 1
fi

# Get Bitcoin container name
BITCOIN_CONTAINER=$(docker ps --format "{{.Names}}" | grep -E "bitcoind.*1$" | head -1)
if [ -z "$BITCOIN_CONTAINER" ]; then
    log_error "No Bitcoin container found. Make sure containers are running."
    
    # Check if containers exist but are stopped
    STOPPED_CONTAINERS=$(docker ps -a --format "{{.Names}} ({{.Status}})" | grep -E "bitcoind")
    if [ ! -z "$STOPPED_CONTAINERS" ]; then
        log_warning "Found stopped Bitcoin containers:"
        echo "$STOPPED_CONTAINERS"
        log_info "Try starting services with: ~/start-counterparty.sh mainnet"
    else
        log_info "No Bitcoin containers found at all. You may need to set up the environment."
        log_info "Try running setup: ~/counterparty-arm64/scripts/setup.sh"
    fi
    
    exit 1
fi

log_info "Found Bitcoin container: $BITCOIN_CONTAINER"

# Try RPC call directly first as it's most critical
log_info "Checking blockchain synchronization status via RPC..."

# Attempt to determine if container is running testnet or mainnet based on name
if [[ "$BITCOIN_CONTAINER" == *"testnet"* ]]; then
    RPC_PORT=18332
    log_info "Detected testnet container, using RPC port 18332"
elif [[ "$BITCOIN_CONTAINER" == *"regtest"* ]]; then
    RPC_PORT=18443
    log_info "Detected regtest container, using RPC port 18443"
else
    RPC_PORT=8332
    log_info "Using mainnet RPC port 8332"
fi

# Try direct RPC call first
BLOCKCHAIN_INFO=$(docker exec $BITCOIN_CONTAINER curl -s --user rpc:rpc --data-binary '{"jsonrpc":"1.0","id":"curl","method":"getblockchaininfo","params":[]}' -H 'content-type: text/plain;' http://127.0.0.1:$RPC_PORT/ 2>/dev/null)

RPC_SUCCESS=false
if [ ! -z "$BLOCKCHAIN_INFO" ] && [ "$(echo $BLOCKCHAIN_INFO | jq -e '.result != null' 2>/dev/null)" == "true" ]; then
    log_success "RPC connection successful!"
    RPC_SUCCESS=true
    # Extract the "result" field from the JSON response
    BLOCKCHAIN_INFO=$(echo $BLOCKCHAIN_INFO | jq .result)
else
    log_warning "RPC call failed. Trying bitcoin-cli command..."
    
    # Try with the bitcoin-cli command as fallback
    BLOCKCHAIN_INFO=$(docker exec $BITCOIN_CONTAINER bitcoin-cli -conf=/bitcoin/.bitcoin/bitcoin.conf getblockchaininfo 2>/dev/null)
    
    if [ $? -eq 0 ] && [ ! -z "$BLOCKCHAIN_INFO" ]; then
        log_success "bitcoin-cli command succeeded."
        # bitcoin-cli output is already the result object
        BLOCKCHAIN_INFO=$(echo $BLOCKCHAIN_INFO)
    else
        # Special handling for blocksonly mode
        BLOCKSONLY_ENABLED=$(docker exec $BITCOIN_CONTAINER grep -c "blocksonly=1" /bitcoin/.bitcoin/bitcoin.conf 2>/dev/null || echo "0")
        if [ "$BLOCKSONLY_ENABLED" -gt "0" ]; then
            log_warning "Bitcoin is in 'blocksonly' mode which limits RPC functionality during initial sync."
            log_info "Attempting to get blockchain info using debug.log..."
            
            # Try to get block count directly from debug.log
            BLOCK_COUNT=$(docker exec $BITCOIN_CONTAINER grep -oE "UpdateTip: new best=[a-z0-9]+ height=([0-9]+)" /bitcoin/.bitcoin/debug.log 2>/dev/null | tail -1 | grep -oE "height=[0-9]+" | cut -d= -f2)
            if [ ! -z "$BLOCK_COUNT" ]; then
                log_success "Found block height in logs: $BLOCK_COUNT"
                # Create minimal blockchain info
                BLOCKCHAIN_INFO="{\"blocks\": $BLOCK_COUNT, \"headers\": 0, \"verificationprogress\": 0.5, \"initialblockdownload\": true}"
                
                # Try to get headers count from debug.log
                HEADERS_COUNT=$(docker exec $BITCOIN_CONTAINER grep -oE "Synchronizing headers, height=([0-9]+)" /bitcoin/.bitcoin/debug.log 2>/dev/null | tail -1 | grep -oE "height=[0-9]+" | cut -d= -f2)
                if [ ! -z "$HEADERS_COUNT" ]; then
                    # Update headers in our blockchain info
                    BLOCKCHAIN_INFO=$(echo "$BLOCKCHAIN_INFO" | jq ".headers = $HEADERS_COUNT")
                    
                    # Calculate approximate progress
                    if [ "$HEADERS_COUNT" -gt "0" ]; then
                        PROGRESS=$(echo "scale=4; $BLOCK_COUNT / $HEADERS_COUNT" | bc)
                        BLOCKCHAIN_INFO=$(echo "$BLOCKCHAIN_INFO" | jq ".verificationprogress = $PROGRESS")
                    fi
                fi
                
                log_info "Generated blockchain info from debug logs - this is normal during initial sync with blocksonly=1"
                
                # Check if we should trigger auto-switch from blocksonly mode
                if [ "$BLOCK_COUNT" -gt "0" ] && [ "$HEADERS_COUNT" -gt "0" ]; then
                    PROGRESS_PERCENT=$(echo "scale=0; $PROGRESS * 100" | bc | cut -d. -f1)
                    if [ "$PROGRESS_PERCENT" -ge "99" ]; then
                        log_warning "Sync is nearly complete ($PROGRESS_PERCENT%). Auto-disabling blocksonly mode..."
                        
                        # Edit bitcoin.conf to disable blocksonly mode
                        docker exec $BITCOIN_CONTAINER sed -i 's/blocksonly=1/blocksonly=0/g' /bitcoin/.bitcoin/bitcoin.conf
                        log_info "Restarting Bitcoin to apply blocksonly=0 setting..."
                        docker restart $BITCOIN_CONTAINER
                        log_success "Bitcoin restarting with full RPC capabilities enabled"
                        log_info "Run this script again in a minute to check new status"
                        exit 0
                    fi
                fi
            else
                log_error "Couldn't extract sync information from Bitcoin logs."
                log_info "Performing standard diagnostics..."
            fi
        else
            log_error "Both RPC and bitcoin-cli methods failed to connect to Bitcoin node."
            log_info "Performing diagnostics..."
        fi
        
        # Check if container is running
        CONTAINER_STATUS=$(docker inspect --format='{{.State.Status}}' $BITCOIN_CONTAINER 2>/dev/null)
        if [ "$CONTAINER_STATUS" != "running" ]; then
            log_error "Container $BITCOIN_CONTAINER is not running (status: $CONTAINER_STATUS)"
            exit 1
        fi
        
        # Check network connectivity within container
        log_info "Testing network connectivity inside container..."
        docker exec $BITCOIN_CONTAINER bash -c "ping -c 1 127.0.0.1" &>/dev/null
        if [ $? -ne 0 ]; then
            log_error "Network connectivity issue inside container!"
        else
            log_success "Internal network connectivity OK"
        fi
        
        # Check if Bitcoin process is running inside container
        log_info "Checking if Bitcoin process is running inside container..."
        BITCOIN_PROCESS=$(docker exec $BITCOIN_CONTAINER ps aux | grep -v grep | grep bitcoind)
        if [ -z "$BITCOIN_PROCESS" ]; then
            log_error "Bitcoin process is not running inside the container!"
            log_info "Container is running but bitcoind process has crashed or failed to start."
        else
            log_success "Bitcoin process is running"
            echo "$BITCOIN_PROCESS" | head -1
        fi
        
        # Check if config file exists and is valid
        log_info "Checking Bitcoin configuration..."
        CONFIG_CHECK=$(docker exec $BITCOIN_CONTAINER bash -c "if [ -f /bitcoin/.bitcoin/bitcoin.conf ]; then echo 'Config exists'; cat /bitcoin/.bitcoin/bitcoin.conf | grep -E 'rpcuser|rpcpassword|rpcallowip|rpcbind'; else echo 'Config missing'; fi")
        echo "$CONFIG_CHECK"
        
        # Check RPC port with netstat
        log_info "Checking if RPC port $RPC_PORT is listening..."
        NETSTAT_CHECK=$(docker exec $BITCOIN_CONTAINER bash -c "netstat -tuln | grep $RPC_PORT" 2>/dev/null || docker exec $BITCOIN_CONTAINER bash -c "ss -tuln | grep $RPC_PORT" 2>/dev/null)
        if [ ! -z "$NETSTAT_CHECK" ]; then
            log_success "RPC port $RPC_PORT is listening:"
            echo "$NETSTAT_CHECK"
        else
            log_error "RPC port $RPC_PORT is NOT listening! Bitcoin may still be starting up."
        fi
        
        log_error "Container is running but Bitcoin RPC is not accessible. Check logs for errors:"
        docker logs --tail 20 $BITCOIN_CONTAINER
        exit 1
    fi
fi

# Verify we can parse the returned JSON data
if ! echo "$BLOCKCHAIN_INFO" | jq -e '.blocks' > /dev/null 2>&1; then
    log_error "Failed to parse blockchain info. Received invalid JSON response."
    echo "$BLOCKCHAIN_INFO" | head -20
    exit 1
fi

# Extract sync information
CURRENT_BLOCKS=$(echo "$BLOCKCHAIN_INFO" | jq -r '.blocks')
HEADERS=$(echo "$BLOCKCHAIN_INFO" | jq -r '.headers')
VERIFICATION_PROGRESS=$(echo "$BLOCKCHAIN_INFO" | jq -r '.verificationprogress')
FORMATTED_PROGRESS=$(printf "%.2f" $(echo "$VERIFICATION_PROGRESS * 100" | bc -l))
IS_INITIAL_BLOCK_DOWNLOAD=$(echo "$BLOCKCHAIN_INFO" | jq -r '.initialblockdownload')

# Get system resource usage
log_info "Checking system resource usage..."
CPU_USAGE=$(docker stats --no-stream $BITCOIN_CONTAINER --format "{{.CPUPerc}}" 2>/dev/null || echo "N/A")
MEM_USAGE=$(docker stats --no-stream $BITCOIN_CONTAINER --format "{{.MemUsage}}" 2>/dev/null || echo "N/A")
DISK_USAGE=$(docker exec $BITCOIN_CONTAINER du -sh /bitcoin/.bitcoin 2>/dev/null || echo "N/A")

# Get network info
NETWORK_INFO=$(docker exec $BITCOIN_CONTAINER bitcoin-cli -conf=/bitcoin/.bitcoin/bitcoin.conf getnetworkinfo 2>/dev/null)
CONNECTIONS=$(echo "$NETWORK_INFO" | jq -r '.connections' 2>/dev/null || echo "N/A")

# Get mempool info for transaction processing capacity
MEMPOOL_INFO=$(docker exec $BITCOIN_CONTAINER bitcoin-cli -conf=/bitcoin/.bitcoin/bitcoin.conf getmempoolinfo 2>/dev/null)
MEMPOOL_SIZE=$(echo "$MEMPOOL_INFO" | jq -r '.size' 2>/dev/null || echo "N/A")
MEMPOOL_BYTES=$(echo "$MEMPOOL_INFO" | jq -r '.bytes' 2>/dev/null || echo "N/A")
MEMPOOL_USAGE_MB=$(echo "scale=2; $MEMPOOL_BYTES / 1048576" | bc 2>/dev/null || echo "N/A")

# Get dbcache setting from config
DBCACHE_SETTING=$(docker exec $BITCOIN_CONTAINER grep -E "^dbcache=" /bitcoin/.bitcoin/bitcoin.conf 2>/dev/null | cut -d= -f2 || echo "N/A")

# Store sync progress for timing estimation
TIMESTAMP=$(date +%s)
STATE_FILE="/tmp/bitcoin_sync_progress.dat"

# Calculate sync speed and ETA
if [ -f "$STATE_FILE" ]; then
    # Load previous state
    source "$STATE_FILE"
    
    # Calculate time difference
    TIME_DIFF=$((TIMESTAMP - PREV_TIMESTAMP))
    
    if [ $TIME_DIFF -gt 60 ]; then  # Only calculate if at least 1 minute has passed
        BLOCKS_DIFF=$((CURRENT_BLOCKS - PREV_BLOCKS))
        
        if [ $BLOCKS_DIFF -gt 0 ] && [ $TIME_DIFF -gt 0 ]; then
            # Blocks per second
            BLOCKS_PER_SECOND=$(echo "scale=4; $BLOCKS_DIFF / $TIME_DIFF" | bc)
            # Blocks per hour
            BLOCKS_PER_HOUR=$(echo "scale=2; $BLOCKS_PER_SECOND * 3600" | bc)
            
            # Estimated time remaining
            if [ $BLOCKS_PER_SECOND != "0" ] && [ $HEADERS -gt $CURRENT_BLOCKS ]; then
                BLOCKS_REMAINING=$((HEADERS - CURRENT_BLOCKS))
                SECONDS_REMAINING=$(echo "scale=0; $BLOCKS_REMAINING / $BLOCKS_PER_SECOND" | bc)
                HOURS_REMAINING=$(echo "scale=2; $SECONDS_REMAINING / 3600" | bc)
                DAYS_REMAINING=$(echo "scale=2; $HOURS_REMAINING / 24" | bc)
            fi
        fi
    fi
fi

# Save current state for next run
echo "PREV_TIMESTAMP=$TIMESTAMP" > "$STATE_FILE"
echo "PREV_BLOCKS=$CURRENT_BLOCKS" >> "$STATE_FILE"
echo "PREV_PROGRESS=$VERIFICATION_PROGRESS" >> "$STATE_FILE"

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
        
        if [ ! -z "$BLOCKS_PER_HOUR" ]; then
            log_info "  Sync Speed: $BLOCKS_PER_HOUR blocks/hour"
            
            if [ ! -z "$DAYS_REMAINING" ] && [ $(echo "$DAYS_REMAINING > 1" | bc) -eq 1 ]; then
                log_info "  Estimated Time Remaining: $DAYS_REMAINING days"
            elif [ ! -z "$HOURS_REMAINING" ]; then
                log_info "  Estimated Time Remaining: $HOURS_REMAINING hours"
            fi
        fi
    fi
else
    log_success "  Status: SYNCHRONIZED (Chain is up to date)"
fi

# Display resource usage
log_info "System Resource Usage:"
log_info "  CPU Usage: $CPU_USAGE"
log_info "  Memory Usage: $MEM_USAGE"
log_info "  Disk Usage: $DISK_USAGE"
log_info "  Network Connections: $CONNECTIONS"
log_info "  Mempool Size: $MEMPOOL_SIZE transactions ($MEMPOOL_USAGE_MB MB)"
log_info "  DB Cache Setting: $DBCACHE_SETTING MB"

# Provide optimization recommendations
log_info "Performance Recommendations:"

# Check dbcache setting (recommend 4-8GB for initial sync, less for running node)
if [ "$DBCACHE_SETTING" != "N/A" ]; then
    if [ $DBCACHE_SETTING -lt 4000 ] && [ "$IS_INITIAL_BLOCK_DOWNLOAD" = "true" ]; then
        log_warning "  Consider increasing dbcache to at least 4000 MB for faster initial sync"
    elif [ $DBCACHE_SETTING -gt 4000 ] && [ "$IS_INITIAL_BLOCK_DOWNLOAD" = "false" ]; then
        log_warning "  Consider reducing dbcache to 1000-2000 MB after sync is complete to free up memory"
    fi
fi

# Check connections
if [ "$CONNECTIONS" != "N/A" ] && [ $CONNECTIONS -lt 8 ]; then
    log_warning "  Low peer connections ($CONNECTIONS). More connections may improve sync speed."
fi

# Check if sync is stalled
if [ ! -z "$BLOCKS_PER_HOUR" ] && [ $(echo "$BLOCKS_PER_HOUR < 1" | bc) -eq 1 ] && [ "$VERIFICATION_PROGRESS" != "1" ]; then
    log_error "  Sync appears to be stalled. Check network connectivity and disk I/O."
    log_info "  Try restarting the Bitcoin container: docker restart $BITCOIN_CONTAINER"
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

log_info "Status check completed at $(date)"
exit 0