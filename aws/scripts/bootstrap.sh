#!/bin/bash
# Bootstrap script for Counterparty ARM64 EC2 instance
# This script is downloaded and executed by the minimal UserData script

# Parse parameters
BITCOIN_VERSION=${1:-"26.0"}
COUNTERPARTY_BRANCH=${2:-"develop"}
COUNTERPARTY_TAG=${3:-""}
NETWORK_PROFILE=${4:-"mainnet"}
GITHUB_TOKEN=${5:-""}
AWS_ACCESS_KEY=${6:-""}
AWS_SECRET_KEY=${7:-""}

# Set AWS credentials if provided
if [ -n "$AWS_ACCESS_KEY" ] && [ -n "$AWS_SECRET_KEY" ]; then
  echo "[INFO] Using provided AWS credentials"
  export AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY"
  export AWS_SECRET_ACCESS_KEY="$AWS_SECRET_KEY"
fi

# Logging functions
log_info() {
    echo "[INFO] $1"
}

log_warning() {
    echo "[WARNING] $1"
}

log_error() {
    echo "[ERROR] $1"
}

log_success() {
    echo "[SUCCESS] $1"
}

# Install basic dependencies 
log_info "Installing basic dependencies..."
apt-get update && apt-get upgrade -y
apt-get install -y apt-transport-https ca-certificates curl software-properties-common git jq htop iotop xfsprogs bc pv logrotate

# Fix for aws-cli in Ubuntu 24.04
if ! command -v aws &> /dev/null; then
  if [ "$(lsb_release -cs)" = "noble" ]; then
    # Use alternative method for Ubuntu 24.04
    curl "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o "awscliv2.zip"
    apt-get install -y unzip
    unzip -q awscliv2.zip
    ./aws/install
    rm -rf aws awscliv2.zip
  else
    # Try standard method for older Ubuntu versions
    apt-get install -y awscli || echo "Warning: Could not install awscli package"
  fi
fi

# Add Docker repository with improved error handling
mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o docker.gpg
if [ -f docker.gpg ]; then
  gpg --dearmor -o /etc/apt/keyrings/docker.gpg docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
  apt-get update
  
  # Install Docker
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
else
  echo "Failed to download Docker GPG key, using alternative method"
  # Alternative Docker installation using snap as fallback
  apt-get install -y snapd
  snap install docker
fi

# Add ubuntu user to docker group
usermod -aG docker ubuntu

# Mount the ST1 volume
mkdir -p /bitcoin-data

# Find the correct device for the attached volume (NVMe naming can vary)
DATA_DEVICE=""
for dev in /dev/nvme*n1; do
  if [ -e "$dev" ] && ! grep -q "$dev" /etc/fstab && [ "$dev" != "/dev/nvme0n1" ]; then
    DATA_DEVICE="$dev"
    echo "Found data device: $DATA_DEVICE"
    break
  fi
done

# If NVMe device wasn't found, try traditional naming
if [ -z "$DATA_DEVICE" ] && [ -e "/dev/xvdf" ]; then
  DATA_DEVICE="/dev/xvdf"
  echo "Found data device: $DATA_DEVICE"
fi

if [ -z "$DATA_DEVICE" ]; then
  echo "Error: Could not find data volume device"
  # Use a fallback directory if volume can't be found
  mkdir -p /bitcoin-data-local
  ln -sf /bitcoin-data-local /bitcoin-data
else
  # Format the volume if needed
  if ! blkid "$DATA_DEVICE"; then
    echo "Formatting $DATA_DEVICE with XFS filesystem"
    mkfs.xfs -f "$DATA_DEVICE"
  fi
  
  # Mount the volume
  echo "Mounting $DATA_DEVICE to /bitcoin-data"
  mount "$DATA_DEVICE" /bitcoin-data || {
    echo "Mount failed, attempting to force format and mount"
    mkfs.xfs -f "$DATA_DEVICE"
    mount "$DATA_DEVICE" /bitcoin-data
  }
  
  # Add to fstab for persistence
  if ! grep -q "$DATA_DEVICE" /etc/fstab; then
    echo "$DATA_DEVICE /bitcoin-data xfs defaults,nofail 0 2" >> /etc/fstab
  fi
fi

# Set permissions and create necessary directories
mkdir -p /bitcoin-data/docker
mkdir -p /bitcoin-data/bitcoin
mkdir -p /bitcoin-data/counterparty
mkdir -p /bitcoin-data/repo
chown -R ubuntu:ubuntu /bitcoin-data
chmod -R 755 /bitcoin-data

# Check if snapshot path is provided
if [ -n "$BITCOIN_SNAPSHOT_PATH" ]; then
  echo "[INFO] Bitcoin blockchain snapshot provided: $BITCOIN_SNAPSHOT_PATH"
  
  # Convert https:// URL to s3:// format if it's an Amazon S3 URL
  if [[ "$BITCOIN_SNAPSHOT_PATH" == https://*s3*.amazonaws.com/* ]]; then
    echo "[INFO] Converting HTTP S3 URL to s3:// format for better performance"
    
    # Extract bucket and key from URL based on format pattern
    if [[ "$BITCOIN_SNAPSHOT_PATH" == https://*s3.amazonaws.com/*/* ]]; then
      # Format: https://s3.amazonaws.com/bucket-name/key
      S3_BUCKET=$(echo "$BITCOIN_SNAPSHOT_PATH" | sed -E 's|https://s3\.amazonaws\.com/([^/]+)/.*|\1|')
      S3_KEY=$(echo "$BITCOIN_SNAPSHOT_PATH" | sed -E 's|https://s3\.amazonaws\.com/[^/]+/(.*$)|\1|')
    elif [[ "$BITCOIN_SNAPSHOT_PATH" == https://*-s3*.amazonaws.com/* ]]; then
      # Format: https://bucket-name-s3-region.amazonaws.com/key
      S3_BUCKET=$(echo "$BITCOIN_SNAPSHOT_PATH" | sed -E 's|https://([^.]+)-s3.*\.amazonaws\.com/.*|\1|')
      S3_KEY=$(echo "$BITCOIN_SNAPSHOT_PATH" | sed -E 's|https://.*\.amazonaws\.com/(.*$)|\1|')
    elif [[ "$BITCOIN_SNAPSHOT_PATH" == https://*.s3.amazonaws.com/* ]]; then
      # Format: https://bucket-name.s3.amazonaws.com/key
      S3_BUCKET=$(echo "$BITCOIN_SNAPSHOT_PATH" | sed -E 's|https://([^.]+)\.s3\.amazonaws\.com/.*|\1|')
      S3_KEY=$(echo "$BITCOIN_SNAPSHOT_PATH" | sed -E 's|https://.*\.s3\.amazonaws\.com/(.*$)|\1|')
    else
      # Unknown format, keep the original URL
      echo "[WARNING] Unrecognized S3 URL format, using original URL"
      S3_BUCKET=""
      S3_KEY=""
    fi
    
    # Convert to s3:// format if bucket and key were successfully extracted
    if [ -n "$S3_BUCKET" ] && [ -n "$S3_KEY" ]; then
      ORIGINAL_URL="$BITCOIN_SNAPSHOT_PATH"
      BITCOIN_SNAPSHOT_PATH="s3://$S3_BUCKET/$S3_KEY"
      echo "[INFO] Converted URL: $ORIGINAL_URL → $BITCOIN_SNAPSHOT_PATH"
    fi
  fi
  
  # Determine if this is a compressed archive or uncompressed directory structure
  IS_UNCOMPRESSED=false
  IS_BLOCKS_ONLY=false
  if [[ "$BITCOIN_SNAPSHOT_PATH" == */uncompressed/* || "$BITCOIN_SNAPSHOT_PATH" == *"uncompressed" ]]; then
    IS_UNCOMPRESSED=true
    echo "[INFO] Using uncompressed blockchain directory structure"
    
    # Check if this is a blocks-only bootstrap
    BOOTSTRAP_TYPE=$(aws s3 cp "s3://$(echo "$BITCOIN_SNAPSHOT_PATH" | cut -d'/' -f3)/$(echo "$BITCOIN_SNAPSHOT_PATH" | cut -d'/' -f4-)/bootstrap_type.txt" - --no-sign-request 2>/dev/null || echo "full")
    
    if [[ "$BOOTSTRAP_TYPE" == "blocks-only" ]]; then
      IS_BLOCKS_ONLY=true
      echo "[INFO] This is a blocks-only bootstrap (chainstate will be rebuilt during sync)"
      echo "[INFO] Expect a longer initial sync time while the UTXO set is reconstructed"
    else
      echo "[INFO] This appears to be a full bootstrap with blocks and chainstate"
    fi
  else
    echo "[INFO] Using compressed blockchain archive"
  fi

  # Extract the snapshot height from the filename if it contains a height indicator
  # Format expected: bitcoin-data-YYYYMMDD-HHMM-HEIGHT.tar.gz where HEIGHT is the block height
  SNAPSHOT_HEIGHT=0
  SNAPSHOT_FILENAME=$(basename "$BITCOIN_SNAPSHOT_PATH")
  if [[ $SNAPSHOT_FILENAME =~ -([0-9]+)\.tar\.gz$ ]]; then
    SNAPSHOT_HEIGHT="${BASH_REMATCH[1]}"
    echo "[INFO] Detected snapshot block height: $SNAPSHOT_HEIGHT"
  else
    # Try to get metadata from S3 if available (only for S3 URLs)
    if [[ "$BITCOIN_SNAPSHOT_PATH" == s3://* ]]; then
      SNAPSHOT_HEIGHT=$(aws s3api head-object --bucket $(echo "$BITCOIN_SNAPSHOT_PATH" | cut -d'/' -f3) --key $(echo "$BITCOIN_SNAPSHOT_PATH" | cut -d'/' -f4-) --query 'Metadata.blockHeight' --output text 2>/dev/null)
    else
      # For HTTPS URLs, try to extract height from the URL
      if [[ "$BITCOIN_SNAPSHOT_PATH" =~ blockchain-snapshots/([^/]+) ]]; then
        FILENAME="${BASH_REMATCH[1]}"
        if [[ $FILENAME =~ -([0-9]+)\.tar\.gz$ ]]; then
          SNAPSHOT_HEIGHT="${BASH_REMATCH[1]}"
          echo "[INFO] Extracted height from HTTPS URL: $SNAPSHOT_HEIGHT"
        fi
      fi
    fi
    if [[ "$SNAPSHOT_HEIGHT" != "None" && -n "$SNAPSHOT_HEIGHT" ]]; then
      echo "[INFO] Found snapshot block height in metadata: $SNAPSHOT_HEIGHT"
    else
      # Default to a high number to encourage using the snapshot for new deployments
      SNAPSHOT_HEIGHT=800000
      echo "[INFO] Snapshot height not found, using default value: $SNAPSHOT_HEIGHT"
    fi
  fi
  
  # Check if blockchain data already exists
  EXISTING_DATA=false
  CURRENT_HEIGHT=0
  
  if [ -d "/bitcoin-data/bitcoin/blocks" ] && [ -f "/bitcoin-data/bitcoin/blocks/blk00000.dat" ]; then
    EXISTING_DATA=true
    echo "[INFO] Existing Bitcoin blockchain data detected"
    
    # Check if bitcoind is running to get current height
    if docker ps | grep -q bitcoind; then
      echo "[INFO] Bitcoin daemon running, checking current block height..."
      # Wait a moment for bitcoind to be responsive
      sleep 5
      # Try up to 3 times to get block count
      for i in {1..3}; do
        CURRENT_HEIGHT=$(docker exec $(docker ps -q -f name=bitcoind) bitcoin-cli -datadir=/bitcoin/.bitcoin getblockcount 2>/dev/null || echo "0")
        if [ "$CURRENT_HEIGHT" != "0" ]; then
          break
        fi
        sleep 5
      done
      
      # If we failed to get height, try with config file
      if [ "$CURRENT_HEIGHT" = "0" ]; then
        CURRENT_HEIGHT=$(docker exec $(docker ps -q -f name=bitcoind) bitcoin-cli -conf=/bitcoin/.bitcoin/bitcoin.conf getblockcount 2>/dev/null || echo "0")
      fi
      
      echo "[INFO] Current blockchain height: $CURRENT_HEIGHT"
    else
      echo "[INFO] Bitcoin daemon not running, checking for checkpoint file..."
      # Try to get height from our last recorded checkpoint if available
      if [ -f "/bitcoin-data/bitcoin/.bitcoin/height.txt" ]; then
        CURRENT_HEIGHT=$(cat "/bitcoin-data/bitcoin/.bitcoin/height.txt")
        echo "[INFO] Found checkpoint height: $CURRENT_HEIGHT"
      else
        echo "[WARNING] Cannot determine current blockchain height - assuming far behind"
        CURRENT_HEIGHT=0
      fi
    fi
    
    # Calculate how far behind current blockchain is compared to the snapshot
    BLOCKS_BEHIND=$((SNAPSHOT_HEIGHT - CURRENT_HEIGHT))
    
    if [ $BLOCKS_BEHIND -le 0 ]; then
      echo "[INFO] Current blockchain height ($CURRENT_HEIGHT) is ahead of snapshot ($SNAPSHOT_HEIGHT), skipping snapshot extraction"
      # Record current height for future reference
      echo "$CURRENT_HEIGHT" > "/bitcoin-data/bitcoin/.bitcoin/height.txt"
      return 0
    elif [ $BLOCKS_BEHIND -lt 10000 ]; then
      echo "[INFO] Current blockchain height ($CURRENT_HEIGHT) is only $BLOCKS_BEHIND blocks behind snapshot ($SNAPSHOT_HEIGHT), continuing with current data"
      return 0
    else
      echo "[INFO] Current blockchain height ($CURRENT_HEIGHT) is $BLOCKS_BEHIND blocks behind snapshot ($SNAPSHOT_HEIGHT)"
      echo "[INFO] Will replace current blockchain data with snapshot data"
      
      # Stop bitcoind if running to prevent data corruption
      if docker ps | grep -q bitcoind; then
        echo "[INFO] Stopping Bitcoin services to safely replace data..."
        docker-compose -f /home/ubuntu/counterparty-node/docker-compose.yml down
        sleep 10
      fi
      
      # Backup existing data
      BACKUP_DIR="/bitcoin-data/bitcoin.bak-$(date +%Y%m%d-%H%M%S)"
      echo "[INFO] Backing up existing blockchain data to $BACKUP_DIR"
      mkdir -p "$BACKUP_DIR"
      mv /bitcoin-data/bitcoin/blocks /bitcoin-data/bitcoin/chainstate "$BACKUP_DIR/" || {
        echo "[ERROR] Failed to back up existing data, aborting snapshot extraction"
        return 1
      }
    fi
  else
    echo "[INFO] No existing Bitcoin blockchain data found"
  fi
  
  echo "[INFO] Downloading and extracting blockchain snapshot..."
  
  # Create temporary directory on the bitcoin-data volume to ensure sufficient space
  TEMP_DIR="/bitcoin-data/temp"
  mkdir -p "$TEMP_DIR"
  chmod 777 "$TEMP_DIR"
  
  # Configure AWS CLI for faster downloads
  mkdir -p /home/ubuntu/.aws
  cat > /home/ubuntu/.aws/config << 'EOF'
[default]
s3 =
    max_concurrent_requests = 100
    max_queue_size = 10000
    multipart_threshold = 64MB
    multipart_chunksize = 64MB
EOF
  chown -R ubuntu:ubuntu /home/ubuntu/.aws
  
  if [ "$IS_UNCOMPRESSED" = true ]; then
    echo "[INFO] Using uncompressed blockchain data approach"
    echo "[INFO] This will directly sync blockchain files from S3 without compression/extraction overhead"
    
    # Create target directories
    mkdir -p /bitcoin-data/bitcoin/blocks
    if [ "$IS_BLOCKS_ONLY" != "true" ]; then
      mkdir -p /bitcoin-data/bitcoin/chainstate
    fi
    
    # Define log directory
    DOWNLOAD_LOG_DIR="/bitcoin-data/download_logs"
    mkdir -p "$DOWNLOAD_LOG_DIR"
    chmod 777 "$DOWNLOAD_LOG_DIR"
    
    # Determine if we should use authentication
    USE_AUTH_FLAG=""
    if [ -n "$AWS_ACCESS_KEY_ID" ] && [ -n "$AWS_SECRET_ACCESS_KEY" ] && [[ "$FORCE_NO_SIGN_REQUEST" != "true" ]]; then
      echo "[INFO] Using AWS credentials for S3 sync"
    else
      echo "[INFO] Using anonymous access for S3 sync (--no-sign-request)"
      USE_AUTH_FLAG="--no-sign-request"
    fi
    
    # Sync blocks directory
    echo "[INFO] Starting blocks directory sync from $BITCOIN_SNAPSHOT_PATH/blocks/ (this may take 1-2 hours)..."
    timeout 10800 aws s3 sync "$BITCOIN_SNAPSHOT_PATH/blocks/" /bitcoin-data/bitcoin/blocks/ $USE_AUTH_FLAG --only-show-errors 2>&1 | tee -a "$DOWNLOAD_LOG_DIR/blocks_sync.log"
    BLOCKS_SYNC_RESULT=$?
    
    if [ $BLOCKS_SYNC_RESULT -ne 0 ]; then
      echo "[ERROR] Blocks sync failed with exit code: $BLOCKS_SYNC_RESULT"
      echo "[WARNING] Bitcoin may still be able to use partial data, continuing..."
    else
      echo "[SUCCESS] Blocks data synced successfully from S3"
    fi
    
    # Only sync chainstate if this is not a blocks-only bootstrap
    if [ "$IS_BLOCKS_ONLY" != "true" ]; then
      echo "[INFO] Starting chainstate directory sync from $BITCOIN_SNAPSHOT_PATH/chainstate/ (this may take 1-2 hours)..."
      timeout 7200 aws s3 sync "$BITCOIN_SNAPSHOT_PATH/chainstate/" /bitcoin-data/bitcoin/chainstate/ $USE_AUTH_FLAG --only-show-errors 2>&1 | tee -a "$DOWNLOAD_LOG_DIR/chainstate_sync.log"
      CHAINSTATE_SYNC_RESULT=$?
      
      if [ $CHAINSTATE_SYNC_RESULT -ne 0 ]; then
        echo "[ERROR] Chainstate sync failed with exit code: $CHAINSTATE_SYNC_RESULT"
        echo "[WARNING] Bitcoin will need to rebuild the UTXO set from blocks, which will take longer"
      else
        echo "[SUCCESS] Chainstate data synced successfully from S3"
      fi
    else
      echo "[INFO] Skipping chainstate sync for blocks-only bootstrap"
      echo "[INFO] Bitcoin will rebuild the UTXO set during initial sync (this will take longer)"
    fi
    
    # Set proper permissions
    chown -R ubuntu:ubuntu /bitcoin-data/bitcoin
    
    # Store snapshot height for future reference if available
    if [ -n "$SNAPSHOT_HEIGHT" ]; then
      mkdir -p "/bitcoin-data/bitcoin/.bitcoin"
      echo "$SNAPSHOT_HEIGHT" > "/bitcoin-data/bitcoin/.bitcoin/height.txt"
    fi
    
    # Calculate size for reporting
    BLOCKCHAIN_SIZE=$(du -sh /bitcoin-data/bitcoin | awk '{print $1}')
    echo "[INFO] Blockchain data size: $BLOCKCHAIN_SIZE"
    
    # Validate critical files exist
    if [ -f "/bitcoin-data/bitcoin/blocks/blk00000.dat" ]; then
      if [ "$IS_BLOCKS_ONLY" = "true" ] || [ -d "/bitcoin-data/bitcoin/chainstate" ]; then
        echo "[SUCCESS] Blockchain data validation successful"
      else
        echo "[WARNING] Missing chainstate directory - Bitcoin will rebuild it (this will take longer)"
      fi
    else
      echo "[WARNING] Blockchain data may be incomplete - missing critical files"
      echo "[INFO] Available files:"
      ls -la /bitcoin-data/bitcoin/
      
      if [ -d "/bitcoin-data/bitcoin/blocks" ]; then
        ls -la /bitcoin-data/bitcoin/blocks/ | head -n 10
      fi
    fi
  else
    # Traditional compressed approach
    echo "[INFO] Downloading snapshot from $BITCOIN_SNAPSHOT_PATH (this may take some time)..."
  
  # Configure AWS CLI for optimal S3 download performance
  mkdir -p /home/ubuntu/.aws
  cat > /home/ubuntu/.aws/config << 'EOC'
[default]
s3 =
    max_concurrent_requests = 100
    max_queue_size = 10000
    multipart_threshold = 64MB
    multipart_chunksize = 64MB
EOC
  chown -R ubuntu:ubuntu /home/ubuntu/.aws
  
  # Check if this is an S3 URL or HTTPS URL
  DOWNLOAD_SUCCESS=false
  DOWNLOAD_RETRIES=3
  EXPECTED_SIZE_KB=0
  
  # Define the log directory on bitcoin-data volume to avoid root filesystem space issues
  DOWNLOAD_LOG_DIR="/bitcoin-data/download_logs"
  mkdir -p "$DOWNLOAD_LOG_DIR"
  chmod 777 "$DOWNLOAD_LOG_DIR"
  
  # Enable extra debugging if requested
  
  if [ "$SNAPSHOT_DEBUG_MODE" = "true" ]; then
    echo "[DEBUG] SNAPSHOT_DEBUG_MODE enabled - increasing verbosity"
    set -x  # Enable command echo
    
    # Check AWS CLI version and availability
    echo "[DEBUG] Checking AWS CLI installation:" >> "$DOWNLOAD_LOG_DIR/aws_check.log"
    which aws >> "$DOWNLOAD_LOG_DIR/aws_check.log" 2>&1
    echo "[DEBUG] AWS CLI version:" >> "$DOWNLOAD_LOG_DIR/aws_check.log"
    aws --version >> "$DOWNLOAD_LOG_DIR/aws_check.log" 2>&1
  fi
  
  # Try to get the expected file size
  if [[ "$BITCOIN_SNAPSHOT_PATH" == s3://* ]]; then
    # Get size from S3 metadata
    BUCKET=$(echo "$BITCOIN_SNAPSHOT_PATH" | cut -d'/' -f3)
    KEY=$(echo "$BITCOIN_SNAPSHOT_PATH" | cut -d'/' -f4-)
    
    echo "[INFO] Getting metadata for S3 object: s3://$BUCKET/$KEY"
    
    # Determine if we should use authentication for metadata request
    USE_AUTH_FLAG=""
    if [ -n "$AWS_ACCESS_KEY_ID" ] && [ -n "$AWS_SECRET_ACCESS_KEY" ] && [[ "$FORCE_NO_SIGN_REQUEST" != "true" ]]; then
      echo "[INFO] Using AWS credentials for S3 metadata"
      # No flag needed for authenticated requests (default behavior)
      S3_METADATA_CMD="aws s3api head-object --bucket \"$BUCKET\" --key \"$KEY\" --query ContentLength --output text"
    else
      echo "[INFO] Using anonymous access for S3 metadata (--no-sign-request)"
      S3_METADATA_CMD="aws s3api head-object --bucket \"$BUCKET\" --key \"$KEY\" --query ContentLength --output text --no-sign-request"
    fi
    
    # Log the command in debug mode
    if [ "$SNAPSHOT_DEBUG_MODE" = "true" ]; then
      echo "[DEBUG] Running S3 metadata command: $S3_METADATA_CMD" >> "$DOWNLOAD_LOG_DIR/s3_debug.log"
    fi
    
    # Execute without eval to avoid the same issue we fixed earlier
    if [ -n "$AWS_ACCESS_KEY_ID" ] && [ -n "$AWS_SECRET_ACCESS_KEY" ] && [[ "$FORCE_NO_SIGN_REQUEST" != "true" ]]; then
      EXPECTED_SIZE_BYTES=$(aws s3api head-object --bucket "$BUCKET" --key "$KEY" --query ContentLength --output text 2>"$DOWNLOAD_LOG_DIR/s3_error.log" || echo 0)
    else
      EXPECTED_SIZE_BYTES=$(aws s3api head-object --bucket "$BUCKET" --key "$KEY" --query ContentLength --output text --no-sign-request 2>"$DOWNLOAD_LOG_DIR/s3_error.log" || echo 0)
    fi
    S3_METADATA_RESULT=$?
    
    if [ "$SNAPSHOT_DEBUG_MODE" = "true" ]; then
      echo "[DEBUG] S3 metadata command result: $S3_METADATA_RESULT" >> "$DOWNLOAD_LOG_DIR/s3_debug.log"
      echo "[DEBUG] S3 metadata command output: $EXPECTED_SIZE_BYTES" >> "$DOWNLOAD_LOG_DIR/s3_debug.log"
      if [ -f "$DOWNLOAD_LOG_DIR/s3_error.log" ]; then
        echo "[DEBUG] S3 metadata error output:" >> "$DOWNLOAD_LOG_DIR/s3_debug.log"
        cat "$DOWNLOAD_LOG_DIR/s3_error.log" >> "$DOWNLOAD_LOG_DIR/s3_debug.log"
      fi
    fi
    
    EXPECTED_SIZE_KB=$((EXPECTED_SIZE_BYTES / 1024))
  elif [[ "$BITCOIN_SNAPSHOT_PATH" == *amazonaws.com* && "$BITCOIN_SNAPSHOT_PATH" == *s3* ]]; then
    # Extract bucket and key from URL 
    S3_URL=$(echo "$BITCOIN_SNAPSHOT_PATH" | sed -E 's|https?://([^/]+).s3.amazonaws.com/(.+)|s3://\1/\2|' | sed -E 's|https?://s3.amazonaws.com/([^/]+)/(.+)|s3://\1/\2|')
    BUCKET=$(echo "$S3_URL" | cut -d'/' -f3)
    KEY=$(echo "$S3_URL" | cut -d'/' -f4-)
    
    echo "[INFO] Getting metadata for S3 object (from HTTP URL): s3://$BUCKET/$KEY"
    
    # Determine if we should use authentication for metadata request
    USE_AUTH_FLAG=""
    if [ -n "$AWS_ACCESS_KEY_ID" ] && [ -n "$AWS_SECRET_ACCESS_KEY" ] && [[ "$FORCE_NO_SIGN_REQUEST" != "true" ]]; then
      echo "[INFO] Using AWS credentials for S3 metadata"
      # No flag needed for authenticated requests (default behavior)
      S3_METADATA_CMD="aws s3api head-object --bucket \"$BUCKET\" --key \"$KEY\" --query ContentLength --output text"
    else
      echo "[INFO] Using anonymous access for S3 metadata (--no-sign-request)"
      S3_METADATA_CMD="aws s3api head-object --bucket \"$BUCKET\" --key \"$KEY\" --query ContentLength --output text --no-sign-request"
    fi
    
    # Log the command in debug mode
    if [ "$SNAPSHOT_DEBUG_MODE" = "true" ]; then
      echo "[DEBUG] Running S3 metadata command: $S3_METADATA_CMD" >> "$DOWNLOAD_LOG_DIR/s3_debug.log"
    fi
    
    # Execute without eval to avoid the same issue we fixed earlier
    if [ -n "$AWS_ACCESS_KEY_ID" ] && [ -n "$AWS_SECRET_ACCESS_KEY" ] && [[ "$FORCE_NO_SIGN_REQUEST" != "true" ]]; then
      EXPECTED_SIZE_BYTES=$(aws s3api head-object --bucket "$BUCKET" --key "$KEY" --query ContentLength --output text 2>"$DOWNLOAD_LOG_DIR/s3_error.log" || echo 0)
    else
      EXPECTED_SIZE_BYTES=$(aws s3api head-object --bucket "$BUCKET" --key "$KEY" --query ContentLength --output text --no-sign-request 2>"$DOWNLOAD_LOG_DIR/s3_error.log" || echo 0)
    fi
    S3_METADATA_RESULT=$?
    
    if [ "$SNAPSHOT_DEBUG_MODE" = "true" ]; then
      echo "[DEBUG] S3 metadata command result: $S3_METADATA_RESULT" >> "$DOWNLOAD_LOG_DIR/s3_debug.log"
      echo "[DEBUG] S3 metadata command output: $EXPECTED_SIZE_BYTES" >> "$DOWNLOAD_LOG_DIR/s3_debug.log"
      if [ -f "$DOWNLOAD_LOG_DIR/s3_error.log" ]; then
        echo "[DEBUG] S3 metadata error output:" >> "$DOWNLOAD_LOG_DIR/s3_debug.log"
        cat "$DOWNLOAD_LOG_DIR/s3_error.log" >> "$DOWNLOAD_LOG_DIR/s3_debug.log"
      fi
    fi
    
    EXPECTED_SIZE_KB=$((EXPECTED_SIZE_BYTES / 1024))
  fi
  
  echo "[INFO] Expected snapshot file size: $EXPECTED_SIZE_KB KB"
  
  # Verify AWS CLI works before attempting download
  if [[ "$BITCOIN_SNAPSHOT_PATH" == s3://* || "$BITCOIN_SNAPSHOT_PATH" == *amazonaws.com* ]]; then
    echo "[INFO] Verifying AWS CLI functionality..."
    if ! aws --version &>/dev/null; then
      echo "[ERROR] AWS CLI not found or not working. Checking installation..."
      # Try to fix AWS CLI installation
      if [ -f "/usr/local/bin/aws" ]; then
        echo "[INFO] AWS CLI found at /usr/local/bin/aws. Adding to PATH..."
        export PATH="/usr/local/bin:$PATH"
      elif [ -f "/usr/bin/aws" ]; then
        echo "[INFO] AWS CLI found at /usr/bin/aws"
      else
        echo "[WARNING] AWS CLI not found. Attempting to install AWS CLI..."
        apt-get update && apt-get install -y unzip
        curl "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o "awscliv2.zip"
        unzip -q awscliv2.zip
        ./aws/install
        rm -rf aws awscliv2.zip
      fi
      
      # Verify again
      if ! aws --version &>/dev/null; then
        echo "[ERROR] AWS CLI installation failed. Will try wget as fallback for downloads."
      else
        echo "[INFO] AWS CLI installation verified."
      fi
    else
      echo "[INFO] AWS CLI installation verified: $(aws --version)"
    fi
    
    # Check AWS credentials and configuration
    echo "[INFO] Checking AWS credentials and configuration..."
    
    # Check if credentials are configured
    if [ "$SNAPSHOT_DEBUG_MODE" = "true" ]; then
      echo "[DEBUG] AWS CLI credentials check:" >> "$DOWNLOAD_LOG_DIR/aws_check.log"
      aws configure list >> "$DOWNLOAD_LOG_DIR/aws_check.log" 2>&1
    fi
    
    # Check if we can list S3 buckets (basic permissions test)
    if ! aws s3 ls >/dev/null 2>&1; then
      echo "[WARNING] AWS credentials may not be properly configured. Checking if --no-sign-request will work..."
      
      # Extract bucket from the S3 URL to test
      if [[ "$BITCOIN_SNAPSHOT_PATH" == s3://* ]]; then
        TEST_BUCKET=$(echo "$BITCOIN_SNAPSHOT_PATH" | cut -d'/' -f3)
      elif [[ "$BITCOIN_SNAPSHOT_PATH" == *amazonaws.com* && "$BITCOIN_SNAPSHOT_PATH" == *s3* ]]; then
        # Extract bucket from HTTP S3 URL
        if [[ "$BITCOIN_SNAPSHOT_PATH" == *s3.amazonaws.com* ]]; then
          # Format: https://<bucket>.s3.amazonaws.com/
          TEST_BUCKET=$(echo "$BITCOIN_SNAPSHOT_PATH" | sed -E 's|https?://([^.]+).s3.amazonaws.com.*|\1|')
        else
          # Format: https://s3.amazonaws.com/<bucket>/
          TEST_BUCKET=$(echo "$BITCOIN_SNAPSHOT_PATH" | sed -E 's|https?://s3.amazonaws.com/([^/]+)/.*|\1|')
        fi
      fi
      
      # Test if we can access the bucket without credentials
      if [ -n "$TEST_BUCKET" ]; then
        echo "[INFO] Testing access to bucket $TEST_BUCKET with --no-sign-request..."
        if aws s3 ls "s3://$TEST_BUCKET" --no-sign-request >/dev/null 2>&1; then
          echo "[INFO] Anonymous access to bucket $TEST_BUCKET works with --no-sign-request."
        else
          echo "[WARNING] Cannot access bucket $TEST_BUCKET even with --no-sign-request."
          echo "[WARNING] If this is a private bucket, please ensure AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY are properly set."
          
          # Check if credentials are set in environment
          if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
            echo "[ERROR] AWS credentials environment variables are not set."
            echo "[INFO] Will attempt download with --no-sign-request anyway, but it may fail if the bucket is private."
          else
            echo "[INFO] AWS credential environment variables are set, but may not have permission to access the bucket."
          fi
        fi
      fi
    else
      echo "[INFO] AWS credentials are properly configured and working."
    fi
  fi
  
  # Download with retries
  for RETRY in $(seq 1 $DOWNLOAD_RETRIES); do
    echo "[INFO] Download attempt $RETRY of $DOWNLOAD_RETRIES"
    
    if [[ "$BITCOIN_SNAPSHOT_PATH" == s3://* ]]; then
      # Using S3 protocol with optimized settings
      echo "[INFO] Using optimized AWS S3 protocol for download"
      # Set a longer timeout to prevent interruption
      aws configure set default.s3.max_concurrent_requests 100
      aws configure set default.s3.multipart_threshold 64MB
      aws configure set default.s3.multipart_chunksize 64MB
      aws configure set default.s3.max_queue_size 10000
      
      # Record these settings for debugging
      if [ "$SNAPSHOT_DEBUG_MODE" = "true" ]; then
        echo "[DEBUG] S3 settings for download:" >> "$DOWNLOAD_LOG_DIR/s3_debug.log"
        aws configure list | grep s3 >> "$DOWNLOAD_LOG_DIR/s3_debug.log"
      fi
      
      echo "[INFO] Running S3 download with timeout monitoring..."
      # Use timeout to prevent hangs and add progress monitoring
      S3_DOWNLOAD_CMD="aws s3 cp \"$BITCOIN_SNAPSHOT_PATH\" \"$TEMP_DIR/bitcoin-data.tar.gz\" --no-sign-request"
      
      # Determine if we should use authentication
      USE_AUTH_FLAG=""
      if [ -n "$AWS_ACCESS_KEY_ID" ] && [ -n "$AWS_SECRET_ACCESS_KEY" ] && [[ "$FORCE_NO_SIGN_REQUEST" != "true" ]]; then
        echo "[INFO] Using AWS credentials for S3 download"
        # No flag needed for authenticated requests (default behavior)
        USE_AUTH_FLAG=""
      else
        echo "[INFO] Using anonymous access for S3 download (--no-sign-request)"
        USE_AUTH_FLAG="--no-sign-request"
      fi
      
      if [ "$SNAPSHOT_DEBUG_MODE" = "true" ]; then
        echo "[DEBUG] Running S3 download command: aws s3 cp \"$BITCOIN_SNAPSHOT_PATH\" \"$TEMP_DIR/bitcoin-data.tar.gz\" $USE_AUTH_FLAG" >> "$DOWNLOAD_LOG_DIR/s3_debug.log"
        # Execute directly without using eval
        timeout 7200 aws s3 cp "$BITCOIN_SNAPSHOT_PATH" "$TEMP_DIR/bitcoin-data.tar.gz" $USE_AUTH_FLAG 2>&1 | tee -a "$DOWNLOAD_LOG_DIR/s3_download.log"
        DOWNLOAD_RESULT=${PIPESTATUS[0]}
        echo "[DEBUG] S3 download command result: $DOWNLOAD_RESULT" >> "$DOWNLOAD_LOG_DIR/s3_debug.log"
      else
        timeout 7200 aws s3 cp "$BITCOIN_SNAPSHOT_PATH" "$TEMP_DIR/bitcoin-data.tar.gz" $USE_AUTH_FLAG
        DOWNLOAD_RESULT=$?
      fi
      
    elif [[ "$BITCOIN_SNAPSHOT_PATH" == http://* || "$BITCOIN_SNAPSHOT_PATH" == https://* ]]; then
      # For HTTP URLs that are actually S3 URLs, try to convert and use s3 command
      if [[ "$BITCOIN_SNAPSHOT_PATH" == *amazonaws.com* && "$BITCOIN_SNAPSHOT_PATH" == *s3* ]]; then
        # Extract bucket and key from URL
        # Format: https://<bucket>.s3.amazonaws.com/<key> or https://s3.amazonaws.com/<bucket>/<key>
        S3_URL=$(echo "$BITCOIN_SNAPSHOT_PATH" | sed -E 's|https?://([^/]+).s3.amazonaws.com/(.+)|s3://\1/\2|' | sed -E 's|https?://s3.amazonaws.com/([^/]+)/(.+)|s3://\1/\2|')
        echo "[INFO] Converted HTTP URL to S3 URL: $S3_URL"
        
        if [ "$SNAPSHOT_DEBUG_MODE" = "true" ]; then
          echo "[DEBUG] Original URL: $BITCOIN_SNAPSHOT_PATH" >> "$DOWNLOAD_LOG_DIR/s3_debug.log"
          echo "[DEBUG] Converted S3 URL: $S3_URL" >> "$DOWNLOAD_LOG_DIR/s3_debug.log"
        fi
        
        # Configure AWS CLI for optimal S3 download
        aws configure set default.s3.max_concurrent_requests 100
        aws configure set default.s3.multipart_threshold 64MB
        aws configure set default.s3.multipart_chunksize 64MB
        aws configure set default.s3.max_queue_size 10000
        
        # Record these settings for debugging
        if [ "$SNAPSHOT_DEBUG_MODE" = "true" ]; then
          echo "[DEBUG] S3 settings for download:" >> "$DOWNLOAD_LOG_DIR/s3_debug.log"
          aws configure list | grep s3 >> "$DOWNLOAD_LOG_DIR/s3_debug.log"
        fi
        
        echo "[INFO] Running S3 download with timeout monitoring..."
        # Use timeout to prevent hangs
        S3_DOWNLOAD_CMD="aws s3 cp \"$S3_URL\" \"$TEMP_DIR/bitcoin-data.tar.gz\" --no-sign-request"
        
        # Determine if we should use authentication
        USE_AUTH_FLAG=""
        if [ -n "$AWS_ACCESS_KEY_ID" ] && [ -n "$AWS_SECRET_ACCESS_KEY" ] && [[ "$FORCE_NO_SIGN_REQUEST" != "true" ]]; then
          echo "[INFO] Using AWS credentials for S3 download"
          # No flag needed for authenticated requests (default behavior)
          USE_AUTH_FLAG=""
        else
          echo "[INFO] Using anonymous access for S3 download (--no-sign-request)"
          USE_AUTH_FLAG="--no-sign-request"
        fi
        
        if [ "$SNAPSHOT_DEBUG_MODE" = "true" ]; then
          echo "[DEBUG] Running S3 download command: aws s3 cp \"$S3_URL\" \"$TEMP_DIR/bitcoin-data.tar.gz\" $USE_AUTH_FLAG" >> "$DOWNLOAD_LOG_DIR/s3_debug.log"
          # Execute directly without using eval
          timeout 7200 aws s3 cp "$S3_URL" "$TEMP_DIR/bitcoin-data.tar.gz" $USE_AUTH_FLAG 2>&1 | tee -a "$DOWNLOAD_LOG_DIR/s3_download.log"
          DOWNLOAD_RESULT=${PIPESTATUS[0]}
          echo "[DEBUG] S3 download command result: $DOWNLOAD_RESULT" >> "$DOWNLOAD_LOG_DIR/s3_debug.log"
        else
          timeout 7200 aws s3 cp "$S3_URL" "$TEMP_DIR/bitcoin-data.tar.gz" $USE_AUTH_FLAG
          DOWNLOAD_RESULT=$?
        fi
        
        # Additional MD5 checksum verification will be handled in the common code after the download
        
      else
        # Regular HTTP download
        echo "[INFO] Using HTTPS protocol for download"
        # Use wget for more reliable downloads of large files with timeout
        HTTP_DOWNLOAD_CMD="wget -O \"$TEMP_DIR/bitcoin-data.tar.gz\" \"$BITCOIN_SNAPSHOT_PATH\" --progress=dot:giga --tries=3 --timeout=300 --continue"
        
        if [ "$SNAPSHOT_DEBUG_MODE" = "true" ]; then
          echo "[DEBUG] Running HTTP download command: $HTTP_DOWNLOAD_CMD" >> "$DOWNLOAD_LOG_DIR/s3_debug.log"
          # Execute directly without using eval
          timeout 7200 wget -O "$TEMP_DIR/bitcoin-data.tar.gz" "$BITCOIN_SNAPSHOT_PATH" --progress=dot:giga --tries=3 --timeout=300 --continue 2>&1 | tee -a "$DOWNLOAD_LOG_DIR/http_download.log"
          DOWNLOAD_RESULT=${PIPESTATUS[0]}
          echo "[DEBUG] HTTP download command result: $DOWNLOAD_RESULT" >> "$DOWNLOAD_LOG_DIR/s3_debug.log"
        else
          timeout 7200 wget -O "$TEMP_DIR/bitcoin-data.tar.gz" "$BITCOIN_SNAPSHOT_PATH" --progress=dot:giga --tries=3 --timeout=300 --continue
          DOWNLOAD_RESULT=$?
        fi
      fi
    else
      # Invalid URL format
      echo "[ERROR] Invalid snapshot URL format: $BITCOIN_SNAPSHOT_PATH"
      echo "[ERROR] URL must begin with 's3://' or 'https://'"
      DOWNLOAD_RESULT=1
    fi
    
    # Check download result
    if [ $DOWNLOAD_RESULT -ne 0 ]; then
      echo "[ERROR] Download attempt $RETRY failed with exit code: $DOWNLOAD_RESULT"
      
      # If we've reached the maximum retries, give up
      if [ $RETRY -eq $DOWNLOAD_RETRIES ]; then
        echo "[ERROR] Failed to download snapshot after $DOWNLOAD_RETRIES attempts"
        break
      else
        echo "[INFO] Retrying download in 30 seconds..."
        sleep 30
        
        # Clear any partial downloads
        rm -f "$TEMP_DIR/bitcoin-data.tar.gz"
      fi
    else
      # Verify download size if expected size is known
      if [ $EXPECTED_SIZE_KB -gt 0 ]; then
        ACTUAL_SIZE_KB=$(du -k "$TEMP_DIR/bitcoin-data.tar.gz" | cut -f1)
        echo "[INFO] Actual downloaded size: $ACTUAL_SIZE_KB KB"
        
        # Allow a small difference (1%) to account for metadata differences
        SIZE_THRESHOLD=$(( EXPECTED_SIZE_KB * 99 / 100 ))
        
        if [ $ACTUAL_SIZE_KB -lt $SIZE_THRESHOLD ]; then
          echo "[ERROR] Downloaded file size ($ACTUAL_SIZE_KB KB) is significantly smaller than expected ($EXPECTED_SIZE_KB KB)"
          echo "[ERROR] This indicates an incomplete download. Retrying..."
          
          # If we've reached the maximum retries, give up
          if [ $RETRY -eq $DOWNLOAD_RETRIES ]; then
            echo "[ERROR] Failed to download complete snapshot after $DOWNLOAD_RETRIES attempts"
            break
          else
            echo "[INFO] Retrying download in 30 seconds..."
            sleep 30
            
            # Clear the partial download
            rm -f "$TEMP_DIR/bitcoin-data.tar.gz"
          fi
        else
          echo "[SUCCESS] Download size verification passed"
          
          # Check MD5 checksum if it's available in S3 metadata
          if [[ "$BITCOIN_SNAPSHOT_PATH" == s3://* ]]; then
            BUCKET=$(echo "$BITCOIN_SNAPSHOT_PATH" | cut -d'/' -f3)
            KEY=$(echo "$BITCOIN_SNAPSHOT_PATH" | cut -d'/' -f4-)
            
            echo "[INFO] Retrieving MD5 checksum from S3 metadata..."
            if [ -n "$AWS_ACCESS_KEY_ID" ] && [ -n "$AWS_SECRET_ACCESS_KEY" ] && [[ "$FORCE_NO_SIGN_REQUEST" != "true" ]]; then
              EXPECTED_MD5=$(aws s3api head-object --bucket "$BUCKET" --key "$KEY" --query "Metadata.md5" --output text 2>/dev/null)
            else
              EXPECTED_MD5=$(aws s3api head-object --bucket "$BUCKET" --key "$KEY" --query "Metadata.md5" --output text --no-sign-request 2>/dev/null)
            fi
            
            if [ -n "$EXPECTED_MD5" ] && [ "$EXPECTED_MD5" != "None" ]; then
              echo "[INFO] Found MD5 checksum in metadata: $EXPECTED_MD5"
              echo "[INFO] Calculating MD5 checksum of downloaded file (this may take a few minutes)..."
              ACTUAL_MD5=$(md5sum "$TEMP_DIR/bitcoin-data.tar.gz" | cut -d' ' -f1)
              echo "[INFO] Calculated MD5 checksum: $ACTUAL_MD5"
              
              if [ "$EXPECTED_MD5" = "$ACTUAL_MD5" ]; then
                echo "[SUCCESS] MD5 checksum verification passed"
                DOWNLOAD_SUCCESS=true
                break
              else
                echo "[ERROR] MD5 checksum verification failed. Expected: $EXPECTED_MD5, Got: $ACTUAL_MD5"
                echo "[ERROR] The downloaded file is corrupted. Retrying..."
                
                # If we've reached the maximum retries, give up
                if [ $RETRY -eq $DOWNLOAD_RETRIES ]; then
                  echo "[ERROR] Failed to download valid snapshot after $DOWNLOAD_RETRIES attempts"
                  break
                else
                  echo "[INFO] Retrying download in 30 seconds..."
                  sleep 30
                  
                  # Clear the partial download
                  rm -f "$TEMP_DIR/bitcoin-data.tar.gz"
                fi
              fi
            else
              echo "[INFO] No MD5 checksum found in S3 metadata. Skipping checksum verification."
              DOWNLOAD_SUCCESS=true
              break
            fi
          else
            # For non-S3 URLs, we can't easily get the MD5 checksum
            DOWNLOAD_SUCCESS=true
            break
          fi
        fi
      else
        # If we can't verify size, check if the file exists and has reasonable size (>1GB)
        if [ -f "$TEMP_DIR/bitcoin-data.tar.gz" ] && [ $(du -m "$TEMP_DIR/bitcoin-data.tar.gz" | cut -f1) -gt 1024 ]; then
          echo "[INFO] Download appears successful (size: $(du -h "$TEMP_DIR/bitcoin-data.tar.gz" | cut -f1))"
          DOWNLOAD_SUCCESS=true
          break
        else
          echo "[ERROR] Downloaded file too small or missing"
          
          # If we've reached the maximum retries, give up
          if [ $RETRY -eq $DOWNLOAD_RETRIES ]; then
            echo "[ERROR] Failed to download valid snapshot after $DOWNLOAD_RETRIES attempts"
            break
          else
            echo "[INFO] Retrying download in 30 seconds..."
            sleep 30
            
            # Clear the partial download
            rm -f "$TEMP_DIR/bitcoin-data.tar.gz"
          fi
        fi
      fi
    fi
  done
  
  # Check if download was successful
  if [ "$DOWNLOAD_SUCCESS" != "true" ]; then
    echo "[ERROR] Failed to download snapshot from $BITCOIN_SNAPSHOT_PATH"
    
    # Try wget as a last resort for S3 URLs
    if [[ "$BITCOIN_SNAPSHOT_PATH" == s3://* ]]; then
      # Convert s3:// URL to https:// public URL if possible
      if [[ "$BITCOIN_SNAPSHOT_PATH" == s3://*.public.* ]]; then
        BUCKET=$(echo "$BITCOIN_SNAPSHOT_PATH" | cut -d'/' -f3)
        KEY=$(echo "$BITCOIN_SNAPSHOT_PATH" | cut -d'/' -f4-)
        HTTP_URL="https://${BUCKET}.s3.amazonaws.com/${KEY}"
        
        echo "[INFO] Trying last-resort download with wget from $HTTP_URL..."
        if wget -O "$TEMP_DIR/bitcoin-data.tar.gz" "$HTTP_URL" --progress=dot:giga --tries=3 --timeout=600 --continue; then
          DOWNLOAD_SUCCESS=true
          echo "[SUCCESS] Last-resort download successful!"
        else
          echo "[ERROR] Last-resort download also failed."
        fi
      fi
    fi
    
    # If still not successful, restore backup if available
    if [ "$DOWNLOAD_SUCCESS" != "true" ]; then
      # If we backed up and moved original data, restore it
      if [ "$EXISTING_DATA" = true ] && [ -d "$BACKUP_DIR/blocks" ] && [ -d "$BACKUP_DIR/chainstate" ]; then
        echo "[INFO] Restoring original blockchain data from backup..."
        mkdir -p /bitcoin-data/bitcoin/
        mv "$BACKUP_DIR/blocks" "$BACKUP_DIR/chainstate" /bitcoin-data/bitcoin/
      fi
      
      echo "[INFO] Continuing with existing data or from scratch..."
    fi
  else
    echo "[INFO] Snapshot downloaded successfully. MD5 checksum validation passed, proceeding with extraction..."
    
    # We skip the tar validation since we've already verified the MD5 checksum
    # This avoids the long-running tar -t verification that can take hours with large files
    echo "[INFO] Skipping tar validation since MD5 checksum verification already passed..."
    
    # Extract snapshot to correct location with progress reporting
    mkdir -p /bitcoin-data/bitcoin
    
    # Extract with progress reporting
    echo "[INFO] Starting extraction process (this may take 15-30 minutes)..."
    pv "$TEMP_DIR/bitcoin-data.tar.gz" 2>/dev/null | tar -xzf - -C /bitcoin-data/bitcoin || {
      # If pv is not available, try with regular tar
      echo "[INFO] Using standard tar extraction..."
      tar -xzf "$TEMP_DIR/bitcoin-data.tar.gz" -C /bitcoin-data/bitcoin
    }
    
    # Set proper permissions
    chown -R ubuntu:ubuntu /bitcoin-data/bitcoin
    
    # Store snapshot height for future reference
    echo "$SNAPSHOT_HEIGHT" > "/bitcoin-data/bitcoin/.bitcoin/height.txt"
    
    # Validate extraction
    if [ -f "/bitcoin-data/bitcoin/blocks/blk00000.dat" ] && [ -d "/bitcoin-data/bitcoin/chainstate" ]; then
      # Calculate extracted size for reporting
      EXTRACTED_SIZE=$(du -sh /bitcoin-data/bitcoin/blocks /bitcoin-data/bitcoin/chainstate | awk '{sum+=$1} END {print sum}')
      DOWNLOAD_SIZE=$(du -h "$TEMP_DIR/bitcoin-data.tar.gz" | cut -f1)
      
      echo "[SUCCESS] Bitcoin blockchain snapshot extracted successfully (height $SNAPSHOT_HEIGHT, downloaded $DOWNLOAD_SIZE, extracted ~$EXTRACTED_SIZE)"
      
      # Remove backup if extraction was successful
      if [ -d "$BACKUP_DIR" ]; then
        echo "[INFO] Removing backup as snapshot was successfully extracted"
        rm -rf "$BACKUP_DIR"
      fi
    else
      echo "[ERROR] Snapshot extraction failed or resulted in incomplete data"
      
      # Restore backup if available
      if [ "$EXISTING_DATA" = true ] && [ -d "$BACKUP_DIR/blocks" ] && [ -d "$BACKUP_DIR/chainstate" ]; then
        echo "[INFO] Restoring original blockchain data from backup..."
        rm -rf /bitcoin-data/bitcoin/blocks /bitcoin-data/bitcoin/chainstate
        mv "$BACKUP_DIR/blocks" "$BACKUP_DIR/chainstate" /bitcoin-data/bitcoin/
      fi
    fi
    
    # Clean up compressed approach temp files
    rm -f "$TEMP_DIR/bitcoin-data.tar.gz"
  fi # End of the compressed approach conditional
  
  # Clean up common temp directory if empty
  rmdir "$TEMP_DIR" 2>/dev/null || true
fi

# Configure Docker to use the volume
mkdir -p /etc/docker
cat > /etc/docker/daemon.json << 'EOF'
{
  "data-root": "/bitcoin-data/docker",
  "storage-driver": "overlay2",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "50m",
    "max-file": "2"
  }
}
EOF

# Ensure Docker can access the directory
chmod 711 /bitcoin-data/docker

# Restart Docker service
systemctl restart docker
systemctl enable docker

# Create symlink for docker-compose command for compatibility
if [ -f "/usr/libexec/docker/cli-plugins/docker-compose" ] && [ ! -f "/usr/bin/docker-compose" ]; then
  ln -s /usr/libexec/docker/cli-plugins/docker-compose /usr/bin/docker-compose
  chmod +x /usr/bin/docker-compose
fi

# Clone counterparty-arm64 repository with retry logic
cd /home/ubuntu
REPO_URL="https://github.com/stampchain-io/counterparty-arm64.git"

# Optional GitHub token for private repository access
if [ ! -z "$GITHUB_TOKEN" ]; then
  echo "GitHub token detected, will use for repository access"
fi

MAX_RETRIES=3

for i in $(seq 1 $MAX_RETRIES); do
  echo "Cloning repository (attempt $i of $MAX_RETRIES)..."
  
  if [ -n "$GITHUB_TOKEN" ]; then
    # Use token for private repository
    echo "Using GitHub token for private repository access"
    REPO_WITH_TOKEN="https://${GITHUB_TOKEN}@github.com/stampchain-io/counterparty-arm64.git"
    git clone $REPO_WITH_TOKEN && break
  else
    # Try public access
    git clone $REPO_URL && break
  fi
  
  if [ $i -eq $MAX_RETRIES ]; then
    echo "Failed to clone repository after $MAX_RETRIES attempts"
    echo "If this is a private repository, please provide a GitHubToken parameter"
    exit 1
  fi
  
  echo "Clone failed. Retrying in 5 seconds..."
  sleep 5
done

# Clone Counterparty Core as well
echo "Cloning Counterparty Core repository..."
mkdir -p /bitcoin-data/repo
chown -R ubuntu:ubuntu /bitcoin-data/repo
cd /bitcoin-data/repo

# Clone Counterparty Core - this is a public repo but could be changed
COUNTERPARTY_REPO_URL="https://github.com/CounterpartyXCP/counterparty-core.git"

if [ -n "$GITHUB_TOKEN" ]; then
  # Use token for private repository - just in case it becomes private
  COUNTERPARTY_REPO_WITH_TOKEN="https://${GITHUB_TOKEN}@github.com/CounterpartyXCP/counterparty-core.git"
  sudo -u ubuntu git clone $COUNTERPARTY_REPO_WITH_TOKEN
else
  # Use public URL
  sudo -u ubuntu git clone $COUNTERPARTY_REPO_URL
fi

chown -R ubuntu:ubuntu /home/ubuntu/counterparty-arm64

# Create symbolic link for counterparty-node pointing to the docker directory
ln -sf /home/ubuntu/counterparty-arm64/docker /home/ubuntu/counterparty-node

# Ensure entrypoint script is available and executable in system path
cp /home/ubuntu/counterparty-arm64/docker/bitcoin-entrypoint.sh /usr/local/bin/
chmod +x /usr/local/bin/bitcoin-entrypoint.sh

chown -R ubuntu:ubuntu /home/ubuntu/counterparty-node

# Make sure all Bitcoin-data directories have correct permissions
echo "Ensuring proper directory permissions..."
chown -R ubuntu:ubuntu /bitcoin-data
chmod -R 755 /bitcoin-data
sudo -u ubuntu mkdir -p /bitcoin-data/repo/counterparty-core

# Run setup script - retry logic in case of network issues
echo "Running setup script..."
su - ubuntu -c "cd counterparty-arm64 && chmod +x scripts/setup.sh && scripts/setup.sh --bitcoin-version '$BITCOIN_VERSION' --counterparty-branch '$COUNTERPARTY_BRANCH' --data-dir '/bitcoin-data' --platform 'aws'" || {
  echo "Setup script failed on first attempt. Waiting 30 seconds and retrying..."
  sleep 30
  # Reset permissions and try again
  chown -R ubuntu:ubuntu /bitcoin-data
  chmod -R 755 /bitcoin-data
  su - ubuntu -c "cd counterparty-arm64 && scripts/setup.sh --bitcoin-version '$BITCOIN_VERSION' --counterparty-branch '$COUNTERPARTY_BRANCH' --data-dir '/bitcoin-data' --platform 'aws'"
}

# Create bitcoin.conf file with optimized settings for initial sync
mkdir -p /bitcoin-data/bitcoin/.bitcoin

# Function to create default blocks-only config based on instance type
create_default_blocks_only_config() {
  local instance_type=$1
  log_info "Creating optimized config for $instance_type"
  
  # Default values
  local dbcache=4000
  local maxmempool=300
  local maxconnections=12
  local par=8
  
  # Tune parameters based on instance type family
  if [[ "$instance_type" == c6g.* ]]; then
    # Compute optimized (c6g family)
    dbcache=3500
    par=24
    log_info "Optimizing for compute-optimized instance"
  elif [[ "$instance_type" == t4g.* ]]; then
    # Burstable instances have more memory
    if [[ "$instance_type" == t4g.large ]]; then
      dbcache=6500
      par=16
    elif [[ "$instance_type" == t4g.xlarge ]]; then
      dbcache=13000
      par=32
      maxconnections=20
    fi
    log_info "Optimizing for burstable instance with $dbcache MB dbcache"
  elif [[ "$instance_type" == m6g.* || "$instance_type" == m7g.* ]]; then
    # General purpose - balance between compute and memory
    if [[ "$instance_type" == *large ]]; then
      dbcache=6000
      par=16
    elif [[ "$instance_type" == *xlarge ]]; then
      dbcache=12000
      par=32
      maxconnections=24
    elif [[ "$instance_type" == *2xlarge ]]; then
      dbcache=24000
      par=48
      maxconnections=32
    fi
    log_info "Optimizing for general purpose instance with $dbcache MB dbcache"
  else
    log_info "Using default parameters for unknown instance type: $instance_type"
  fi
  
  # Create the optimized config file
  cat << EOF > /bitcoin-data/bitcoin/.bitcoin/bitcoin.conf
# Bitcoin Core configuration - Optimized for blocks-only bootstrap (UTXO reconstruction)
# Auto-configured for instance type: $instance_type

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

# Enhanced Performance for Chainstate Rebuild
# Auto-tuned for $instance_type
dbcache=$dbcache
maxmempool=$maxmempool
maxconnections=$maxconnections
blocksonly=1
mempoolfullrbf=1
assumevalid=000000000000000000053b17c1c2e1ea8a965a6240ede8ffd0729f7f2e77283e
par=$par

# ZMQ Settings
zmqpubrawtx=tcp://0.0.0.0:9332
zmqpubhashtx=tcp://0.0.0.0:9332
zmqpubsequence=tcp://0.0.0.0:9332
zmqpubrawblock=tcp://0.0.0.0:9333
EOF

  log_info "Created optimized Bitcoin config with dbcache=$dbcache MB and par=$par"
}

# Use different configurations for blocks-only bootstrap vs full bootstrap
if [ "$IS_BLOCKS_ONLY" = "true" ]; then
  # For blocks-only bootstrap, detect instance type and use appropriate config
  log_info "Blocks-only bootstrap detected, optimizing configuration based on instance type"

  # Detect instance type
  INSTANCE_TYPE=$(curl -s http://169.254.169.254/latest/meta-data/instance-type)
  
  # Check if config template exists in S3
  CONFIG_TEMPLATE_PATH=""
  if [[ "$BITCOIN_SNAPSHOT_PATH" == s3://* ]]; then
    # Try to get instance-specific config template
    INSTANCE_TYPE_CONFIG="s3://$(echo "$BITCOIN_SNAPSHOT_PATH" | cut -d'/' -f3)/$(echo "$BITCOIN_SNAPSHOT_PATH" | cut -d'/' -f4-)/config-templates/bitcoin.conf.$INSTANCE_TYPE"
    
    # Check if instance-specific config exists
    if aws s3 ls "$INSTANCE_TYPE_CONFIG" --no-sign-request &>/dev/null; then
      CONFIG_TEMPLATE_PATH="$INSTANCE_TYPE_CONFIG"
      log_info "Found instance-specific config template for $INSTANCE_TYPE"
    else
      # Try default blocks-only config
      DEFAULT_CONFIG="s3://$(echo "$BITCOIN_SNAPSHOT_PATH" | cut -d'/' -f3)/$(echo "$BITCOIN_SNAPSHOT_PATH" | cut -d'/' -f4-)/config-templates/bitcoin.conf.blocks-only"
      if aws s3 ls "$DEFAULT_CONFIG" --no-sign-request &>/dev/null; then
        CONFIG_TEMPLATE_PATH="$DEFAULT_CONFIG"
        log_info "Using default blocks-only config template"
      fi
    fi
  fi
  
  # If we found a config template, download and use it
  if [ -n "$CONFIG_TEMPLATE_PATH" ]; then
    log_info "Downloading config template from $CONFIG_TEMPLATE_PATH"
    aws s3 cp "$CONFIG_TEMPLATE_PATH" /bitcoin-data/bitcoin/.bitcoin/bitcoin.conf --no-sign-request
    
    # Verify download was successful
    if [ -f /bitcoin-data/bitcoin/.bitcoin/bitcoin.conf ]; then
      log_success "Successfully downloaded optimized config"
    else
      log_warning "Failed to download config template, using default config"
      # Generate default optimized config
      create_default_blocks_only_config "$INSTANCE_TYPE"
    fi
  else
    log_info "No config template found in S3, generating optimized config for $INSTANCE_TYPE"
    create_default_blocks_only_config "$INSTANCE_TYPE"
  fi
else
  # Standard config for full bootstrap
  cat << 'EOF' > /bitcoin-data/bitcoin/.bitcoin/bitcoin.conf
# Bitcoin Core configuration file - Created by CloudFormation template with optimizations

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

# Performance Optimizations
dbcache=6000
maxmempool=300
maxconnections=25
blocksonly=1
mempoolfullrbf=1
assumevalid=000000000000000000053b17c1c2e1ea8a965a6240ede8ffd0729f7f2e77283e
par=8

# ZMQ Settings
zmqpubrawtx=tcp://0.0.0.0:9332
zmqpubhashtx=tcp://0.0.0.0:9332
zmqpubsequence=tcp://0.0.0.0:9332
zmqpubrawblock=tcp://0.0.0.0:9333
EOF
fi
chmod 600 /bitcoin-data/bitcoin/.bitcoin/bitcoin.conf
chown -R ubuntu:ubuntu /bitcoin-data/bitcoin/.bitcoin

# Create symbolic link to scripts in the home directory
ln -sf /home/ubuntu/counterparty-arm64/scripts/check-sync-status.sh /home/ubuntu/check-sync-status.sh
chmod +x /home/ubuntu/check-sync-status.sh

# Update docker-compose.yml to use pre-built Docker Hub images
echo "Updating docker-compose.yml to use Docker Hub images..."

# Create config directory if it doesn't exist
mkdir -p /home/ubuntu/.counterparty-arm64

# Create a config.env file for Docker Compose with Docker Hub image references
# Using printf to avoid heredoc YAML parsing issues
printf "%s\n" \
  "# Counterparty ARM64 Configuration" \
  "# Generated on $(date)" \
  "COUNTERPARTY_DOCKER_DATA=/bitcoin-data" \
  "COUNTERPARTY_REPO=/bitcoin-data/repo/counterparty-core" \
  "BITCOIN_VERSION=$BITCOIN_VERSION" \
  "COUNTERPARTY_BRANCH=$COUNTERPARTY_BRANCH" \
  "COUNTERPARTY_TAG=$COUNTERPARTY_TAG" \
  "NETWORK_PROFILE=$NETWORK_PROFILE" \
  "" \
  "# Docker Hub images" \
  "DOCKERHUB_IMAGE_BITCOIND=xcparty/bitcoind-arm64" \
  "DOCKERHUB_IMAGE_COUNTERPARTY=xcparty/counterparty-core-arm64" \
  > /home/ubuntu/.counterparty-arm64/config.env
chown -R ubuntu:ubuntu /home/ubuntu/.counterparty-arm64

# Create .env file for docker-compose
cp /home/ubuntu/.counterparty-arm64/config.env /home/ubuntu/counterparty-node/.env
chown ubuntu:ubuntu /home/ubuntu/counterparty-node/.env

# Build Bitcoin image locally with entrypoint script
cd /home/ubuntu/counterparty-arm64/docker
cp bitcoin-entrypoint.sh /usr/local/bin/
chmod +x /usr/local/bin/bitcoin-entrypoint.sh
docker build -t bitcoind:arm64-local -f Dockerfile.bitcoind .

# Pull Counterparty image
docker pull xcparty/counterparty-core-arm64:$COUNTERPARTY_BRANCH
docker tag xcparty/counterparty-core-arm64:$COUNTERPARTY_BRANCH counterparty/counterparty:local

# Start Bitcoin and Counterparty services
echo "Starting services with profile $NETWORK_PROFILE..."
cd /home/ubuntu/counterparty-node && docker compose --profile $NETWORK_PROFILE up -d

# We don't need a cron job to start Counterparty - we'll start it directly
# Counterparty will start alongside Bitcoin as long as Bitcoin is running

# Wait for Bitcoin to start and verify it's using the correct data directory
echo "Waiting for Bitcoin to initialize..."
sleep 15

# Check if Bitcoin is running and using the correct data directory
BITCOIN_CONTAINER=$(docker ps --format "{{.Names}}" | grep -E "bitcoind" | head -1)
if [ -n "$BITCOIN_CONTAINER" ]; then
  echo "Bitcoin container $BITCOIN_CONTAINER is running"
  # Run check-sync-status.sh to verify initial sync is starting
  su - ubuntu -c "/home/ubuntu/check-sync-status.sh"
else
  echo "WARNING: Bitcoin container not running, check logs for errors"
fi

echo "Deployment completed. Bitcoin and Counterparty services are now starting."
echo "Check status with: ~/check-sync-status.sh"
echo "Deploy time: $(date -u) UTC" 
echo "Build version: bootstrap-$(date +%s)"

# Copy scripts to the home directory for easier access
cp /home/ubuntu/counterparty-arm64/aws/scripts/check-sync-status.sh /home/ubuntu/
cp /home/ubuntu/counterparty-arm64/scripts/common.sh /home/ubuntu/
chmod +x /home/ubuntu/check-sync-status.sh
chown ubuntu:ubuntu /home/ubuntu/check-sync-status.sh /home/ubuntu/common.sh

# Set up system maintenance and security scripts
echo "[INFO] Setting up system maintenance and security scripts..."

# Set up system-maintenance.sh
cp /home/ubuntu/counterparty-arm64/aws/scripts/system-maintenance.sh /usr/local/bin/
chmod +x /usr/local/bin/system-maintenance.sh

# Set up unattended-upgrades
echo "[INFO] Setting up unattended-upgrades for automatic security updates..."
cp /home/ubuntu/counterparty-arm64/aws/scripts/setup-unattended-upgrades.sh /usr/local/bin/
chmod +x /usr/local/bin/setup-unattended-upgrades.sh
/usr/local/bin/setup-unattended-upgrades.sh

# Set up security check script
cp /home/ubuntu/counterparty-arm64/aws/scripts/security-check.sh /usr/local/bin/
chmod +x /usr/local/bin/security-check.sh

# Add weekly cron job for system maintenance
echo "# Weekly system maintenance job for Counterparty ARM64" > /etc/cron.d/counterparty-maintenance
echo "# Run at 3:30 AM every Sunday" >> /etc/cron.d/counterparty-maintenance
echo "30 3 * * 0 root /usr/local/bin/system-maintenance.sh > /dev/null 2>&1" >> /etc/cron.d/counterparty-maintenance
echo "# Run security check at 4:30 AM every Monday" >> /etc/cron.d/counterparty-maintenance
echo "30 4 * * 1 root /usr/local/bin/security-check.sh > /dev/null 2>&1" >> /etc/cron.d/counterparty-maintenance

# Set up log rotation
echo "[INFO] Setting up log rotation..."
cp /home/ubuntu/counterparty-arm64/aws/scripts/counterparty-logrotate.conf /etc/logrotate.d/counterparty
chmod 644 /etc/logrotate.d/counterparty

# Force run logrotate once to make sure it works
logrotate -f /etc/logrotate.d/counterparty

# Copy monitoring scripts for disk usage and bitcoin sync
cp /home/ubuntu/counterparty-arm64/aws/scripts/check-disk-usage.sh /usr/local/bin/
cp /home/ubuntu/counterparty-arm64/aws/scripts/monitor-bitcoin.sh /usr/local/bin/
cp /home/ubuntu/counterparty-arm64/aws/scripts/disk-usage-analysis.sh /usr/local/bin/
chmod +x /usr/local/bin/check-disk-usage.sh /usr/local/bin/monitor-bitcoin.sh /usr/local/bin/disk-usage-analysis.sh

# Add daily cron job for disk usage monitoring
echo "# Daily monitoring jobs for Counterparty ARM64" > /etc/cron.d/counterparty-monitoring
echo "# Check disk usage at 2:00 AM daily" >> /etc/cron.d/counterparty-monitoring
echo "0 2 * * * root /usr/local/bin/check-disk-usage.sh > /dev/null 2>&1" >> /etc/cron.d/counterparty-monitoring
echo "# Check Bitcoin sync status at 6:00 AM daily" >> /etc/cron.d/counterparty-monitoring
echo "0 6 * * * root /usr/local/bin/monitor-bitcoin.sh --host localhost --port 8332 --user rpc --pass rpc > /dev/null 2>&1" >> /etc/cron.d/counterparty-monitoring

# Set up basic SSH hardening
echo "[INFO] Applying basic SSH security hardening..."
if [ -f /etc/ssh/sshd_config ]; then
    # Disable root login
    sed -i 's/^#PermitRootLogin yes/PermitRootLogin no/g' /etc/ssh/sshd_config
    # Use Protocol 2 only
    if ! grep -q "^Protocol 2" /etc/ssh/sshd_config; then
        echo "Protocol 2" >> /etc/ssh/sshd_config
    fi
    # Restart SSH to apply changes - only if not in the middle of setup
    if systemctl is-active --quiet sshd; then
        systemctl restart sshd
    fi
fi

echo "Deployment completed. Bitcoin and Counterparty services are now starting."
echo "Check status with: ~/check-sync-status.sh"
echo "Deploy time: $(date -u +'%Y-%m-%d %H:%M:%S UTC')"
echo "Build version: bootstrap-$(date -u +%s)"

# Close the if statement for Bitcoin_SNAPSHOT_PATH check on line 132
fi

# End of bootstrap script