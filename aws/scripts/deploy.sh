#!/bin/bash
# Script to deploy Counterparty ARM64 to AWS using CloudFormation

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
source "$REPO_DIR/scripts/common.sh"

# Check dependencies
check_dependencies aws curl jq

# Check AWS CLI configuration
log_info "Checking AWS CLI configuration..."
if ! aws sts get-caller-identity &>/dev/null; then
    log_error "AWS CLI is not properly configured. Please run 'aws configure' or set proper AWS environment variables."
    log_info "You need valid AWS credentials with permissions to:"
    log_info "  - Create and manage EC2 instances"
    log_info "  - Create and manage CloudFormation stacks"
    log_info "  - Create and manage security groups"
    log_info "  - Create and manage EBS volumes"
    exit 1
fi

# Get account info (without displaying sensitive info)
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
AWS_ACCOUNT_ID_MASKED="${AWS_ACCOUNT_ID:0:4}...${AWS_ACCOUNT_ID:(-4)}"
log_success "AWS CLI is properly configured for account: $AWS_ACCOUNT_ID_MASKED"

# Verify region is set
if [ -z "$AWS_REGION" ]; then
    # Try to get it from AWS CLI config
    AWS_REGION=$(aws configure get region)
    if [ -z "$AWS_REGION" ]; then
        log_error "AWS region is not set. Please specify AWS_REGION in your .env file or AWS CLI config."
        exit 1
    fi
    log_info "Using AWS region from AWS CLI config: $AWS_REGION"
fi

# Load environment variables from .env file
ENV_FILE="$REPO_DIR/.env"
if [ -f "$ENV_FILE" ]; then
    log_info "Loading environment variables from $ENV_FILE"
    source "$ENV_FILE"
else
    log_warning "No .env file found. Using default values or environment variables."
    log_info "You can create a .env file by copying .env.example and filling in your values."
fi

# Set default values for required parameters
AWS_REGION=${AWS_REGION:-"us-east-1"}
AWS_VPC_ID=${AWS_VPC_ID:-""}
AWS_SUBNET_ID=${AWS_SUBNET_ID:-""}
USE_EXISTING_SG=${USE_EXISTING_SG:-"false"}
EXISTING_SECURITY_GROUP_ID=${EXISTING_SECURITY_GROUP_ID:-""}
PUBLIC_RPC_ACCESS=${PUBLIC_RPC_ACCESS:-"false"}
AWS_KEY_NAME=${AWS_KEY_NAME:-""}
AWS_INSTANCE_TYPE=${AWS_INSTANCE_TYPE:-"m7g.xlarge"}
ROOT_VOLUME_SIZE=${ROOT_VOLUME_SIZE:-100}
DATA_VOLUME_SIZE=${DATA_VOLUME_SIZE:-1000}
BITCOIN_VERSION=${BITCOIN_VERSION:-"26.0"}
COUNTERPARTY_BRANCH=${COUNTERPARTY_BRANCH:-"master"}
UBUNTU_VERSION=${UBUNTU_VERSION:-"24.04"}
STACK_NAME=${STACK_NAME:-"counterparty-arm64"}

# Detect the current public IP address if not provided
if [ -z "$YOUR_IP" ]; then
    log_info "Detecting your current public IP address..."
    YOUR_IP=$(curl -s https://api.ipify.org)
    if [ -z "$YOUR_IP" ] || [ "$YOUR_IP" = "undefined" ]; then
        log_error "Failed to detect your public IP address. Please set YOUR_IP in your .env file."
        exit 1
    fi
    YOUR_IP="$YOUR_IP/32"
    log_info "Detected IP: $YOUR_IP"
fi

# Parse command line arguments
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        --stack-name)
        STACK_NAME="$2"
        shift
        shift
        ;;
        --vpc-id)
        AWS_VPC_ID="$2"
        shift
        shift
        ;;
        --subnet-id)
        AWS_SUBNET_ID="$2"
        shift
        shift
        ;;
        --security-group-id)
        AWS_SECURITY_GROUP_ID="$2"
        shift
        shift
        ;;
        --key-name)
        AWS_KEY_NAME="$2"
        shift
        shift
        ;;
        --your-ip)
        YOUR_IP="$2"
        shift
        shift
        ;;
        --region)
        AWS_REGION="$2"
        shift
        shift
        ;;
        --dry-run)
        DRY_RUN=true
        shift
        ;;
        --auto-confirm)
        AUTO_CONFIRM=true
        shift
        ;;
        --help)
        echo "Usage: deploy.sh [OPTIONS]"
        echo "Options:"
        echo "  --stack-name NAME           CloudFormation stack name (default: counterparty-arm64)"
        echo "  --vpc-id ID                 VPC ID for deployment"
        echo "  --subnet-id ID              Subnet ID for deployment"
        echo "  --security-group-id ID      Security group ID"
        echo "  --key-name NAME             EC2 key pair name"
        echo "  --your-ip IP                Your IP address with CIDR (e.g., 1.2.3.4/32)"
        echo "  --region REGION             AWS region (default: us-east-1)"
        echo "  --dry-run                   Validate template without creating resources"
        echo "  --auto-confirm              Skip confirmation prompt"
        echo "  --help                      Show this help message"
        exit 0
        ;;
        *)
        echo "Unknown option: $key"
        exit 1
        ;;
    esac
done

# CloudFormation template path
TEMPLATE_PATH="$REPO_DIR/aws/cloudformation/graviton-st1.yml"

# Validate required parameters
validation_error=false
if [ -z "$AWS_VPC_ID" ]; then
    log_error "VPC ID is required. Set AWS_VPC_ID in your .env file or environment."
    validation_error=true
fi

if [ -z "$AWS_SUBNET_ID" ]; then
    log_error "Subnet ID is required. Set AWS_SUBNET_ID in your .env file or environment."
    validation_error=true
fi

if [ -z "$AWS_KEY_NAME" ]; then
    log_error "Key name is required. Set AWS_KEY_NAME in your .env file or environment."
    validation_error=true
fi

if [ "$USE_EXISTING_SG" = "true" ] && [ -z "$EXISTING_SECURITY_GROUP_ID" ]; then
    log_error "Security group ID is required when USE_EXISTING_SG=true. Set EXISTING_SECURITY_GROUP_ID in your .env file."
    validation_error=true
fi

if [ "$validation_error" = true ]; then
    log_error "Fix the above errors and try again."
    exit 1
fi

# Display configuration
log_info "Deployment Configuration:"
log_info "  Stack Name: $STACK_NAME"
log_info "  AWS Region: $AWS_REGION"
log_info "  VPC ID: $AWS_VPC_ID"
log_info "  Subnet ID: $AWS_SUBNET_ID"
if [ "$USE_EXISTING_SG" = "true" ]; then
    log_info "  Using Existing Security Group: $EXISTING_SECURITY_GROUP_ID"
else
    log_info "  Creating New Security Group"
fi
log_info "  Key Name: $AWS_KEY_NAME"
log_info "  Your IP: $YOUR_IP"
if [ "$PUBLIC_RPC_ACCESS" = "true" ]; then
    log_warning "  PUBLIC RPC ACCESS: ENABLED (Counterparty API port 4000 is open to the world)"
else
    log_info "  Public RPC Access: Disabled (Counterparty API port 4000 restricted to your IP)"
fi
log_info "  Instance Type: $AWS_INSTANCE_TYPE"
log_info "  Root Volume Size: $ROOT_VOLUME_SIZE GB"
log_info "  Data Volume Size: $DATA_VOLUME_SIZE GB"
log_info "  Bitcoin Version: $BITCOIN_VERSION"
log_info "  Counterparty Branch: $COUNTERPARTY_BRANCH"
log_info "  Ubuntu Version: $UBUNTU_VERSION"

# Confirm deployment
if [ "$DRY_RUN" = "true" ] || [ "$AUTO_CONFIRM" = "true" ]; then
    # Skip confirmation for dry run or auto-confirm
    log_info "Auto-confirm enabled or dry run, skipping prompt."
else
    read -p "Continue with deployment? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Deployment cancelled."
        exit 0
    fi
fi

# Prepare parameters
PARAMETERS="ParameterKey=VpcId,ParameterValue=\"$AWS_VPC_ID\" \
  ParameterKey=SubnetId,ParameterValue=\"$AWS_SUBNET_ID\" \
  ParameterKey=KeyName,ParameterValue=\"$AWS_KEY_NAME\" \
  ParameterKey=YourIp,ParameterValue=\"$YOUR_IP\" \
  ParameterKey=CreateNewKeyPair,ParameterValue=\"false\" \
  ParameterKey=UseExistingSecurityGroup,ParameterValue=\"$USE_EXISTING_SG\" \
  ParameterKey=ExistingSecurityGroupId,ParameterValue=\"$EXISTING_SECURITY_GROUP_ID\" \
  ParameterKey=InstanceType,ParameterValue=\"$AWS_INSTANCE_TYPE\" \
  ParameterKey=RootVolumeSize,ParameterValue=\"$ROOT_VOLUME_SIZE\" \
  ParameterKey=DataVolumeSize,ParameterValue=\"$DATA_VOLUME_SIZE\" \
  ParameterKey=BitcoinVersion,ParameterValue=\"$BITCOIN_VERSION\" \
  ParameterKey=CounterpartyBranch,ParameterValue=\"$COUNTERPARTY_BRANCH\" \
  ParameterKey=CounterpartyTag,ParameterValue=\"$COUNTERPARTY_TAG\" \
  ParameterKey=UbuntuVersion,ParameterValue=\"$UBUNTU_VERSION\""

if [ "$DRY_RUN" = "true" ]; then
    log_info "Performing a dry run (validation only)..."
    aws cloudformation validate-template \
      --region "$AWS_REGION" \
      --template-body "file://$TEMPLATE_PATH"
      
    if [ $? -eq 0 ]; then
        log_success "Template validation successful."
        log_info "Parameters that would be used:"
        eval "echo ParameterKey=VpcId,ParameterValue=$AWS_VPC_ID"
        eval "echo ParameterKey=SubnetId,ParameterValue=$AWS_SUBNET_ID"
        eval "echo ParameterKey=KeyName,ParameterValue=$AWS_KEY_NAME"
        eval "echo ParameterKey=YourIp,ParameterValue=$YOUR_IP"
        eval "echo ParameterKey=UseExistingSecurityGroup,ParameterValue=$USE_EXISTING_SG"
        [ "$USE_EXISTING_SG" = "true" ] && eval "echo ParameterKey=ExistingSecurityGroupId,ParameterValue=$EXISTING_SECURITY_GROUP_ID"
        eval "echo ParameterKey=InstanceType,ParameterValue=$AWS_INSTANCE_TYPE"
        eval "echo ParameterKey=UbuntuVersion,ParameterValue=$UBUNTU_VERSION"
        # ... and so on
        
        log_info "To deploy for real, run without the --dry-run flag."
    else
        log_error "Template validation failed."
    fi
    exit $?
else
    # Create CloudFormation stack
    log_info "Creating CloudFormation stack: $STACK_NAME..."
    aws cloudformation create-stack \
      --region "$AWS_REGION" \
      --stack-name "$STACK_NAME" \
      --template-body "file://$TEMPLATE_PATH" \
      --capabilities CAPABILITY_IAM \
      --parameters \
        ParameterKey=VpcId,ParameterValue="$AWS_VPC_ID" \
        ParameterKey=SubnetId,ParameterValue="$AWS_SUBNET_ID" \
        ParameterKey=KeyName,ParameterValue="$AWS_KEY_NAME" \
        ParameterKey=YourIp,ParameterValue="$YOUR_IP" \
        ParameterKey=CreateNewKeyPair,ParameterValue="false" \
        ParameterKey=UseExistingSecurityGroup,ParameterValue="$USE_EXISTING_SG" \
        ParameterKey=ExistingSecurityGroupId,ParameterValue="$EXISTING_SECURITY_GROUP_ID" \
        ParameterKey=PublicRpcAccess,ParameterValue="$PUBLIC_RPC_ACCESS" \
        ParameterKey=InstanceType,ParameterValue="$AWS_INSTANCE_TYPE" \
        ParameterKey=RootVolumeSize,ParameterValue="$ROOT_VOLUME_SIZE" \
        ParameterKey=DataVolumeSize,ParameterValue="$DATA_VOLUME_SIZE" \
        ParameterKey=BitcoinVersion,ParameterValue="$BITCOIN_VERSION" \
        ParameterKey=CounterpartyBranch,ParameterValue="$COUNTERPARTY_BRANCH" \
        ParameterKey=CounterpartyTag,ParameterValue="$COUNTERPARTY_TAG" \
        ParameterKey=UbuntuVersion,ParameterValue="$UBUNTU_VERSION"
fi

# Check if creation was successful
if [ $? -eq 0 ]; then
    log_success "Stack creation initiated successfully."
    log_info "You can check the stack status with:"
    log_info "  aws cloudformation describe-stacks --stack-name $STACK_NAME --region $AWS_REGION"
    log_info "Or view it in the AWS CloudFormation Console."
else
    log_error "Failed to create stack. Check the error message above."
    exit 1
fi

# Wait for stack creation to complete (optional)
log_info "Waiting for stack creation to complete... This may take 10-15 minutes."
if aws cloudformation wait stack-create-complete --stack-name "$STACK_NAME" --region "$AWS_REGION"; then
    # Get outputs from the stack
    outputs=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$AWS_REGION" --query "Stacks[0].Outputs" --output json)
    
    # Extract specific outputs for easy access
    public_ip=$(echo "$outputs" | jq -r '.[] | select(.OutputKey=="PublicIp") | .OutputValue')
    public_dns=$(echo "$outputs" | jq -r '.[] | select(.OutputKey=="PublicDns") | .OutputValue')
    ssh_command=$(echo "$outputs" | jq -r '.[] | select(.OutputKey=="SSHCommand") | .OutputValue')
    
    log_success "Stack created successfully!"
    log_info "Instance Public IP: $public_ip"
    log_info "SSH Command: $ssh_command"
    log_info ""
    log_info "It may take a few more minutes for the instance to complete its setup."
    log_info "You can check the setup progress with:"
    log_info "  ssh ubuntu@$public_ip 'tail -f /var/log/cloud-init-output.log'"
else
    log_error "Stack creation failed or timed out. Check the AWS CloudFormation Console for details."
    exit 1
fi