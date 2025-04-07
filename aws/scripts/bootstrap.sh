#!/bin/bash
# Bootstrap script for Counterparty ARM64 EC2 instance
# This script is downloaded and executed by the minimal UserData script

# Parse parameters
BITCOIN_VERSION=${1:-"26.0"}
COUNTERPARTY_BRANCH=${2:-"develop"}
COUNTERPARTY_TAG=${3:-""}
NETWORK_PROFILE=${4:-"mainnet"}
GITHUB_TOKEN=${5:-""}

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
  
  # Create temporary directory
  TEMP_DIR=$(mktemp -d)
  
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
  
  # Download snapshot with optimized S3 configuration
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
  
  # Enable extra debugging if requested
  if [ "$SNAPSHOT_DEBUG_MODE" = "true" ]; then
    echo "[DEBUG] SNAPSHOT_DEBUG_MODE enabled - increasing verbosity"
    set -x  # Enable command echo
    # Create debug log directory
    mkdir -p /tmp/download_logs
    
    # Check AWS CLI version and availability
    echo "[DEBUG] Checking AWS CLI installation:" >> /tmp/download_logs/aws_check.log
    which aws >> /tmp/download_logs/aws_check.log 2>&1
    echo "[DEBUG] AWS CLI version:" >> /tmp/download_logs/aws_check.log
    aws --version >> /tmp/download_logs/aws_check.log 2>&1
  fi
  
  # Try to get the expected file size
  if [[ "$BITCOIN_SNAPSHOT_PATH" == s3://* ]]; then
    # Get size from S3 metadata
    BUCKET=$(echo "$BITCOIN_SNAPSHOT_PATH" | cut -d'/' -f3)
    KEY=$(echo "$BITCOIN_SNAPSHOT_PATH" | cut -d'/' -f4-)
    
    echo "[INFO] Getting metadata for S3 object: s3://$BUCKET/$KEY"
    S3_METADATA_CMD="aws s3api head-object --bucket \"$BUCKET\" --key \"$KEY\" --query ContentLength --output text --no-sign-request"
    
    # Log the command in debug mode
    if [ "$SNAPSHOT_DEBUG_MODE" = "true" ]; then
      echo "[DEBUG] Running S3 metadata command: $S3_METADATA_CMD" >> /tmp/download_logs/s3_debug.log
    fi
    
    EXPECTED_SIZE_BYTES=$(eval "$S3_METADATA_CMD" 2>/tmp/download_logs/s3_error.log || echo 0)
    S3_METADATA_RESULT=$?
    
    if [ "$SNAPSHOT_DEBUG_MODE" = "true" ]; then
      echo "[DEBUG] S3 metadata command result: $S3_METADATA_RESULT" >> /tmp/download_logs/s3_debug.log
      echo "[DEBUG] S3 metadata command output: $EXPECTED_SIZE_BYTES" >> /tmp/download_logs/s3_debug.log
      if [ -f /tmp/download_logs/s3_error.log ]; then
        echo "[DEBUG] S3 metadata error output:" >> /tmp/download_logs/s3_debug.log
        cat /tmp/download_logs/s3_error.log >> /tmp/download_logs/s3_debug.log
      fi
    fi
    
    EXPECTED_SIZE_KB=$((EXPECTED_SIZE_BYTES / 1024))
  elif [[ "$BITCOIN_SNAPSHOT_PATH" == *amazonaws.com* && "$BITCOIN_SNAPSHOT_PATH" == *s3* ]]; then
    # Extract bucket and key from URL 
    S3_URL=$(echo "$BITCOIN_SNAPSHOT_PATH" | sed -E 's|https?://([^/]+).s3.amazonaws.com/(.+)|s3://\1/\2|' | sed -E 's|https?://s3.amazonaws.com/([^/]+)/(.+)|s3://\1/\2|')
    BUCKET=$(echo "$S3_URL" | cut -d'/' -f3)
    KEY=$(echo "$S3_URL" | cut -d'/' -f4-)
    
    echo "[INFO] Getting metadata for S3 object (from HTTP URL): s3://$BUCKET/$KEY"
    S3_METADATA_CMD="aws s3api head-object --bucket \"$BUCKET\" --key \"$KEY\" --query ContentLength --output text --no-sign-request"
    
    # Log the command in debug mode
    if [ "$SNAPSHOT_DEBUG_MODE" = "true" ]; then
      echo "[DEBUG] Running S3 metadata command: $S3_METADATA_CMD" >> /tmp/download_logs/s3_debug.log
    fi
    
    EXPECTED_SIZE_BYTES=$(eval "$S3_METADATA_CMD" 2>/tmp/download_logs/s3_error.log || echo 0)
    S3_METADATA_RESULT=$?
    
    if [ "$SNAPSHOT_DEBUG_MODE" = "true" ]; then
      echo "[DEBUG] S3 metadata command result: $S3_METADATA_RESULT" >> /tmp/download_logs/s3_debug.log
      echo "[DEBUG] S3 metadata command output: $EXPECTED_SIZE_BYTES" >> /tmp/download_logs/s3_debug.log
      if [ -f /tmp/download_logs/s3_error.log ]; then
        echo "[DEBUG] S3 metadata error output:" >> /tmp/download_logs/s3_debug.log
        cat /tmp/download_logs/s3_error.log >> /tmp/download_logs/s3_debug.log
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
        echo "[DEBUG] S3 settings for download:" >> /tmp/download_logs/s3_debug.log
        aws configure list | grep s3 >> /tmp/download_logs/s3_debug.log
      fi
      
      echo "[INFO] Running S3 download with timeout monitoring..."
      # Use timeout to prevent hangs and add progress monitoring
      S3_DOWNLOAD_CMD="aws s3 cp \"$BITCOIN_SNAPSHOT_PATH\" \"$TEMP_DIR/bitcoin-data.tar.gz\" --no-sign-request"
      
      if [ "$SNAPSHOT_DEBUG_MODE" = "true" ]; then
        echo "[DEBUG] Running S3 download command: $S3_DOWNLOAD_CMD" >> /tmp/download_logs/s3_debug.log
        # Execute directly without using eval
        timeout 7200 aws s3 cp "$BITCOIN_SNAPSHOT_PATH" "$TEMP_DIR/bitcoin-data.tar.gz" --no-sign-request 2>&1 | tee -a /tmp/download_logs/s3_download.log
        DOWNLOAD_RESULT=${PIPESTATUS[0]}
        echo "[DEBUG] S3 download command result: $DOWNLOAD_RESULT" >> /tmp/download_logs/s3_debug.log
      else
        timeout 7200 aws s3 cp "$BITCOIN_SNAPSHOT_PATH" "$TEMP_DIR/bitcoin-data.tar.gz" --no-sign-request
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
          echo "[DEBUG] Original URL: $BITCOIN_SNAPSHOT_PATH" >> /tmp/download_logs/s3_debug.log
          echo "[DEBUG] Converted S3 URL: $S3_URL" >> /tmp/download_logs/s3_debug.log
        fi
        
        # Configure AWS CLI for optimal S3 download
        aws configure set default.s3.max_concurrent_requests 100
        aws configure set default.s3.multipart_threshold 64MB
        aws configure set default.s3.multipart_chunksize 64MB
        aws configure set default.s3.max_queue_size 10000
        
        # Record these settings for debugging
        if [ "$SNAPSHOT_DEBUG_MODE" = "true" ]; then
          echo "[DEBUG] S3 settings for download:" >> /tmp/download_logs/s3_debug.log
          aws configure list | grep s3 >> /tmp/download_logs/s3_debug.log
        fi
        
        echo "[INFO] Running S3 download with timeout monitoring..."
        # Use timeout to prevent hangs
        S3_DOWNLOAD_CMD="aws s3 cp \"$S3_URL\" \"$TEMP_DIR/bitcoin-data.tar.gz\" --no-sign-request"
        
        if [ "$SNAPSHOT_DEBUG_MODE" = "true" ]; then
          echo "[DEBUG] Running S3 download command: $S3_DOWNLOAD_CMD" >> /tmp/download_logs/s3_debug.log
          # Execute directly without using eval
          timeout 7200 aws s3 cp "$S3_URL" "$TEMP_DIR/bitcoin-data.tar.gz" --no-sign-request 2>&1 | tee -a /tmp/download_logs/s3_download.log
          DOWNLOAD_RESULT=${PIPESTATUS[0]}
          echo "[DEBUG] S3 download command result: $DOWNLOAD_RESULT" >> /tmp/download_logs/s3_debug.log
        else
          timeout 7200 aws s3 cp "$S3_URL" "$TEMP_DIR/bitcoin-data.tar.gz" --no-sign-request
          DOWNLOAD_RESULT=$?
        fi
        
      else
        # Regular HTTP download
        echo "[INFO] Using HTTPS protocol for download"
        # Use wget for more reliable downloads of large files with timeout
        HTTP_DOWNLOAD_CMD="wget -O \"$TEMP_DIR/bitcoin-data.tar.gz\" \"$BITCOIN_SNAPSHOT_PATH\" --progress=dot:giga --tries=3 --timeout=300 --continue"
        
        if [ "$SNAPSHOT_DEBUG_MODE" = "true" ]; then
          echo "[DEBUG] Running HTTP download command: $HTTP_DOWNLOAD_CMD" >> /tmp/download_logs/s3_debug.log
          # Execute directly without using eval
          timeout 7200 wget -O "$TEMP_DIR/bitcoin-data.tar.gz" "$BITCOIN_SNAPSHOT_PATH" --progress=dot:giga --tries=3 --timeout=300 --continue 2>&1 | tee -a /tmp/download_logs/http_download.log
          DOWNLOAD_RESULT=${PIPESTATUS[0]}
          echo "[DEBUG] HTTP download command result: $DOWNLOAD_RESULT" >> /tmp/download_logs/s3_debug.log
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
          DOWNLOAD_SUCCESS=true
          break
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
    echo "[INFO] Snapshot downloaded successfully. Validating file integrity..."
    
    # Verify file integrity - check that it's a valid tar.gz file
    if ! tar -tzf "$TEMP_DIR/bitcoin-data.tar.gz" >/dev/null 2>&1; then
      echo "[ERROR] Downloaded file is not a valid tar.gz archive"
      
      # If we backed up and moved original data, restore it
      if [ "$EXISTING_DATA" = true ] && [ -d "$BACKUP_DIR/blocks" ] && [ -d "$BACKUP_DIR/chainstate" ]; then
        echo "[INFO] Restoring original blockchain data from backup..."
        mkdir -p /bitcoin-data/bitcoin/
        mv "$BACKUP_DIR/blocks" "$BACKUP_DIR/chainstate" /bitcoin-data/bitcoin/
      fi
      
      echo "[INFO] Continuing with existing data or from scratch..."
    else
      echo "[INFO] Snapshot validated successfully. Extracting..."
    
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
    fi
  fi
  
  # Clean up
  rm -rf "$TEMP_DIR"
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