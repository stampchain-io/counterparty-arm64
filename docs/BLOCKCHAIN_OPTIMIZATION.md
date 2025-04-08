# Blockchain Data Optimization

This document outlines optimization strategies for handling Bitcoin blockchain data in Counterparty ARM64 deployments.

## Traditional Compressed Approach vs. Uncompressed Approach

### Traditional Compressed Approach

The traditional approach uses a single compressed tarball containing the blockchain data:

1. **Download**: Download a single large `bitcoin-data.tar.gz` file (~473GB compressed)
2. **Verify**: Validate file integrity (MD5 checksum)
3. **Extract**: Extract the tarball to the local filesystem

**Pros:**
- Single file to manage and version
- Less S3 storage space required
- Fewer S3 objects to manage

**Cons:**
- Time-consuming extraction process
- Requires double the disk space during extraction
- Sequential process (download then extract)
- High CPU usage during extraction

### Uncompressed Approach

The new optimized approach uses uncompressed blockchain data stored directly in S3:

1. **Sync**: Directly sync blockchain files from S3 to the local filesystem
2. **Ready**: Blockchain is immediately ready to use without extraction

**Pros:**
- Much faster setup (no extraction overhead)
- Lower CPU requirements
- Less disk space needed (no temporary copy)
- Parallel downloads of multiple files
- Can selectively download only needed files

**Cons:**
- More S3 storage required
- More complex to manage multiple files
- Higher S3 bandwidth usage

## Preparing Uncompressed Blockchain Data

To prepare uncompressed blockchain data for optimized deployments:

1. Launch the blockchain extractor CloudFormation stack:

```bash
aws cloudformation create-stack \
  --stack-name blockchain-extractor \
  --template-body file://aws/cloudformation/blockchain-extractor.yml \
  --parameters \
    ParameterKey=KeyName,ParameterValue=your-key-name \
    ParameterKey=VpcId,ParameterValue=vpc-xxxxxxxx \
    ParameterKey=SubnetId,ParameterValue=subnet-xxxxxxxx \
    ParameterKey=SourceBucket,ParameterValue=bitcoin-blockchain-snapshots \
    ParameterKey=SourceObject,ParameterValue=bitcoin-data-live-20250406-1347.tar.gz \
    ParameterKey=DestBucket,ParameterValue=bitcoin-blockchain-snapshots \
    ParameterKey=DestPrefix,ParameterValue=uncompressed \
    ParameterKey=DiskSizeGB,ParameterValue=2000
```

2. SSH into the extractor instance and run the extraction script:

```bash
ssh ubuntu@<instance-dns-name>
~/run-extractor.sh
```

3. Monitor the extraction process:

```bash
tail -f ~/disk-usage.log  # Monitor disk usage
```

4. Once completed, update your `.env` to use the uncompressed path:

```bash
# .env file
BITCOIN_SNAPSHOT_PATH=s3://bitcoin-blockchain-snapshots/uncompressed
```

5. Terminate the extractor stack when finished:

```bash
aws cloudformation delete-stack --stack-name blockchain-extractor
```

## Using Uncompressed Blockchain Data

The bootstrap process automatically detects when you're using uncompressed blockchain data and will use the optimized sync method. Simply specify the path in your CloudFormation deployment:

```bash
./aws/scripts/deploy.sh --stack-name counterparty-node --bitcoin-snapshot-path s3://bitcoin-blockchain-snapshots/uncompressed
```

## Performance Comparison

| Metric | Compressed | Uncompressed |
|--------|------------|--------------|
| Download Time | ~2-3 hours (473GB) | ~2-3 hours (473GB) |
| Extraction Time | ~1-2 hours | None (0 minutes) |
| Total Setup Time | ~3-5 hours | ~2-3 hours |
| CPU Usage | Very High | Moderate |
| Disk Space Required | ~1TB (2x size) | ~473GB (1x size) |
| S3 Storage Cost | Lower | Higher |

## Recommendation

For production deployments, the uncompressed approach is strongly recommended as it significantly reduces setup time and resource requirements. The additional S3 storage cost is minimal compared to the operational benefits gained.