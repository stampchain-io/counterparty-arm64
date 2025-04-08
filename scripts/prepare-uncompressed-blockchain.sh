#!/bin/bash
# Script to prepare uncompressed blockchain data
set -e

# Configuration
SOURCE_BUCKET="bitcoin-blockchain-snapshots"
SOURCE_OBJECT="bitcoin-data-live-20250406-1347.tar.gz"
DEST_BUCKET="bitcoin-blockchain-snapshots"
DEST_PREFIX="uncompressed"
WORK_DIR="/blockchain-data"

# Usage info
usage() {
  echo "Usage: $0 [OPTIONS]"
  echo "Prepares uncompressed blockchain data and uploads to S3"
  echo ""
  echo "Options:"
  echo "  --source-bucket BUCKET    Source S3 bucket for compressed blockchain (default: bitcoin-blockchain-snapshots)"
  echo "  --source-object OBJECT    Object key for compressed blockchain (default: bitcoin-data-live-20250406-1347.tar.gz)"
  echo "  --dest-bucket BUCKET      Destination S3 bucket for uncompressed data (default: bitcoin-blockchain-snapshots)"
  echo "  --dest-prefix PREFIX      Prefix in destination bucket (default: uncompressed)"
  echo "  --work-dir DIR            Working directory (default: /blockchain-data)"
  echo "  --help                    Display this help and exit"
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-bucket)
      SOURCE_BUCKET="$2"
      shift 2
      ;;
    --source-object)
      SOURCE_OBJECT="$2"
      shift 2
      ;;
    --dest-bucket)
      DEST_BUCKET="$2"
      shift 2
      ;;
    --dest-prefix)
      DEST_PREFIX="$2"
      shift 2
      ;;
    --work-dir)
      WORK_DIR="$2"
      shift 2
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

# Create working directories
echo "Setting up working directories..."
mkdir -p "$WORK_DIR/temp"
mkdir -p "$WORK_DIR/extracted"
mkdir -p "$WORK_DIR/upload"

# Configure AWS CLI for faster data transfer
echo "Configuring AWS CLI for optimal performance..."
mkdir -p ~/.aws
cat > ~/.aws/config << 'EOF'
[default]
s3 = 
    max_concurrent_requests = 100
    max_queue_size = 10000
    multipart_threshold = 64MB
    multipart_chunksize = 64MB
EOF

# Download the compressed blockchain data
echo "Downloading compressed blockchain from s3://$SOURCE_BUCKET/$SOURCE_OBJECT"
aws s3 cp "s3://$SOURCE_BUCKET/$SOURCE_OBJECT" "$WORK_DIR/temp/bitcoin-data.tar.gz" --no-sign-request

# Get file size info
COMPRESSED_SIZE=$(du -sh "$WORK_DIR/temp/bitcoin-data.tar.gz" | cut -f1)
echo "Downloaded compressed blockchain data ($COMPRESSED_SIZE)"

# Extract the blockchain data
echo "Extracting blockchain data (this may take some time)..."
mkdir -p "$WORK_DIR/extracted"
tar -xf "$WORK_DIR/temp/bitcoin-data.tar.gz" -C "$WORK_DIR/extracted"

# Check extraction result
if [ ! -f "$WORK_DIR/extracted/blocks/blk00000.dat" ] || [ ! -d "$WORK_DIR/extracted/chainstate" ]; then
  echo "ERROR: Extraction failed or incomplete. Missing essential blockchain files."
  exit 1
fi

EXTRACTED_SIZE=$(du -sh "$WORK_DIR/extracted" | cut -f1)
echo "Extraction complete. Extracted size: $EXTRACTED_SIZE"

# Prepare for upload
echo "Preparing blockchain directory structure for upload..."
mkdir -p "$WORK_DIR/upload"
cp -r "$WORK_DIR/extracted/blocks" "$WORK_DIR/upload/"
cp -r "$WORK_DIR/extracted/chainstate" "$WORK_DIR/upload/"

# Calculate MD5 hash of key files for integrity verification
echo "Calculating MD5 hashes of blockchain files for verification..."
find "$WORK_DIR/upload" -type f -name "blk*.dat" -o -name "rev*.dat" | sort | head -10 | xargs md5sum > "$WORK_DIR/upload/block_files_md5.txt"

# Upload to S3
echo "Uploading uncompressed blockchain data to S3..."
echo "Destination: s3://$DEST_BUCKET/$DEST_PREFIX/"

# Upload with metadata
aws s3 sync "$WORK_DIR/upload/" "s3://$DEST_BUCKET/$DEST_PREFIX/" \
  --metadata "source=$SOURCE_OBJECT,prepared=$(date -u +%Y%m%d),md5-verified=true"

echo "Verifying upload..."
aws s3 ls "s3://$DEST_BUCKET/$DEST_PREFIX/" --recursive --human-readable | head

echo ""
echo "=========================================================="
echo "Upload complete! Uncompressed blockchain data is available at:"
echo "s3://$DEST_BUCKET/$DEST_PREFIX/"
echo ""
echo "Use this path in your CloudFormation template with parameter:"
echo "--bitcoin-snapshot-path s3://$DEST_BUCKET/$DEST_PREFIX"
echo "=========================================================="