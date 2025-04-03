#!/bin/bash
# Script to create EBS snapshots of the data volume

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

# Check if AWS CLI is installed
if ! command -v aws &> /dev/null; then
    log_error "AWS CLI not found. Please install it and try again."
    exit 1
fi

# Initialize variables
KEEP_SNAPSHOTS=7  # Number of snapshots to keep

# Get instance metadata
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
AVAILABILITY_ZONE=$(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone)
REGION=${AVAILABILITY_ZONE%?}  # Remove last character to get region

# Find the ST1 volume attached to /bitcoin-data
log_info "Finding the data volume..."
VOLUME_ID=$(aws ec2 describe-volumes \
  --region $REGION \
  --filters "Name=attachment.instance-id,Values=$INSTANCE_ID" \
            "Name=volume-type,Values=st1" \
  --query "Volumes[0].VolumeId" \
  --output text)

if [ "$VOLUME_ID" = "None" ] || [ -z "$VOLUME_ID" ]; then
    log_error "No ST1 volume found attached to this instance."
    
    # Try to find any volume
    VOLUME_ID=$(aws ec2 describe-volumes \
      --region $REGION \
      --filters "Name=attachment.instance-id,Values=$INSTANCE_ID" \
                "Name=attachment.device,Values=/dev/sdf,/dev/xvdf,/dev/nvme1n1" \
      --query "Volumes[0].VolumeId" \
      --output text)
    
    if [ "$VOLUME_ID" = "None" ] || [ -z "$VOLUME_ID" ]; then
        log_error "No suitable volume found. Exiting."
        exit 1
    else
        log_warning "Using volume $VOLUME_ID (not ST1 type)"
    fi
else
    log_info "Found ST1 volume: $VOLUME_ID"
fi

# Create timestamp for snapshot description
TIMESTAMP=$(date +%Y-%m-%d-%H%M)
DESCRIPTION="Bitcoin and Counterparty data volume backup $TIMESTAMP"

# Create the snapshot
log_info "Creating snapshot of volume $VOLUME_ID..."
SNAPSHOT_ID=$(aws ec2 create-snapshot \
  --region $REGION \
  --volume-id $VOLUME_ID \
  --description "$DESCRIPTION" \
  --tag-specifications "ResourceType=snapshot,Tags=[{Key=Name,Value=bitcoin-data-$TIMESTAMP},{Key=AutoDelete,Value=true}]" \
  --query SnapshotId --output text)

log_success "Created snapshot $SNAPSHOT_ID from volume $VOLUME_ID"

# List snapshots to delete (keep the last N snapshots)
log_info "Cleaning up old snapshots (keeping the last $KEEP_SNAPSHOTS)..."
SNAPSHOTS_TO_DELETE=$(aws ec2 describe-snapshots \
  --region $REGION \
  --filters "Name=volume-id,Values=$VOLUME_ID" "Name=tag:AutoDelete,Values=true" \
  --query "Snapshots[?StartTime]" \
  --output text | sort -k 4 | head -n -$KEEP_SNAPSHOTS | cut -f 3)

# Delete old snapshots
for SNAPSHOT in $SNAPSHOTS_TO_DELETE; do
    log_info "Deleting snapshot $SNAPSHOT..."
    aws ec2 delete-snapshot --region $REGION --snapshot-id $SNAPSHOT
done

log_success "Snapshot maintenance complete."