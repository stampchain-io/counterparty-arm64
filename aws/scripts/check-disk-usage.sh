#!/bin/bash
# Script to monitor disk usage of the data volume

# Source common functions if available in the repo
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"

if [ -f "$REPO_DIR/scripts/common.sh" ]; then
    source "$REPO_DIR/scripts/common.sh"
# Otherwise use basic functions
else
    # Colors for output
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m' # No Color

    # Log functions
    log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
    log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
    log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
    log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
fi

# Configuration
THRESHOLD=80  # Alert threshold percentage
DATA_DIR=${COUNTERPARTY_DOCKER_DATA:-/bitcoin-data}
LOG_FILE="$DATA_DIR/disk_usage.log"
SNS_TOPIC_ARN=${SNS_TOPIC_ARN:-""}  # Optional SNS topic for notifications

# Ensure log directory exists
mkdir -p $(dirname "$LOG_FILE")

# Get current disk usage
USAGE=$(df -h "$DATA_DIR" | awk 'NR==2 {print $5}' | tr -d '%')

# Log the disk usage
echo "$(date): Disk usage: $USAGE%" >> "$LOG_FILE"

# Check if usage is above threshold
if [ "$USAGE" -gt "$THRESHOLD" ]; then
    MESSAGE="ALERT: Disk usage for $DATA_DIR is at $USAGE% (threshold: $THRESHOLD%)"
    log_warning "$MESSAGE"
    
    # Send SNS notification if configured
    if [ -n "$SNS_TOPIC_ARN" ] && command -v aws &> /dev/null; then
        log_info "Sending SNS notification..."
        
        # Get instance metadata for the message
        INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
        AVAILABILITY_ZONE=$(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone)
        REGION=${AVAILABILITY_ZONE%?}  # Remove last character to get region
        
        # Compose detailed message
        DETAILED_MESSAGE="Disk Usage Alert\n\nInstance: $INSTANCE_ID\nRegion: $REGION\nDirectory: $DATA_DIR\nUsage: $USAGE%\nThreshold: $THRESHOLD%\nTimestamp: $(date)"
        
        # Send the notification
        aws sns publish \
            --region "$REGION" \
            --topic-arn "$SNS_TOPIC_ARN" \
            --subject "Disk Usage Alert - $INSTANCE_ID" \
            --message "$DETAILED_MESSAGE"
            
        log_info "SNS notification sent."
    fi
else
    log_info "Disk usage is at $USAGE% (threshold: $THRESHOLD%)"
fi