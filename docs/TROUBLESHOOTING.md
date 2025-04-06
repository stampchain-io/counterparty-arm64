# Troubleshooting Guide

This document covers common issues you might encounter when setting up and running Counterparty on ARM64 architecture.

## Docker Issues

### Exec Format Error

**Problem:** You see errors like `exec /usr/local/bin/docker-entrypoint.sh: exec format error` when starting containers.

**Solution:** This indicates you're trying to run x86_64 images on ARM64 hardware. Make sure you're building from source:

```bash
~/start-counterparty.sh mainnet true
```

The setup automatically detects ARM64 architecture and builds appropriate images, but you can force a rebuild if needed.

### Docker Mount Issues

**Problem:** Seeing errors like failed to mount local volume errors with docker volumes.

**Solution:** Create the required directories and check permissions:

```bash
mkdir -p /bitcoin-data/bitcoin
mkdir -p /bitcoin-data/counterparty
sudo chown -R ubuntu:ubuntu /bitcoin-data/bitcoin
sudo chown -R ubuntu:ubuntu /bitcoin-data/counterparty
```

### Missing Images

**Problem:** Getting errors about missing Docker images.

**Solution:** Force a rebuild of the images:

```bash
cd ~/counterparty-node
docker compose -f docker-compose.yml -f docker-compose.build.yml build
```

## AWS Specific Issues

### Volume Mount Issues

**Problem:** The ST1 volume is not mounting properly.

**Solution:** Check that the volume is attached and properly formatted:

```bash
# List block devices
lsblk

# Check if the device has a filesystem
sudo file -s /dev/nvme1n1

# If it shows "data" (no filesystem), format it:
sudo mkfs -t xfs /dev/nvme1n1

# Mount the volume
sudo mount /dev/nvme1n1 /bitcoin-data

# Check if mounted
df -h | grep bitcoin-data
```

### Snapshot Creation Failing

**Problem:** The automated snapshot creation script is failing.

**Solution:** Check IAM permissions and configure the AWS CLI:

```bash
# Configure AWS CLI
aws configure

# Test permissions
aws ec2 describe-volumes
```

The EC2 instance needs permissions to:
- Create snapshots
- Delete snapshots
- Describe volumes and snapshots

## Counterparty Core Issues

### Counterparty Not Connecting to Bitcoin

**Problem:** Counterparty container starts but can't connect to Bitcoin Core.

**Solution:** Check the logs and ensure the Bitcoin container is running. Counterparty will automatically retry connecting to Bitcoin once it's available:

```bash
# Check container status
docker ps

# Check logs
docker logs counterparty-core-counterparty-core-1

# Check if Bitcoin is running
docker logs counterparty-core-bitcoind-1

# If needed, restart services
docker compose --profile mainnet restart
```

### Container Startup Order Issues

**Problem:** When deploying, the Counterparty container fails to start because Bitcoin isn't ready yet.

**Solution:** This should rarely happen with our improved deployment, but if it does:

```bash
# Start Bitcoin first
cd ~/counterparty-node && docker compose --profile mainnet up -d bitcoind

# Wait for Bitcoin to initialize (about 30 seconds)
sleep 30

# Then start Counterparty
cd ~/counterparty-node && docker compose --profile mainnet up -d
```

### Counterparty Build Fails

**Problem:** The Counterparty image fails to build from source.

**Solution:** Check that the repository was cloned correctly and try a different branch or tag:

```bash
# Check repository
ls -la /bitcoin-data/repo/counterparty-core

# Update repository
cd /bitcoin-data/repo/counterparty-core
git fetch
git checkout master
git pull

# Try specific tag
~/start-counterparty.sh mainnet true
```

## Performance Issues

### Slow Blockchain Synchronization

**Problem:** Bitcoin Core is syncing very slowly.

**Solution:** 
- Our deployment now includes optimized settings for initial blockchain synchronization
- The following optimizations are automatically applied:
  - Increased dbcache (6GB for initial sync)
  - Enabled blocksonly mode during initial sync
  - Reduced peer connections (25 connections during sync)
  - Enabled assumevalid to skip signature verification
  - Set parallel block validation for your CPU cores

- You can check current sync status and estimated time remaining:
```bash
# Check sync status and estimated time remaining
~/check-sync-status.sh
```

- After sync completes, you can switch to normal operating parameters:
```bash
# Run this after sync is complete
~/counterparty-arm64/scripts/post-sync-optimization.sh
```

- For additional storage performance, optimize the I/O scheduler:
```bash
# Check current I/O scheduler
cat /sys/block/nvme1n1/queue/scheduler

# Set deadline scheduler for ST1 volume
echo 'ACTION=="add|change", KERNEL=="nvme1n1", ATTR{queue/scheduler}="deadline"' | sudo tee /etc/udev/rules.d/60-scheduler.rules
sudo udevadm control --reload-rules
sudo udevadm trigger
```

- If you're using newer kernel, try the following instead:
```bash
# Optimize for throughput on newer kernels
echo 'ACTION=="add|change", KERNEL=="nvme1n1", ATTR{queue/scheduler}="none"' | sudo tee /etc/udev/rules.d/60-scheduler.rules
echo 'ACTION=="add|change", KERNEL=="nvme1n1", ATTR{queue/nr_requests}="2048"' | sudo tee -a /etc/udev/rules.d/60-scheduler.rules
sudo udevadm control --reload-rules
sudo udevadm trigger
```

## Common Commands

### Reset Everything

If you need a clean start:

```bash
# Stop all containers
docker compose -f ~/counterparty-node/docker-compose.yml down

# Remove all images
docker rmi $(docker images -q)

# Clear Docker data
sudo systemctl stop docker
sudo rm -rf /bitcoin-data/docker/volumes
sudo mkdir -p /bitcoin-data/docker/volumes
sudo systemctl start docker

# Re-run setup
~/counterparty-arm64/scripts/setup.sh
```

### Checking Service Status

```bash
# Check running containers
docker ps

# Check service logs
docker logs -f counterparty-core-bitcoind-1
docker logs -f counterparty-core-counterparty-core-1

# Check disk usage
df -h /bitcoin-data
```

### Counterparty Logs Not Found

**Problem:** Unable to find Counterparty log files in the expected location:
```bash
sudo cat /root/.cache/counterparty/log/server.access.log
cat: /root/.cache/counterparty/log/server.access.log: No such file or directory
```

**Solution:** 
The Counterparty logs are stored in the container's mapped volume. Based on our volume mapping configuration, access logs are in the container volume and can be accessed as follows:

```bash
# Find the actual Counterparty container name
COUNTERPARTY_CONTAINER=$(docker ps --format "{{.Names}}" | grep -E "counterparty.*core.*1$" | head -1)

# Check recent logs from the container
docker logs $COUNTERPARTY_CONTAINER | tail -50

# To access the logs directly
docker exec $COUNTERPARTY_CONTAINER cat /data/log/server.access.log

# You can also check the logs in the host mount
ls -la /bitcoin-data/counterparty/log/

# And view the logs directly from the host
cat /bitcoin-data/counterparty/log/server.access.log
```

This happens because we've configured the Counterparty container to use the following environment variables:
```
XDG_DATA_HOME=/data/
XDG_LOG_HOME=/data/
```

Which redirects the logs to the mounted volume at `/data/` inside the container, which maps to `/bitcoin-data/counterparty` on the host.

### Backup and Restore

```bash
# Manual snapshot
~/create-snapshot.sh

# List snapshots
aws ec2 describe-snapshots --filters "Name=description,Values=*Bitcoin*" --query "Snapshots[].{ID:SnapshotId,Time:StartTime,Desc:Description}" --output table

# Restore from snapshot (requires recreating volume)
# See AWS documentation for details
```

## Still Having Issues?

- Check the logs in `/bitcoin-data/bitcoin` and `/bitcoin-data/counterparty`
- Open an issue on the GitHub repository
- Refer to the official Counterparty documentation for additional troubleshooting