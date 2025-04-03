#!/bin/bash
# update-image-info.sh - Script to update Docker image information in README.md

# Markdown table template for image information
TABLE_START="### Available Images

| Image | Tags | Status | Size |
|-------|------|--------|------|"

# Check if jq is installed
if ! command -v jq &> /dev/null; then
    echo "Error: jq is required but not installed. Please install jq."
    exit 1
fi

# Get information about Bitcoin Core image tags
echo "Checking Docker Hub for Bitcoin Core ARM64 images..."
BITCOIN_TAGS=$(curl -s "https://hub.docker.com/v2/repositories/xcparty/bitcoind-arm64/tags?page_size=25" | jq -r '.results[].name' | sort -V)

# Get information about Counterparty Core image tags
echo "Checking Docker Hub for Counterparty Core ARM64 images..."
COUNTERPARTY_TAGS=$(curl -s "https://hub.docker.com/v2/repositories/xcparty/counterparty-core-arm64/tags?page_size=25" | jq -r '.results[].name' | sort -V)

# Generate table rows for Bitcoin Core tags
BITCOIN_ROWS=""
for tag in $BITCOIN_TAGS; do
    # Get image size (compressed)
    SIZE=$(curl -s "https://hub.docker.com/v2/repositories/xcparty/bitcoind-arm64/tags/$tag" | jq -r '.full_size' 2>/dev/null)
    
    # Convert size to MB and format
    if [ ! -z "$SIZE" ] && [ "$SIZE" != "null" ]; then
        # Convert bytes to MB
        SIZE_MB=$(echo "scale=1; $SIZE / 1024 / 1024" | bc)
        BITCOIN_ROWS+="| \`xcparty/bitcoind-arm64\` | \`$tag\` | ✅ Available | ~${SIZE_MB} MB |\n"
    else
        BITCOIN_ROWS+="| \`xcparty/bitcoind-arm64\` | \`$tag\` | ✅ Available | Unknown |\n"
    fi
done

# Generate table rows for Counterparty Core tags
COUNTERPARTY_ROWS=""
for tag in $COUNTERPARTY_TAGS; do
    # Get image size (compressed)
    SIZE=$(curl -s "https://hub.docker.com/v2/repositories/xcparty/counterparty-core-arm64/tags/$tag" | jq -r '.full_size' 2>/dev/null)
    
    # Convert size to MB and format
    if [ ! -z "$SIZE" ] && [ "$SIZE" != "null" ]; then
        # Convert bytes to MB
        SIZE_MB=$(echo "scale=1; $SIZE / 1024 / 1024" | bc)
        COUNTERPARTY_ROWS+="| \`xcparty/counterparty-core-arm64\` | \`$tag\` | ✅ Available | ~${SIZE_MB} MB |\n"
    else
        COUNTERPARTY_ROWS+="| \`xcparty/counterparty-core-arm64\` | \`$tag\` | ✅ Available | Unknown |\n"
    fi
done

# If no images found, provide placeholder information
if [ -z "$BITCOIN_ROWS" ]; then
    BITCOIN_ROWS="| \`xcparty/bitcoind-arm64\` | \`26.0\` | 🔄 Building | ~150 MB |\n"
fi

if [ -z "$COUNTERPARTY_ROWS" ]; then
    COUNTERPARTY_ROWS="| \`xcparty/counterparty-core-arm64\` | \`develop\` | 🔄 Building | ~800 MB |\n"
fi

# Combine all rows
TABLE="$TABLE_START
$BITCOIN_ROWS$COUNTERPARTY_ROWS"

# Get current note about build time
NOTE_PATTERN="> Note: .+"
README_CONTENT=$(cat ../README.md)
if [[ $README_CONTENT =~ $NOTE_PATTERN ]]; then
    NOTE="${BASH_REMATCH[0]}"
else
    NOTE="> Note: The Counterparty Core image build takes approximately 1 hour due to ARM64 cross-compilation."
fi

# Find the start and end of the current Available Images section
README_FILE="../README.md"
IMAGE_SECTION_START=$(grep -n "### Available Images" $README_FILE | cut -d: -f1)
IMAGE_TABLE_END=$(tail -n +$IMAGE_SECTION_START $README_FILE | grep -n "^$" | head -1 | cut -d: -f1)
IMAGE_TABLE_END=$((IMAGE_SECTION_START + IMAGE_TABLE_END - 1))

# Replace the content between these lines
sed -i.bak "${IMAGE_SECTION_START},${IMAGE_TABLE_END}c\\
### Available Images\\
\\
| Image | Tags | Status | Size |\\
|-------|------|--------|------|\\
${BITCOIN_ROWS}${COUNTERPARTY_ROWS}\\
\\
${NOTE}\\
" $README_FILE

# Clean up backup file
rm -f "${README_FILE}.bak"

echo "Docker Hub image information updated in README.md"