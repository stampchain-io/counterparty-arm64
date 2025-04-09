# Launching Your Counterparty Node with Blocks-Only Bootstrap

This quick guide shows how to deploy your Counterparty node with the new blocks-only bootstrap method for faster initial setup.

## Quick Launch Command

```bash
# Clone the repository
git clone https://github.com/stampchain-io/counterparty-arm64.git
cd counterparty-arm64

# Create a .env file with your AWS details
cat > .env << EOF
# VPC and Subnet Configuration
AWS_VPC_ID=vpc-12345abcdef
AWS_SUBNET_ID=subnet-12345abcdef

# EC2 Instance Configuration
AWS_KEY_NAME=your-key-name

# Using c6g.large for fastest initial sync
AWS_INSTANCE_TYPE=c6g.large
EOF

# Launch the stack with blocks-only bootstrap
./aws/scripts/deploy.sh
```

## Key Benefits

- **Faster Deployment**: Only 30-45 minutes for initial sync on c6g.large
- **Optimized Performance**: Auto-tunes for your instance type
- **Lower Bandwidth**: Downloads only blocks data (~604GB)
- **No Extraction**: Files are synced directly, no tar extraction needed
- **Lower Cost**: Uses 700GB ST1 volume ($31.50/month) instead of 1TB ($45/month)

## What's happening?

1. CloudFormation stack launches a c6g.large instance
2. The bootstrap.sh script detects this is a blocks-only bootstrap
3. It downloads only the block files directly from S3
4. It optimizes Bitcoin configuration based on your instance type
5. Bitcoin rebuilds the UTXO set (chainstate) during initial sync

## Monitoring Progress

```bash
# SSH to your instance
ssh ubuntu@YOUR_INSTANCE_IP

# Check sync status
./check-sync-status.sh
```

## For More Details

See the full documentation in [docs/BLOCKS_ONLY_BOOTSTRAP.md](docs/BLOCKS_ONLY_BOOTSTRAP.md)