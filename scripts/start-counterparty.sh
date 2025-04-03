#!/bin/bash
# Script to start Counterparty services

set -e

# Get the script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

# Source common functions if available in the repo
if [ -f "$SCRIPT_DIR/common.sh" ]; then
    source "$SCRIPT_DIR/common.sh"
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

# Change to counterparty-node directory
cd "$HOME/counterparty-node" || { log_error "counterparty-node directory not found!"; exit 1; }

# Load config if available
CONFIG_DIR=${CONFIG_DIR:-$HOME/.counterparty-arm64}
if [ -f "$CONFIG_DIR/config.env" ]; then
    source "$CONFIG_DIR/config.env"
fi

# Default profile is mainnet unless specified differently
# First use argument if provided, then env var, then default to mainnet
PROFILE=${1:-${NETWORK_PROFILE:-mainnet}}
BUILD_FROM_SOURCE=${2:-false}

# Ensure the COUNTERPARTY_DOCKER_DATA environment variable is set
if [ -z "$COUNTERPARTY_DOCKER_DATA" ]; then
    export COUNTERPARTY_DOCKER_DATA=/bitcoin-data
    log_info "COUNTERPARTY_DOCKER_DATA wasn't set. Using default: $COUNTERPARTY_DOCKER_DATA"
fi

# Make sure the data directory exists
mkdir -p "${COUNTERPARTY_DOCKER_DATA}/counterparty-docker-data"

log_info "Starting Counterparty services with profile: $PROFILE"
log_info "Building from source: $BUILD_FROM_SOURCE"
log_info "Data directory: $COUNTERPARTY_DOCKER_DATA"

# For ARM64/Graviton instances, we need to build from source
ARCH=$(uname -m)
if [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
    log_info "ARM64 architecture detected. Using custom ARM64 setup."
    
    # First clean any existing containers and images
    log_info "Cleaning up existing containers..."
    docker compose down 2>/dev/null || true
    docker rm -f $(docker ps -a -q -f name=bitcoind) 2>/dev/null || true
    docker rm -f $(docker ps -a -q -f name=counterparty-core) 2>/dev/null || true
    
    # Build both Bitcoin and Counterparty images for ARM64
    log_info "Building ARM64-compatible images..."
    
    # Set environment variables for the build
    export BITCOIN_VERSION=${BITCOIN_VERSION:-26.0}
    export COUNTERPARTY_BRANCH=${COUNTERPARTY_BRANCH:-master}
    export COUNTERPARTY_TAG=${COUNTERPARTY_TAG:-}
    export COUNTERPARTY_REPO=${COUNTERPARTY_REPO:-${COUNTERPARTY_DOCKER_DATA}/repo/counterparty-core}
    
    # Build the images
    docker compose -f docker-compose.yml -f docker-compose.build.yml build
    
    # Start the services
    log_info "Starting services with profile: $PROFILE"
    docker compose -f docker-compose.yml --profile $PROFILE up -d
else
    # For x86_64 architecture, use standard setup
    if [ "$BUILD_FROM_SOURCE" = "true" ]; then
        log_info "Building Counterparty image from source..."
        docker compose -f docker-compose.yml -f docker-compose.build.yml --profile $PROFILE up -d
    else
        log_info "Using Docker Hub images..."
        docker compose --profile $PROFILE up -d
    fi
fi

log_success "Services started. Docker containers:"
docker ps