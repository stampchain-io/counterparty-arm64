# Testing Guide for Counterparty ARM64

This document outlines the steps to test the Counterparty ARM64 deployment before pushing to GitHub.

## Pre-Testing Checklist

1. Ensure you have AWS CLI installed and configured
2. Ensure you have the required AWS permissions
3. Verify all files have the correct permissions:
   ```bash
   chmod +x scripts/*.sh
   chmod +x aws/scripts/*.sh
   ```

## Step 1: Local Environment Testing

First, test that the scripts work correctly in your local environment:

```bash
# Check that common.sh functions work
source scripts/common.sh
check_arm64
log_info "Testing logging functions"

# Check the dependency checker
check_dependencies aws jq curl
```

## Step 2: AWS Deployment Testing

1. **Create or verify your `.env` file**:
   ```bash
   cp .env.example .env
   # Edit .env to include your actual AWS details
   vi .env
   ```

2. **Run deployment script with `--dry-run` (not actually creating resources)**:
   ```bash
   # This will validate the CloudFormation template without deploying
   AWS_PROFILE=your-profile aws cloudformation validate-template \
     --template-body file://$(pwd)/aws/cloudformation/graviton-st1.yml
   ```

3. **Full deployment test**:
   ```bash
   ./aws/scripts/deploy.sh --stack-name counterparty-test
   ```

4. **Monitor the deployment**:
   - Check CloudFormation console for stack status
   - When complete, SSH into the instance and verify services are running
   ```bash
   # SSH to instance (get IP from CloudFormation outputs)
   ssh ubuntu@<instance-ip>
   
   # Check Docker containers
   docker ps
   
   # Check logs
   docker logs -f counterparty-core-bitcoind-1
   docker logs -f counterparty-core-counterparty-core-1
   ```

5. **Test cleanup**:
   ```bash
   # Delete the test stack when done
   aws cloudformation delete-stack --stack-name counterparty-test
   ```

## Step 3: GitHub Repository Setup

After successful testing, follow these steps to create the GitHub repository:

1. **Initialize Git repository**:
   ```bash
   cd /path/to/counterparty-arm64
   git init
   ```

2. **Create `.gitignore` file**:
   ```bash
   # This should already exist but verify it contains:
   cat .gitignore
   ```

3. **Make initial commit**:
   ```bash
   git add .
   git commit -m "Initial commit: Counterparty ARM64 deployment"
   ```

4. **Create GitHub repository**:
   ```bash
   # Using GitHub CLI
   gh repo create stampchain-io/counterparty-arm64 --private --description "Deploy Counterparty on ARM64 architecture, optimized for AWS Graviton instances"
   
   # Or manually create via GitHub website
   ```

5. **Push to GitHub**:
   ```bash
   git remote add origin https://github.com/stampchain-io/counterparty-arm64.git
   git push -u origin main
   ```

## Additional Testing Notes

### Ubuntu Version Testing

To test with both Ubuntu versions:

```bash
# Set to 22.04 in .env
sed -i 's/UBUNTU_VERSION=24.04/UBUNTU_VERSION=22.04/' .env
./aws/scripts/deploy.sh --stack-name counterparty-2204

# Reset to 24.04
sed -i 's/UBUNTU_VERSION=22.04/UBUNTU_VERSION=24.04/' .env
```

### Security Group Testing

Test both options:

```bash
# Using existing security group
sed -i 's/USE_EXISTING_SG=false/USE_EXISTING_SG=true/' .env
./aws/scripts/deploy.sh --stack-name counterparty-existing-sg

# Creating new security group
sed -i 's/USE_EXISTING_SG=true/USE_EXISTING_SG=false/' .env
./aws/scripts/deploy.sh --stack-name counterparty-new-sg
```

### Branch vs Tag Testing

Test specifying both branch and tag:

```bash
# Using branch only
sed -i 's/COUNTERPARTY_TAG=.*/COUNTERPARTY_TAG=/' .env
sed -i 's/COUNTERPARTY_BRANCH=.*/COUNTERPARTY_BRANCH=develop/' .env

# Using tag (which should override branch)
sed -i 's/COUNTERPARTY_TAG=.*/COUNTERPARTY_TAG=v10.10.1/' .env
sed -i 's/COUNTERPARTY_BRANCH=.*/COUNTERPARTY_BRANCH=develop/' .env
```

## Final Verification

Before considering the testing complete:

1. Verify instance can connect to the Internet and download packages
2. Verify Bitcoin node can sync with the blockchain
3. Verify Counterparty services are running correctly
4. Verify data is being stored on the ST1 volume
5. Verify proper error handling when incorrect parameters are provided