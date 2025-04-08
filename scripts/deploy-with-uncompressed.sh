#!/bin/bash
# Deploy Counterparty with uncompressed blockchain data

# Configuration
STACK_NAME="counterparty-node-uncompressed"
AUTO_CONFIRM=true

# Change to aws/scripts directory
cd "$(dirname "$0")/../aws/scripts"

# Deploy the stack
./deploy.sh \
  --stack-name "$STACK_NAME" \
  --bitcoin-snapshot-path "s3://bitcoin-blockchain-snapshots/uncompressed" \
  --auto-confirm

# Print monitoring instructions
echo ""
echo "==================================================================="
echo "Stack deployment initiated. To monitor the stack creation:"
echo "aws cloudformation describe-stacks --stack-name $STACK_NAME --query \"Stacks[0].StackStatus\""
echo ""
echo "Once the stack is created, you can check the extraction process:"
echo "SSH_COMMAND=\$(aws cloudformation describe-stacks --stack-name $STACK_NAME --query \"Stacks[0].Outputs[?OutputKey=='SSHCommand'].OutputValue\" --output text)"
echo "eval \$SSH_COMMAND 'tail -f /tmp/download_logs/bootstrap.log'"
echo "==================================================================="