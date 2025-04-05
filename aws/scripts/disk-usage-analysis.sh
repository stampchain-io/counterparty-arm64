#!/bin/bash
# Script to analyze disk usage on Counterparty ARM64 deployment
# Helps validate if 20GB is sufficient for the root volume

# Source common functions if available
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"

if [ -f "$REPO_DIR/scripts/common.sh" ]; then
    source "$REPO_DIR/scripts/common.sh"
else
    # Basic logging functions
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m' # No Color

    log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
    log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
    log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
    log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
fi

# Output file
OUTPUT_FILE="/tmp/disk-usage-analysis.txt"

# Start with a fresh output file
echo "Counterparty ARM64 Disk Usage Analysis" > $OUTPUT_FILE
echo "Date: $(date)" >> $OUTPUT_FILE
echo "=======================================" >> $OUTPUT_FILE

# System information
echo -e "\n[SYSTEM INFORMATION]" >> $OUTPUT_FILE
echo "Hostname: $(hostname)" >> $OUTPUT_FILE
echo "Kernel: $(uname -r)" >> $OUTPUT_FILE
echo "Distribution: $(lsb_release -d | cut -d: -f2- | xargs)" >> $OUTPUT_FILE

# Overall disk usage
echo -e "\n[OVERALL DISK USAGE]" >> $OUTPUT_FILE
df -h | grep -v /bitcoin-data | sort -k 5 -hr >> $OUTPUT_FILE

# Root partition usage
echo -e "\n[ROOT PARTITION USAGE]" >> $OUTPUT_FILE
ROOT_USAGE=$(df -h / | awk 'NR==2 {print $5}' | tr -d '%')
ROOT_SIZE=$(df -h / | awk 'NR==2 {print $2}')
ROOT_USED=$(df -h / | awk 'NR==2 {print $3}')
ROOT_AVAIL=$(df -h / | awk 'NR==2 {print $4}')

echo "Root partition: $ROOT_USED used of $ROOT_SIZE ($ROOT_USAGE%)" >> $OUTPUT_FILE
echo "Available space: $ROOT_AVAIL" >> $OUTPUT_FILE

if [ $ROOT_USAGE -gt 80 ]; then
    echo "WARNING: Root partition is over 80% full" >> $OUTPUT_FILE
elif [ $ROOT_USAGE -lt 50 ]; then
    echo "Root partition has plenty of free space" >> $OUTPUT_FILE
else
    echo "Root partition usage is moderate" >> $OUTPUT_FILE
fi

# Detailed directory usage for root
echo -e "\n[ROOT DIRECTORY USAGE]" >> $OUTPUT_FILE
echo "Top 10 directories by size:" >> $OUTPUT_FILE
du -h --max-depth=1 / 2>/dev/null | sort -hr | head -10 >> $OUTPUT_FILE

# Docker usage (if Docker is on root)
if [ -d "/var/lib/docker" ]; then
    echo -e "\n[DOCKER USAGE ON ROOT]" >> $OUTPUT_FILE
    echo "Docker directory size on root:" >> $OUTPUT_FILE
    du -sh /var/lib/docker 2>/dev/null >> $OUTPUT_FILE
    
    echo "Docker container details:" >> $OUTPUT_FILE
    if command -v docker &> /dev/null; then
        docker system df -v 2>/dev/null >> $OUTPUT_FILE
    else
        echo "Docker command not available" >> $OUTPUT_FILE
    fi
fi

# Check apt cache
echo -e "\n[APT CACHE]" >> $OUTPUT_FILE
echo "APT cache size:" >> $OUTPUT_FILE
du -sh /var/cache/apt 2>/dev/null >> $OUTPUT_FILE

# Check log files on root
echo -e "\n[LOG FILES]" >> $OUTPUT_FILE
echo "Log directory size:" >> $OUTPUT_FILE
du -sh /var/log 2>/dev/null >> $OUTPUT_FILE

# Check journal logs
if [ -d "/var/log/journal" ]; then
    echo "Journal logs size:" >> $OUTPUT_FILE
    du -sh /var/log/journal 2>/dev/null >> $OUTPUT_FILE
fi

# Check user home directories
echo -e "\n[HOME DIRECTORIES]" >> $OUTPUT_FILE
du -sh /home/* 2>/dev/null | sort -hr >> $OUTPUT_FILE

# Check Bitcoin data directory
if [ -d "/bitcoin-data" ]; then
    echo -e "\n[BITCOIN DATA DIRECTORY]" >> $OUTPUT_FILE
    echo "Bitcoin data directory is mounted at /bitcoin-data" >> $OUTPUT_FILE
    df -h /bitcoin-data >> $OUTPUT_FILE
else
    echo -e "\n[BITCOIN DATA DIRECTORY]" >> $OUTPUT_FILE
    echo "WARNING: Bitcoin data directory not found at /bitcoin-data" >> $OUTPUT_FILE
fi

# Analysis and recommendations
echo -e "\n[ANALYSIS AND RECOMMENDATIONS]" >> $OUTPUT_FILE

if [ $ROOT_USAGE -gt 80 ]; then
    echo "CRITICAL: Root partition is running out of space. Consider:" >> $OUTPUT_FILE
    echo "- Running system-maintenance.sh to clean up resources" >> $OUTPUT_FILE
    echo "- Increasing root volume size in CloudFormation template" >> $OUTPUT_FILE
elif [ $ROOT_USAGE -gt 60 ]; then
    echo "RECOMMENDATION: Root partition usage is getting high. Consider cleaning up:" >> $OUTPUT_FILE
    echo "- Run 'apt-get clean' to clear package cache" >> $OUTPUT_FILE
    echo "- Clean log files" >> $OUTPUT_FILE
    echo "- Run docker system prune if Docker is on root partition" >> $OUTPUT_FILE
elif [ $ROOT_USAGE -lt 40 ]; then
    echo "OBSERVATION: Root partition has plenty of free space" >> $OUTPUT_FILE
    echo "- 20GB is a reasonable size for the root volume" >> $OUTPUT_FILE
    echo "- Regular maintenance with system-maintenance.sh should prevent issues" >> $OUTPUT_FILE
else
    echo "OBSERVATION: Root partition usage is normal" >> $OUTPUT_FILE
    echo "- Continue regular maintenance to prevent space issues" >> $OUTPUT_FILE
fi

# Space saving opportunities
echo -e "\n[SPACE SAVING OPPORTUNITIES]" >> $OUTPUT_FILE
echo "1. Clean APT cache: apt-get clean" >> $OUTPUT_FILE
echo "2. Remove old logs: find /var/log -type f -name \"*.gz\" -delete" >> $OUTPUT_FILE
echo "3. Vacuum journal: journalctl --vacuum-time=7d" >> $OUTPUT_FILE
echo "4. Remove unused Docker data: docker system prune -a" >> $OUTPUT_FILE
echo "5. Consider enabling automatic cleanup in our maintenance script" >> $OUTPUT_FILE

# Conclusion
if [ $ROOT_USAGE -lt 50 ]; then
    echo -e "\n[CONCLUSION]" >> $OUTPUT_FILE
    echo "20GB is sufficient for the root volume with regular maintenance" >> $OUTPUT_FILE
    echo "The system has adequate space for OS, software, and logs" >> $OUTPUT_FILE
    echo "The Bitcoin blockchain data is stored on the separate data volume" >> $OUTPUT_FILE
elif [ $ROOT_USAGE -lt 70 ]; then
    echo -e "\n[CONCLUSION]" >> $OUTPUT_FILE
    echo "20GB appears sufficient for the root volume with careful maintenance" >> $OUTPUT_FILE
    echo "Regular cleanup is recommended to prevent space issues" >> $OUTPUT_FILE
else
    echo -e "\n[CONCLUSION]" >> $OUTPUT_FILE
    echo "The system may benefit from a larger root volume (30GB)" >> $OUTPUT_FILE
    echo "Alternatively, aggressive maintenance can be scheduled" >> $OUTPUT_FILE
fi

log_success "Disk usage analysis completed. Results saved to $OUTPUT_FILE"
echo "To view the results: cat $OUTPUT_FILE"
exit 0