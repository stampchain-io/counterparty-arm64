# Blocks-Only Bootstrap for Counterparty ARM64

This document describes the "blocks-only bootstrap" approach for Counterparty ARM64 deployments, which provides a faster and more efficient way to deploy a new Counterparty node.

## What is a Blocks-Only Bootstrap?

A blocks-only bootstrap contains only the Bitcoin blockchain's raw block data (without the chainstate/UTXO set). This approach has several advantages:

1. **Smaller download size**: Only the blocks directory (~604GB) instead of blocks+chainstate (~800GB+)
2. **No extraction required**: Files are uploaded uncompressed to S3 and directly synced
3. **No tar/extraction issues**: Avoids problems with large compressed archives
4. **Auto-optimized configuration**: Automatically detects instance type and optimizes configuration
5. **Lower storage cost**: Uses 700GB ST1 volume ($31.50/month) instead of 1TB ($45/month)

## How It Works

When using a blocks-only bootstrap, the following process happens:

1. The bootstrap.sh script detects this is a blocks-only bootstrap (via bootstrap_type.txt marker)
2. It downloads only the blocks directory from S3 (no chainstate)
3. It detects the instance type and automatically configures Bitcoin with optimized settings
4. Bitcoin Core rebuilds the UTXO set (chainstate) during initial sync
5. Once the UTXO set is rebuilt, Bitcoin becomes fully synchronized

## Instance Type Optimization

Different instance types require different optimization settings. We've optimized the configuration for the following instance types:

### c6g.large (Default/Recommended)
- **vCPUs:** 2 vCPUs (compute-optimized)
- **Memory:** 4 GB
- **Performance:** Fastest UTXO rebuilding (30-45 minutes)
- **Cost:** ~$77/month
- **Optimizations:**
  - dbcache=3500 (using most available memory)
  - par=24 (maximizes CPU usage for UTXO reconstruction)
  - maxconnections=12 (balanced for network throughput)

### t4g.large (Cost-optimized)
- **vCPUs:** 2 vCPUs (burstable)
- **Memory:** 8 GB (more memory than c6g.large)
- **Performance:** Slower initial sync (1-2 hours)
- **Cost:** ~$67/month
- **Optimizations:**
  - dbcache=6500 (leverages higher memory)
  - par=16 (balanced for burstable CPU)
  - maxconnections=12 (balanced for throughput)

### Other Supported Instance Types
- m6g.large: Balanced performance (~$80/month)
- t4g.xlarge: Higher memory, burstable performance (~$134/month)
- All instances auto-detect and optimize configurations

## Deployment Instructions

To deploy a Counterparty node using the blocks-only bootstrap:

1. Update the BitcoinSnapshotPath parameter in CloudFormation to point to the blocks-only bootstrap:
   ```
   s3://bitcoin-blockchain-snapshots/uncompressed/blocks-only-bootstrap
   ```

2. Set the InstanceType parameter to c6g.large (default) for fastest UTXO rebuilding:
   ```yaml
   InstanceType: c6g.large
   ```

3. Launch the stack and monitor the sync progress:
   ```bash
   ssh ubuntu@your-instance-ip '~/check-sync-status.sh'
   ```

## Expected Timeline

- **c6g.large:** 30-45 minutes for UTXO set rebuilding
- **t4g.large:** 1-2 hours for UTXO set rebuilding
- **m6g.large:** 45-75 minutes for UTXO set rebuilding

## Technical Details

The blocks-only bootstrap approach works by:

1. Storing uncompressed block files in S3
2. Marking the bootstrap with a bootstrap_type.txt file containing "blocks-only"
3. Including optimized configuration templates for different instance types
4. Auto-detecting instance type and applying appropriate optimizations
5. Using parallel processing (par parameter) to maximize CPU utilization during UTXO rebuilding

## Troubleshooting

If you encounter any issues:

1. Check the system logs:
   ```bash
   sudo journalctl -u docker 
   ```

2. View Bitcoin logs:
   ```bash
   docker logs counterparty-node-bitcoind-1
   ```

3. Check sync status:
   ```bash
   ~/check-sync-status.sh
   ```

4. Common issues:
   - If sync seems stalled, check if the instance is CPU throttled (common with t4g family)
   - Verify that disk I/O is not a bottleneck using `iostat -x 1`
   - Check memory usage with `free -h` to ensure you're not swapping

## Creating Your Own Blocks-Only Bootstrap

To create your own blocks-only bootstrap:

1. Extract your blockchain data or use an existing Bitcoin data directory
2. Use the upload-blocks-bootstrap.sh script to upload to S3:
   ```bash
   ./upload-blocks-bootstrap.sh /path/to/blocks your-s3-bucket your-s3-prefix
   ```

The script will:
- Create the bootstrap_type.txt marker
- Create metadata about the bootstrap
- Generate optimized configuration templates for different instance types
- Upload everything to S3 in the correct structure