#!/bin/bash
# Common functions used across scripts

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Log levels
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running on ARM64
check_arm64() {
    local arch=$(uname -m)
    if [[ "$arch" != "aarch64" && "$arch" != "arm64" ]]; then
        log_warning "This setup is optimized for ARM64 architecture."
        log_warning "Current architecture: $arch"
        read -p "Do you want to continue anyway? [y/N] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    else
        log_info "ARM64 architecture detected."
    fi
}

# Check for dependencies
check_dependencies() {
    local missing_deps=()
    for cmd in "$@"; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_deps+=("$cmd")
        fi
    done
    
    if [ ${#missing_deps[@]} -ne 0 ]; then
        log_error "Missing dependencies: ${missing_deps[*]}"
        log_info "Please install these dependencies and try again."
        exit 1
    fi
}

# Create directory if it doesn't exist
ensure_dir() {
    if [ ! -d "$1" ]; then
        mkdir -p "$1"
        log_info "Created directory: $1"
    fi
}

# Check if a Docker image exists
docker_image_exists() {
    docker image inspect "$1" &> /dev/null
}

# Get the script directory
get_script_dir() {
    dirname "$(readlink -f "$0")"
}

# Set environment variables
set_env_vars() {
    # Base directory for data
    export COUNTERPARTY_DOCKER_DATA=${COUNTERPARTY_DOCKER_DATA:-/bitcoin-data}
    
    # Repository for counterparty
    export COUNTERPARTY_REPO=${COUNTERPARTY_REPO:-${COUNTERPARTY_DOCKER_DATA}/repo/counterparty-core}
    
    # Branch/tag settings
    export COUNTERPARTY_BRANCH=${COUNTERPARTY_BRANCH:-master}
    export COUNTERPARTY_TAG=${COUNTERPARTY_TAG:-}
    export BITCOIN_VERSION=${BITCOIN_VERSION:-26.0}
    
    # Path settings
    export CONFIG_DIR=${CONFIG_DIR:-$HOME/.counterparty-arm64}
    
    # Log exports
    log_info "Using data directory: $COUNTERPARTY_DOCKER_DATA"
    log_info "Using Counterparty repository: $COUNTERPARTY_REPO"
    
    if [ -n "$COUNTERPARTY_TAG" ]; then
        log_info "Using Counterparty tag: $COUNTERPARTY_TAG"
    else
        log_info "Using Counterparty branch: $COUNTERPARTY_BRANCH"
    fi
    
    log_info "Using Bitcoin version: $BITCOIN_VERSION"
}

# Save configuration
save_config() {
    ensure_dir "$CONFIG_DIR"
    cat > "$CONFIG_DIR/config.env" << EOF
# Counterparty ARM64 Configuration
# Generated on $(date)

# Data Directory
COUNTERPARTY_DOCKER_DATA=$COUNTERPARTY_DOCKER_DATA

# Repository
COUNTERPARTY_REPO=$COUNTERPARTY_REPO

# Version Control
COUNTERPARTY_BRANCH=$COUNTERPARTY_BRANCH
COUNTERPARTY_TAG=$COUNTERPARTY_TAG
BITCOIN_VERSION=$BITCOIN_VERSION
EOF
    log_success "Configuration saved to $CONFIG_DIR/config.env"
}

# Load configuration if it exists
load_config() {
    if [ -f "$CONFIG_DIR/config.env" ]; then
        log_info "Loading configuration from $CONFIG_DIR/config.env"
        source "$CONFIG_DIR/config.env"
    fi
}

# Function to handle Docker container cleanup
cleanup_containers() {
    log_info "Cleaning up existing containers..."
    docker compose down 2>/dev/null || true
    docker rm -f $(docker ps -a -q -f name=bitcoind) 2>/dev/null || true
    docker rm -f $(docker ps -a -q -f name=counterparty-core) 2>/dev/null || true
}

# Ensure data directory structure
ensure_data_structure() {
    ensure_dir "${COUNTERPARTY_DOCKER_DATA}"
    ensure_dir "${COUNTERPARTY_DOCKER_DATA}/counterparty-docker-data"
    ensure_dir "${COUNTERPARTY_DOCKER_DATA}/repo"
    
    # Ensure permissions are correct
    if [ -d "${COUNTERPARTY_DOCKER_DATA}" ]; then
        chmod -R 755 "${COUNTERPARTY_DOCKER_DATA}"
    fi
}

# Export variables to ~/.bashrc
export_to_bashrc() {
    local var_name="$1"
    local var_value="$2"
    
    # Check if already in .bashrc
    if grep -q "export ${var_name}=" ~/.bashrc; then
        # Update existing value
        sed -i "s|export ${var_name}=.*|export ${var_name}=${var_value}|" ~/.bashrc
    else
        # Add new export
        echo "export ${var_name}=${var_value}" >> ~/.bashrc
    fi
    
    # Export in current session
    export "${var_name}"="${var_value}"
}