#!/bin/bash
# Entrypoint script for the Bitcoin container

# Create the bitcoin config directory if it doesn't exist
mkdir -p /bitcoin/.bitcoin

# Extract environment variables with defaults
RPC_USER=${RPC_USER:-rpc}
RPC_PASSWORD=${RPC_PASSWORD:-rpc}
RPC_ALLOW_IP=${RPC_ALLOW_IP:-0.0.0.0/0}
RPC_BIND=${RPC_BIND:-0.0.0.0}
SERVER=${SERVER:-1}
LISTEN=${LISTEN:-1}
ADDRESS_TYPE=${ADDRESS_TYPE:-legacy}
TX_INDEX=${TX_INDEX:-1}
PRUNE=${PRUNE:-0}
DB_CACHE=${DB_CACHE:-6000}
BLOCKSONLY=${BLOCKSONLY:-0}  # Disable blocksonly by default to ensure RPC works
MAXCONNECTIONS=${MAXCONNECTIONS:-25}
MAXMEMPOOL=${MAXMEMPOOL:-300}
MEMPOOL_FULL_RBF=${MEMPOOL_FULL_RBF:-1}
ASSUMEVALID=${ASSUMEVALID:-000000000000000000053b17c1c2e1ea8a965a6240ede8ffd0729f7f2e77283e}
PARALLEL_BLOCKS=${PARALLEL_BLOCKS:-8}
ZMQ_PUB_RAW_TX=${ZMQ_PUB_RAW_TX:-tcp://0.0.0.0:9332}
ZMQ_PUB_HASH_TX=${ZMQ_PUB_HASH_TX:-tcp://0.0.0.0:9332}
ZMQ_PUB_SEQUENCE=${ZMQ_PUB_SEQUENCE:-tcp://0.0.0.0:9332}
ZMQ_PUB_RAW_BLOCK=${ZMQ_PUB_RAW_BLOCK:-tcp://0.0.0.0:9333}

# Write config file
cat > /bitcoin/.bitcoin/bitcoin.conf << EOF
# Bitcoin Core configuration file
# Created by bitcoin-entrypoint.sh

# Explicitly set the data directory
datadir=/bitcoin/.bitcoin

# RPC Settings
rpcuser=$RPC_USER
rpcpassword=$RPC_PASSWORD
rpcallowip=$RPC_ALLOW_IP
rpcbind=$RPC_BIND

# Node Settings
server=$SERVER
listen=$LISTEN
addresstype=$ADDRESS_TYPE
txindex=$TX_INDEX
prune=$PRUNE
dbcache=$DB_CACHE
maxconnections=$MAXCONNECTIONS
maxmempool=$MAXMEMPOOL
blocksonly=$BLOCKSONLY
mempoolfullrbf=$MEMPOOL_FULL_RBF
assumevalid=$ASSUMEVALID
par=$PARALLEL_BLOCKS

# ZMQ Settings
zmqpubrawtx=$ZMQ_PUB_RAW_TX
zmqpubhashtx=$ZMQ_PUB_HASH_TX
zmqpubsequence=$ZMQ_PUB_SEQUENCE
zmqpubrawblock=$ZMQ_PUB_RAW_BLOCK
EOF

# Set proper permissions for bitcoin.conf
chmod 600 /bitcoin/.bitcoin/bitcoin.conf

echo "Created bitcoin.conf with RPC and ZMQ settings"
echo "Starting bitcoind with command-line arguments..."

# Execute bitcoind with explicit datadir to ensure consistent data location
# This forces Bitcoin to use /bitcoin/.bitcoin instead of the default /root/.bitcoin
exec bitcoind -datadir=/bitcoin/.bitcoin "$@"