#!/bin/bash
# Script to monitor ST1 volume usage in Counterparty deployment
# Especially useful when multiple Bitcoin networks are enabled

# Usage: ./monitor-st1-volume.sh [server-ip] [user] [ssh-key]
# Example: ./monitor-st1-volume.sh ec2-12-34-56-78.compute-1.amazonaws.com ubuntu ~/.ssh/id_rsa

# Default values
SERVER_IP=$1
SSH_USER=${2:-ubuntu}
SSH_KEY=${3:-~/.ssh/id_rsa}

if [ -z "$SERVER_IP" ]; then
    # Try to get the server IP from stack outputs
    SERVER_IP=$(aws cloudformation describe-stacks --stack-name counterparty-server-6 \
        --query "Stacks[0].Outputs[?OutputKey=='PublicDns'].OutputValue" --output text)
    
    if [ -z "$SERVER_IP" ] || [ "$SERVER_IP" == "None" ]; then
        echo "Error: Server IP/hostname not provided and couldn't be retrieved from stack outputs."
        echo "Usage: $0 [server-ip] [user] [ssh-key]"
        exit 1
    fi
fi

# Color definitions
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Function to display information with color
info() { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check if the server is reachable
info "Checking if server $SERVER_IP is reachable..."
if ! ping -c 1 -W 2 $SERVER_IP &> /dev/null; then
    error "Server $SERVER_IP is not reachable."
    
    # Check CloudFormation stack status
    info "Checking CloudFormation stack status..."
    STACK_STATUS=$(aws cloudformation describe-stacks --stack-name counterparty-server-6 \
        --query "Stacks[0].StackStatus" --output text 2>/dev/null)
    
    if [ -n "$STACK_STATUS" ]; then
        info "Stack status: $STACK_STATUS"
        
        if [ "$STACK_STATUS" == "CREATE_IN_PROGRESS" ]; then
            info "Stack creation is still in progress. Please wait..."
        elif [ "$STACK_STATUS" == "CREATE_COMPLETE" ]; then
            info "Stack creation is complete but server might still be initializing."
            info "You can check CloudFormation events for more details."
        else
            warning "Stack status indicates there might be an issue."
        fi
    else
        error "Could not retrieve stack status."
    fi
    
    exit 1
fi

info "Server $SERVER_IP is reachable. Checking SSH connectivity..."

# Test SSH connectivity
if ! ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" echo "SSH connection successful" &> /dev/null; then
    error "SSH connection failed. Check your SSH key and permissions."
    exit 1
fi

success "SSH connection successful."

# Monitor ST1 volume usage
info "Checking ST1 volume usage..."
SSH_CMD="ssh -o StrictHostKeyChecking=no -i \"$SSH_KEY\" \"$SSH_USER@$SERVER_IP\""

# Get disk usage
echo "========== DISK USAGE =========="
eval "$SSH_CMD 'df -h | grep /bitcoin-data'"
echo

# Check Bitcoin directory size
echo "========== BITCOIN DIRECTORY SIZE =========="
eval "$SSH_CMD 'du -sh /bitcoin-data/bitcoin/.bitcoin 2>/dev/null || echo \"Bitcoin directory not found\"'"
echo

# Check which networks are active
echo "========== ACTIVE CONTAINERS =========="
eval "$SSH_CMD 'docker ps --format \"table {{.Names}}\t{{.Status}}\"'"
echo

# Check Docker volume usage
echo "========== DOCKER VOLUME USAGE =========="
eval "$SSH_CMD 'docker system df -v | grep -A 20 \"VOLUME NAME\"'"
echo

# Run the disk analysis tool if available
echo "========== DISK ANALYSIS =========="
eval "$SSH_CMD 'if [ -x /usr/local/bin/disk-usage-analysis.sh ]; then sudo /usr/local/bin/disk-usage-analysis.sh && cat /tmp/disk-usage-analysis.txt; else echo \"Disk analysis tool not available\"; fi'"
echo

# Provide recommendations based on usage
echo "========== RECOMMENDATIONS =========="

# Get ST1 usage percentage
ST1_USAGE=$(eval "$SSH_CMD 'df -h | grep /bitcoin-data'" | awk '{print $5}' | tr -d '%')

if [ -n "$ST1_USAGE" ]; then
    if [ "$ST1_USAGE" -gt 85 ]; then
        warning "ST1 volume usage is very high at $ST1_USAGE%"
        echo "Recommendations:"
        echo "1. Consider increasing DATA_VOLUME_SIZE in your deployment"
        echo "2. If running multiple Bitcoin networks, consider disabling networks you don't need"
        echo "3. Use pruning mode for Bitcoin if full history is not required"
    elif [ "$ST1_USAGE" -gt 70 ]; then
        warning "ST1 volume usage is getting high at $ST1_USAGE%"
        echo "Recommendations:"
        echo "1. Monitor usage closely"
        echo "2. Consider cleanup of old blockchain data if possible"
    else
        success "ST1 volume usage is at a healthy $ST1_USAGE%"
    fi
else
    warning "Could not determine ST1 volume usage"
fi

# Final status
success "Monitoring completed successfully."
echo "To SSH into this server:"
echo "ssh -i $SSH_KEY $SSH_USER@$SERVER_IP"