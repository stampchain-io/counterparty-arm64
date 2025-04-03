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

**Problem:** Seeing errors like `failed to mount local volume: mount /bitcoin-data/counterparty-docker-data:/bitcoin-data/docker/volumes/counterparty-core_data/_data, flags: 0x1000: no such file or directory`

**Solution:** Create the required directory and check permissions:

```bash
mkdir -p /bitcoin-data/counterparty-docker-data
sudo chown -R ubuntu:ubuntu /bitcoin-data/counterparty-docker-data
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

**Solution:** Check the logs and ensure the Bitcoin container is running:

```bash
# Check logs
docker logs counterparty-core-counterparty-core-1

# Check if Bitcoin is running
docker logs counterparty-core-bitcoind-1

# Restart services
~/start-counterparty.sh mainnet
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
- Increase the dbcache parameter in docker-compose.yml
- Optimize storage performance by ensuring I/O scheduler is properly configured:

```bash
# Check current I/O scheduler
cat /sys/block/nvme1n1/queue/scheduler

# Set deadline scheduler for ST1 volume
echo 'ACTION=="add|change", KERNEL=="nvme1n1", ATTR{queue/scheduler}="deadline"' | sudo tee /etc/udev/rules.d/60-scheduler.rules
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

- Check the logs in `/bitcoin-data/counterparty-docker-data`
- Open an issue on the GitHub repository
- Refer to the official Counterparty documentation for additional troubleshooting