#!/bin/bash
# Script to monitor Bitcoin node with alerts

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
source "$REPO_DIR/scripts/common.sh"

# Default values
HOST="localhost"
PORT="8332"
USER=""
PASS=""
LOG_FILE="/var/log/bitcoin-monitor.log"
ALERT_EMAIL=""
SEND_ALERTS=false

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
        --log)
        LOG_FILE="$2"
        shift
        shift
        ;;
        --email)
        ALERT_EMAIL="$2"
        SEND_ALERTS=true
        shift
        shift
        ;;
        --help)
        echo "Usage: monitor-bitcoin.sh [OPTIONS]"
        echo "Options:"
        echo "  --host HOST              Bitcoin RPC host (default: localhost)"
        echo "  --port PORT              Bitcoin RPC port (default: 8332)"
        echo "  --user USER              Bitcoin RPC username"
        echo "  --pass PASS              Bitcoin RPC password"
        echo "  --log FILE               Log file (default: /var/log/bitcoin-monitor.log)"
        echo "  --email EMAIL            Send alerts to this email address"
        echo "  --help                   Show this help message"
        exit 0
        ;;
        *)
        echo "Unknown option: $key"
        exit 1
        ;;
    esac
done

# Ensure log directory exists
LOG_DIR=$(dirname "$LOG_FILE")
if [ ! -d "$LOG_DIR" ]; then
    mkdir -p "$LOG_DIR"
fi

# Add timestamp to log entries
log_with_timestamp() {
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] $1" >> "$LOG_FILE"
}

# Run the sync check script
SYNC_STATUS=$("$SCRIPT_DIR/check-bitcoin-sync.sh" --host "$HOST" --port "$PORT" --user "$USER" --pass "$PASS" 2>&1)
EXIT_CODE=$?

# Extract just the last line which contains the status
STATUS_LINE=$(echo "$SYNC_STATUS" | tail -1)

# Log the status
log_with_timestamp "Bitcoin Sync Status: $STATUS_LINE"

# Check for errors
if [ $EXIT_CODE -eq 1 ]; then
    log_with_timestamp "ERROR: $SYNC_STATUS"
    
    # Send alert if configured
    if [ "$SEND_ALERTS" = "true" ]; then
        echo "Bitcoin Node Error: $SYNC_STATUS" | mail -s "ALERT: Bitcoin Node Error" "$ALERT_EMAIL"
    fi
    
    exit 1
fi

# Get the sync status
STATUS_TYPE=$(echo "$STATUS_LINE" | cut -d: -f1)
PROGRESS=$(echo "$STATUS_LINE" | cut -d: -f2)

# Capture the full status output
FULL_OUTPUT=$(echo "$SYNC_STATUS" | head -n -1)
log_with_timestamp "Details: $FULL_OUTPUT"

# Display status
if [ "$STATUS_TYPE" = "SYNCHRONIZED" ]; then
    log_with_timestamp "Node is fully synchronized at $PROGRESS"
else
    log_with_timestamp "Node is syncing: $PROGRESS complete"
fi

# Set up automatic monitoring using a cron job
setup_monitoring_cron() {
    local cron_cmd="0 * * * * $SCRIPT_DIR/monitor-bitcoin.sh --host $HOST --port $PORT --user $USER --pass $PASS --log $LOG_FILE"
    
    if [ "$SEND_ALERTS" = "true" ]; then
        cron_cmd="$cron_cmd --email $ALERT_EMAIL"
    fi
    
    # Add to crontab if not already there - run hourly instead of every 10 minutes to reduce CloudWatch costs
    if ! crontab -l | grep -q "monitor-bitcoin.sh"; then
        # Change from */10 to 0 to run once per hour
        cron_cmd=$(echo "$cron_cmd" | sed 's/\*\/10/0/g')
        (crontab -l 2>/dev/null; echo "$cron_cmd") | crontab -
        log_with_timestamp "Added monitoring to crontab (runs hourly to optimize CloudWatch costs)"
    fi
}

# Call setup_monitoring_cron only if requested
if [ "$1" = "--setup-cron" ]; then
    setup_monitoring_cron
fi

exit 0