#!/bin/bash
# upload-blocks-bootstrap.sh - Upload blocks directory to S3 as a blocks-only bootstrap
# This script uploads extracted Bitcoin blockchain blocks to S3 for use with the blocks-only bootstrap method

# Set defaults
SOURCE_DIR=${1:-"/bitcoin-data/bitcoin/blocks"}
S3_BUCKET=${2:-"bitcoin-blockchain-snapshots"}
S3_PREFIX=${3:-"uncompressed/blocks-only-bootstrap"}
USE_AUTH=${4:-"true"}  # Use AWS credentials for authentication

# Source common functions if available
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${SCRIPT_DIR}/common.sh" ]; then
    source "${SCRIPT_DIR}/common.sh"
fi

# Define log functions if not already defined by common.sh
if ! type log_info > /dev/null 2>&1; then
    log_info() { echo "[INFO] $1"; }
    log_warning() { echo "[WARNING] $1"; }
    log_error() { echo "[ERROR] $1"; }
    log_success() { echo "[SUCCESS] $1"; }
fi

# Check if source directory exists
if [ ! -d "$SOURCE_DIR" ]; then
    log_error "Source directory $SOURCE_DIR does not exist!"
    exit 1
fi

# Check AWS CLI is installed
if ! command -v aws &> /dev/null; then
    log_error "AWS CLI is not installed. Please install it first."
    exit 1
fi

# Calculate block files count
BLOCKS_COUNT=$(find "$SOURCE_DIR" -type f -name "blk*.dat" | wc -l)
log_info "Found $BLOCKS_COUNT block files in $SOURCE_DIR"

# Create bootstrap_type.txt marker file
log_info "Creating bootstrap_type.txt marker file..."
echo "blocks-only" > "${SOURCE_DIR}/bootstrap_type.txt"

# Create metadata file with information about this upload
log_info "Creating metadata file..."
mkdir -p "${SOURCE_DIR}/metadata"
cat > "${SOURCE_DIR}/metadata/bootstrap_info.json" << METAEOF
{
  "created_date": "$(date -u +%Y-%m-%d)",
  "created_time": "$(date -u +%H:%M:%S)",
  "type": "blocks-only",
  "blocks_count": $BLOCKS_COUNT,
  "size_gb": "$(du -sh "$SOURCE_DIR" | cut -f1)",
  "first_block": "$(find "$SOURCE_DIR" -name "blk*.dat" | sort | head -1 | xargs basename)",
  "last_block": "$(find "$SOURCE_DIR" -name "blk*.dat" | sort | tail -1 | xargs basename)",
  "notes": "Contains only block data. Chainstate will be rebuilt during sync."
}
METAEOF

# Create Bitcoin config templates optimized for rebuilding UTXO set on various instance types
mkdir -p "${SOURCE_DIR}/config-templates"

# Config for c6g.large (compute optimized)
cat > "${SOURCE_DIR}/config-templates/bitcoin.conf.c6g.large" << CONFIG
# Bitcoin Core configuration - Optimized for blocks-only bootstrap (UTXO reconstruction)
# Configured for c6g.large instance type (2 vCPU, 4GB RAM, compute optimized)

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

# Enhanced Performance for Chainstate Rebuild on c6g.large
dbcache=3500
maxmempool=300
maxconnections=12
blocksonly=1
mempoolfullrbf=1
assumevalid=000000000000000000053b17c1c2e1ea8a965a6240ede8ffd0729f7f2e77283e
par=24

# ZMQ Settings
zmqpubrawtx=tcp://0.0.0.0:9332
zmqpubhashtx=tcp://0.0.0.0:9332
zmqpubsequence=tcp://0.0.0.0:9332
zmqpubrawblock=tcp://0.0.0.0:9333
CONFIG

# Config for t4g.large (burstable)
cat > "${SOURCE_DIR}/config-templates/bitcoin.conf.t4g.large" << CONFIG
# Bitcoin Core configuration - Optimized for blocks-only bootstrap (UTXO reconstruction)
# Configured for t4g.large instance type (2 vCPU, 8GB RAM, burstable)

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

# Enhanced Performance for Chainstate Rebuild on t4g.large
dbcache=6500
maxmempool=500
maxconnections=12
blocksonly=1
mempoolfullrbf=1
assumevalid=000000000000000000053b17c1c2e1ea8a965a6240ede8ffd0729f7f2e77283e
par=16

# ZMQ Settings
zmqpubrawtx=tcp://0.0.0.0:9332
zmqpubhashtx=tcp://0.0.0.0:9332
zmqpubsequence=tcp://0.0.0.0:9332
zmqpubrawblock=tcp://0.0.0.0:9333
CONFIG

# Default config (symlink to c6g.large)
cat > "${SOURCE_DIR}/config-templates/bitcoin.conf.blocks-only" << CONFIG
# Bitcoin Core configuration - Optimized for blocks-only bootstrap (UTXO reconstruction)
# Default configuration - Optimized for c6g.large instance

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

# Enhanced Performance for Chainstate Rebuild (c6g.large optimized)
dbcache=3500
maxmempool=300
maxconnections=12
blocksonly=1
mempoolfullrbf=1
assumevalid=000000000000000000053b17c1c2e1ea8a965a6240ede8ffd0729f7f2e77283e
par=24

# ZMQ Settings
zmqpubrawtx=tcp://0.0.0.0:9332
zmqpubhashtx=tcp://0.0.0.0:9332
zmqpubsequence=tcp://0.0.0.0:9332
zmqpubrawblock=tcp://0.0.0.0:9333
CONFIG

# Configure AWS CLI for faster uploads
log_info "Configuring AWS CLI for optimal upload performance..."
mkdir -p ~/.aws
cat > ~/.aws/config << 'EOC'
[default]
s3 =
    max_concurrent_requests = 100
    max_queue_size = 10000
    multipart_threshold = 64MB
    multipart_chunksize = 64MB
EOC

# Determine if we should use authentication
USE_AUTH_FLAG=""
if [ "$USE_AUTH" != "true" ]; then
    log_info "Using anonymous access for S3 sync (--no-sign-request)"
    USE_AUTH_FLAG="--no-sign-request"
else
    log_info "Using AWS credentials for S3 sync"
fi

# Get total size for reporting
TOTAL_SIZE=$(du -sh "$SOURCE_DIR" | awk '{print $1}')
log_info "Total size to upload: $TOTAL_SIZE"

# Upload metadata first for visibility
log_info "Uploading metadata..."
aws s3 sync "${SOURCE_DIR}/metadata/" "s3://${S3_BUCKET}/${S3_PREFIX}/metadata/" $USE_AUTH_FLAG --only-show-errors

# Upload bootstrap_type.txt marker
log_info "Uploading bootstrap_type.txt marker..."
aws s3 cp "${SOURCE_DIR}/bootstrap_type.txt" "s3://${S3_BUCKET}/${S3_PREFIX}/bootstrap_type.txt" $USE_AUTH_FLAG --only-show-errors

# Upload config templates
log_info "Uploading config templates..."
aws s3 sync "${SOURCE_DIR}/config-templates/" "s3://${S3_BUCKET}/${S3_PREFIX}/config-templates/" $USE_AUTH_FLAG --only-show-errors

# Main upload of block files
log_info "Starting upload of block files to s3://${S3_BUCKET}/${S3_PREFIX}/blocks/"
log_info "This may take several hours depending on your upload bandwidth..."
log_info "Started at: $(date)"

# Use sync command for uploading
aws s3 sync "$SOURCE_DIR" "s3://${S3_BUCKET}/${S3_PREFIX}/blocks/" $USE_AUTH_FLAG \
    --exclude "*" --include "blk*.dat" --include "rev*.dat" \
    --only-show-errors

# Check result of upload
UPLOAD_RESULT=$?
if [ $UPLOAD_RESULT -eq 0 ]; then
    log_success "Upload completed successfully at $(date)"
    
    # Set metadata for better searchability
    aws s3api put-object-tagging --bucket "$S3_BUCKET" --key "${S3_PREFIX}/bootstrap_type.txt" \
        --tagging 'TagSet=[{Key=type,Value=blocks-only}]' $USE_AUTH_FLAG
    
    log_info "S3 location: s3://${S3_BUCKET}/${S3_PREFIX}/"
    log_info "To use this bootstrap with the Counterparty ARM64 stack:"
    log_info "1. Update the BitcoinSnapshotPath parameter in CloudFormation to:"
    log_info "   s3://${S3_BUCKET}/${S3_PREFIX}"
    log_info "2. The bootstrap.sh script will automatically detect this is a blocks-only bootstrap"
    log_info "3. Bitcoin Core will rebuild the UTXO set (chainstate) during initial sync"
else
    log_error "Upload failed with exit code $UPLOAD_RESULT"
    log_error "Please check for errors and try again."
fi

# Cleanup temporary files
log_info "Cleaning up temporary files..."
rm -f "${SOURCE_DIR}/bootstrap_type.txt"
rm -rf "${SOURCE_DIR}/metadata"
rm -rf "${SOURCE_DIR}/config-templates"

log_info "Process completed at $(date)"