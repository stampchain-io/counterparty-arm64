# Counterparty ARM64

This repository provides a complete solution for running Counterparty and Bitcoin Core on ARM64 architecture, specifically optimized for AWS Graviton instances with ST1 storage volumes.

## Features

* Native ARM64 support for both Bitcoin Core and Counterparty
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
   ~/start-counterparty.sh mainnet
   ```

### AWS Deployment

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
   # The script will auto-detect your IP address
   ./aws/scripts/deploy.sh
   
   # Or specify a custom stack name
   ./aws/scripts/deploy.sh --stack-name my-counterparty-node
   ```

3. The script will:
   - Detect your public IP address automatically
   - Use your environment configuration
   - Create a CloudFormation stack
   - Wait for deployment to complete
   - Display connection information

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

### Counterparty Version

You can specify which Counterparty branch or tag to use:

```bash
# Use a specific branch
scripts/setup.sh --counterparty-branch develop

# Use a specific tag
scripts/setup.sh --counterparty-tag v10.10.1
```

### Data Directory

You can specify where the blockchain data will be stored:

```bash
scripts/setup.sh --data-dir /path/to/data
```

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

```bash
# Basic sync status check
~/check-bitcoin-sync.sh --user rpc --pass rpc

# Detailed sync status with more information
~/check-bitcoin-sync.sh --user rpc --pass rpc --verbose
```

#### Automated Monitoring

Set up automatic monitoring that runs every 10 minutes and logs the status:

```bash
# Set up monitoring (runs every 10 minutes)
~/monitor-bitcoin.sh --user rpc --pass rpc --setup-cron

# Set up monitoring with email alerts
~/monitor-bitcoin.sh --user rpc --pass rpc --email your@email.com --setup-cron

# Check the logs
cat /var/log/bitcoin-monitor.log
```

To customize the RPC credentials, edit the docker-compose.yml file and update all instances of the credentials consistently.

## Troubleshooting

See the [Troubleshooting Guide](docs/TROUBLESHOOTING.md) for common issues and solutions.

## License

MIT License