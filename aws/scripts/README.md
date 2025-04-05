# Counterparty ARM64 Maintenance and Security Scripts

This directory contains scripts for deploying, monitoring, maintaining, and securing a Counterparty ARM64 node on AWS.

> **Note:** The root volume size has been optimized to 20GB (down from 100GB) to reduce costs. Our maintenance scripts and regular cleanup ensure this is sufficient for the OS and applications, while the blockchain data is stored on a separate data volume.

## System Maintenance Script

`system-maintenance.sh` performs routine system maintenance tasks:

- Cleans up Docker resources (unused containers, images, volumes)
- Removes old log files
- Cleans up APT cache
- Vacuums systemd journal
- Removes temporary files

### Usage

```bash
/usr/local/bin/system-maintenance.sh [OPTIONS]
```

Options:
- `--dry-run`: Show what would be done without doing it
- `--no-docker`: Skip Docker cleanup
- `--no-logs`: Skip log cleanup
- `--no-apt`: Skip APT cache cleanup
- `--no-journal`: Skip systemd journal cleanup
- `--no-temp`: Skip temporary files cleanup
- `--log-file FILE`: Log file (default: /var/log/system-maintenance.log)

## Unattended Upgrades

`setup-unattended-upgrades.sh` configures automatic security updates:

- Installs and configures unattended-upgrades for security patches only
- Never performs automatic reboots
- Excludes Docker packages to prevent disruption
- Notifies when reboots are required
- Updates the MOTD when a reboot is needed

## Security Checks

`security-check.sh` performs comprehensive security audits:

- System update status and security patches
- Docker security configuration
- SSH configuration (root login, password auth, etc.)
- Open ports analysis
- Bitcoin configuration security
- SSH hardening is applied automatically during installation

### Usage

```bash
/usr/local/bin/security-check.sh [OPTIONS]
```

Options:
- `--log-file FILE`: Log file (default: /var/log/security-check.log)
- `--email EMAIL`: Send report to this email address
- `--no-updates`: Skip checking for updates
- `--no-docker`: Skip Docker security checks
- `--no-ssh`: Skip SSH configuration checks
- `--no-ports`: Skip open ports scanning
- `--no-bitcoin`: Skip Bitcoin security checks
- `--alert-threshold DAYS`: Alert if system not updated in X days (default: 7)

## Log Rotation Configuration

`counterparty-logrotate.conf` configures automatic log rotation for:

- Docker container logs
- Bitcoin debug logs
- Counterparty logs
- System maintenance logs
- Bitcoin monitoring logs
- Security check logs

## Monitoring Scripts

- `check-disk-usage.sh`: Monitors disk usage and sends alerts if threshold is exceeded
- `check-bitcoin-sync.sh`: Checks Bitcoin node sync status
- `monitor-bitcoin.sh`: Monitors Bitcoin node and logs status
- `check-sync-status.sh`: Checks sync status of both Bitcoin and Counterparty
- `disk-usage-analysis.sh`: Provides detailed analysis of disk usage to validate volume sizing

## CloudFormation Deployment

The scripts are automatically installed by the CloudFormation template `graviton-st1.yml`:

- System maintenance runs weekly on Sunday at 3:30 AM
- Security check runs weekly on Monday at 4:30 AM
- Disk usage check runs daily at 2:00 AM
- Bitcoin sync status check runs daily at 6:00 AM
- Unattended upgrades run daily (security patches only)
- SSH hardening is applied during setup

## Manual Configuration

If you need to modify the maintenance schedule:

```bash
sudo nano /etc/cron.d/counterparty-maintenance
sudo nano /etc/cron.d/counterparty-monitoring
```

For log rotation settings:

```bash
sudo nano /etc/logrotate.d/counterparty
```

For unattended upgrades configuration:

```bash
sudo nano /etc/apt/apt.conf.d/50unattended-upgrades
```

## Security Best Practices

- Security updates are applied automatically (unattended-upgrades)
- SSH is hardened (root login disabled, Protocol 2 only)
- Regular security audits run weekly
- System maintenance reduces attack surface
- Log rotation prevents disk space issues
- All scripts use proper error handling and logging