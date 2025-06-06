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
AWS_INSTANCE_TYPE=${AWS_INSTANCE_TYPE:-"t4g.large"}
ROOT_VOLUME_SIZE=${ROOT_VOLUME_SIZE:-20}
DATA_VOLUME_SIZE=${DATA_VOLUME_SIZE:-1000}
BITCOIN_VERSION=${BITCOIN_VERSION:-"26.0"}
COUNTERPARTY_BRANCH=${COUNTERPARTY_BRANCH:-"master"}
UBUNTU_VERSION=${UBUNTU_VERSION:-"24.04"}
NETWORK_PROFILE=${NETWORK_PROFILE:-"mainnet"}
ENABLE_SNAPSHOTS=${ENABLE_SNAPSHOTS:-"false"}
GITHUB_TOKEN=${GITHUB_TOKEN:-""}
STACK_NAME=${STACK_NAME:-"counterparty-arm64"}
BITCOIN_SNAPSHOT_PATH=${BITCOIN_SNAPSHOT_PATH:-"s3://bitcoin-blockchain-snapshots/uncompressed"}

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
WAIT_TIME=120  # Default wait time: 2 minutes (120 seconds)
UPDATE_STACK=false  # Default is to create new stack
UPDATE_COUNTERPARTY_ONLY=false  # Default is to update all parameters

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
        --wait-time)
        WAIT_TIME="$2"
        shift
        shift
        ;;
        --no-wait)
        WAIT_TIME=0
        shift
        ;;
        --update-stack)
        UPDATE_STACK=true
        shift
        ;;
        --update-counterparty-only)
        UPDATE_STACK=true
        UPDATE_COUNTERPARTY_ONLY=true
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
        --bitcoin-snapshot-path)
        BITCOIN_SNAPSHOT_PATH="$2"
        shift
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
        echo "  --wait-time SECONDS         Time to wait after stack creation before checking status (default: 120)"
        echo "  --no-wait                   Skip waiting after stack creation"
        echo "  --update-stack              Update existing stack instead of creating new one"
        echo "  --update-counterparty-only  Update only Counterparty version parameters"
        echo "  --bitcoin-snapshot-path PATH S3 path to Bitcoin blockchain snapshot"
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

# Auto-detect existing stack info if we're updating
if [ "$UPDATE_STACK" = true ]; then
    log_info "Checking existing stack configuration for '$STACK_NAME'..."
    
    # Check if stack exists and get security group info
    if aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$AWS_REGION" &>/dev/null; then
        # Get existing instance ID from stack
        INSTANCE_ID=$(aws cloudformation describe-stack-resources --stack-name "$STACK_NAME" --region "$AWS_REGION" \
                    --query "StackResources[?ResourceType=='AWS::EC2::Instance'].PhysicalResourceId" --output text)
        
        if [ -n "$INSTANCE_ID" ]; then
            # Get security group ID from the instance
            SG_ID=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --region "$AWS_REGION" \
                  --query "Reservations[].Instances[].SecurityGroups[0].GroupId" --output text)
            
            if [ -n "$SG_ID" ]; then
                log_info "Found existing security group: $SG_ID"
                # Auto-set USE_EXISTING_SG to true and set security group ID
                USE_EXISTING_SG="true"
                EXISTING_SECURITY_GROUP_ID="$SG_ID"
            fi
        fi
    fi
fi

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
log_info "  Network Profile: $NETWORK_PROFILE"
if [ "$ENABLE_SNAPSHOTS" = "true" ]; then
    log_info "  EBS Snapshots: Enabled (monthly)"
else
    log_info "  EBS Snapshots: Disabled"
fi

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
  ParameterKey=UbuntuVersion,ParameterValue=\"$UBUNTU_VERSION\" \
  ParameterKey=BitcoinSnapshotPath,ParameterValue=\"$BITCOIN_SNAPSHOT_PATH\""

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
    # Prepare parameters array
    ALL_PARAMETERS=(
        "ParameterKey=VpcId,ParameterValue=\"$AWS_VPC_ID\""
        "ParameterKey=SubnetId,ParameterValue=\"$AWS_SUBNET_ID\""
        "ParameterKey=KeyName,ParameterValue=\"$AWS_KEY_NAME\""
        "ParameterKey=YourIp,ParameterValue=\"$YOUR_IP\""
        "ParameterKey=CreateNewKeyPair,ParameterValue=\"false\""
        "ParameterKey=UseExistingSecurityGroup,ParameterValue=\"$USE_EXISTING_SG\""
        "ParameterKey=PublicRpcAccess,ParameterValue=\"$PUBLIC_RPC_ACCESS\""
        "ParameterKey=InstanceType,ParameterValue=\"$AWS_INSTANCE_TYPE\""
        "ParameterKey=RootVolumeSize,ParameterValue=\"$ROOT_VOLUME_SIZE\""
        "ParameterKey=DataVolumeSize,ParameterValue=\"$DATA_VOLUME_SIZE\""
        "ParameterKey=BitcoinVersion,ParameterValue=\"$BITCOIN_VERSION\""
        "ParameterKey=CounterpartyBranch,ParameterValue=\"$COUNTERPARTY_BRANCH\""
        "ParameterKey=CounterpartyTag,ParameterValue=\"$COUNTERPARTY_TAG\""
        "ParameterKey=UbuntuVersion,ParameterValue=\"$UBUNTU_VERSION\""
        "ParameterKey=GitHubToken,ParameterValue=\"$GITHUB_TOKEN\""
        "ParameterKey=NetworkProfile,ParameterValue=\"$NETWORK_PROFILE\""
        "ParameterKey=EnableSnapshots,ParameterValue=\"$ENABLE_SNAPSHOTS\""
        "ParameterKey=BitcoinSnapshotPath,ParameterValue=\"$BITCOIN_SNAPSHOT_PATH\""
    )
    
    # Only add existing security group parameter if we're using an existing SG
    if [ "$USE_EXISTING_SG" = "true" ]; then
        ALL_PARAMETERS+=("ParameterKey=ExistingSecurityGroupId,ParameterValue=\"$EXISTING_SECURITY_GROUP_ID\"")
    else
        # Use a default SG when not using existing SG (to satisfy CloudFormation validation)
        ALL_PARAMETERS+=("ParameterKey=ExistingSecurityGroupId,ParameterValue=\"sg-12345678abcdef012\"")
    fi
    
    # Counterparty-only parameters for update-counterparty-only mode
    COUNTERPARTY_PARAMETERS=(
        "ParameterKey=CounterpartyBranch,ParameterValue=\"$COUNTERPARTY_BRANCH\""
        "ParameterKey=CounterpartyTag,ParameterValue=\"$COUNTERPARTY_TAG\""
        "ParameterKey=GitHubToken,ParameterValue=\"$GITHUB_TOKEN\""
    )
    
    if [ "$UPDATE_STACK" = true ]; then
        # Check if stack exists
        if ! aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$AWS_REGION" &>/dev/null; then
            log_error "Stack '$STACK_NAME' does not exist. Cannot update."
            exit 1
        fi
        
        # Handle different update modes
        if [ "$UPDATE_COUNTERPARTY_ONLY" = true ]; then
            log_info "Updating only Counterparty parameters in stack: $STACK_NAME..."
            PARAMETERS_TO_USE=("${COUNTERPARTY_PARAMETERS[@]}")
            
            # All other parameters will use previous values
            for param in $(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$AWS_REGION" --query "Stacks[0].Parameters[?!(ParameterKey=='CounterpartyBranch' || ParameterKey=='CounterpartyTag' || ParameterKey=='GitHubToken')].ParameterKey" --output text); do
                PARAMETERS_TO_USE+=("ParameterKey=$param,UsePreviousValue=true")
            done
        else
            log_info "Updating all parameters in stack: $STACK_NAME..."
            PARAMETERS_TO_USE=("${ALL_PARAMETERS[@]}")
        fi
        
        # Show parameters that will be updated
        log_info "Parameters that will be updated:"
        for param in "${PARAMETERS_TO_USE[@]}"; do
            if [[ "$param" != *"GitHubToken"* ]]; then  # Don't display token
                echo "  $param"
            fi
        done
        
        # Confirm update
        if [ "$AUTO_CONFIRM" != "true" ]; then
            read -p "Continue with stack update? [y/N] " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                log_info "Stack update cancelled."
                exit 0
            fi
        fi
        
        # Create a streamlined version of UserData to avoid size limitations
        log_info "Optimizing CloudFormation template to avoid UserData size limits..."
        TEMP_DIR=$(mktemp -d)
        OPTIMIZED_TEMPLATE_PATH="$TEMP_DIR/optimized-template.yml"
        
        # Extract and modify UserData script to reduce size
        awk '
        BEGIN { in_user_data = 0; print_line = 1; }
        /^ *UserData:/ { in_user_data = 1; print_line = 1; print; next; }
        /^ *Fn::Base64:/ && in_user_data { print_line = 1; print; next; }
        /^ *!Sub/ && in_user_data { 
            print "          !Sub |"; 
            print "            #!/bin/bash"; 
            print "            # Compressed UserData script - download and run setup from S3"; 
            print "            apt-get update && apt-get install -y curl";
            print "            mkdir -p /tmp/setup";
            print "            curl -s https://raw.githubusercontent.com/stampchain-io/counterparty-arm64/main/aws/scripts/bootstrap.sh > /tmp/setup/bootstrap.sh";
            print "            chmod +x /tmp/setup/bootstrap.sh";
            print "            export BITCOIN_SNAPSHOT_PATH=${BitcoinSnapshotPath}";
            print "            /tmp/setup/bootstrap.sh ${BitcoinVersion} ${CounterpartyBranch} ${CounterpartyTag} ${NetworkProfile} ${GitHubToken}";
            in_user_data = 0;
            next;
        }
        in_user_data && /^ *\|/ { print_line = 0; next; }
        !in_user_data || print_line { print; }
        ' "$TEMPLATE_PATH" > "$OPTIMIZED_TEMPLATE_PATH"
        
        # Note to create bootstrap.sh file
        log_warning "IMPORTANT: You need to create a bootstrap.sh file in the Github repository"
        log_warning "The bootstrap.sh file should contain the full setup script from the CloudFormation template"
        
        # Update stack with optimized template
        aws cloudformation update-stack \
          --region "$AWS_REGION" \
          --stack-name "$STACK_NAME" \
          --template-body "file://$OPTIMIZED_TEMPLATE_PATH" \
          --capabilities CAPABILITY_IAM \
          --parameters "${PARAMETERS_TO_USE[@]}"
        
        # Clean up temp files
        rm -rf "$TEMP_DIR"
        
        OPERATION_TYPE="update"
        WAIT_COMMAND="stack-update-complete"
    else
        # Create new stack with optimized UserData
        log_info "Creating CloudFormation stack: $STACK_NAME..."
        
        # Create a streamlined version of UserData to avoid size limitations
        log_info "Optimizing CloudFormation template to avoid UserData size limits..."
        TEMP_DIR=$(mktemp -d)
        OPTIMIZED_TEMPLATE_PATH="$TEMP_DIR/optimized-template.yml"
        
        # Extract and modify UserData script to reduce size (same as in update section)
        awk '
        BEGIN { in_user_data = 0; print_line = 1; }
        /^ *UserData:/ { in_user_data = 1; print_line = 1; print; next; }
        /^ *Fn::Base64:/ && in_user_data { print_line = 1; print; next; }
        /^ *!Sub/ && in_user_data { 
            print "          !Sub |"; 
            print "            #!/bin/bash"; 
            print "            # Compressed UserData script - download and run setup from S3"; 
            print "            apt-get update && apt-get install -y curl";
            print "            mkdir -p /tmp/setup";
            print "            curl -s https://raw.githubusercontent.com/stampchain-io/counterparty-arm64/main/aws/scripts/bootstrap.sh > /tmp/setup/bootstrap.sh";
            print "            chmod +x /tmp/setup/bootstrap.sh";
            print "            export BITCOIN_SNAPSHOT_PATH=${BitcoinSnapshotPath}";
            print "            /tmp/setup/bootstrap.sh ${BitcoinVersion} ${CounterpartyBranch} ${CounterpartyTag} ${NetworkProfile} ${GitHubToken}";
            in_user_data = 0;
            next;
        }
        in_user_data && /^ *\|/ { print_line = 0; next; }
        !in_user_data || print_line { print; }
        ' "$TEMPLATE_PATH" > "$OPTIMIZED_TEMPLATE_PATH"
        
        # Note to create bootstrap.sh file
        log_warning "IMPORTANT: You need to create a bootstrap.sh file in the Github repository"
        log_warning "The bootstrap.sh file should contain the full setup script from the CloudFormation template"
        
        # Update stack with optimized template
        aws cloudformation create-stack \
          --region "$AWS_REGION" \
          --stack-name "$STACK_NAME" \
          --template-body "file://$OPTIMIZED_TEMPLATE_PATH" \
          --capabilities CAPABILITY_IAM \
          --parameters "${ALL_PARAMETERS[@]}"
        
        # Clean up temp files
        rm -rf "$TEMP_DIR"
        
        OPERATION_TYPE="creation"
        WAIT_COMMAND="stack-create-complete"
    fi
fi

# Check if operation was successful
if [ $? -eq 0 ]; then
    log_success "Stack $OPERATION_TYPE initiated successfully."
    log_info "You can check the stack status with:"
    log_info "  aws cloudformation describe-stacks --stack-name $STACK_NAME --region $AWS_REGION"
    log_info "Or view it in the AWS CloudFormation Console."
else
    log_error "Failed to $OPERATION_TYPE stack. Check the error message above."
    exit 1
fi

# Wait for stack operation to complete (optional)
log_info "Waiting for stack $OPERATION_TYPE to complete... This may take 10-15 minutes."
if aws cloudformation wait $WAIT_COMMAND --stack-name "$STACK_NAME" --region "$AWS_REGION"; then
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
    
    # For stack creation or complete stack update, wait and check status
    if [ "$OPERATION_TYPE" = "creation" ] || [ "$UPDATE_COUNTERPARTY_ONLY" = false ]; then
        # Display blockchain download time estimate if a snapshot is being used
        if [ -n "$BITCOIN_SNAPSHOT_PATH" ]; then
            log_warning "IMPORTANT: When using a Bitcoin blockchain snapshot (~472GB), the download and extraction process can take 1-2 hours"
            log_warning "           This depends on your instance's network bandwidth and storage performance"
            log_warning "           The instance will automatically configure and start the services after the download completes"
            log_info "To monitor the download progress: ssh ubuntu@$public_ip 'sudo tail -f /var/log/cloud-init-output.log'"
        fi
        
        if [ "$WAIT_TIME" -gt 0 ]; then
            if [ "$WAIT_TIME" -ge 60 ]; then
                # Calculate minutes and seconds for display
                minutes=$((WAIT_TIME / 60))
                seconds=$((WAIT_TIME % 60))
                if [ "$seconds" -eq 0 ]; then
                    log_info "Waiting $minutes minute(s) for the instance to complete its setup..."
                else
                    log_info "Waiting $minutes minute(s) and $seconds second(s) for the instance to complete its setup..."
                fi
            else
                log_info "Waiting $WAIT_TIME second(s) for the instance to complete its setup..."
            fi
            
            sleep $WAIT_TIME
            log_info "Checking deployment status..."
        else
            log_info "Skipping wait period. Your instance will continue setting up in the background."
            log_info "You can check the status later with: ssh ubuntu@$public_ip './check-sync-status.sh'"
            exit 0
        fi
    elif [ "$UPDATE_COUNTERPARTY_ONLY" = true ]; then
        # For Counterparty-only update, ssh in and check the containers
        log_info "Counterparty update completed. Checking container status..."
        ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 ubuntu@$public_ip "docker ps | grep counterparty"
        log_info "You may need to wait a moment for the Counterparty container to restart with the new version."
        exit 0
    fi
    if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 ubuntu@$public_ip "docker ps | grep counterparty" 2>/dev/null; then
        log_success "Counterparty services are running! You can now access your Counterparty node."
        ssh -o StrictHostKeyChecking=no ubuntu@$public_ip "./check-sync-status.sh"
    else
        # Check if there was a blockchain snapshot specified
        if [ -n "$BITCOIN_SNAPSHOT_PATH" ]; then
            log_warning "Blockchain download and setup is still in progress. This can take 1-2 hours for large snapshots (~472GB)."
            log_info "To check download progress (look for 'Completed X/472.3 GiB'):"
            log_info "  ssh ubuntu@$public_ip 'sudo tail -f /var/log/cloud-init-output.log'"
            log_info ""
            log_info "To check if Docker containers have started:"
            log_info "  ssh ubuntu@$public_ip 'docker ps'"
            log_info ""
            log_info "To verify Bitcoin data extraction (should show blocks and chainstate directories):"
            log_info "  ssh ubuntu@$public_ip 'ls -la /bitcoin-data/bitcoin/'"
        else
            log_warning "Services may still be initializing. You can check the setup progress with:"
            log_info "  ssh ubuntu@$public_ip 'sudo tail -f /var/log/cloud-init-output.log'"
            log_info "  ssh ubuntu@$public_ip 'docker ps'"
        fi
    fi
else
    log_error "Stack creation failed or timed out. Check the AWS CloudFormation Console for details."
    exit 1
fi