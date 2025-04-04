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
rpcuser=${RPC_USER:-rpc}
rpcpassword=${RPC_PASSWORD:-rpc}
rpcallowip=${RPC_ALLOW_IP:-0.0.0.0/0}
rpcbind=${RPC_BIND:-0.0.0.0}
server=${SERVER:-1}
listen=${LISTEN:-1}
addresstype=${ADDRESS_TYPE:-legacy}
txindex=${TX_INDEX:-1}
prune=${PRUNE:-0}
dbcache=${DB_CACHE:-4000}
mempoolfullrbf=${MEMPOOL_FULL_RBF:-1}

# ZMQ settings required by Counterparty
zmqpubrawtx=${ZMQ_PUB_RAW_TX:-tcp://0.0.0.0:9332}
zmqpubhashtx=${ZMQ_PUB_HASH_TX:-tcp://0.0.0.0:9332}
zmqpubsequence=${ZMQ_PUB_SEQUENCE:-tcp://0.0.0.0:9332}
zmqpubrawblock=${ZMQ_PUB_RAW_BLOCK:-tcp://0.0.0.0:9333}
EOL

# Create symlink to the config for bitcoin-cli in the root directory
ln -sf /bitcoin/.bitcoin/bitcoin.conf /root/.bitcoin/bitcoin.conf

# Set proper permissions
chmod 600 /bitcoin/.bitcoin/bitcoin.conf
chmod 600 /root/.bitcoin/bitcoin.conf

echo "Created bitcoin.conf with RPC and ZMQ settings"
echo "Starting bitcoind with command-line arguments..."

# Execute bitcoind with all passed arguments
exec bitcoind "$@"