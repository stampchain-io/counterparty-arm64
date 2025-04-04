# ARM64 Build Pipeline for Counterparty

This document describes how to build and use the ARM64 Docker images for Counterparty.

## Overview

This project includes a GitHub Actions workflow to build and push Docker images for ARM64 architecture:

1. **Bitcoin Core ARM64 Image**: Built from the official Bitcoin Core binaries for ARM64
2. **Counterparty Core ARM64 Image**: Built from the official Counterparty Core repository

## Building ARM64 Images with GitHub Actions

The repository contains a consolidated workflow that can be triggered manually to build the ARM64 images:

1. Go to the GitHub repository → Actions → "Build ARM64 Docker Images"
2. Click "Run workflow"
3. Enter the parameters:
   - **Bitcoin version**: Version of Bitcoin Core to build (e.g., "26.0")
   - **Counterparty branch**: Branch or tag of Counterparty Core to build (e.g., "develop" or "v10.0.0")
   - **Network profile**: Network to use (mainnet, testnet3, testnet4, regtest)
   - **Build mode**: How to optimize the build:
     - `standard`: Basic build using QEMU emulation (works on all GitHub plans)
     - `parallel`: Parallel matrix builds (for Team/Business plans)
     - `optimized`: Advanced caching and optimization (for Team/Business plans)
4. Click "Run workflow" to start the build

The workflow will:
- Build the Bitcoin Core ARM64 image and push it to Docker Hub as `xcparty/bitcoind-arm64:[version]`
- Build the Counterparty Core ARM64 image and push it to Docker Hub as `xcparty/counterparty-core-arm64:[branch]`

## Using the ARM64 Images

### Local Use

To use these images locally on an ARM64 system:

```bash
# Pull the images
docker pull xcparty/bitcoind-arm64:26.0
docker pull xcparty/counterparty-core-arm64:develop

# Create a .env file with configuration
cat > .env << EOL
DOCKERHUB_IMAGE_BITCOIND=xcparty/bitcoind-arm64
DOCKERHUB_IMAGE_COUNTERPARTY=xcparty/counterparty-core-arm64
BITCOIN_VERSION=26.0
COUNTERPARTY_BRANCH=develop
NETWORK_PROFILE=mainnet
COUNTERPARTY_DOCKER_DATA=/path/to/data
EOL

# Start the containers
docker compose --profile mainnet up -d
```

### AWS Deployment

The AWS CloudFormation template is configured to use the Docker Hub images. When deploying:

1. The template will pull the pre-built images from Docker Hub
2. No building happens on the EC2 instance, saving time and resources
3. Both Bitcoin and Counterparty containers start immediately 
4. Counterparty automatically connects to Bitcoin when it becomes available

## Environment Variables

Add these variables to your .env file to configure the deployment:

```
# Docker Hub Configuration
DOCKERHUB_USERNAME=xcparty
DOCKERHUB_IMAGE_BITCOIND=xcparty/bitcoind-arm64
DOCKERHUB_IMAGE_COUNTERPARTY=xcparty/counterparty-core-arm64
BITCOIN_VERSION=26.0
COUNTERPARTY_BRANCH=develop
```

## Security

- The Docker Hub credentials are stored securely in GitHub Secrets
- The .env file is in .gitignore to prevent credentials from being committed

## Tags and Branches

- Each branch/tag of Counterparty Core can be built separately
- Each version of Bitcoin Core can be built separately
- Use specific tags in production environments for stability
- Use latest tags for development and testing