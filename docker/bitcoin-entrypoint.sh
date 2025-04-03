#!/bin/bash
# Entrypoint script for the Bitcoin container that preserves command-line arguments
# while also creating a bitcoin.conf file for bitcoin-cli to use

# Create the bitcoin config directory if it doesn't exist
mkdir -p /bitcoin/.bitcoin
mkdir -p /root/.bitcoin

# Default RPC settings - these will be overridden by any command line args
cat > /bitcoin/.bitcoin/bitcoin.conf << EOL
# Bitcoin Core configuration file
# Created automatically by bitcoin-entrypoint.sh

# Default RPC settings
rpcuser=rpc
rpcpassword=rpc
rpcallowip=0.0.0.0/0
rpcbind=0.0.0.0
server=1
EOL

# Create symlink to the config for bitcoin-cli in the root directory
ln -sf /bitcoin/.bitcoin/bitcoin.conf /root/.bitcoin/bitcoin.conf

# Set proper permissions
chmod 600 /bitcoin/.bitcoin/bitcoin.conf
chmod 600 /root/.bitcoin/bitcoin.conf

echo "Created bitcoin.conf with default RPC settings"
echo "Starting bitcoind with command-line arguments..."

# Execute bitcoind with all passed arguments
exec bitcoind "$@"