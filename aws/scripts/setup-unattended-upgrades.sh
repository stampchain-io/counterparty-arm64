#!/bin/bash
# Setup unattended upgrades for Counterparty ARM64
# Configures automatic security updates without reboots

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

# Make sure only root can run this script
if [ "$(id -u)" != "0" ]; then
   log_error "This script must be run as root" 
   exit 1
fi

# Determine the Ubuntu version
UBUNTU_VERSION=$(lsb_release -rs)
log_info "Detected Ubuntu $UBUNTU_VERSION"

# Install unattended-upgrades package
log_info "Installing unattended-upgrades package..."
apt-get update -q
apt-get install -y unattended-upgrades apt-listchanges

# Configure unattended-upgrades for security updates only
log_info "Configuring unattended-upgrades for security updates only..."

cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'EOF'
// Automatically upgrade packages from these (origin:archive) pairs
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};

// List of packages to not update
Unattended-Upgrade::Package-Blacklist {
    "docker-ce";
    "docker-ce-cli";
    "containerd.io";
    "docker-compose-plugin";
};

// Do not automatically reboot even if a restart is required
Unattended-Upgrade::Automatic-Reboot "false";

// If automatic reboot is enabled and needed, reboot at the specific
// time instead of immediately
Unattended-Upgrade::Automatic-Reboot-Time "02:30";

// Split the upgrade into the smallest possible chunks so that
// they can be interrupted with SIGTERM
Unattended-Upgrade::MinimalSteps "true";

// Send email to this address for problems or packages upgrades
// If empty or unset then no email is sent
Unattended-Upgrade::Mail "";

// Always send an email report after unattended-upgrades runs
Unattended-Upgrade::MailReport "only-on-error";

// Remove unused kernel packages and dependencies
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";

// Remove unused automatically installed packages
Unattended-Upgrade::Remove-Unused-Dependencies "true";

// Clean downloaded packages after successful installation
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";

// Skip the normal apt-get update process, which can be useful when using 
// other package management tools
Unattended-Upgrade::Skip-Updates-On-Metered-Connections "true";

// Enable logging to syslog
Unattended-Upgrade::SyslogEnable "true";
Unattended-Upgrade::SyslogFacility "daemon";
EOF

# Enable automatic updates
cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Download-Upgradeable-Packages "1";
EOF

# Configure to reduce download bandwidth
cat > /etc/apt/apt.conf.d/80slow-connection << 'EOF'
Acquire::http::Dl-Limit "512";
EOF

# Create a daily notification if system requires a reboot
if [ ! -f /etc/cron.daily/check-reboot-required ]; then
    cat > /etc/cron.daily/check-reboot-required << 'EOF'
#!/bin/bash
if [ -f /var/run/reboot-required ]; then
    echo "System requires a reboot" | mail -s "System Reboot Required" root
    echo "*** System reboot required ***" > /etc/motd
    echo "Last security update: $(date)" >> /etc/motd
    echo "" >> /etc/motd
fi
EOF
    chmod +x /etc/cron.daily/check-reboot-required
fi

# Test the configuration
log_info "Testing unattended-upgrades configuration..."
unattended-upgrade --dry-run --debug

log_success "Unattended-upgrades setup completed successfully"
log_info "The system will automatically install security updates daily"
log_info "Reboots will not happen automatically. Check /var/run/reboot-required"
log_info "A notification will display on login if a reboot is needed"

exit 0