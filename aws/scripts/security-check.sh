#!/bin/bash
# Security monitoring script for Counterparty ARM64
# Performs basic security checks and logs results

# Source common functions if available
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"

if [ -f "$REPO_DIR/scripts/common.sh" ]; then
    source "$REPO_DIR/scripts/common.sh"
else
    # Basic logging functions
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m' # No Color

    log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
    log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
    log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
    log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
fi

# Default values
LOG_FILE="/var/log/security-check.log"
SEND_EMAIL=false
EMAIL=""
CHECK_UPDATES=true
CHECK_DOCKER=true
CHECK_SSH=true
CHECK_PORTS=true
CHECK_BITCOIN=true
ALERT_THRESHOLD=7 # Days since last update

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        --log-file)
        LOG_FILE="$2"
        shift
        shift
        ;;
        --email)
        EMAIL="$2"
        SEND_EMAIL=true
        shift
        shift
        ;;
        --no-updates)
        CHECK_UPDATES=false
        shift
        ;;
        --no-docker)
        CHECK_DOCKER=false
        shift
        ;;
        --no-ssh)
        CHECK_SSH=false
        shift
        ;;
        --no-ports)
        CHECK_PORTS=false
        shift
        ;;
        --no-bitcoin)
        CHECK_BITCOIN=false
        shift
        ;;
        --alert-threshold)
        ALERT_THRESHOLD="$2"
        shift
        shift
        ;;
        --help)
        echo "Usage: security-check.sh [OPTIONS]"
        echo "Options:"
        echo "  --log-file FILE         Log file (default: /var/log/security-check.log)"
        echo "  --email EMAIL           Send report to this email address"
        echo "  --no-updates            Skip checking for updates"
        echo "  --no-docker             Skip Docker security checks"
        echo "  --no-ssh                Skip SSH configuration checks"
        echo "  --no-ports              Skip open ports scanning"
        echo "  --no-bitcoin            Skip Bitcoin security checks"
        echo "  --alert-threshold DAYS  Alert if system not updated in X days (default: 7)"
        echo "  --help                  Show this help message"
        exit 0
        ;;
        *)
        echo "Unknown option: $key"
        exit 1
        ;;
    esac
done

# Make sure only root can run this script
if [ "$(id -u)" != "0" ]; then
   log_error "This script must be run as root" 
   exit 1
fi

# Setup logging
LOG_DIR=$(dirname "$LOG_FILE")
if [ ! -d "$LOG_DIR" ]; then
    mkdir -p "$LOG_DIR"
fi

# Log with timestamp and append to log file
log_to_file() {
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] $1" | tee -a "$LOG_FILE"
}

# Reporting variables
WARNINGS=0
ISSUES=0
REPORT=""

append_report() {
    REPORT+="$1\n"
    log_to_file "$1"
}

log_to_file "Starting security check"
log_to_file "Options: Updates: $CHECK_UPDATES, Docker: $CHECK_DOCKER, SSH: $CHECK_SSH, Ports: $CHECK_PORTS, Bitcoin: $CHECK_BITCOIN"

# Get system information
HOSTNAME=$(hostname)
KERNEL=$(uname -r)
UBUNTU_VERSION=$(lsb_release -d | cut -d: -f2- | xargs)

append_report "Security Check Report for $HOSTNAME"
append_report "System: $UBUNTU_VERSION, Kernel: $KERNEL"
append_report "====================================="

# 1. Check for system updates
if [ "$CHECK_UPDATES" = "true" ]; then
    append_report "\n[SYSTEM UPDATES]"
    
    # Check when the last update was performed
    LAST_UPDATE=$(stat -c %Y /var/lib/apt/periodic/update-success-stamp 2>/dev/null || echo "0")
    CURRENT_TIME=$(date +%s)
    DAYS_SINCE_UPDATE=$(( (CURRENT_TIME - LAST_UPDATE) / 86400 ))
    
    if [ "$DAYS_SINCE_UPDATE" -gt "$ALERT_THRESHOLD" ]; then
        append_report "WARNING: System has not been updated in $DAYS_SINCE_UPDATE days"
        ((WARNINGS++))
    else
        append_report "System was last updated $DAYS_SINCE_UPDATE days ago"
    fi
    
    # Check for security updates
    apt-get update -qq > /dev/null
    SECURITY_UPDATES=$(apt-get upgrade -s | grep -c 'security')
    
    if [ "$SECURITY_UPDATES" -gt 0 ]; then
        append_report "WARNING: $SECURITY_UPDATES security updates are available"
        ((WARNINGS++))
    else
        append_report "No security updates available"
    fi
    
    # Check if a reboot is required
    if [ -f /var/run/reboot-required ]; then
        append_report "WARNING: System requires a reboot"
        ((WARNINGS++))
    else
        append_report "No reboot required"
    fi
fi

# 2. Docker security checks
if [ "$CHECK_DOCKER" = "true" ] && command -v docker &> /dev/null; then
    append_report "\n[DOCKER SECURITY]"
    
    # Check Docker version
    DOCKER_VERSION=$(docker --version | awk '{print $3}' | tr -d ,)
    append_report "Docker version: $DOCKER_VERSION"
    
    # Check for containers running as root
    ROOT_CONTAINERS=$(docker ps --format "{{.Names}}" --quiet)
    if [ -n "$ROOT_CONTAINERS" ]; then
        ROOT_COUNT=$(echo "$ROOT_CONTAINERS" | wc -l)
        append_report "INFO: $ROOT_COUNT containers running (this is normal for Counterparty/Bitcoin)"
    else
        append_report "No containers running"
    fi
    
    # Check Docker socket permissions
    DOCKER_SOCKET_PERMS=$(stat -c %a /var/run/docker.sock 2>/dev/null || echo "N/A")
    if [ "$DOCKER_SOCKET_PERMS" = "660" ] || [ "$DOCKER_SOCKET_PERMS" = "600" ]; then
        append_report "Docker socket has secure permissions: $DOCKER_SOCKET_PERMS"
    elif [ "$DOCKER_SOCKET_PERMS" != "N/A" ]; then
        append_report "WARNING: Docker socket has permissive permissions: $DOCKER_SOCKET_PERMS"
        ((WARNINGS++))
    fi
    
    # Check for exposed ports on containers
    EXPOSED_PORTS=$(docker ps --format "{{.Ports}}" | grep -E '0\.0\.0\.0|:::' | grep -v "127.0.0.1")
    if [ -n "$EXPOSED_PORTS" ]; then
        append_report "INFO: Exposed container ports (expected for Bitcoin/Counterparty):"
        append_report "$EXPOSED_PORTS"
    else
        append_report "No container ports exposed to public"
    fi
fi

# 3. SSH security checks
if [ "$CHECK_SSH" = "true" ]; then
    append_report "\n[SSH SECURITY]"
    
    # Check SSH config
    SSH_CONFIG="/etc/ssh/sshd_config"
    if [ -f "$SSH_CONFIG" ]; then
        # Check root login
        ROOT_LOGIN=$(grep -E "^PermitRootLogin" "$SSH_CONFIG" | awk '{print $2}')
        if [ "$ROOT_LOGIN" = "yes" ] || [ -z "$ROOT_LOGIN" ]; then
            append_report "WARNING: Root SSH login is permitted"
            ((WARNINGS++))
        else
            append_report "Root SSH login is disabled"
        fi
        
        # Check password authentication
        PASS_AUTH=$(grep -E "^PasswordAuthentication" "$SSH_CONFIG" | awk '{print $2}')
        if [ "$PASS_AUTH" = "yes" ] || [ -z "$PASS_AUTH" ]; then
            append_report "WARNING: SSH password authentication is enabled"
            ((WARNINGS++))
        else
            append_report "SSH password authentication is disabled"
        fi
        
        # Check protocol version
        SSH_PROTOCOL=$(grep -E "^Protocol" "$SSH_CONFIG" | awk '{print $2}')
        if [ "$SSH_PROTOCOL" = "1" ]; then
            append_report "WARNING: Insecure SSH protocol version 1 is in use"
            ((WARNINGS++))
        elif [ -z "$SSH_PROTOCOL" ] || [ "$SSH_PROTOCOL" = "2" ]; then
            append_report "SSH protocol version is secure (default 2)"
        else
            append_report "SSH protocol version: $SSH_PROTOCOL"
        fi
    else
        append_report "WARNING: SSH config file not found. SSH may not be properly configured."
        ((WARNINGS++))
    fi
    
    # Check for authorized keys
    AUTHORIZED_KEYS=$(find /home -name "authorized_keys" 2>/dev/null)
    if [ -n "$AUTHORIZED_KEYS" ]; then
        NUM_KEYS=$(echo "$AUTHORIZED_KEYS" | wc -l)
        append_report "Found $NUM_KEYS authorized_keys files"
    else
        append_report "WARNING: No authorized_keys files found. SSH key authentication may not be set up."
        ((WARNINGS++))
    fi
fi

# 4. Open ports scan
if [ "$CHECK_PORTS" = "true" ]; then
    append_report "\n[OPEN PORTS]"
    
    if command -v netstat &> /dev/null || command -v ss &> /dev/null; then
        # Use ss if available, netstat otherwise
        if command -v ss &> /dev/null; then
            LISTENING_PORTS=$(ss -tuln | grep LISTEN | grep -v "127.0.0.1" | grep -v "::1")
        else
            LISTENING_PORTS=$(netstat -tuln | grep LISTEN | grep -v "127.0.0.1" | grep -v "::1")
        fi
        
        if [ -n "$LISTENING_PORTS" ]; then
            append_report "Publicly accessible ports detected:"
            append_report "$LISTENING_PORTS"
            
            # Check for standard ports that should be exposed for Counterparty 
            BITCOIN_P2P=$(echo "$LISTENING_PORTS" | grep -E '(8333|18333|48333|18444)')
            COUNTERPARTY_API=$(echo "$LISTENING_PORTS" | grep -E '(4000|14000|24000|44000)')
            
            if [ -n "$BITCOIN_P2P" ]; then
                append_report "INFO: Bitcoin P2P ports detected (expected)"
            fi
            
            if [ -n "$COUNTERPARTY_API" ]; then
                append_report "INFO: Counterparty API ports detected (expected)"
            fi
        else
            append_report "No publicly accessible ports detected"
        fi
    else
        append_report "WARNING: netstat/ss not available, can't check open ports"
        ((WARNINGS++))
    fi
fi

# 5. Bitcoin security checks
if [ "$CHECK_BITCOIN" = "true" ]; then
    append_report "\n[BITCOIN SECURITY]"
    
    # Find Bitcoin config file in expected locations
    BITCOIN_CONF=""
    for conf_path in "/bitcoin-data/bitcoin/.bitcoin/bitcoin.conf" "/bitcoin/.bitcoin/bitcoin.conf" "/root/.bitcoin/bitcoin.conf" "/home/ubuntu/.bitcoin/bitcoin.conf"; do
        if [ -f "$conf_path" ]; then
            BITCOIN_CONF="$conf_path"
            break
        fi
    done
    
    if [ -n "$BITCOIN_CONF" ]; then
        append_report "Found Bitcoin config at $BITCOIN_CONF"
        
        # Check for RPC user/pass
        RPC_USER=$(grep -E "^rpcuser=" "$BITCOIN_CONF" | cut -d= -f2)
        if [ "$RPC_USER" = "rpc" ] || [ "$RPC_USER" = "bitcoin" ] || [ -z "$RPC_USER" ]; then
            append_report "WARNING: Bitcoin RPC uses default/weak username"
            ((WARNINGS++))
        else
            append_report "Bitcoin RPC uses custom username"
        fi
        
        # Check for rpcallowip settings
        RPC_ALLOW_IP=$(grep -E "^rpcallowip=" "$BITCOIN_CONF" | cut -d= -f2)
        if [ "$RPC_ALLOW_IP" = "0.0.0.0/0" ]; then
            append_report "WARNING: Bitcoin RPC allows connections from any IP"
            ((WARNINGS++))
        elif [ -z "$RPC_ALLOW_IP" ]; then
            append_report "No rpcallowip setting found, defaults apply"
        else
            append_report "Bitcoin RPC allows connections from: $RPC_ALLOW_IP"
        fi
        
        # Check for custom Bitcoin data directory
        DATADIR=$(grep -E "^datadir=" "$BITCOIN_CONF" | cut -d= -f2)
        if [ -n "$DATADIR" ]; then
            append_report "Bitcoin using custom data directory: $DATADIR"
        else
            append_report "Bitcoin using default data directory"
        fi
    else
        append_report "WARNING: Bitcoin config file not found in standard locations"
        ((WARNINGS++))
    fi
    
    # Check if Bitcoin directory is protected
    BITCOIN_DIR="/bitcoin-data/bitcoin/.bitcoin"
    if [ -d "$BITCOIN_DIR" ]; then
        BITCOIN_PERMS=$(stat -c %a "$BITCOIN_DIR" 2>/dev/null || echo "N/A")
        if [ "$BITCOIN_PERMS" = "700" ] || [ "$BITCOIN_PERMS" = "750" ]; then
            append_report "Bitcoin directory has secure permissions: $BITCOIN_PERMS"
        else
            append_report "WARNING: Bitcoin directory has permissive permissions: $BITCOIN_PERMS"
            ((WARNINGS++))
        fi
    fi
fi

# Summary
append_report "\n[SUMMARY]"
append_report "Security check completed with $WARNINGS warnings"

if [ "$WARNINGS" -gt 0 ]; then
    append_report "Please review the warnings and take appropriate action"
else
    append_report "No security issues detected"
fi

# Send email report if requested
if [ "$SEND_EMAIL" = "true" ] && [ -n "$EMAIL" ]; then
    log_to_file "Sending security report to $EMAIL"
    
    if command -v mail &> /dev/null; then
        echo -e "$REPORT" | mail -s "Security Check Report for $HOSTNAME" "$EMAIL"
        log_to_file "Email sent to $EMAIL"
    else
        log_to_file "WARNING: 'mail' command not available. Could not send email."
    fi
fi

log_to_file "Security check completed"

# Output summary to console
if [ "$WARNINGS" -gt 0 ]; then
    log_warning "Security check completed with $WARNINGS warnings. See $LOG_FILE for details."
else
    log_success "Security check completed. No issues found."
fi

exit 0