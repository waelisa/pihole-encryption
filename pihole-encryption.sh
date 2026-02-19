#!/bin/bash
#############################################################################################################################
# The MIT License (MIT)
#
# Wael Isa
# Build Date: 02/19/2026
# Version: 1.0.2
# GitHub: https://github.com/waelisa/pihole-encryption
# Website: https://www.wael.name/
# Support: https://www.paypal.me/WaelIsa
#
#############################################################################################################################
#
# COMPLETE FIX HISTORY - ALL ISSUES RESOLVED:
# ==============================================================================
# v1.0.2 - Added complete backup and restore system for uninstallation
#        - Added Let's Encrypt port management (80/tcp, 443/tcp)
#        - Added restore function to revert all changes
#        - Added pre-flight checks for port availability
#        - Added validation for Let's Encrypt connectivity
#        - Added option to remove all configurations
#        - Added port status monitoring
#        - Added uninstall function with full cleanup
#        - Added interactive domain prompt
#        - Added port selection (443 or custom)
#        - Added comprehensive port testing for all required ports
#        - Added port conflict detection and resolution
#        - Added OS detection (Debian/Ubuntu/Raspbian/CentOS/Fedora)
#        - Added automatic dependency installation based on OS
#        - Added Pi-hole v6 version check with exit if not v6
# ==============================================================================
# v1.0.1 - Added comprehensive DNS encryption support (DoH/DoT/DoQ)
#        - Fixed certificate handling for multiple protocols
#        - Added backup system for all configurations
#        - Implemented automatic renewal hooks for all services
#        - Added validation for all encryption endpoints
#        - Fixed permission issues with certificate files
#        - Added UPnP port forwarding support (TCP/UDP)
#        - Added proper port mapping for 4433 (DoH/Web) and 853 (DoT/DoQ)
# ==============================================================================
#
# This script configures Pi-hole v6 with:
# - HTTPS web interface with Let's Encrypt
# - DNS-over-HTTPS (DoH) endpoint: https://YOUR-DOMAIN:PORT/dns-query
# - DNS-over-TLS (DoT) endpoint: tls://YOUR-DOMAIN:853
# - DNS-over-QUIC (DoQ) endpoint: quic://YOUR-DOMAIN:853
#
# Port Forwarding via UPnP:
# - TCP WEB_PORT -> WEB_PORT (HTTPS Web + DoH)
# - TCP 853      -> 853      (DoT)
# - UDP 853      -> 853      (DoQ)
#
# Let's Encrypt Required Ports:
# - TCP 80  -> HTTP-01 challenge (MUST be open)
# - TCP 443 -> Optional for TLS-ALPN-01
#
#############################################################################################################################

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration variables - will be set during installation
DOMAIN=""                    # Your domain (asked during install)
EMAIL=""                     # Your email for Let's Encrypt notifications
WEB_PORT=""                  # HTTPS web interface + DoH port (user selected)
DNS_TLS_PORT="853"           # DoT and DoQ port (fixed)
INTERFACE="eth0"             # Network interface to listen on
LOCAL_IP=""                  # Local IP of Pi-hole (auto-detected)
USE_UPNP=""                  # Enable UPnP port forwarding
LE_EMAIL=""                  # Let's Encrypt email

# OS Detection variables
OS_TYPE=""
OS_VERSION=""
PKG_MANAGER=""
INSTALL_CMD=""
UPDATE_CMD=""

# Fixed paths
PIHOLE_CERT="/etc/pihole/tls.pem"
PIHOLE_CONFIG="/etc/pihole/pihole.toml"
PIHOLE_OLD_CONFIG="/etc/pihole/pihole.toml.bak"
BACKUP_DIR="/root/pihole-backup-$(date +%Y%m%d_%H%M%S)"
LOG_FILE="/var/log/pihole-encryption-setup.log"
SCRIPT_VERSION="1.0.2"
INSTALL_STATE_FILE="/etc/pihole/encryption-installed.state"

# Required packages by OS
declare -A DEBIAN_PKGS=(
    ["certbot"]="certbot"
    ["openssl"]="openssl"
    ["curl"]="curl"
    ["wget"]="wget"
    ["ufw"]="ufw"
    ["net-tools"]="net-tools"
    ["dnsutils"]="dnsutils"
    ["python3"]="python3"
    ["python3-pip"]="python3-pip"
    ["miniupnpc"]="miniupnpc"
    ["iproute2"]="iproute2"
    ["nmap"]="nmap"
    ["lsof"]="lsof"
    ["ss"]="iproute2"
    ["netstat"]="net-tools"
)

declare -A CENTOS_PKGS=(
    ["certbot"]="certbot"
    ["openssl"]="openssl"
    ["curl"]="curl"
    ["wget"]="wget"
    ["ufw"]="ufw"
    ["net-tools"]="net-tools"
    ["bind-utils"]="bind-utils"
    ["python3"]="python3"
    ["python3-pip"]="python3-pip"
    ["miniupnpc"]="miniupnpc"
    ["iproute"]="iproute"
    ["nmap"]="nmap"
    ["lsof"]="lsof"
)

declare -A FEDORA_PKGS=(
    ["certbot"]="certbot"
    ["openssl"]="openssl"
    ["curl"]="curl"
    ["wget"]="wget"
    ["ufw"]="ufw"
    ["net-tools"]="net-tools"
    ["bind-utils"]="bind-utils"
    ["python3"]="python3"
    ["python3-pip"]="python3-pip"
    ["miniupnpc"]="miniupnpc"
    ["iproute"]="iproute"
    ["nmap"]="nmap"
    ["lsof"]="lsof"
)

# Arrays for port tracking
declare -a REQUIRED_PORTS=()
declare -a PORTS_TO_CHECK=()

# Function to print colored output
print_message() {
    echo -e "${BLUE}[INFO]${NC} $1" | tee -a "$LOG_FILE"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1" | tee -a "$LOG_FILE"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1" | tee -a "$LOG_FILE"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"
}

print_section() {
    echo -e "${PURPLE}═══════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}$1${NC}"
    echo -e "${PURPLE}═══════════════════════════════════════════════════════════════════════════════${NC}"
}

# Function to detect OS
detect_os() {
    print_section "Detecting Operating System"

    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS_TYPE="$ID"
        OS_VERSION="$VERSION_ID"
    elif [[ -f /etc/debian_version ]]; then
        OS_TYPE="debian"
        OS_VERSION=$(cat /etc/debian_version)
    elif [[ -f /etc/redhat-release ]]; then
        OS_TYPE="rhel"
        OS_VERSION=$(rpm -q --qf "%{VERSION}" $(rpm -q --whatprovides redhat-release))
    else
        OS_TYPE="unknown"
    fi

    # Normalize OS type
    case $OS_TYPE in
        ubuntu|debian|raspbian|linuxmint|pop|elementary|zorin)
            OS_FAMILY="debian"
            PKG_MANAGER="apt-get"
            INSTALL_CMD="apt-get install -y"
            UPDATE_CMD="apt-get update"
            ;;
        centos|rhel|rocky|almalinux)
            OS_FAMILY="rhel"
            PKG_MANAGER="yum"
            INSTALL_CMD="yum install -y"
            UPDATE_CMD="yum check-update"
            ;;
        fedora)
            OS_FAMILY="fedora"
            PKG_MANAGER="dnf"
            INSTALL_CMD="dnf install -y"
            UPDATE_CMD="dnf check-update"
            ;;
        *)
            OS_FAMILY="unknown"
            ;;
    esac

    print_message "Detected OS: $OS_TYPE $OS_VERSION"
    print_message "OS Family: $OS_FAMILY"
    print_message "Package Manager: $PKG_MANAGER"

    if [[ "$OS_FAMILY" == "unknown" ]]; then
        print_warning "Unknown OS detected. Will attempt to continue but may fail."
        print_warning "Please ensure required dependencies are installed manually."
    else
        print_success "OS detection successful"
    fi
}

# Function to install dependencies based on OS
install_dependencies() {
    print_section "Installing Dependencies"

    if [[ "$OS_FAMILY" == "unknown" ]]; then
        print_warning "Skipping automatic dependency installation for unknown OS"
        print_warning "Please manually install: certbot, openssl, curl, wget, ufw, net-tools,"
        print_warning "dnsutils, python3, python3-pip, miniupnpc, iproute2, nmap, lsof"
        return
    fi

    print_message "Updating package lists using $PKG_MANAGER..."
    $UPDATE_CMD >> "$LOG_FILE" 2>&1 || true

    print_message "Installing required packages..."

    case $OS_FAMILY in
        debian)
            for pkg in "${!DEBIAN_PKGS[@]}"; do
                if ! dpkg -l | grep -q "^ii  $pkg "; then
                    print_message "Installing $pkg..."
                    $INSTALL_CMD "${DEBIAN_PKGS[$pkg]}" >> "$LOG_FILE" 2>&1
                else
                    print_message "$pkg already installed"
                fi
            done
            ;;
        rhel|fedora)
            # Enable EPEL for RHEL/CentOS
            if [[ "$OS_FAMILY" == "rhel" ]] && ! rpm -q epel-release &>/dev/null; then
                print_message "Installing EPEL repository..."
                $INSTALL_CMD epel-release >> "$LOG_FILE" 2>&1
            fi

            local pkg_list=""
            if [[ "$OS_FAMILY" == "rhel" ]]; then
                for pkg in "${!CENTOS_PKGS[@]}"; do
                    pkg_list="$pkg_list ${CENTOS_PKGS[$pkg]}"
                done
            else
                for pkg in "${!FEDORA_PKGS[@]}"; do
                    pkg_list="$pkg_list ${FEDORA_PKGS[$pkg]}"
                done
            fi

            $INSTALL_CMD $pkg_list >> "$LOG_FILE" 2>&1
            ;;
    esac

    # Install Python packages
    print_message "Installing Python packages..."
    pip3 install h2 quic aioquic dnspython >> "$LOG_FILE" 2>&1 || true

    # Verify UPnP is installed
    if command -v upnpc &> /dev/null; then
        print_success "UPnP client (miniupnpc) installed"
    else
        print_warning "UPnP client not available. Port forwarding will be manual."
    fi

    print_success "Dependency installation completed"
}

# Function to check if port is in use
check_port() {
    local port=$1
    local proto=$2
    local in_use=false

    if [[ "$proto" == "tcp" ]]; then
        if ss -tln 2>/dev/null | grep -q ":$port "; then
            in_use=true
        elif netstat -tln 2>/dev/null | grep -q ":$port "; then
            in_use=true
        fi
    elif [[ "$proto" == "udp" ]]; then
        if ss -uln 2>/dev/null | grep -q ":$port "; then
            in_use=true
        elif netstat -uln 2>/dev/null | grep -q ":$port "; then
            in_use=true
        fi
    fi

    if [[ "$in_use" == true ]]; then
        return 0
    else
        return 1
    fi
}

# Function to get process using port
get_port_process() {
    local port=$1
    local proto=$2

    if command -v lsof &> /dev/null; then
        lsof -i "${proto}:${port}" 2>/dev/null | grep LISTEN
    elif command -v ss &> /dev/null; then
        ss -lpn 2>/dev/null | grep ":$port"
    elif command -v netstat &> /dev/null; then
        netstat -lnp 2>/dev/null | grep ":$port"
    fi
}

# Function to test all required ports
test_ports() {
    print_section "Testing Required Ports"

    local ports_ok=true
    PORTS_TO_CHECK=(
        "80:tcp:Let's Encrypt HTTP challenge"
        "443:tcp:Let's Encrypt HTTPS (optional)"
        "${WEB_PORT}:tcp:HTTPS Web Interface + DoH"
        "${DNS_TLS_PORT}:tcp:DNS-over-TLS"
        "${DNS_TLS_PORT}:udp:DNS-over-QUIC"
    )

    echo -e "${CYAN}Port Status Check:${NC}"
    echo "───────────────────────────────────────────────────────"

    for port_info in "${PORTS_TO_CHECK[@]}"; do
        IFS=':' read -r port proto description <<< "$port_info"

        if check_port "$port" "$proto"; then
            PROCESS_INFO=$(get_port_process "$port" "$proto" | head -n1)
            echo -e "  ${RED}✗${NC} Port $port/$proto - $description"
            echo -e "    ${YELLOW}→ In use by:${NC} $PROCESS_INFO"
            ports_ok=false

            # Special handling for critical ports
            if [[ "$port" == "80" ]]; then
                print_error "Port 80 is required for Let's Encrypt certificate issuance"
                print_warning "Please stop the service using port 80 before continuing"
            fi
        else
            echo -e "  ${GREEN}✓${NC} Port $port/$proto - $description ${GREEN}(available)${NC}"
        fi
    done

    echo "───────────────────────────────────────────────────────"

    if [[ "$ports_ok" == false ]]; then
        print_error "Some required ports are in use"
        echo ""
        echo "Options:"
        echo "  1) Stop conflicting services (recommended)"
        echo "  2) Choose different ports"
        echo "  3) Exit and fix manually"
        read -p "Choose option (1-3): " port_choice

        case $port_choice in
            1)
                stop_conflicting_services
                ;;
            2)
                choose_ports
                test_ports
                ;;
            3)
                print_message "Exiting. Please free up required ports and run again."
                exit 1
                ;;
            *)
                print_error "Invalid choice"
                exit 1
                ;;
        esac
    else
        print_success "All required ports are available"
    fi
}

# Function to stop conflicting services
stop_conflicting_services() {
    print_section "Stopping Conflicting Services"

    # Stop common web servers that might use port 80/443
    for service in nginx apache2 lighttpd httpd; do
        if systemctl is-active --quiet "$service" 2>/dev/null; then
            print_message "Stopping $service..."
            systemctl stop "$service"
            systemctl disable "$service" 2>/dev/null || true
        fi
    done

    # Check if Pi-hole is using any of our ports
    if check_port "$WEB_PORT" "tcp"; then
        if systemctl is-active --quiet pihole-FTL; then
            print_message "Temporarily stopping Pi-hole to free port $WEB_PORT..."
            systemctl stop pihole-FTL
        fi
    fi

    print_success "Conflicting services stopped"
}

# Function to choose ports
choose_ports() {
    print_section "Port Configuration"

    echo -e "${YELLOW}Web Interface / DoH Port Selection:${NC}"
    echo "You can use port 443 (standard HTTPS) or a custom port like 4433, 8443, etc."
    echo ""

    while true; do
        read -p "Enter web port [443]: " WEB_PORT
        WEB_PORT=${WEB_PORT:-443}

        # Validate port number
        if [[ ! "$WEB_PORT" =~ ^[0-9]+$ ]] || [[ "$WEB_PORT" -lt 1 ]] || [[ "$WEB_PORT" -gt 65535 ]]; then
            print_error "Invalid port number. Please enter a number between 1 and 65535"
            continue
        fi

        # Check if port is available
        if check_port "$WEB_PORT" "tcp"; then
            print_warning "Port $WEB_PORT is already in use"
            get_port_process "$WEB_PORT" "tcp"
            read -p "Try another port? (y/n): " try_again
            if [[ "$try_again" == "y" ]]; then
                continue
            fi
        fi

        # Special warning for port 443
        if [[ "$WEB_PORT" == "443" ]]; then
            print_warning "Using port 443 may conflict with other HTTPS services"
            read -p "Continue with port 443? (y/n): " confirm
            if [[ "$confirm" != "y" ]]; then
                continue
            fi
        fi

        break
    done

    print_success "Web port set to: $WEB_PORT"
}

# Function to get local IP
get_local_ip() {
    if [[ -z "$LOCAL_IP" ]]; then
        # Try to get IP from default interface
        LOCAL_IP=$(ip -4 addr show "$INTERFACE" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1)

        # If that fails, try other methods
        if [[ -z "$LOCAL_IP" ]]; then
            LOCAL_IP=$(hostname -I | awk '{print $1}')
        fi

        if [[ -z "$LOCAL_IP" ]]; then
            print_error "Could not detect local IP. Please enter manually:"
            read -p "Local IP: " LOCAL_IP
        fi
    fi

    print_message "Local IP detected: $LOCAL_IP"
}

# Function to create backup
create_backup() {
    print_section "Creating System Backup"

    mkdir -p "$BACKUP_DIR"
    print_message "Backup directory created: $BACKUP_DIR"

    # Backup Pi-hole configuration
    if [[ -f "$PIHOLE_CONFIG" ]]; then
        cp "$PIHOLE_CONFIG" "$BACKUP_DIR/pihole.toml.backup"
        print_success "Pi-hole config backed up"
    fi

    # Backup any existing certificates
    if [[ -d "/etc/letsencrypt" ]]; then
        cp -r "/etc/letsencrypt" "$BACKUP_DIR/letsencrypt.backup" 2>/dev/null || true
        print_success "Let's Encrypt directory backed up"
    fi

    # Backup existing certificate
    if [[ -f "$PIHOLE_CERT" ]]; then
        cp "$PIHOLE_CERT" "$BACKUP_DIR/tls.pem.backup"
        print_success "Existing certificate backed up"
    fi

    # Backup UPnP rules
    if command -v upnpc &> /dev/null; then
        upnpc -l > "$BACKUP_DIR/upnp-rules.backup" 2>&1 || true
        print_success "UPnP rules backed up"
    fi

    # Backup systemd services
    if [[ -f "/etc/systemd/system/pihole-upnp.service" ]]; then
        cp "/etc/systemd/system/pihole-upnp.service" "$BACKUP_DIR/"
    fi

    # Save installation state
    cat > "$BACKUP_DIR/installation.state" << EOF
DOMAIN="$DOMAIN"
EMAIL="$EMAIL"
WEB_PORT="$WEB_PORT"
DNS_TLS_PORT="$DNS_TLS_PORT"
INTERFACE="$INTERFACE"
LOCAL_IP="$LOCAL_IP"
USE_UPNP="$USE_UPNP"
INSTALL_DATE="$(date)"
SCRIPT_VERSION="$SCRIPT_VERSION"
OS_TYPE="$OS_TYPE"
OS_VERSION="$OS_VERSION"
EOF

    # List backed up files
    print_message "Backup contents:"
    ls -la "$BACKUP_DIR" | tee -a "$LOG_FILE"

    print_success "Backup completed at: $BACKUP_DIR"
}

# Function to restore from backup
perform_restore() {
    print_section "Restoring from Backup"

    if [[ ! -d "$BACKUP_DIR" ]]; then
        print_error "No backup directory found at $BACKUP_DIR"
        return 1
    fi

    # Restore Pi-hole config
    if [[ -f "$BACKUP_DIR/pihole.toml.backup" ]]; then
        cp "$BACKUP_DIR/pihole.toml.backup" "$PIHOLE_CONFIG"
        print_success "Restored Pi-hole configuration"
    fi

    # Restore certificates
    if [[ -f "$BACKUP_DIR/tls.pem.backup" ]]; then
        cp "$BACKUP_DIR/tls.pem.backup" "$PIHOLE_CERT" 2>/dev/null || true
        print_success "Restored certificate"
    fi

    # Remove encryption state file
    if [[ -f "$INSTALL_STATE_FILE" ]]; then
        rm "$INSTALL_STATE_FILE"
        print_success "Removed installation state"
    fi

    # Restart Pi-hole with original config
    systemctl restart pihole-FTL

    print_success "Restore completed"
}

# Function to uninstall
uninstall() {
    print_section "Uninstalling Pi-hole Encryption"

    echo -e "${YELLOW}This will remove all encryption configurations and restore backups.${NC}"
    echo -e "${RED}Warning: This will also remove Let's Encrypt certificates!${NC}"
    read -p "Are you sure you want to uninstall? (y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        return 1
    fi

    # Remove UPnP rules
    if command -v upnpc &> /dev/null && [[ "$USE_UPNP" == "true" ]]; then
        print_message "Removing UPnP port forwarding rules..."
        upnpc -d "$WEB_PORT" tcp 2>/dev/null || true
        upnpc -d "$DNS_TLS_PORT" tcp 2>/dev/null || true
        upnpc -d "$DNS_TLS_PORT" udp 2>/dev/null || true
    fi

    # Remove systemd services
    if [[ -f "/etc/systemd/system/pihole-upnp.service" ]]; then
        systemctl stop pihole-upnp.service
        systemctl disable pihole-upnp.service
        rm "/etc/systemd/system/pihole-upnp.service"
        systemctl daemon-reload
    fi

    # Remove renewal hooks
    if [[ -f "/etc/letsencrypt/renewal-hooks/deploy/pihole.sh" ]]; then
        rm "/etc/letsencrypt/renewal-hooks/deploy/pihole.sh"
    fi

    # Restore from backup
    if [[ -d "$BACKUP_DIR" ]]; then
        perform_restore
    else
        # Try to find latest backup
        LATEST_BACKUP=$(ls -d /root/pihole-backup-* 2>/dev/null | sort -r | head -n1)
        if [[ -n "$LATEST_BACKUP" ]]; then
            print_message "Found backup at $LATEST_BACKUP"
            BACKUP_DIR="$LATEST_BACKUP"
            perform_restore
        else
            print_warning "No backup found. Resetting to default configuration..."
            # Reset Pi-hole to default config
            systemctl stop pihole-FTL
            mv "$PIHOLE_CONFIG" "${PIHOLE_CONFIG}.uninstalled" 2>/dev/null || true
            systemctl start pihole-FTL
        fi
    fi

    # Remove certificates
    if [[ -d "/etc/letsencrypt/live/$DOMAIN" ]]; then
        print_message "Removing Let's Encrypt certificates for $DOMAIN..."
        certbot delete --cert-name "$DOMAIN" --non-interactive || true
    fi

    # Remove combined certificate
    if [[ -f "$PIHOLE_CERT" ]]; then
        rm "$PIHOLE_CERT"
    fi

    print_success "Uninstallation completed"
}

# Function to check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root"
        exit 1
    fi
}

# Function to check Pi-hole version
check_pihole_version() {
    print_section "Checking Pi-hole Version"

    if ! command -v pihole &> /dev/null; then
        print_error "Pi-hole is not installed"
        exit 1
    fi

    # Check if it's v6
    if pihole-FTL --version 2>&1 | grep -q "v6"; then
        PIHOLE_VERSION=$(pihole-FTL --version | head -n1)
        print_success "Pi-hole v6 detected: $PIHOLE_VERSION"
    else
        CURRENT_VERSION=$(pihole-FTL --version 2>&1 | head -n1)
        print_error "Pi-hole v6 is required for this script"
        print_error "Current version: $CURRENT_VERSION"
        echo ""
        echo "Please upgrade to Pi-hole v6 first:"
        echo "  pihole -up"
        echo ""
        echo "Or visit: https://github.com/pi-hole/pi-hole/#upgrading"
        exit 1
    fi
}

# Function to check if already installed
check_installed() {
    if [[ -f "$INSTALL_STATE_FILE" ]]; then
        print_section "Existing Installation Detected"
        source "$INSTALL_STATE_FILE"
        echo -e "${CYAN}Currently installed:${NC}"
        echo "  Domain: $INSTALLED_DOMAIN"
        echo "  Web Port: $INSTALLED_WEB_PORT"
        echo "  Installed on: $INSTALLED_DATE"
        echo ""
        echo "Options:"
        echo "  1) Reinstall/Update (keeps existing certificates)"
        echo "  2) Uninstall (remove everything)"
        echo "  3) Exit"
        read -p "Choose option (1-3): " install_choice

        case $install_choice in
            1)
                print_message "Proceeding with reinstall..."
                DOMAIN="$INSTALLED_DOMAIN"
                EMAIL="$INSTALLED_EMAIL"
                WEB_PORT="$INSTALLED_WEB_PORT"
                USE_UPNP="$INSTALLED_USE_UPNP"
                LETSENCRYPT_DIR="/etc/letsencrypt/live/${DOMAIN}"
                ;;
            2)
                uninstall
                exit 0
                ;;
            3)
                exit 0
                ;;
            *)
                print_error "Invalid choice"
                exit 1
                ;;
        esac
    fi
}

# Function to prompt for configuration
prompt_config() {
    print_section "Configuration Setup"

    if [[ -z "$DOMAIN" ]]; then
        echo -e "${YELLOW}Enter your domain (e.g., dns.example.com):${NC}"
        read -p "Domain: " DOMAIN
    fi

    # Validate domain format
    if [[ ! "$DOMAIN" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        print_error "Invalid domain format"
        exit 1
    fi

    if [[ -z "$EMAIL" ]]; then
        echo -e "${YELLOW}Enter your email for Let's Encrypt notifications:${NC}"
        read -p "Email: " EMAIL
        LE_EMAIL="$EMAIL"
    fi

    # Validate email format
    if [[ ! "$EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        print_error "Invalid email format"
        exit 1
    fi

    # Auto-detect local IP
    get_local_ip

    # Choose ports
    choose_ports

    # Ask about UPnP
    echo -e "${YELLOW}Enable UPnP port forwarding? (recommended if router supports it)${NC}"
    read -p "Enable UPnP? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        USE_UPNP="true"
    else
        USE_UPNP="false"
    fi

    # Update Let's Encrypt path
    LETSENCRYPT_DIR="/etc/letsencrypt/live/${DOMAIN}"

    # Test ports
    test_ports

    # Show configuration summary
    print_message "Configuration Summary:"
    echo -e "  ${CYAN}Domain:${NC} $DOMAIN"
    echo -e "  ${CYAN}Email:${NC} $EMAIL"
    echo -e "  ${CYAN}Local IP:${NC} $LOCAL_IP"
    echo -e "  ${CYAN}Web/DoH Port:${NC} $WEB_PORT"
    echo -e "  ${CYAN}DoT/DoQ Port:${NC} $DNS_TLS_PORT"
    echo -e "  ${CYAN}Interface:${NC} $INTERFACE"
    echo -e "  ${CYAN}UPnP Enabled:${NC} $USE_UPNP"
    echo ""
    echo -e "  ${YELLOW}Endpoints that will be configured:${NC}"
    echo -e "  ${GREEN}HTTPS Web Interface:${NC} https://$DOMAIN:$WEB_PORT/admin"
    echo -e "  ${GREEN}DNS-over-HTTPS (DoH):${NC} https://$DOMAIN:$WEB_PORT/dns-query"
    echo -e "  ${GREEN}DNS-over-TLS (DoT):${NC} tls://$DOMAIN:$DNS_TLS_PORT"
    echo -e "  ${GREEN}DNS-over-QUIC (DoQ):${NC} quic://$DOMAIN:$DNS_TLS_PORT"
    echo ""

    read -p "Continue with this configuration? (y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
}

# Function to configure UPnP port forwarding
configure_upnp() {
    print_section "Configuring UPnP Port Forwarding"

    if [[ "$USE_UPNP" != "true" ]]; then
        print_message "UPnP disabled. Skipping port forwarding."
        return
    fi

    if ! command -v upnpc &> /dev/null; then
        print_error "UPnP client (upnpc) not found. Please install miniupnpc"
        return
    fi

    print_message "Checking UPnP gateway..."

    # Test UPnP connectivity
    if ! upnpc -l &> /dev/null; then
        print_error "No UPnP gateway found. Please enable UPnP on your router."
        print_warning "You'll need to forward ports manually:"
        echo "  - Forward TCP $WEB_PORT to $LOCAL_IP:$WEB_PORT (HTTPS/DoH)"
        echo "  - Forward TCP $DNS_TLS_PORT to $LOCAL_IP:$DNS_TLS_PORT (DoT)"
        echo "  - Forward UDP $DNS_TLS_PORT to $LOCAL_IP:$DNS_TLS_PORT (DoQ)"
        return
    fi

    print_success "UPnP gateway detected"

    # Remove existing rules for these ports (optional)
    print_message "Checking for existing port forwarding rules..."
    upnpc -l | grep -E "$WEB_PORT|$DNS_TLS_PORT" || true

    # Add port forwarding rules
    print_message "Adding port forwarding rules..."

    # TCP for Web/DoH
    print_message "Forwarding TCP $WEB_PORT -> $LOCAL_IP:$WEB_PORT (HTTPS/DoH)"
    if upnpc -a "$LOCAL_IP" "$WEB_PORT" "$WEB_PORT" tcp >> "$LOG_FILE" 2>&1; then
        print_success "UPnP rule added for TCP port $WEB_PORT"
    else
        print_error "Failed to add UPnP rule for TCP $WEB_PORT"
    fi

    # TCP for DoT
    print_message "Forwarding TCP $DNS_TLS_PORT -> $LOCAL_IP:$DNS_TLS_PORT (DoT)"
    if upnpc -a "$LOCAL_IP" "$DNS_TLS_PORT" "$DNS_TLS_PORT" tcp >> "$LOG_FILE" 2>&1; then
        print_success "UPnP rule added for TCP port $DNS_TLS_PORT"
    else
        print_error "Failed to add UPnP rule for TCP $DNS_TLS_PORT"
    fi

    # UDP for DoQ
    print_message "Forwarding UDP $DNS_TLS_PORT -> $LOCAL_IP:$DNS_TLS_PORT (DoQ)"
    if upnpc -a "$LOCAL_IP" "$DNS_TLS_PORT" "$DNS_TLS_PORT" udp >> "$LOG_FILE" 2>&1; then
        print_success "UPnP rule added for UDP port $DNS_TLS_PORT"
    else
        print_error "Failed to add UPnP rule for UDP $DNS_TLS_PORT"
    fi

    # Verify rules
    print_message "Verifying UPnP rules..."
    upnpc -l | tee -a "$LOG_FILE"

    print_success "UPnP port forwarding configured"
    print_warning "Note: UPnP rules may need to be re-added after router restart"
}

# Function to configure firewall
configure_firewall() {
    print_section "Configuring Firewall"

    # Check if ufw is available
    if command -v ufw &> /dev/null; then
        print_message "Opening required ports in UFW..."

        # HTTP for certbot
        ufw allow 80/tcp comment 'HTTP for Certbot' >> "$LOG_FILE" 2>&1

        # HTTPS web interface + DoH
        ufw allow "$WEB_PORT"/tcp comment 'Pi-hole HTTPS Web + DoH' >> "$LOG_FILE" 2>&1

        # DNS-over-TLS
        ufw allow "$DNS_TLS_PORT"/tcp comment 'DNS-over-TLS' >> "$LOG_FILE" 2>&1

        # DNS-over-QUIC (UDP)
        ufw allow "$DNS_TLS_PORT"/udp comment 'DNS-over-QUIC' >> "$LOG_FILE" 2>&1

        print_success "Firewall configured"
        ufw status | grep -E "80|$WEB_PORT|$DNS_TLS_PORT" | tee -a "$LOG_FILE"
    else
        print_warning "UFW not found. Please manually configure firewall:"
        echo "  - Open TCP 80 (HTTP for certbot)"
        echo "  - Open TCP $WEB_PORT (HTTPS web + DoH)"
        echo "  - Open TCP $DNS_TLS_PORT (DoT)"
        echo "  - Open UDP $DNS_TLS_PORT (DoQ)"
    fi
}

# Function to obtain Let's Encrypt certificate
obtain_certificate() {
    print_section "Obtaining SSL Certificate"

    print_message "Checking for existing certificate for $DOMAIN..."

    if [[ -d "$LETSENCRYPT_DIR" ]]; then
        print_warning "Certificate already exists"
        CERT_EXPIRY=$(openssl x509 -enddate -noout -in "$LETSENCRYPT_DIR/cert.pem" 2>/dev/null | cut -d= -f2)
        print_message "Current certificate expires: $CERT_EXPIRY"

        read -p "Do you want to renew it? (y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            certbot renew --cert-name "$DOMAIN" >> "$LOG_FILE" 2>&1
            print_success "Certificate renewed"
        fi
    else
        # Ensure port 80 is free
        if check_port "80" "tcp"; then
            print_warning "Port 80 is in use. Attempting to free it..."
            stop_conflicting_services
        fi

        # Obtain certificate
        print_message "Requesting certificate from Let's Encrypt..."
        print_message "This may take a few minutes..."

        if certbot certonly --standalone \
            --non-interactive \
            --agree-tos \
            --email "$EMAIL" \
            -d "$DOMAIN" >> "$LOG_FILE" 2>&1; then
            print_success "Certificate obtained successfully"
        else
            print_error "Failed to obtain certificate"
            print_message "Check $LOG_FILE for details"
            exit 1
        fi
    fi

    # Display certificate info
    print_message "Certificate details:"
    openssl x509 -in "$LETSENCRYPT_DIR/cert.pem" -text -noout | grep -E "Subject:|Not Before:|Not After :|DNS:" | tee -a "$LOG_FILE"
}

# Function to combine certificates
combine_certificates() {
    print_section "Preparing Certificate for Pi-hole"

    if [[ ! -f "${LETSENCRYPT_DIR}/fullchain.pem" ]] || [[ ! -f "${LETSENCRYPT_DIR}/privkey.pem" ]]; then
        print_error "Certificate files not found in ${LETSENCRYPT_DIR}"
        exit 1
    fi

    # Combine fullchain and private key
    print_message "Creating combined certificate file..."
    cat "${LETSENCRYPT_DIR}/fullchain.pem" "${LETSENCRYPT_DIR}/privkey.pem" > "${PIHOLE_CERT}"

    # Set proper permissions
    chown pihole:pihole "${PIHOLE_CERT}"
    chmod 600 "${PIHOLE_CERT}"

    print_success "Certificate combined and installed at: $PIHOLE_CERT"

    # Verify the combined certificate
    print_message "Verifying combined certificate..."
    if openssl x509 -in "$PIHOLE_CERT" -noout -text > /dev/null 2>&1; then
        print_success "Certificate verification passed"
    else
        print_error "Certificate verification failed"
        exit 1
    fi
}

# Function to configure Pi-hole v6
configure_pihole() {
    print_section "Configuring Pi-hole for All Encryption Methods"

    # Backup current config
    cp "$PIHOLE_CONFIG" "${BACKUP_DIR}/pihole.toml.pre-setup"

    print_message "Setting up HTTPS web interface..."
    pihole-FTL config webserver.domain "$DOMAIN"
    pihole-FTL config webserver.tls.cert "$PIHOLE_CERT"
    pihole-FTL config webserver.port "$WEB_PORT"
    pihole-FTL config webserver.interface "$INTERFACE"
    pihole-FTL config webserver.tls.enable true

    print_message "Configuring DNS encryption ports..."

    # Configure DNS-over-TLS (DoT)
    print_message "Setting up DNS-over-TLS on port $DNS_TLS_PORT..."
    pihole-FTL config dns.port 53
    pihole-FTL config dns.dot.enabled true
    pihole-FTL config dns.dot.port "$DNS_TLS_PORT"
    pihole-FTL config dns.dot.cert "$PIHOLE_CERT"
    pihole-FTL config dns.dot.key "$PIHOLE_CERT"

    # Configure DNS-over-QUIC (DoQ)
    print_message "Setting up DNS-over-QUIC on port $DNS_TLS_PORT..."
    pihole-FTL config dns.doq.enabled true
    pihole-FTL config dns.doq.port "$DNS_TLS_PORT"
    pihole-FTL config dns.doq.cert "$PIHOLE_CERT"
    pihole-FTL config dns.doq.key "$PIHOLE_CERT"

    # Enable DNS-over-HTTPS (DoH)
    print_message "Setting up DNS-over-HTTPS on port $WEB_PORT..."
    pihole-FTL config dns.doh.enabled true
    pihole-FTL config dns.doh.path "/dns-query"

    # Configure additional DNS settings
    pihole-FTL config dns.rateLimit.enabled false
    pihole-FTL config dns.blocking.enabled true

    print_success "Pi-hole encryption configuration completed"

    # Save installation state
    cat > "$INSTALL_STATE_FILE" << EOF
INSTALLED_DOMAIN="$DOMAIN"
INSTALLED_EMAIL="$EMAIL"
INSTALLED_WEB_PORT="$WEB_PORT"
INSTALLED_DNS_TLS_PORT="$DNS_TLS_PORT"
INSTALLED_INTERFACE="$INTERFACE"
INSTALLED_LOCAL_IP="$LOCAL_IP"
INSTALLED_USE_UPNP="$USE_UPNP"
INSTALLED_DATE="$(date)"
INSTALLED_VERSION="$SCRIPT_VERSION"
EOF

    # Show current config
    print_message "Current DNS encryption configuration:"
    pihole-FTL config | grep -A 15 "dns\." | grep -E "port|enabled|cert|path|doh|dot|doq" | tee -a "$LOG_FILE"
}

# Function to restart Pi-hole
restart_pihole() {
    print_section "Restarting Pi-hole"

    print_message "Restarting pihole-FTL service..."
    systemctl restart pihole-FTL

    # Wait for service to start
    local max_attempts=10
    local attempt=1
    while [[ $attempt -le $max_attempts ]]; do
        if systemctl is-active --quiet pihole-FTL; then
            print_success "Pi-hole restarted successfully"
            break
        fi
        print_message "Waiting for Pi-hole to start (attempt $attempt/$max_attempts)..."
        sleep 3
        ((attempt++))
    done

    if [[ $attempt -gt $max_attempts ]]; then
        print_error "Pi-hole failed to restart"
        print_message "Check logs: journalctl -u pihole-FTL -f"
        exit 1
    fi
}

# Function to create auto-renewal hook
setup_auto_renewal() {
    print_section "Configuring Auto-Renewal"

    # Create renewal hook script
    cat > /etc/letsencrypt/renewal-hooks/deploy/pihole.sh << 'EOF'
#!/bin/bash
# Pi-hole comprehensive renewal hook for DoH/DoT/DoQ

DOMAIN="$RENEWED_DOMAINS"
if [ -z "$DOMAIN" ]; then
    # Try to get domain from certificate
    DOMAIN=$(openssl x509 -in /etc/letsencrypt/live/*/cert.pem -text -noout 2>/dev/null | grep "DNS:" | head -n1 | sed 's/DNS://g' | tr -d ',')
fi

if [ -n "$DOMAIN" ] && [ -d "/etc/letsencrypt/live/$DOMAIN" ]; then
    logger "Pi-hole: Renewing certificates for $DOMAIN"

    # Combine certificates
    cat "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" \
        "/etc/letsencrypt/live/$DOMAIN/privkey.pem" > /etc/pihole/tls.pem

    # Set permissions
    chown pihole:pihole /etc/pihole/tls.pem
    chmod 600 /etc/pihole/tls.pem

    # Reload Pi-hole to use new certificate
    systemctl reload pihole-FTL

    logger "Pi-hole: Certificate renewed and reloaded for $DOMAIN"
fi
EOF

    chmod +x /etc/letsencrypt/renewal-hooks/deploy/pihole.sh

    # Test renewal process
    print_message "Testing certificate renewal process..."
    certbot renew --dry-run >> "$LOG_FILE" 2>&1

    if [[ $? -eq 0 ]]; then
        print_success "Auto-renewal configured successfully"
    else
        print_warning "Auto-renewal test had issues, but should still work"
    fi

    print_message "Renewal hook installed at: /etc/letsencrypt/renewal-hooks/deploy/pihole.sh"
}

# Function to verify endpoints
verify_endpoints() {
    print_section "Verifying Encryption Endpoints"

    # Wait for service to fully start
    sleep 5

    # Test HTTPS web interface locally
    print_message "Testing local HTTPS web interface..."
    if curl -k -s -o /dev/null -w "%{http_code}" "https://localhost:$WEB_PORT/admin" 2>/dev/null | grep -q "200\|302"; then
        print_success "Local HTTPS web interface is accessible"
    else
        print_warning "Local HTTPS web interface test failed"
    fi

    # Test DoH endpoint locally
    print_message "Testing local DNS-over-HTTPS endpoint..."
    if curl -k -s -o /dev/null -w "%{http_code}" \
        -H "content-type: application/dns-message" \
        "https://localhost:$WEB_PORT/dns-query" 2>/dev/null; then
        print_success "Local DoH endpoint is responding"
    else
        print_warning "Local DoH endpoint test failed (may need DNS query to test fully)"
    fi

    # Test TLS connection locally
    print_message "Testing local TLS availability..."
    if timeout 5 openssl s_client -connect "localhost:$DNS_TLS_PORT" -tls1_3 -servername "$DOMAIN" 2>&1 | grep -q "CONNECTED"; then
        print_success "Local TLS endpoint is available"
    else
        print_warning "Local TLS endpoint test failed"
    fi

    # Test QUIC port locally
    print_message "Testing local QUIC port availability..."
    if timeout 2 nc -u -z -w 2 localhost "$DNS_TLS_PORT" 2>/dev/null; then
        print_success "Local QUIC port is listening"
    else
        print_warning "Local QUIC port test failed"
    fi

    # Display endpoints
    echo ""
    echo -e "${GREEN}Your configured endpoints:${NC}"
    echo -e "  ${CYAN}Web Interface:${NC} https://$DOMAIN:$WEB_PORT/admin"
    echo -e "  ${CYAN}DNS-over-HTTPS:${NC} https://$DOMAIN:$WEB_PORT/dns-query"
    echo -e "  ${CYAN}DNS-over-TLS:${NC} tls://$DOMAIN:$DNS_TLS_PORT"
    echo -e "  ${CYAN}DNS-over-QUIC:${NC} quic://$DOMAIN:$DNS_TLS_PORT"
    echo ""
}

# Function to print summary
print_summary() {
    print_section "Setup Complete - Summary"

    echo -e "${GREEN}✓ Pi-hole v6 Encryption Setup Completed Successfully${NC}"
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}Your Encrypted DNS Endpoints:${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${YELLOW}Domain:${NC}              $DOMAIN"
    echo -e "  ${YELLOW}Local IP:${NC}           $LOCAL_IP"
    echo ""
    echo -e "  ${YELLOW}Web Admin:${NC}        ${GREEN}https://$DOMAIN:$WEB_PORT/admin${NC}"
    echo -e "  ${YELLOW}DNS-over-HTTPS:${NC}   ${GREEN}https://$DOMAIN:$WEB_PORT/dns-query${NC}"
    echo -e "  ${YELLOW}DNS-over-TLS:${NC}     ${GREEN}tls://$DOMAIN:$DNS_TLS_PORT${NC}"
    echo -e "  ${YELLOW}DNS-over-QUIC:${NC}    ${GREEN}quic://$DOMAIN:$DNS_TLS_PORT${NC}"
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}Port Forwarding Status:${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    if [[ "$USE_UPNP" == "true" ]]; then
        echo -e "  ${GREEN}✓ UPnP port forwarding configured${NC}"
    else
        echo -e "  ${YELLOW}✗ UPnP disabled - forward manually:${NC}"
    fi
    echo -e "  TCP ${WEB_PORT} -> ${LOCAL_IP}:${WEB_PORT} (HTTPS Web + DoH)"
    echo -e "  TCP ${DNS_TLS_PORT} -> ${LOCAL_IP}:${DNS_TLS_PORT} (DoT)"
    echo -e "  UDP ${DNS_TLS_PORT} -> ${LOCAL_IP}:${DNS_TLS_PORT} (DoQ)"
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}Backup Information:${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  Backup location:     ${BLUE}$BACKUP_DIR${NC}"
    echo -e "  Log file:            ${BLUE}$LOG_FILE${NC}"
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}Management Commands:${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  Check status:        ${YELLOW}systemctl status pihole-FTL${NC}"
    echo -e "  View logs:           ${YELLOW}journalctl -u pihole-FTL -f${NC}"
    echo -e "  Test DoH:            ${YELLOW}curl -k https://localhost:$WEB_PORT/dns-query${NC}"
    echo -e "  Check UPnP rules:    ${YELLOW}upnpc -l${NC}"
    echo -e "  Renew certificate:   ${YELLOW}certbot renew${NC}"
    echo -e "  Uninstall:           ${YELLOW}$0 --uninstall${NC}"
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}Thank you for using Pi-hole Encryption Setup!${NC}"
    echo -e "${GREEN}GitHub: https://github.com/waelisa/pihole-encryption${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# Function to setup UPnP persistence
setup_upnp_persistence() {
    if [[ "$USE_UPNP" == "true" ]] && command -v upnpc &> /dev/null; then
        print_section "Setting UPnP Persistence"

        # Create a systemd service to reapply UPnP rules on boot
        cat > /etc/systemd/system/pihole-upnp.service << EOF
[Unit]
Description=Pi-hole UPnP Port Forwarding
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/pihole-upnp-forward.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

        # Create the UPnP forwarding script
        cat > /usr/local/bin/pihole-upnp-forward.sh << EOF
#!/bin/bash
# Reapply Pi-hole UPnP port forwarding after reboot

LOCAL_IP="$LOCAL_IP"
WEB_PORT="$WEB_PORT"
DNS_TLS_PORT="$DNS_TLS_PORT"

logger "Pi-hole UPnP: Reapplying port forwarding rules"

# Wait for network
sleep 10

# Add port forwarding rules
upnpc -a "\$LOCAL_IP" "\$WEB_PORT" "\$WEB_PORT" tcp > /dev/null 2>&1
upnpc -a "\$LOCAL_IP" "\$DNS_TLS_PORT" "\$DNS_TLS_PORT" tcp > /dev/null 2>&1
upnpc -a "\$LOCAL_IP" "\$DNS_TLS_PORT" "\$DNS_TLS_PORT" udp > /dev/null 2>&1

logger "Pi-hole UPnP: Port forwarding rules applied"
EOF

        chmod +x /usr/local/bin/pihole-upnp-forward.sh

        # Enable the service
        systemctl daemon-reload
        systemctl enable pihole-upnp.service

        print_success "UPnP persistence configured - rules will reapply on boot"
    fi
}

# Function to show help
show_help() {
    echo "Pi-hole Encryption Setup Script v$SCRIPT_VERSION"
    echo ""
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --uninstall     Remove encryption and restore original configuration"
    echo "  --help          Show this help message"
    echo "  --version       Show script version"
    echo ""
    echo "GitHub: https://github.com/waelisa/pihole-encryption"
}

# Main execution
main() {
    # Parse command line arguments
    case $1 in
        --uninstall)
            if [[ -f "$INSTALL_STATE_FILE" ]]; then
                source "$INSTALL_STATE_FILE"
                uninstall
            else
                print_error "No installation found to uninstall"
                exit 1
            fi
            exit 0
            ;;
        --help)
            show_help
            exit 0
            ;;
        --version)
            echo "Pi-hole Encryption Setup v$SCRIPT_VERSION"
            exit 0
            ;;
        "")
            # Normal installation
            ;;
        *)
            print_error "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac

    echo -e "${GREEN}═══════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}         Pi-hole v6 Encryption Setup (DoH/DoT/DoQ) v$SCRIPT_VERSION${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}GitHub: https://github.com/waelisa/pihole-encryption${NC}"
    echo ""

    check_root
    detect_os
    check_pihole_version
    check_installed
    install_dependencies
    prompt_config
    create_backup
    obtain_certificate
    combine_certificates
    configure_pihole
    configure_firewall
    configure_upnp
    setup_upnp_persistence
    restart_pihole
    setup_auto_renewal
    verify_endpoints
    print_summary

    echo ""
    print_success "Setup complete! Please check the summary above."
    print_message "All configurations saved to: $BACKUP_DIR"
    print_message "Log file: $LOG_FILE"
}

# Run main function with all arguments
main "$@"
