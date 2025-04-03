#!/bin/bash
# Main setup script for Counterparty ARM64

set -e

# Get the script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

# Source common functions
source "$SCRIPT_DIR/common.sh"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        --bitcoin-version)
        BITCOIN_VERSION="$2"
        shift
        shift
        ;;
        --counterparty-branch)
        COUNTERPARTY_BRANCH="$2"
        shift
        shift
        ;;
        --counterparty-tag)
        COUNTERPARTY_TAG="$2"
        shift
        shift
        ;;
        --data-dir)
        COUNTERPARTY_DOCKER_DATA="$2"
        shift
        shift
        ;;
        --repo-dir)
        COUNTERPARTY_REPO="$2"
        shift
        shift
        ;;
        --platform)
        PLATFORM="$2"
        shift
        shift
        ;;
        --help)
        echo "Usage: setup.sh [OPTIONS]"
        echo "Options:"
        echo "  --bitcoin-version VERSION      Bitcoin Core version (default: 26.0)"
        echo "  --counterparty-branch BRANCH   Counterparty branch (default: master)"
        echo "  --counterparty-tag TAG         Counterparty tag (overrides branch)"
        echo "  --data-dir DIR                 Data directory (default: /bitcoin-data)"
        echo "  --repo-dir DIR                 Counterparty repository directory"
        echo "  --platform PLATFORM            Deployment platform (aws, general)"
        echo "  --help                         Show this help message"
        exit 0
        ;;
        *)
        echo "Unknown option: $key"
        exit 1
        ;;
    esac
done

# Initial checks
check_dependencies docker docker-compose git curl

# Check for ARM64 architecture
check_arm64

# Set environment variables
set_env_vars

# Create the data directory structure
log_info "Creating data directory structure..."
ensure_data_structure

# Clone Counterparty repository if it doesn't exist
if [ ! -d "$COUNTERPARTY_REPO" ]; then
    log_info "Cloning Counterparty repository..."
    git clone https://github.com/CounterpartyXCP/counterparty-core.git "$COUNTERPARTY_REPO"
    
    # Check if tag is specified
    if [ -n "$COUNTERPARTY_TAG" ]; then
        cd "$COUNTERPARTY_REPO"
        git checkout "tags/$COUNTERPARTY_TAG" -b "tag-$COUNTERPARTY_TAG"
        log_success "Checked out Counterparty tag: $COUNTERPARTY_TAG"
    elif [ "$COUNTERPARTY_BRANCH" != "master" ]; then
        cd "$COUNTERPARTY_REPO"
        git checkout "$COUNTERPARTY_BRANCH"
        log_success "Checked out Counterparty branch: $COUNTERPARTY_BRANCH"
    fi
else
    log_info "Counterparty repository already exists at $COUNTERPARTY_REPO"
    
    # Update the repository
    cd "$COUNTERPARTY_REPO"
    git fetch
    
    # Check if tag is specified
    if [ -n "$COUNTERPARTY_TAG" ]; then
        git checkout "tags/$COUNTERPARTY_TAG" -b "tag-$COUNTERPARTY_TAG" 2>/dev/null || git checkout "tag-$COUNTERPARTY_TAG" 2>/dev/null || true
        log_success "Checked out Counterparty tag: $COUNTERPARTY_TAG"
    elif [ "$COUNTERPARTY_BRANCH" != "master" ]; then
        git checkout "$COUNTERPARTY_BRANCH" 2>/dev/null || git checkout -b "$COUNTERPARTY_BRANCH" origin/"$COUNTERPARTY_BRANCH" 2>/dev/null || true
        log_success "Checked out Counterparty branch: $COUNTERPARTY_BRANCH"
    else
        git checkout master
        git pull
        log_success "Updated Counterparty repository to latest master"
    fi
fi

# Create counterparty-node directory in home directory
COUNTERPARTY_NODE_DIR="$HOME/counterparty-node"
ensure_dir "$COUNTERPARTY_NODE_DIR"

# Copy Docker files
log_info "Copying Docker files to $COUNTERPARTY_NODE_DIR..."
cp "$REPO_DIR/docker/Dockerfile.bitcoind" "$COUNTERPARTY_NODE_DIR/"
cp "$REPO_DIR/docker/docker-compose.yml" "$COUNTERPARTY_NODE_DIR/"
cp "$REPO_DIR/docker/docker-compose.build.yml" "$COUNTERPARTY_NODE_DIR/"

# Copy startup script
log_info "Copying startup script..."
cp "$REPO_DIR/scripts/start-counterparty.sh" "$HOME/"
chmod +x "$HOME/start-counterparty.sh"

# Set up AWS-specific components if platform is AWS
if [ "$PLATFORM" = "aws" ]; then
    log_info "Setting up AWS-specific components..."
    
    # Copy AWS scripts
    cp "$REPO_DIR/aws/scripts/create-snapshot.sh" "$HOME/"
    cp "$REPO_DIR/aws/scripts/check-disk-usage.sh" "$HOME/"
    cp "$REPO_DIR/aws/scripts/check-sync-status.sh" "$HOME/"
    cp "$REPO_DIR/scripts/common.sh" "$HOME/"
    chmod +x "$HOME/create-snapshot.sh" "$HOME/check-disk-usage.sh" "$HOME/check-sync-status.sh" "$HOME/common.sh"
    
    # Set up cron jobs for maintenance
    (crontab -l 2>/dev/null; echo "0 2 * * 0 $HOME/create-snapshot.sh") | crontab -
    (crontab -l 2>/dev/null; echo "0 * * * * $HOME/check-disk-usage.sh") | crontab -
    
    log_success "AWS-specific setup complete"
    
    log_info "To check Bitcoin sync status, you can run:"
    log_info "  ~/check-sync-status.sh"
    log_info ""
    log_info "You can check disk usage with:"
    log_info "  ~/check-disk-usage.sh"
fi

# Add environment variables to .bashrc
log_info "Adding environment variables to ~/.bashrc..."
export_to_bashrc "COUNTERPARTY_DOCKER_DATA" "$COUNTERPARTY_DOCKER_DATA"
export_to_bashrc "COUNTERPARTY_REPO" "$COUNTERPARTY_REPO"
export_to_bashrc "COUNTERPARTY_BRANCH" "$COUNTERPARTY_BRANCH"
[ -n "$COUNTERPARTY_TAG" ] && export_to_bashrc "COUNTERPARTY_TAG" "$COUNTERPARTY_TAG"
export_to_bashrc "BITCOIN_VERSION" "$BITCOIN_VERSION"

# Save configuration
save_config

log_success "Setup complete!"
log_info "You can now start your Counterparty node with:"
log_info "~/start-counterparty.sh mainnet"
log_info ""
log_info "Other available profiles: testnet3, testnet4, regtest"