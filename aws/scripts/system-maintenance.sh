#!/bin/bash
# System maintenance script for Counterparty ARM64
# Cleans up system resources, logs, and Docker components

# Source common functions if available in the repo
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"

if [ -f "$REPO_DIR/scripts/common.sh" ]; then
    source "$REPO_DIR/scripts/common.sh"
# Otherwise use basic functions
else
    # Colors for output
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m' # No Color

    # Log functions
    log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
    log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
    log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
    log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
fi

# Parse arguments
DRY_RUN=false
CLEAN_DOCKER=true
CLEAN_LOGS=true
CLEAN_APT=true
CLEAN_JOURNAL=true
CLEAN_TEMP=true
LOG_FILE="/var/log/system-maintenance.log"

while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        --dry-run)
        DRY_RUN=true
        shift
        ;;
        --no-docker)
        CLEAN_DOCKER=false
        shift
        ;;
        --no-logs)
        CLEAN_LOGS=false
        shift
        ;;
        --no-apt)
        CLEAN_APT=false
        shift
        ;;
        --no-journal)
        CLEAN_JOURNAL=false
        shift
        ;;
        --no-temp)
        CLEAN_TEMP=false
        shift
        ;;
        --log-file)
        LOG_FILE="$2"
        shift
        shift
        ;;
        --help)
        echo "Usage: system-maintenance.sh [OPTIONS]"
        echo "Options:"
        echo "  --dry-run              Show what would be done without doing it"
        echo "  --no-docker            Skip Docker cleanup"
        echo "  --no-logs              Skip log cleanup"
        echo "  --no-apt               Skip APT cache cleanup"
        echo "  --no-journal           Skip systemd journal cleanup"
        echo "  --no-temp              Skip temporary files cleanup"
        echo "  --log-file FILE        Log file (default: /var/log/system-maintenance.log)"
        echo "  --help                 Show this help message"
        exit 0
        ;;
        *)
        echo "Unknown option: $key"
        exit 1
        ;;
    esac
done

# Make sure only root can run this script
if [ "$(id -u)" != "0" ]; then
   log_error "This script must be run as root" 
   exit 1
fi

# Setup logging
LOG_DIR=$(dirname "$LOG_FILE")
if [ ! -d "$LOG_DIR" ]; then
    mkdir -p "$LOG_DIR"
fi

# Log with timestamp and append to log file
log_to_file() {
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] $1" | tee -a "$LOG_FILE"
}

log_to_file "Starting system maintenance"
log_to_file "Options: Docker cleanup: $CLEAN_DOCKER, Logs cleanup: $CLEAN_LOGS, APT cleanup: $CLEAN_APT, Journal cleanup: $CLEAN_JOURNAL, Temp cleanup: $CLEAN_TEMP"

if [ "$DRY_RUN" = "true" ]; then
    log_to_file "DRY RUN MODE: Only showing what would be done"
fi

# Get initial disk usage
INITIAL_USAGE=$(df -h / | awk 'NR==2 {print $5}' | tr -d '%')
log_to_file "Initial disk usage: $INITIAL_USAGE%"

# 1. Docker cleanup
if [ "$CLEAN_DOCKER" = "true" ]; then
    log_to_file "Cleaning up Docker resources..."
    
    if command -v docker &> /dev/null; then
        if [ "$DRY_RUN" = "true" ]; then
            log_to_file "Would remove unused Docker data (containers, networks, images)"
        else
            # Remove stopped containers, unused networks, dangling images, and build cache
            docker system prune -f >> "$LOG_FILE" 2>&1
            
            # Remove unused volumes (careful - only removes volumes not used by any container)
            docker volume prune -f >> "$LOG_FILE" 2>&1
            
            log_to_file "Docker resources cleaned up"
        fi
    else
        log_to_file "Docker not installed, skipping Docker cleanup"
    fi
fi

# 2. Log cleanup
if [ "$CLEAN_LOGS" = "true" ]; then
    log_to_file "Cleaning up log files..."
    
    if [ "$DRY_RUN" = "true" ]; then
        log_to_file "Would clean log files in /var/log/"
    else
        # Clean old log files (compress logs older than 7 days, delete older than 30 days)
        find /var/log -type f -name "*.log" -mtime +7 -exec gzip -f {} \; 2>/dev/null || true
        find /var/log -type f -name "*.gz" -mtime +30 -delete 2>/dev/null || true
        find /var/log -type f -name "*.log.*" -mtime +30 -delete 2>/dev/null || true
        
        # Clean rotated logs
        rm -f /var/log/*.{0,1,2,3,4,5,6,7,8,9} 2>/dev/null || true
        rm -f /var/log/*/*.{0,1,2,3,4,5,6,7,8,9} 2>/dev/null || true
        
        log_to_file "Log files cleaned up"
    fi
fi

# 3. APT cache cleanup
if [ "$CLEAN_APT" = "true" ]; then
    log_to_file "Cleaning up APT cache..."
    
    if [ "$DRY_RUN" = "true" ]; then
        log_to_file "Would clean APT cache"
    else
        apt-get clean >> "$LOG_FILE" 2>&1
        apt-get autoclean -y >> "$LOG_FILE" 2>&1
        
        log_to_file "APT cache cleaned up"
    fi
fi

# 4. Journal cleanup
if [ "$CLEAN_JOURNAL" = "true" ]; then
    log_to_file "Cleaning up systemd journal..."
    
    if [ "$DRY_RUN" = "true" ]; then
        log_to_file "Would vacuum systemd journal"
    else
        if command -v journalctl &> /dev/null; then
            # Vacuum journal files to save space (keep only last 7 days)
            journalctl --vacuum-time=7d >> "$LOG_FILE" 2>&1
            
            log_to_file "Systemd journal cleaned up"
        else
            log_to_file "journalctl not found, skipping journal cleanup"
        fi
    fi
fi

# 5. Temporary files cleanup
if [ "$CLEAN_TEMP" = "true" ]; then
    log_to_file "Cleaning up temporary files..."
    
    if [ "$DRY_RUN" = "true" ]; then
        log_to_file "Would clean temporary files"
    else
        # Remove temporary files
        rm -rf /tmp/* 2>/dev/null || true
        rm -rf /var/tmp/* 2>/dev/null || true
        
        # Clean home directory caches for system users
        find /home -type f -path "*/tmp/*" -atime +30 -delete 2>/dev/null || true
        
        log_to_file "Temporary files cleaned up"
    fi
fi

# Get final disk usage and calculate savings
FINAL_USAGE=$(df -h / | awk 'NR==2 {print $5}' | tr -d '%')
SAVED=$(( INITIAL_USAGE - FINAL_USAGE ))

log_to_file "Final disk usage: $FINAL_USAGE%"

if [ $SAVED -gt 0 ]; then
    log_to_file "Freed up approximately $SAVED% disk space"
else
    log_to_file "No significant disk space was freed"
fi

log_to_file "System maintenance completed successfully"
log_success "System maintenance completed. Log file: $LOG_FILE"

exit 0