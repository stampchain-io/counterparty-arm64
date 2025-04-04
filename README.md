# Counterparty ARM64

[![Build and Push ARM64 Docker Images](https://github.com/stampchain-io/counterparty-arm64/actions/workflows/docker-build.yml/badge.svg)](https://github.com/stampchain-io/counterparty-arm64/actions/workflows/docker-build.yml)

This repository provides a complete solution for running Counterparty and Bitcoin Core on ARM64 architecture, specifically optimized for AWS Graviton instances with ST1 storage volumes.

## Features

* Native ARM64 support for both Bitcoin Core and Counterparty
* Pre-built Docker images for ARM64 architecture
* Fast deployment using Docker Hub images
* Optimized storage configuration for AWS ST1 volumes
* Version/branch selection for Counterparty and Bitcoin Core
* AWS CloudFormation template for one-click deployment
* Maintenance tools for backups and monitoring
* Bitcoin synchronization status monitoring
* Optional public RPC access mode for Counterparty API

## Prerequisites

### AWS CLI Setup

This project requires the AWS CLI to be installed and configured with appropriate credentials:

1. **Install AWS CLI**:
   ```bash
   # For Ubuntu/Debian
   sudo apt-get update && sudo apt-get install -y awscli jq
   
   # For macOS
   brew install awscli jq
   ```

2. **Configure AWS CLI**:
   ```bash
   aws configure
   ```
   You'll be prompted to enter:
   - AWS Access Key ID
   - AWS Secret Access Key
   - Default region (e.g., us-east-1)
   - Default output format (json recommended)

3. **Required Permissions**:
   Your AWS user must have permissions to:
   - Create and manage EC2 instances
   - Create and manage CloudFormation stacks
   - Create and manage security groups
   - Create and manage EBS volumes

## Quick Start

### Manual Setup

1. Clone this repository
   ```bash
   git clone https://github.com/stampchain-io/counterparty-arm64.git
   cd counterparty-arm64
   ```

2. Run the setup script
   ```bash
   # Make the script executable
   chmod +x scripts/setup.sh
   
   # Run setup with default options
   scripts/setup.sh
   
   # Or specify versions/branches
   scripts/setup.sh --bitcoin-version 26.0 --counterparty-branch master --data-dir /bitcoin-data
   ```

3. Start Counterparty
   ```bash
   # Start with mainnet (default)
   ~/start-counterparty.sh
   
   # Or explicitly specify the network
   ~/start-counterparty.sh mainnet
   
   # For testnet
   ~/start-counterparty.sh testnet3
   ```

### AWS Deployment

The AWS deployment uses pre-built Docker Hub images to significantly speed up the setup process. Instead of building containers on the instance, the CloudFormation template pulls optimized ARM64 images from Docker Hub.

#### Easy Deployment with Environment Configuration

1. Create your environment file:
   ```bash
   # Copy the example file
   cp .env.example .env
   
   # Edit the file with your specific values
   vi .env
   ```

   **Important**: You must provide at minimum:
   - `AWS_VPC_ID`: Your VPC ID
   - `AWS_SUBNET_ID`: Your subnet ID
   - `AWS_KEY_NAME`: Your EC2 key pair name
   
   **For Private Repositories**:
   If you're using a private GitHub repository for counterparty-arm64, you'll need to:
   - Create a GitHub Personal Access Token with repo access permissions
   - Add it to the .env file as `GITHUB_TOKEN=your_token_here`
   
   Example .env file with values for a private deployment:
   ```
   # VPC and Subnet Configuration
   AWS_VPC_ID=vpc-01234567890abcdef
   AWS_SUBNET_ID=subnet-01234567890abcdef
   
   # Security Group Configuration
   USE_EXISTING_SG=true
   EXISTING_SECURITY_GROUP_ID=sg-01234567890abcdef
   
   # EC2 Instance Configuration
   AWS_KEY_NAME=my-key-pair
   ```

2. Run the deployment script:
   ```bash
   # Create a new stack (auto-detects your IP address)
   ./aws/scripts/deploy.sh
   
   # Or specify a custom stack name
   ./aws/scripts/deploy.sh --stack-name my-counterparty-node
   
   # For updating an existing stack with new parameters
   ./aws/scripts/deploy.sh --stack-name my-counterparty-node --update-stack
   
   # For updating only the Counterparty version on an existing stack
   ./aws/scripts/deploy.sh --stack-name my-counterparty-node --update-counterparty-only
   ```

3. The script will:
   - Detect your public IP address automatically
   - Use your environment configuration
   - Create or update a CloudFormation stack
   - Wait for deployment to complete
   - Display connection information
   
4. The deployment process:
   - Pulls optimized Bitcoin Core image from `xcparty/bitcoind-arm64:[version]`
   - Pulls optimized Counterparty Core image from `xcparty/counterparty-core-arm64:[branch]`
   - Starts both Bitcoin and Counterparty services immediately after instance setup
   - Counterparty will automatically connect to Bitcoin when it becomes available
   
5. For upgrading Counterparty:
   - Update your .env file with the new Counterparty branch or tag
   - Run the update script with `--update-counterparty-only` flag
   - The script will update only the Counterparty-related parameters
   - Your Bitcoin data and configuration will remain intact

#### Manual Deployment Options

1. Launch using CloudFormation console:
   - Go to AWS CloudFormation console
   - Create a new stack
   - Upload the template from `aws/cloudformation/graviton-st1.yml`
   - Fill in the parameters and launch the stack

2. Or use the AWS CLI directly:
   ```bash
   aws cloudformation create-stack \
     --stack-name counterparty-arm64 \
     --template-body file://aws/cloudformation/graviton-st1.yml \
     --parameters \
       ParameterKey=KeyName,ParameterValue=your-key-name \
       ParameterKey=VpcId,ParameterValue=vpc-xxxxxxxx \
       ParameterKey=SubnetId,ParameterValue=subnet-xxxxxxxx \
       ParameterKey=YourIp,ParameterValue=your-ip/32
   ```

## Configuration Options

### Security Group Options

You can choose to create a new security group or use an existing one:

```bash
# In your .env file:

# Create a new security group (recommended for new deployments)
USE_EXISTING_SG=false 

# Or use an existing security group
USE_EXISTING_SG=true
EXISTING_SECURITY_GROUP_ID=sg-08094ebfd75d4873f

# Public RPC Access (optional)
# Set to true to allow public access to the Counterparty RPC API (port 4000)
# Warning: This opens your RPC to public access - use with caution
PUBLIC_RPC_ACCESS=false
```

When creating a new security group, it will automatically:
- Allow SSH access only from your IP address
- Open Bitcoin P2P port (8333) to the world for blockchain sync
- Open Counterparty P2P port (4001) to the world
- Restrict Bitcoin RPC (8332) to your IP address
- For Counterparty API (port 4000):
  - Allow access from your IP address
  - Allow access from all RFC1918 private IP ranges (10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16) which covers all standard AWS VPC CIDRs
  - Optionally open to the world if PUBLIC_RPC_ACCESS=true

### Ubuntu Version

You can choose which Ubuntu version to use:

```bash
# In your .env file:
UBUNTU_VERSION=24.04  # Default, Ubuntu 24.04 LTS (Noble Numbat)
# or
UBUNTU_VERSION=22.04  # Ubuntu 22.04 LTS (Jammy Jellyfish)
```

### Bitcoin Core Version

You can specify which Bitcoin Core version to use:

```bash
scripts/setup.sh --bitcoin-version 26.0
```

### Counterparty Version and Network

You can specify which Counterparty branch or tag to use:

```bash
# Use a specific branch
scripts/setup.sh --counterparty-branch develop

# Use a specific tag
scripts/setup.sh --counterparty-tag v10.10.1
```

You can also set the default network in your environment file:

```bash
# In your .env file:
NETWORK_PROFILE=mainnet  # Default
# Other options: testnet3, testnet4, regtest
```

Or specify it when starting the service:

```bash
# Start with a specific network profile
~/start-counterparty.sh testnet3
```

### Data Directory

You can specify where the blockchain data will be stored:

```bash
scripts/setup.sh --data-dir /path/to/data
```

## Docker Hub Images

This project uses pre-built Docker images for faster deployment on ARM64 systems:

- **Bitcoin Core**: [`xcparty/bitcoind-arm64`](https://hub.docker.com/r/xcparty/bitcoind-arm64)
  - Version tags match Bitcoin Core releases (e.g., `26.0`)
  - Optimized for ARM64 architecture
  - Includes all necessary dependencies

- **Counterparty Core**: [`xcparty/counterparty-core-arm64`](https://hub.docker.com/r/xcparty/counterparty-core-arm64)
  - Branch/tag tags match Counterparty Core branches (e.g., `develop`, `master`)
  - Built with ARM64 native support
  - Includes all Python dependencies

### Building Custom Images

You can build custom ARM64 Docker images using our GitHub Actions workflow:

1. Go to the repository's Actions tab
2. Select the "Build ARM64 Docker Images" workflow
3. Click "Run workflow"
4. Choose your build parameters:
   - **Bitcoin version**: The Bitcoin Core version to build
   - **Counterparty branch**: The Counterparty Core branch or tag to build
   - **Network profile**: The network to optimize for
   - **Build mode**:
     - `standard`: Basic build with QEMU emulation (all GitHub plans)
     - `parallel`: Parallel matrix builds (Team/Business plans)
     - `optimized`: Advanced caching and optimizations (Team/Business plans)

The workflow automatically uploads template files as artifacts and updates the Docker Hub image status below.

### Available Images

_This section is automatically updated by GitHub Actions showing current Docker Hub image status._

| Image | Tags | Status | Size |
|-------|------|--------|------|
| `xcparty/bitcoind-arm64` | `26.0` | ✅ Available | ~150 MB |
| `xcparty/counterparty-core-arm64` | `develop` | 🔄 Building | ~800 MB |

> Note: The Counterparty Core image build takes approximately 1 hour due to ARM64 cross-compilation. Last updated: 2025-04-03 22:55 UTC

These images are built through our GitHub Actions workflow. For more information about the build process, see [ARM64_BUILD.md](ARM64_BUILD.md).

## Directory Structure

```
counterparty-arm64/
├── docker/                        # Docker configuration
│   ├── Dockerfile.bitcoind        # ARM64 Bitcoin Core Dockerfile
│   ├── docker-compose.yml         # Main Docker Compose configuration
│   └── docker-compose.build.yml   # Build configuration
├── scripts/                       # Setup and utility scripts
│   ├── setup.sh                   # Main setup script
│   ├── start-counterparty.sh      # Service control script
│   └── common.sh                  # Common functions
├── aws/                           # AWS-specific resources
│   ├── cloudformation/            # CloudFormation templates
│   │   └── graviton-st1.yml       # Template for Graviton with ST1
│   └── scripts/                   # AWS maintenance scripts
│       ├── create-snapshot.sh     # Backup script
│       ├── check-disk-usage.sh    # Disk monitoring script
│       ├── check-bitcoin-sync.sh  # Bitcoin sync status script
│       ├── monitor-bitcoin.sh     # Automated Bitcoin monitoring
│       └── deploy.sh              # CloudFormation deployment script
├── .github/                       # GitHub configuration
│   └── workflows/                 # GitHub Actions workflows
│       └── docker-build.yml       # ARM64 Docker image build workflow
└── docs/                          # Documentation
```

## Maintenance

### Backups

For AWS deployments, an automated snapshot system is included:

- Daily snapshots of the ST1 data volume
- Retention of the last 7 snapshots
- Configurable through the AWS scripts

### Disk Usage Monitoring

A monitoring script checks disk usage and can send alerts:

```bash
# Set up SNS notifications
export SNS_TOPIC_ARN="arn:aws:sns:region:account-id:topic-name"
```

### Bitcoin Sync Status Monitoring

The deployment includes tools to monitor Bitcoin synchronization status:

#### Default RPC Credentials

The Docker containers use the following RPC credentials by default:
- Username: `rpc`
- Password: `rpc`

These credentials are configured in the docker-compose.yml file and are used for communication between the Bitcoin and Counterparty containers.

#### Check Bitcoin Sync Status

A simple script is included to check the synchronization status of your Bitcoin node:

```bash
# Check the sync status
~/check-sync-status.sh
```

The script will display:
- Current block height
- Chain headers height
- Synchronization progress percentage
- Synchronization status (syncing or synchronized)
- If syncing, the number of blocks remaining
- Recent Counterparty logs

#### Disk Usage Monitoring

Monitor disk space usage with:

```bash
# Check disk usage
~/check-disk-usage.sh
```

This is run as a cron job every hour to ensure sufficient disk space is available.

To customize the RPC credentials, edit the docker-compose.yml file and update all instances of the credentials consistently.

## Troubleshooting

See the [Troubleshooting Guide](docs/TROUBLESHOOTING.md) for common issues and solutions.

## License

MIT License