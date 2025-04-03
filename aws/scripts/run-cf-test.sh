#!/bin/bash
# run-cf-test.sh - Script to deploy a test CloudFormation stack for ARM64 Counterparty

# Source common functions if available
if [ -f "../scripts/common.sh" ]; then
  source "../scripts/common.sh"
fi

# Default values
STACK_NAME="counterparty-arm64-test"
NETWORK_PROFILE="testnet3"  # Use testnet for testing to save space and time
BITCOIN_VERSION="26.0"
COUNTERPARTY_BRANCH="develop"

# Help function
show_help() {
  echo "Usage: $0 [options]"
  echo ""
  echo "Options:"
  echo "  --stack-name NAME         Stack name (default: counterparty-arm64-test)"
  echo "  --network-profile PROFILE Network profile: mainnet, testnet3, testnet4, regtest (default: testnet3)"
  echo "  --bitcoin-version VERSION Bitcoin Core version (default: 26.0)"
  echo "  --counterparty-branch BRANCH Counterparty branch (default: develop)"
  echo "  --help                    Show this help message"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --stack-name)
      STACK_NAME="$2"
      shift 2
      ;;
    --network-profile)
      NETWORK_PROFILE="$2"
      shift 2
      ;;
    --bitcoin-version)
      BITCOIN_VERSION="$2"
      shift 2
      ;;
    --counterparty-branch)
      COUNTERPARTY_BRANCH="$2"
      shift 2
      ;;
    --help)
      show_help
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      show_help
      exit 1
      ;;
  esac
done

# Detect current IP address
YOUR_IP=$(curl -s https://checkip.amazonaws.com)
if [ -z "$YOUR_IP" ]; then
  echo "Failed to detect IP address. Please check your internet connection."
  exit 1
fi
YOUR_IP="${YOUR_IP}/32"
echo "Detected IP: $YOUR_IP"

# Load AWS configuration from .env file if it exists
ENV_FILE="../.env"
if [ -f "$ENV_FILE" ]; then
  source "$ENV_FILE"
  echo "Loaded configuration from $ENV_FILE"
else
  echo "No .env file found. Please make sure AWS_VPC_ID, AWS_SUBNET_ID, and AWS_KEY_NAME are set."
  exit 1
fi

# Check required parameters
if [ -z "$AWS_VPC_ID" ]; then
  echo "Error: AWS_VPC_ID is not set"
  exit 1
fi

if [ -z "$AWS_SUBNET_ID" ]; then
  echo "Error: AWS_SUBNET_ID is not set"
  exit 1
fi

if [ -z "$AWS_KEY_NAME" ]; then
  echo "Error: AWS_KEY_NAME is not set"
  exit 1
fi

# Set up CloudFormation parameters
PARAMETERS=(
  "ParameterKey=KeyName,ParameterValue=$AWS_KEY_NAME"
  "ParameterKey=VpcId,ParameterValue=$AWS_VPC_ID"
  "ParameterKey=SubnetId,ParameterValue=$AWS_SUBNET_ID"
  "ParameterKey=YourIp,ParameterValue=$YOUR_IP"
  "ParameterKey=NetworkProfile,ParameterValue=$NETWORK_PROFILE"
  "ParameterKey=BitcoinVersion,ParameterValue=$BITCOIN_VERSION"
  "ParameterKey=CounterpartyBranch,ParameterValue=$COUNTERPARTY_BRANCH"
  "ParameterKey=InstanceType,ParameterValue=m7g.large"
  "ParameterKey=RootVolumeSize,ParameterValue=50"
  "ParameterKey=DataVolumeSize,ParameterValue=500"
)

# Add USE_EXISTING_SG and ExistingSecurityGroupId if needed
if [ "$USE_EXISTING_SG" = "true" ] && [ ! -z "$EXISTING_SECURITY_GROUP_ID" ]; then
  PARAMETERS+=(
    "ParameterKey=UseExistingSecurityGroup,ParameterValue=true"
    "ParameterKey=ExistingSecurityGroupId,ParameterValue=$EXISTING_SECURITY_GROUP_ID"
  )
else
  PARAMETERS+=("ParameterKey=UseExistingSecurityGroup,ParameterValue=false")
fi

# Add PUBLIC_RPC_ACCESS if defined
if [ "$PUBLIC_RPC_ACCESS" = "true" ]; then
  PARAMETERS+=("ParameterKey=PublicRpcAccess,ParameterValue=true")
else
  PARAMETERS+=("ParameterKey=PublicRpcAccess,ParameterValue=false")
fi

# Add UBUNTU_VERSION if defined
if [ "$UBUNTU_VERSION" = "22.04" ]; then
  PARAMETERS+=("ParameterKey=UbuntuVersion,ParameterValue=22.04")
else
  PARAMETERS+=("ParameterKey=UbuntuVersion,ParameterValue=24.04")
fi

# Deploy the CloudFormation stack
echo "Deploying CloudFormation stack: $STACK_NAME"
echo "Network profile: $NETWORK_PROFILE"
echo "Bitcoin version: $BITCOIN_VERSION"
echo "Counterparty branch: $COUNTERPARTY_BRANCH"

aws cloudformation create-stack \
  --stack-name "$STACK_NAME" \
  --template-body "file://$(pwd)/../cloudformation/graviton-st1.yml" \
  --parameters "${PARAMETERS[@]}" \
  --capabilities CAPABILITY_IAM

if [ $? -eq 0 ]; then
  echo "Stack creation initiated successfully."
  echo "You can monitor the stack creation in the AWS CloudFormation console."
  echo "To check stack status:"
  echo "aws cloudformation describe-stacks --stack-name $STACK_NAME --query 'Stacks[0].StackStatus'"
  echo ""
  echo "To get the instance IP once the stack is complete:"
  echo "aws cloudformation describe-stacks --stack-name $STACK_NAME --query 'Stacks[0].Outputs[?OutputKey==\`PublicIp\`].OutputValue' --output text"
else
  echo "Failed to create CloudFormation stack."
fi