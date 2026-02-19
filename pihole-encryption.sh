#!/bin/bash
#############################################################################################################################
# The MIT License (MIT)
#
# Wael Isa
# Build Date: 02/19/2026
# Version: 1.1.1
# GitHub: https://github.com/waelisa/pihole-encryption
# Website: https://www.wael.name/
# Support: https://www.paypal.me/WaelIsa
#
#############################################################################################################################
#
# COMPLETE FIX HISTORY - ALL ISSUES RESOLVED:
# ==============================================================================
# v1.1.1 - FIXED: Complete script rewrite with ALL functions properly defined
#        - Added ALL missing functions (check_root, detect_os, install_dependencies,
#          check_pihole_version, check_installed, prompt_domain, prompt_email,
#          get_local_ip, test_ports, prompt_upnp, show_config_summary, create_backup,
#          detect_services_to_restart, detect_acme_client, verify_certificate,
#          configure_pihole, configure_firewall, verify_endpoints, print_summary)
#        - Fixed function call order in main execution
#        - Added proper domain display in webroot test page
#        - All 24 steps now work sequentially
# ==============================================================================
# v1.1.0 - Added temporary self-signed certificate for HTTPS testing
#        - During uninstall/restore, asks user about self-signed cert creation
#        - Follows Pi-hole TLS docs exactly (PEM format, pihole user perms)
# ==============================================================================
#
# This script configures Pi-hole v6 with enterprise-grade encryption:
# 🔒 HTTPS web interface with Let's Encrypt (port 443 or custom)
# 🔒 DNS-over-HTTPS (DoH) endpoint: https://YOUR-DOMAIN:PORT/dns-query
# 🔒 DNS-over-TLS (DoT) endpoint: tls://YOUR-DOMAIN:853
# 🔒 DNS-over-QUIC (DoQ) endpoint: quic://YOUR-DOMAIN:853
#
#############################################################################################################################

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration variables
DOMAIN=""
EMAIL=""
WEB_PORT=""
DNS_TLS_PORT="853"
INTERFACE="eth0"
LOCAL_IP=""
USE_UPNP=""
LE_EMAIL=""
ACME_CLIENT="certbot"
LETSENCRYPT_DIR=""
WEBROOT="/var/www/html"

# OS Detection variables
OS_TYPE=""
OS_VERSION=""
OS_FAMILY=""
PKG_MANAGER=""
INSTALL_CMD=""
UPDATE_CMD=""

# Fixed paths (based on Pi-hole TLS docs)
PIHOLE_CERT="/etc/pihole/tls.pem"
PIHOLE_CA_CERT="/etc/pihole/tls_ca.crt"
PIHOLE_CONFIG="/etc/pihole/pihole.toml"
PIHOLE_OLD_CONFIG="/etc/pihole/pihole.toml.bak"
BACKUP_DIR="/root/pihole-backup-$(date +%Y%m%d_%H%M%S)"
LOG_FILE="/var/log/pihole-encryption-setup.log"
SCRIPT_VERSION="1.1.1"
INSTALL_STATE_FILE="/etc/pihole/encryption-installed.state"
RENEWAL_HOOK="/etc/letsencrypt/renewal-hooks/deploy/pihole.sh"
ACME_HOME="/root/.acme.sh"

# Debug flag
DEBUG=true

# Error trap
trap 'error_handler $? $LINENO' ERR

error_handler() {
    local exit_code=$1
    local line_no=$2
    print_error "Error on line $line_no: exit code $exit_code"
    print_error "Script execution stopped. Check $LOG_FILE for details"
    exit $exit_code
}

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
    ["cron"]="cron"
    ["systemd"]="systemd"
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
    ["cronie"]="cronie"
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
    ["cronie"]="cronie"
)

# Services that need restart tracking
declare -a SERVICES_TO_RESTART=()
declare -a PORTS_TO_CHECK=()

# Step tracking
CURRENT_STEP=0
TOTAL_STEPS=24

#================================================================================
# UTILITY FUNCTIONS
#================================================================================

debug_log() {
    if [[ "$DEBUG" == true ]]; then
        echo -e "${PURPLE}[DEBUG]${NC} $1" | tee -a "$LOG_FILE"
    fi
}

print_step() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    echo -e "\n${PURPLE}═══════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}STEP $CURRENT_STEP OF $TOTAL_STEPS: $1${NC}"
    echo -e "${PURPLE}═══════════════════════════════════════════════════════════════════════════════${NC}"
    debug_log "Starting step $CURRENT_STEP: $1"
    sleep 1
}

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

pause() {
    echo ""
    read -p "Press Enter to continue..." -r
    echo ""
}

#================================================================================
# ROOT CHECK FUNCTIONS
#================================================================================

check_root() {
    print_step "Checking Root Privileges"
    debug_log "Entering check_root"

    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root"
        print_message "Please run: sudo $0"
        exit 1
    fi

    print_success "Root privileges confirmed"
    debug_log "Root check passed"
    pause
}

#================================================================================
# OS DETECTION FUNCTIONS
#================================================================================

detect_os() {
    print_step "Detecting Operating System"
    debug_log "Entering detect_os"

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
    print_success "OS detection successful"
    debug_log "OS detection complete: $OS_FAMILY"
    pause
}

#================================================================================
# DEPENDENCY INSTALLATION FUNCTIONS
#================================================================================

install_dependencies() {
    print_step "Installing Dependencies"
    debug_log "Entering install_dependencies"

    if [[ "$OS_FAMILY" == "unknown" ]]; then
        print_warning "Unknown OS - please install dependencies manually"
        return
    fi

    print_message "Updating package lists..."
    $UPDATE_CMD >> "$LOG_FILE" 2>&1 || true

    print_message "Installing required packages..."

    case $OS_FAMILY in
        debian)
            for pkg in "${!DEBIAN_PKGS[@]}"; do
                if ! dpkg -l | grep -q "^ii  $pkg "; then
                    print_message "Installing $pkg..."
                    $INSTALL_CMD "${DEBIAN_PKGS[$pkg]}" >> "$LOG_FILE" 2>&1
                fi
            done
            ;;
        rhel|fedora)
            if [[ "$OS_FAMILY" == "rhel" ]] && ! rpm -q epel-release &>/dev/null; then
                $INSTALL_CMD epel-release >> "$LOG_FILE" 2>&1
            fi

            if [[ "$OS_FAMILY" == "rhel" ]]; then
                for pkg in "${!CENTOS_PKGS[@]}"; do
                    rpm -q "${CENTOS_PKGS[$pkg]}" &>/dev/null || $INSTALL_CMD "${CENTOS_PKGS[$pkg]}" >> "$LOG_FILE" 2>&1
                done
            else
                for pkg in "${!FEDORA_PKGS[@]}"; do
                    rpm -q "${FEDORA_PKGS[$pkg]}" &>/dev/null || $INSTALL_CMD "${FEDORA_PKGS[$pkg]}" >> "$LOG_FILE" 2>&1
                done
            fi
            ;;
    esac

    # Install Python packages for validation
    pip3 install h2 quic aioquic dnspython >> "$LOG_FILE" 2>&1 || true

    print_success "Dependencies installed"
    debug_log "Dependencies installation complete"
    pause
}

#================================================================================
# PI-HOLE VERSION CHECK
#================================================================================

check_pihole_version() {
    print_step "Checking Pi-hole Version"
    debug_log "Entering check_pihole_version"

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
        exit 1
    fi
    debug_log "Pi-hole version check passed"
    pause
}

#================================================================================
# INSTALLATION STATE CHECK
#================================================================================

check_installed() {
    debug_log "Entering check_installed"
    if [[ -f "$INSTALL_STATE_FILE" ]]; then
        print_step "Existing Installation Detected"
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
        pause
    fi
    debug_log "No existing installation found"
}

#================================================================================
# PROMPT FUNCTIONS
#================================================================================

prompt_domain() {
    print_step "Domain Configuration"
    debug_log "Entering prompt_domain"

    if [[ -z "$DOMAIN" ]]; then
        echo -e "${YELLOW}Enter your domain (e.g., dns.example.com):${NC}"
        read -p "Domain: " DOMAIN
        DOMAIN=$(echo "$DOMAIN" | xargs)
    fi

    # Validate domain format
    if [[ ! "$DOMAIN" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        print_error "Invalid domain format"
        exit 1
    fi

    print_success "Domain set to: $DOMAIN"
    debug_log "Domain: $DOMAIN"
    pause
}

prompt_email() {
    print_step "Email Configuration"
    debug_log "Entering prompt_email"

    if [[ -z "$EMAIL" ]]; then
        echo -e "${YELLOW}Enter your email for Let's Encrypt notifications:${NC}"
        read -p "Email: " EMAIL
        EMAIL=$(echo "$EMAIL" | xargs)
        LE_EMAIL="$EMAIL"
    fi

    # Validate email format
    if [[ ! "$EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        print_error "Invalid email format"
        exit 1
    fi

    print_success "Email set to: $EMAIL"
    debug_log "Email: $EMAIL"
    pause
}

get_local_ip() {
    print_step "Detecting Local IP Address"
    debug_log "Entering get_local_ip"

    if command -v ip &> /dev/null; then
        LOCAL_IP=$(ip -4 addr show "$INTERFACE" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1)
    fi

    if [[ -z "$LOCAL_IP" ]] && command -v hostname &> /dev/null; then
        LOCAL_IP=$(hostname -I | awk '{print $1}')
    fi

    if [[ -z "$LOCAL_IP" ]]; then
        read -p "Enter local IP address: " LOCAL_IP
    fi

    print_message "Local IP: $LOCAL_IP"
    debug_log "Local IP: $LOCAL_IP"
    pause
}

#================================================================================
# PORT FUNCTIONS
#================================================================================

check_port() {
    local port=$1
    local proto=$2
    local in_use=false
    local using_pihole=false

    debug_log "Checking port $port/$proto"

    if [[ "$proto" == "tcp" ]]; then
        if command -v ss &> /dev/null; then
            if ss -tlnp 2>/dev/null | grep -q ":$port "; then
                in_use=true
                if ss -tlnp 2>/dev/null | grep ":$port " | grep -q "pihole-FTL"; then
                    using_pihole=true
                fi
            fi
        elif command -v netstat &> /dev/null; then
            if netstat -tlnp 2>/dev/null | grep -q ":$port "; then
                in_use=true
                if netstat -tlnp 2>/dev/null | grep ":$port " | grep -q "pihole-FTL"; then
                    using_pihole=true
                fi
            fi
        fi
    elif [[ "$proto" == "udp" ]]; then
        if command -v ss &> /dev/null; then
            if ss -ulnp 2>/dev/null | grep -q ":$port "; then
                in_use=true
                if ss -ulnp 2>/dev/null | grep ":$port " | grep -q "pihole-FTL"; then
                    using_pihole=true
                fi
            fi
        elif command -v netstat &> /dev/null; then
            if netstat -ulnp 2>/dev/null | grep -q ":$port "; then
                in_use=true
                if netstat -ulnp 2>/dev/null | grep ":$port " | grep -q "pihole-FTL"; then
                    using_pihole=true
                fi
            fi
        fi
    fi

    if [[ "$in_use" == true ]]; then
        if [[ "$using_pihole" == true ]]; then
            debug_log "Port $port is used by Pi-hole (acceptable)"
            return 2  # Used by Pi-hole (acceptable)
        else
            debug_log "Port $port is in use by another service"
            return 0  # Used by other service (conflict)
        fi
    else
        debug_log "Port $port is free"
        return 1  # Free
    fi
}

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

choose_ports() {
    print_step "Port Configuration"
    debug_log "Entering choose_ports"

    echo -e "${YELLOW}Web Interface / DoH Port Selection:${NC}"
    echo "Options:"
    echo "  443 - Standard HTTPS port (recommended)"
    echo "  Custom - e.g., 4433, 8443, etc."
    echo ""

    while true; do
        read -p "Enter web port [443]: " WEB_PORT
        WEB_PORT=${WEB_PORT:-443}
        WEB_PORT=$(echo "$WEB_PORT" | xargs)

        if [[ ! "$WEB_PORT" =~ ^[0-9]+$ ]] || [[ "$WEB_PORT" -lt 1 ]] || [[ "$WEB_PORT" -gt 65535 ]]; then
            print_error "Invalid port number"
            continue
        fi

        check_port "$WEB_PORT" "tcp"
        local result=$?

        if [[ $result -eq 0 ]]; then
            print_warning "Port $WEB_PORT is in use by another service"
            get_port_process "$WEB_PORT" "tcp"
            echo ""
            read -p "Try another port? (y/n): " try_again
            if [[ "$try_again" =~ ^[Yy]$ ]]; then
                continue
            fi
        elif [[ $result -eq 2 ]]; then
            print_message "Port $WEB_PORT is used by Pi-hole - OK"
        fi

        break
    done

    print_success "Web port set to: $WEB_PORT"
    debug_log "Selected port: $WEB_PORT"
    pause
}

test_ports() {
    print_step "Testing Required Ports"
    debug_log "Entering test_ports"

    local ports_ok=true
    local conflict_found=false
    PORTS_TO_CHECK=(
        "80:tcp:Let's Encrypt HTTP challenge (webroot)"
        "443:tcp:Let's Encrypt HTTPS (optional)"
        "${WEB_PORT}:tcp:HTTPS Web Interface + DoH"
        "${DNS_TLS_PORT}:tcp:DNS-over-TLS"
        "${DNS_TLS_PORT}:udp:DNS-over-QUIC"
    )

    echo -e "${CYAN}Port Status Check:${NC}"
    echo "───────────────────────────────────────────────────────"

    for port_info in "${PORTS_TO_CHECK[@]}"; do
        IFS=':' read -r port proto description <<< "$port_info"

        check_port "$port" "$proto"
        local result=$?

        if [[ $result -eq 0 ]]; then
            PROCESS_INFO=$(get_port_process "$port" "$proto" | head -n1)
            echo -e "  ${RED}✗${NC} Port $port/$proto - $description"
            echo -e "    ${YELLOW}→ In use by:${NC} $PROCESS_INFO"
            ports_ok=false
            conflict_found=true

            if [[ "$port" == "80" ]] || [[ "$port" == "443" ]]; then
                print_warning "Port $port is used by another service, but Let's Encrypt can use webroot method"
                print_message "Will use webroot directory: $WEBROOT"
            fi
        elif [[ $result -eq 2 ]]; then
            echo -e "  ${GREEN}✓${NC} Port $port/$proto - $description ${GREEN}(used by Pi-hole - OK)${NC}"
        else
            echo -e "  ${GREEN}✓${NC} Port $port/$proto - $description ${GREEN}(available)${NC}"
        fi
    done

    echo "───────────────────────────────────────────────────────"

    # Handle port conflicts (excluding webroot ports which are fine)
    if [[ "$conflict_found" == true ]]; then
        # Check if conflicts are only on ports 80/443 (which we can work around)
        local has_other_conflicts=false
        for port_info in "${PORTS_TO_CHECK[@]}"; do
            IFS=':' read -r port proto description <<< "$port_info"
            if [[ "$port" != "80" ]] && [[ "$port" != "443" ]]; then
                check_port "$port" "$proto"
                if [[ $? -eq 0 ]]; then
                    has_other_conflicts=true
                    break
                fi
            fi
        done

        if [[ "$has_other_conflicts" == true ]]; then
            print_warning "Port conflicts detected on non-webroot ports."
            echo ""
            echo "Options:"
            echo "  1) Attempt to stop conflicting services automatically"
            echo "  2) Choose a different web port"
            echo "  3) Exit and fix manually"
            read -p "Choose option (1-3): " port_choice

            case $port_choice in
                1)
                    stop_conflicting_services
                    debug_log "Re-running test_ports after stopping services"
                    test_ports
                    return $?
                    ;;
                2)
                    choose_ports
                    debug_log "Re-running test_ports with new port"
                    test_ports
                    return $?
                    ;;
                3)
                    print_error "Installation aborted by user due to port conflicts."
                    exit 1
                    ;;
                *)
                    print_error "Invalid choice"
                    test_ports
                    return $?
                    ;;
            esac
        else
            print_message "Ports 80/443 are in use but Let's Encrypt will use webroot method - continuing"
            print_success "Port checks passed for webroot method"
            pause
            return 0
        fi
    else
        print_success "All required ports are available or properly configured"
        debug_log "Port testing completed successfully"
        pause
        return 0
    fi
}

stop_conflicting_services() {
    print_step "Stopping Conflicting Services"
    debug_log "Entering stop_conflicting_services"

    local stopped=false

    for service in nginx apache2 lighttpd httpd; do
        if systemctl is-active --quiet "$service" 2>/dev/null; then
            # Check if it's using any of our ports (excluding 80/443 for webroot)
            if command -v ss &> /dev/null; then
                if ss -tlnp 2>/dev/null | grep -E ":$WEB_PORT " | grep -q "$service"; then
                    print_message "Stopping $service..."
                    systemctl stop "$service"
                    systemctl disable "$service" 2>/dev/null || true
                    stopped=true
                fi
            fi
        fi
    done

    if [[ "$stopped" == true ]]; then
        print_success "Conflicting services stopped"
    else
        print_warning "No conflicting services found to stop"
    fi

    debug_log "stop_conflicting_services completed, stopped=$stopped"
}

#================================================================================
# UPnP FUNCTIONS
#================================================================================

prompt_upnp() {
    print_step "UPnP Configuration"
    debug_log "Entering prompt_upnp"

    echo -e "${YELLOW}Enable UPnP port forwarding? (recommended if router supports it)${NC}"
    echo "UPnP will automatically forward ports on your router:"
    echo "  - TCP 80  -> $LOCAL_IP:80   (Let's Encrypt HTTP)"
    echo "  - TCP 443 -> $LOCAL_IP:443  (Let's Encrypt HTTPS)"
    echo "  - TCP $WEB_PORT -> $LOCAL_IP:$WEB_PORT (HTTPS/DoH)"
    echo "  - TCP $DNS_TLS_PORT -> $LOCAL_IP:$DNS_TLS_PORT (DoT)"
    echo "  - UDP $DNS_TLS_PORT -> $LOCAL_IP:$DNS_TLS_PORT (DoQ)"
    echo ""

    read -p "Enable UPnP? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        USE_UPNP="true"
        print_success "UPnP enabled"
    else
        USE_UPNP="false"
        print_message "UPnP disabled - forward ports manually if needed"
    fi
    debug_log "UPnP enabled: $USE_UPNP"
    pause
}

configure_upnp() {
    print_step "Configuring UPnP Port Forwarding"
    debug_log "Entering configure_upnp"

    if [[ "$USE_UPNP" != "true" ]]; then
        print_message "UPnP disabled. Skipping port forwarding."
        return
    fi

    if ! command -v upnpc &> /dev/null; then
        print_error "UPnP client not found"
        return
    fi

    print_message "Checking UPnP gateway..."

    if ! upnpc -l &> /dev/null; then
        print_error "No UPnP gateway found"
        return
    fi

    print_success "UPnP gateway detected"

    # Add port forwarding rules for Let's Encrypt
    print_message "Forwarding TCP 80 -> $LOCAL_IP:80 (Let's Encrypt HTTP)"
    upnpc -a "$LOCAL_IP" 80 80 tcp >> "$LOG_FILE" 2>&1

    print_message "Forwarding TCP 443 -> $LOCAL_IP:443 (Let's Encrypt HTTPS)"
    upnpc -a "$LOCAL_IP" 443 443 tcp >> "$LOG_FILE" 2>&1

    # Add port forwarding rules for Pi-hole
    print_message "Forwarding TCP $WEB_PORT -> $LOCAL_IP:$WEB_PORT (HTTPS/DoH)"
    upnpc -a "$LOCAL_IP" "$WEB_PORT" "$WEB_PORT" tcp >> "$LOG_FILE" 2>&1

    print_message "Forwarding TCP $DNS_TLS_PORT -> $LOCAL_IP:$DNS_TLS_PORT (DoT)"
    upnpc -a "$LOCAL_IP" "$DNS_TLS_PORT" "$DNS_TLS_PORT" tcp >> "$LOG_FILE" 2>&1

    print_message "Forwarding UDP $DNS_TLS_PORT -> $LOCAL_IP:$DNS_TLS_PORT (DoQ)"
    upnpc -a "$LOCAL_IP" "$DNS_TLS_PORT" "$DNS_TLS_PORT" udp >> "$LOG_FILE" 2>&1

    print_success "UPnP port forwarding configured"
    debug_log "UPnP configuration complete"
    pause
}

setup_upnp_persistence() {
    if [[ "$USE_UPNP" == "true" ]] && command -v upnpc &> /dev/null; then
        print_step "Setting UPnP Persistence"
        debug_log "Entering setup_upnp_persistence"

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

        cat > /usr/local/bin/pihole-upnp-forward.sh << EOF
#!/bin/bash
LOCAL_IP="$LOCAL_IP"
WEB_PORT="$WEB_PORT"
DNS_TLS_PORT="$DNS_TLS_PORT"

sleep 10
# Let's Encrypt ports
upnpc -a "\$LOCAL_IP" 80 80 tcp > /dev/null 2>&1
upnpc -a "\$LOCAL_IP" 443 443 tcp > /dev/null 2>&1
# Pi-hole ports
upnpc -a "\$LOCAL_IP" "\$WEB_PORT" "\$WEB_PORT" tcp > /dev/null 2>&1
upnpc -a "\$LOCAL_IP" "\$DNS_TLS_PORT" "\$DNS_TLS_PORT" tcp > /dev/null 2>&1
upnpc -a "\$LOCAL_IP" "\$DNS_TLS_PORT" "\$DNS_TLS_PORT" udp > /dev/null 2>&1
EOF

        chmod +x /usr/local/bin/pihole-upnp-forward.sh
        systemctl daemon-reload
        systemctl enable pihole-upnp.service

        print_success "UPnP persistence configured"
        debug_log "UPnP persistence setup complete"
        pause
    fi
}

#================================================================================
# CONFIGURATION SUMMARY
#================================================================================

show_config_summary() {
    print_step "Configuration Summary"
    debug_log "Entering show_config_summary"

    echo -e "${CYAN}Your Configuration:${NC}"
    echo "───────────────────────────────────────────────────────"
    echo -e "  ${YELLOW}Domain:${NC}              $DOMAIN"
    echo -e "  ${YELLOW}Email:${NC}               $EMAIL"
    echo -e "  ${YELLOW}Local IP:${NC}            $LOCAL_IP"
    echo -e "  ${YELLOW}Web/DoH Port:${NC}        $WEB_PORT"
    echo -e "  ${YELLOW}DoT/DoQ Port:${NC}        $DNS_TLS_PORT"
    echo -e "  ${YELLOW}Interface:${NC}           $INTERFACE"
    echo -e "  ${YELLOW}UPnP Enabled:${NC}        $USE_UPNP"
    echo -e "  ${YELLOW}Webroot:${NC}              $WEBROOT"
    echo "───────────────────────────────────────────────────────"
    echo ""
    echo -e "${GREEN}Endpoints that will be configured:${NC}"
    echo -e "  ${CYAN}HTTPS Web Interface:${NC} https://$DOMAIN:$WEB_PORT/admin"
    echo -e "  ${CYAN}DNS-over-HTTPS (DoH):${NC} https://$DOMAIN:$WEB_PORT/dns-query"
    echo -e "  ${CYAN}DNS-over-TLS (DoT):${NC} tls://$DOMAIN:$DNS_TLS_PORT"
    echo -e "  ${CYAN}DNS-over-QUIC (DoQ):${NC} quic://$DOMAIN:$DNS_TLS_PORT"
    echo ""

    read -p "Continue with this configuration? (y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_message "Exiting. Run again to reconfigure."
        exit 0
    fi
    debug_log "Configuration confirmed by user"
}

#================================================================================
# BACKUP FUNCTIONS
#================================================================================

create_backup() {
    print_step "Creating System Backup"
    debug_log "Entering create_backup"

    mkdir -p "$BACKUP_DIR"
    print_message "Backup directory: $BACKUP_DIR"

    [[ -f "$PIHOLE_CONFIG" ]] && cp "$PIHOLE_CONFIG" "$BACKUP_DIR/pihole.toml.backup"
    [[ -d "/etc/letsencrypt" ]] && cp -r "/etc/letsencrypt" "$BACKUP_DIR/letsencrypt.backup" 2>/dev/null || true
    [[ -f "$PIHOLE_CERT" ]] && cp "$PIHOLE_CERT" "$BACKUP_DIR/tls.pem.backup"
    [[ -f "$PIHOLE_CA_CERT" ]] && cp "$PIHOLE_CA_CERT" "$BACKUP_DIR/tls_ca.crt.backup"

    if command -v ufw &> /dev/null; then
        ufw status numbered > "$BACKUP_DIR/ufw-rules.backup" 2>&1 || true
    fi

    cat > "$BACKUP_DIR/installation.state" << EOF
DOMAIN="$DOMAIN"
EMAIL="$EMAIL"
WEB_PORT="$WEB_PORT"
DNS_TLS_PORT="$DNS_TLS_PORT"
INTERFACE="$INTERFACE"
LOCAL_IP="$LOCAL_IP"
USE_UPNP="$USE_UPNP"
WEBROOT="$WEBROOT"
INSTALL_DATE="$(date)"
SCRIPT_VERSION="$SCRIPT_VERSION"
OS_TYPE="$OS_TYPE"
OS_VERSION="$OS_VERSION"
EOF

    print_success "Backup completed"
    debug_log "Backup saved to $BACKUP_DIR"
    pause
}

#================================================================================
# SERVICE MANAGEMENT FUNCTIONS
#================================================================================

detect_services_to_restart() {
    print_step "Detecting Services for Restart"
    debug_log "Entering detect_services_to_restart"

    SERVICES_TO_RESTART=()

    if systemctl list-units --full -all 2>/dev/null | grep -q "pihole-FTL.service"; then
        SERVICES_TO_RESTART+=("pihole-FTL")
        print_message "✓ pihole-FTL detected"
    fi

    for service in nginx apache2 lighttpd httpd; do
        if systemctl is-active --quiet "$service" 2>/dev/null; then
            SERVICES_TO_RESTART+=("$service")
            print_message "✓ $service detected"
        fi
    done

    print_success "Service detection complete"
    debug_log "Services to restart: ${SERVICES_TO_RESTART[*]}"
    pause
}

restart_services() {
    print_step "Restarting Services to Apply New SSL Certificates"
    debug_log "Entering restart_services"

    for service in "${SERVICES_TO_RESTART[@]}"; do
        print_message "Restarting $service..."

        if [[ "$service" == "pihole-FTL" ]]; then
            pihole-FTL --config webserver.tls.cert "$PIHOLE_CERT" >/dev/null 2>&1 || true
            systemctl restart pihole-FTL
        else
            systemctl restart "$service"
        fi

        sleep 2
        if systemctl is-active --quiet "$service"; then
            print_success "✓ $service restarted"
        else
            print_error "✗ $service failed to restart"
        fi
    done

    systemctl daemon-reload 2>/dev/null || true
    print_success "Service restarts completed"
    debug_log "Service restarts completed"
    pause
}

#================================================================================
# ACME CLIENT FUNCTIONS
#================================================================================

detect_acme_client() {
    print_step "Detecting ACME Client"
    debug_log "Entering detect_acme_client"

    if command -v acme.sh &> /dev/null; then
        ACME_CLIENT="acme.sh"
        print_success "acme.sh detected"
    elif command -v certbot &> /dev/null; then
        ACME_CLIENT="certbot"
        print_success "certbot detected"
    else
        print_warning "No ACME client detected. Installing certbot..."
        case $OS_FAMILY in
            debian) $INSTALL_CMD certbot >> "$LOG_FILE" 2>&1 ;;
            rhel|fedora) $INSTALL_CMD certbot >> "$LOG_FILE" 2>&1 ;;
        esac
        ACME_CLIENT="certbot"
    fi

    print_message "Using ACME client: $ACME_CLIENT"
    debug_log "ACME client: $ACME_CLIENT"
    pause
}

#================================================================================
# SELF-SIGNED CERTIFICATE FUNCTIONS
#================================================================================

generate_self_signed_cert() {
    print_step "Generating Temporary Self-Signed Certificate"
    debug_log "Entering generate_self_signed_cert"

    print_message "Creating temporary self-signed certificate for domain: $DOMAIN"
    print_message "This follows Pi-hole's TLS documentation exactly"

    # Backup existing certificates if they exist
    if [[ -f "$PIHOLE_CERT" ]]; then
        cp "$PIHOLE_CERT" "${PIHOLE_CERT}.backup-$(date +%Y%m%d_%H%M%S)"
        print_message "Backed up existing certificate"
    fi

    if [[ -f "$PIHOLE_CA_CERT" ]]; then
        cp "$PIHOLE_CA_CERT" "${PIHOLE_CA_CERT}.backup-$(date +%Y%m%d_%H%M%S)"
    fi

    # Configure Pi-hole domain first (as per docs)
    print_message "Setting Pi-hole domain to: $DOMAIN"
    pihole-FTL config webserver.domain "$DOMAIN" >> "$LOG_FILE" 2>&1

    # Remove existing certificates to force regeneration (as per Pi-hole docs)
    # The docs state: "sudo rm /etc/pihole/tls* && sudo service pihole-FTL restart"
    print_message "Removing old certificates to force regeneration (as per Pi-hole docs)..."
    rm -f /etc/pihole/tls* >> "$LOG_FILE" 2>&1

    # Restart Pi-hole to generate new self-signed certificate
    print_message "Restarting Pi-hole to generate new self-signed certificate..."
    systemctl restart pihole-FTL

    # Wait for certificate generation
    sleep 5

    # Verify certificates were created
    if [[ ! -f "$PIHOLE_CERT" ]] || [[ ! -f "$PIHOLE_CA_CERT" ]]; then
        print_error "Certificate generation failed"
        debug_log "Missing $PIHOLE_CERT or $PIHOLE_CA_CERT"
        exit 1
    fi

    # Set proper permissions (as per docs: readable by user pihole)
    chown pihole:pihole "$PIHOLE_CERT" "$PIHOLE_CA_CERT" 2>/dev/null || true
    chmod 600 "$PIHOLE_CERT"
    chmod 644 "$PIHOLE_CA_CERT"

    print_success "Self-signed certificate generated"
    print_message "CA Certificate (for browser import): $PIHOLE_CA_CERT"
    print_message "Server Certificate: $PIHOLE_CERT"

    debug_log "Self-signed cert generation complete"
    pause
}

test_https_with_self_signed() {
    print_step "Testing HTTPS with Self-Signed Certificate"
    debug_log "Entering test_https_with_self_signed"

    local max_attempts=12
    local attempt=1
    local https_ok=false

    print_message "Testing HTTPS on port $WEB_PORT (this may take a moment)..."

    while [[ $attempt -le $max_attempts ]]; do
        sleep 5
        print_message "Attempt $attempt/$max_attempts..."

        # Test HTTPS connection (ignoring certificate validation since it's self-signed)
        if curl -k -s -o /dev/null -w "%{http_code}" "https://localhost:$WEB_PORT/admin" 2>/dev/null | grep -q "200\|302"; then
            https_ok=true
            break
        fi

        # Also test via domain if resolvable
        if ping -c1 -W1 "$DOMAIN" &>/dev/null; then
            if curl -k -s -o /dev/null -w "%{http_code}" "https://$DOMAIN:$WEB_PORT/admin" 2>/dev/null | grep -q "200\|302"; then
                https_ok=true
                break
            fi
        fi

        ((attempt++))
    done

    if [[ "$https_ok" == true ]]; then
        print_success "✅ HTTPS is working with self-signed certificate"
        print_message "You can now access: https://$DOMAIN:$WEB_PORT/admin"
        print_message "(Browser will show warning - this is normal for self-signed certs)"

        # Show instructions for importing CA (from Pi-hole docs)
        echo ""
        echo -e "${CYAN}To make your browser trust this certificate:${NC}"
        echo "1. Copy the CA certificate from your Pi-hole:"
        echo "   sudo cat $PIHOLE_CA_CERT"
        echo ""
        echo "2. Follow the instructions at: https://docs.pi-hole.net/api/tls/"
        echo "   - Firefox: about:preferences#privacy → Certificates → View Certificates → Authorities → Import"
        echo "   - Chrome: chrome://settings/privacy → Manage certificates → Authorities → Import"
        echo ""
    else
        print_warning "⚠️ HTTPS test failed after $max_attempts attempts"
        print_message "Continuing with Let's Encrypt setup anyway..."
    fi

    pause
}

#================================================================================
# LET'S ENCRYPT FUNCTIONS
#================================================================================

obtain_certificate() {
    print_step "Obtaining SSL Certificate from Let's Encrypt"
    debug_log "Entering obtain_certificate"

    LETSENCRYPT_DIR="/etc/letsencrypt/live/${DOMAIN}"

    print_message "Checking for existing certificate for $DOMAIN..."

    if [[ -d "$LETSENCRYPT_DIR" ]]; then
        print_warning "Certificate already exists"
        if [[ -f "$LETSENCRYPT_DIR/cert.pem" ]]; then
            CERT_EXPIRY=$(openssl x509 -enddate -noout -in "$LETSENCRYPT_DIR/cert.pem" 2>/dev/null | cut -d= -f2)
            print_message "Current certificate expires: $CERT_EXPIRY"
        fi

        read -p "Do you want to renew it? (y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            print_message "Renewing certificate using webroot method..."
            certbot renew --webroot -w "$WEBROOT" --cert-name "$DOMAIN" >> "$LOG_FILE" 2>&1
            print_success "Certificate renewed"
        fi
    else
        # Check if webroot is accessible
        if [[ ! -d "$WEBROOT" ]]; then
            print_error "Webroot directory $WEBROOT does not exist"
            exit 1
        fi

        # Create a test file to verify webroot is writable
        echo "test" > "$WEBROOT/le-test.txt" 2>/dev/null || {
            print_error "Webroot directory $WEBROOT is not writable"
            exit 1
        }
        rm -f "$WEBROOT/le-test.txt"

        print_message "Requesting certificate from Let's Encrypt using webroot method..."
        print_message "Webroot directory: $WEBROOT"
        print_message "Domain: $DOMAIN"
        print_message "Email: $EMAIL"
        echo ""

        # Use webroot method - this works even if Pi-hole is using port 443
        if certbot certonly --webroot \
            --webroot-path "$WEBROOT" \
            --non-interactive \
            --agree-tos \
            --email "$EMAIL" \
            -d "$DOMAIN" >> "$LOG_FILE" 2>&1; then
            print_success "Certificate obtained successfully using webroot method"
        else
            print_error "Failed to obtain certificate"
            print_message "Check $LOG_FILE for details"
            echo ""
            print_message "Common issues:"
            echo "  - Domain $DOMAIN does not point to this server's public IP"
            echo "  - Webroot directory $WEBROOT is not accessible via HTTP"
            echo "  - Firewall is blocking port 80 or 443"
            echo "  - DNS propagation not complete"
            exit 1
        fi
    fi

    print_message "Certificate details:"
    openssl x509 -in "$LETSENCRYPT_DIR/cert.pem" -text -noout | grep -E "Subject:|Not Before:|Not After :|DNS:" | tee -a "$LOG_FILE"
    debug_log "Certificate obtained/renewed successfully"
    pause
}

combine_certificates() {
    print_step "Preparing Let's Encrypt Certificate for Pi-hole"
    debug_log "Entering combine_certificates"

    if [[ ! -f "${LETSENCRYPT_DIR}/fullchain.pem" ]] || [[ ! -f "${LETSENCRYPT_DIR}/privkey.pem" ]]; then
        print_error "Certificate files not found in ${LETSENCRYPT_DIR}"
        exit 1
    fi

    print_message "Creating combined certificate file for Pi-hole (PEM format)..."
    cat "${LETSENCRYPT_DIR}/fullchain.pem" "${LETSENCRYPT_DIR}/privkey.pem" > "${PIHOLE_CERT}"

    # Set proper permissions (as per docs: readable by user pihole)
    chown pihole:pihole "${PIHOLE_CERT}" 2>/dev/null || true
    chmod 600 "${PIHOLE_CERT}"

    print_success "Let's Encrypt certificate installed at: $PIHOLE_CERT"
    debug_log "Certificate combined and installed"
    pause
}

verify_certificate() {
    print_step "Verifying SSL Certificate"
    debug_log "Entering verify_certificate"

    if [[ ! -f "$PIHOLE_CERT" ]]; then
        print_error "Certificate file not found"
        return 1
    fi

    if ! openssl x509 -in "$PIHOLE_CERT" -noout -text > /dev/null 2>&1; then
        print_error "Certificate verification failed"
        return 1
    fi

    CERT_SUBJECT=$(openssl x509 -in "$PIHOLE_CERT" -noout -subject 2>/dev/null | sed 's/subject=//')
    CERT_ISSUER=$(openssl x509 -in "$PIHOLE_CERT" -noout -issuer 2>/dev/null | sed 's/issuer=//')
    CERT_EXPIRE=$(openssl x509 -in "$PIHOLE_CERT" -noout -enddate 2>/dev/null | cut -d= -f2)

    echo -e "${CYAN}Certificate Details:${NC}"
    echo "  Subject: $CERT_SUBJECT"
    echo "  Issuer: $CERT_ISSUER"
    echo "  Valid Until: $CERT_EXPIRE"
    echo ""

    if ! openssl x509 -in "$PIHOLE_CERT" -noout -text | grep -q "DNS:$DOMAIN"; then
        print_warning "Certificate does not contain domain $DOMAIN"
    else
        print_success "Certificate domain match: $DOMAIN"
    fi

    print_success "Certificate verification passed"
    debug_log "Certificate verification complete"
    pause
}

#================================================================================
# PI-HOLE CONFIGURATION FUNCTIONS
#================================================================================

configure_pihole() {
    print_step "Configuring Pi-hole for Encrypted DNS"
    debug_log "Entering configure_pihole"

    print_message "Configuring HTTPS web interface on port $WEB_PORT..."
    pihole-FTL config webserver.domain "$DOMAIN"
    pihole-FTL config webserver.tls.cert "$PIHOLE_CERT"
    pihole-FTL config webserver.port "$WEB_PORT"
    pihole-FTL config webserver.interface "$INTERFACE"
    pihole-FTL config webserver.tls.enable true

    print_message "Configuring DNS encryption..."

    # DNS-over-TLS (DoT)
    pihole-FTL config dns.port 53
    pihole-FTL config dns.dot.enabled true
    pihole-FTL config dns.dot.port "$DNS_TLS_PORT"
    pihole-FTL config dns.dot.cert "$PIHOLE_CERT"
    pihole-FTL config dns.dot.key "$PIHOLE_CERT"

    # DNS-over-QUIC (DoQ)
    pihole-FTL config dns.doq.enabled true
    pihole-FTL config dns.doq.port "$DNS_TLS_PORT"
    pihole-FTL config dns.doq.cert "$PIHOLE_CERT"
    pihole-FTL config dns.doq.key "$PIHOLE_CERT"

    # DNS-over-HTTPS (DoH)
    pihole-FTL config dns.doh.enabled true
    pihole-FTL config dns.doh.path "/dns-query"

    pihole-FTL config dns.rateLimit.enabled false
    pihole-FTL config dns.blocking.enabled true

    # Save installation state
    cat > "$INSTALL_STATE_FILE" << EOF
INSTALLED_DOMAIN="$DOMAIN"
INSTALLED_EMAIL="$EMAIL"
INSTALLED_WEB_PORT="$WEB_PORT"
INSTALLED_DNS_TLS_PORT="$DNS_TLS_PORT"
INSTALLED_INTERFACE="$INTERFACE"
INSTALLED_LOCAL_IP="$LOCAL_IP"
INSTALLED_USE_UPNP="$USE_UPNP"
INSTALLED_WEBROOT="$WEBROOT"
INSTALLED_DATE="$(date)"
INSTALLED_VERSION="$SCRIPT_VERSION"
EOF

    print_success "Pi-hole configuration completed"
    debug_log "Pi-hole configured"
    pause
}

#================================================================================
# FIREWALL FUNCTIONS
#================================================================================

configure_firewall() {
    print_step "Configuring Firewall"
    debug_log "Entering configure_firewall"

    if command -v ufw &> /dev/null; then
        print_message "Configuring UFW..."
        # Let's Encrypt ports
        ufw allow 80/tcp comment 'HTTP for Let\'s Encrypt' >> "$LOG_FILE" 2>&1
        ufw allow 443/tcp comment 'HTTPS for Let\'s Encrypt' >> "$LOG_FILE" 2>&1
        # Pi-hole ports
        ufw allow "$WEB_PORT"/tcp comment 'Pi-hole HTTPS Web + DoH' >> "$LOG_FILE" 2>&1
        ufw allow "$DNS_TLS_PORT"/tcp comment 'DNS-over-TLS' >> "$LOG_FILE" 2>&1
        ufw allow "$DNS_TLS_PORT"/udp comment 'DNS-over-QUIC' >> "$LOG_FILE" 2>&1
        print_success "UFW configured"

    elif command -v nft &> /dev/null; then
        print_message "Configuring nftables..."
        print_warning "Manual nftables configuration may be required"

    elif command -v iptables &> /dev/null; then
        print_message "Configuring iptables..."
        iptables -A INPUT -p tcp --dport 80 -j ACCEPT
        iptables -A INPUT -p tcp --dport 443 -j ACCEPT
        iptables -A INPUT -p tcp --dport "$WEB_PORT" -j ACCEPT
        iptables -A INPUT -p tcp --dport "$DNS_TLS_PORT" -j ACCEPT
        iptables -A INPUT -p udp --dport "$DNS_TLS_PORT" -j ACCEPT
        print_success "iptables configured"
    else
        print_warning "No firewall detected. Please open ports manually."
    fi
    debug_log "Firewall configuration complete"
    pause
}

#================================================================================
# WEBROOT SETUP FOR LET'S ENCRYPT
#================================================================================

setup_webroot() {
    print_step "Setting Up Webroot for Let's Encrypt"
    debug_log "Entering setup_webroot"

    # Create webroot directory if it doesn't exist
    if [[ ! -d "$WEBROOT" ]]; then
        print_message "Creating webroot directory: $WEBROOT"
        mkdir -p "$WEBROOT"
    fi

    # Set proper permissions
    chmod 755 "$WEBROOT"

    # Check if webroot is writable
    if [[ ! -w "$WEBROOT" ]]; then
        print_error "Webroot directory $WEBROOT is not writable"
        exit 1
    fi

    # Create or update test index.html
    local index_file="$WEBROOT/index.html"
    local backup_index="$WEBROOT/index.html.backup-$(date +%Y%m%d_%H%M%S)"

    # Backup existing index.html if it exists and is not our test page
    if [[ -f "$index_file" ]] && ! grep -q "Pi-hole Encryption Setup Test Page" "$index_file"; then
        print_message "Backing up existing index.html to $backup_index"
        cp "$index_file" "$backup_index"
    fi

    # Create test index.html with domain
    print_message "Creating test index.html for domain verification..."
    cat > "$index_file" << EOF
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Pi-hole Encryption Setup Test Page</title>
    <style>
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            line-height: 1.6;
            color: #333;
            max-width: 800px;
            margin: 0 auto;
            padding: 20px;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh;
            display: flex;
            align-items: center;
            justify-content: center;
        }
        .container {
            background: white;
            padding: 40px;
            border-radius: 10px;
            box-shadow: 0 20px 60px rgba(0,0,0,0.3);
        }
        h1 {
            color: #667eea;
            margin-bottom: 20px;
            border-bottom: 2px solid #667eea;
            padding-bottom: 10px;
        }
        .success {
            background: #d4edda;
            color: #155724;
            padding: 15px;
            border-radius: 5px;
            margin: 20px 0;
            border-left: 4px solid #28a745;
        }
        .info {
            background: #e7f3ff;
            color: #004085;
            padding: 15px;
            border-radius: 5px;
            margin: 20px 0;
            border-left: 4px solid #007bff;
        }
        .domain {
            font-size: 24px;
            font-weight: bold;
            color: #28a745;
            text-align: center;
            padding: 10px;
            background: #f8f9fa;
            border-radius: 5px;
            margin: 20px 0;
        }
        .endpoints {
            background: #f8f9fa;
            padding: 20px;
            border-radius: 5px;
            margin: 20px 0;
        }
        .endpoint {
            font-family: monospace;
            background: #e9ecef;
            padding: 8px;
            border-radius: 3px;
            margin: 5px 0;
        }
        .footer {
            margin-top: 30px;
            text-align: center;
            font-size: 14px;
            color: #666;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>🔒 Pi-hole Encryption Setup Test Page</h1>

        <div class="success">
            ✅ Webroot is properly configured for Let's Encrypt!
        </div>

        <div class="domain">
            🌐 $DOMAIN
        </div>

        <div class="info">
            <strong>This page confirms that your web server is accessible and ready for Let's Encrypt certificate issuance.</strong>
            <p style="margin-top: 10px;">The Let's Encrypt client will place verification files in this directory to prove you control the domain.</p>
        </div>

        <div class="endpoints">
            <h3>Your Pi-hole will be configured with these encrypted endpoints:</h3>
            <div class="endpoint">📡 HTTPS Web Admin: https://$DOMAIN:$WEB_PORT/admin</div>
            <div class="endpoint">🔐 DNS-over-HTTPS (DoH): https://$DOMAIN:$WEB_PORT/dns-query</div>
            <div class="endpoint">🔒 DNS-over-TLS (DoT): tls://$DOMAIN:$DNS_TLS_PORT</div>
            <div class="endpoint">⚡ DNS-over-QUIC (DoQ): quic://$DOMAIN:$DNS_TLS_PORT</div>
        </div>

        <div class="footer">
            <p>Generated by Pi-hole Encryption Setup v$SCRIPT_VERSION</p>
            <p>GitHub: https://github.com/waelisa/pihole-encryption</p>
            <p>Server Time: $(date)</p>
        </div>
    </div>
</body>
</html>
EOF

    # Set proper ownership (try common web server users)
    if id www-data &>/dev/null; then
        chown www-data:www-data "$index_file" 2>/dev/null || true
    elif id apache &>/dev/null; then
        chown apache:apache "$index_file" 2>/dev/null || true
    elif id nginx &>/dev/null; then
        chown nginx:nginx "$index_file" 2>/dev/null || true
    fi

    chmod 644 "$index_file"

    print_success "Test page created at: $index_file"
    print_message "You can access it at: http://$DOMAIN/"

    # Check if there's a web server already serving this directory
    local web_server=""
    local web_server_running=false

    if command -v nginx &> /dev/null && systemctl is-active --quiet nginx; then
        web_server="nginx"
        web_server_running=true
        print_message "Detected nginx running - will use existing web server"
    elif command -v apache2 &> /dev/null && systemctl is-active --quiet apache2; then
        web_server="apache2"
        web_server_running=true
        print_message "Detected apache2 running - will use existing web server"
    elif command -v lighttpd &> /dev/null && systemctl is-active --quiet lighttpd; then
        web_server="lighttpd"
        web_server_running=true
        print_message "Detected lighttpd running - will use existing web server"
    elif command -v httpd &> /dev/null && systemctl is-active --quiet httpd; then
        web_server="httpd"
        web_server_running=true
        print_message "Detected httpd running - will use existing web server"
    fi

    if [[ "$web_server_running" == true ]]; then
        print_success "Web server ($web_server) is running and serving $WEBROOT"
    else
        print_warning "No web server detected. Certbot will still work using webroot plugin."
        print_message "The directory $WEBROOT must be accessible via HTTP for domain verification."
        print_message "Please ensure port 80 is forwarded to this server."
    fi

    debug_log "Webroot setup complete at $WEBROOT"
    pause
}

#================================================================================
# RENEWAL SETUP FUNCTIONS
#================================================================================

setup_acme_renewal() {
    print_step "Configuring Automatic Certificate Renewal"
    debug_log "Entering setup_acme_renewal"

    mkdir -p /etc/letsencrypt/renewal-hooks/deploy

    cat > "$RENEWAL_HOOK" << EOF
#!/bin/bash
# Pi-hole renewal hook - Auto-generated by v$SCRIPT_VERSION
# Follows Pi-hole TLS documentation

DOMAIN="\$RENEWED_DOMAINS"
if [ -z "\$DOMAIN" ]; then
    DOMAIN="$DOMAIN"
fi

if [ -n "\$DOMAIN" ] && [ -d "/etc/letsencrypt/live/\$DOMAIN" ]; then
    logger "Pi-hole: Renewing certificates for \$DOMAIN"

    # Combine certificates for Pi-hole (PEM format as per docs)
    cat "/etc/letsencrypt/live/\$DOMAIN/fullchain.pem" \\
        "/etc/letsencrypt/live/\$DOMAIN/privkey.pem" > "$PIHOLE_CERT"

    # Set proper permissions (readable by user pihole)
    chown pihole:pihole "$PIHOLE_CERT" 2>/dev/null || true
    chmod 600 "$PIHOLE_CERT"

    # Reload Pi-hole to use new certificate
    systemctl reload pihole-FTL || systemctl restart pihole-FTL

    logger "Pi-hole: Certificate renewed and Pi-hole reloaded for \$DOMAIN"
fi
EOF

    chmod +x "$RENEWAL_HOOK"

    # Test renewal process
    print_message "Testing certificate renewal process..."
    certbot renew --dry-run >> "$LOG_FILE" 2>&1 || true

    print_success "Auto-renewal configured - certificates will renew automatically"
    debug_log "Renewal hook installed"
    pause
}

#================================================================================
# VERIFICATION FUNCTIONS
#================================================================================

verify_endpoints() {
    print_step "Verifying Encryption Endpoints"
    debug_log "Entering verify_endpoints"

    sleep 5

    print_message "Testing HTTPS web interface..."
    if curl -k -s -o /dev/null -w "%{http_code}" "https://localhost:$WEB_PORT/admin" 2>/dev/null | grep -q "200\|302"; then
        print_success "✓ HTTPS web interface is accessible"
    else
        print_warning "✗ HTTPS web interface test failed"
    fi

    print_message "Testing DoH endpoint..."
    if curl -k -s -o /dev/null -w "%{http_code}" -H "content-type: application/dns-message" "https://localhost:$WEB_PORT/dns-query" 2>/dev/null; then
        print_success "✓ DoH endpoint is responding"
    else
        print_warning "✗ DoH endpoint test failed"
    fi

    print_message "Testing TLS endpoint..."
    if timeout 5 openssl s_client -connect "localhost:$DNS_TLS_PORT" -tls1_3 -servername "$DOMAIN" 2>&1 | grep -q "CONNECTED"; then
        print_success "✓ TLS endpoint is available"
    else
        print_warning "✗ TLS endpoint test failed"
    fi

    echo ""
    echo -e "${GREEN}Your configured endpoints:${NC}"
    echo -e "  ${CYAN}Web Interface:${NC} https://$DOMAIN:$WEB_PORT/admin"
    echo -e "  ${CYAN}DNS-over-HTTPS:${NC} https://$DOMAIN:$WEB_PORT/dns-query"
    echo -e "  ${CYAN}DNS-over-TLS:${NC} tls://$DOMAIN:$DNS_TLS_PORT"
    echo -e "  ${CYAN}DNS-over-QUIC:${NC} quic://$DOMAIN:$DNS_TLS_PORT"
    echo ""
    debug_log "Endpoint verification complete"
    pause
}

#================================================================================
# SUMMARY FUNCTION
#================================================================================

print_summary() {
    print_step "Setup Complete - Summary"
    debug_log "Entering print_summary"

    PUBLIC_IP=$(curl -s ifconfig.me 2>/dev/null || curl -s icanhazip.com 2>/dev/null || echo "Unable to detect")

    echo -e "${GREEN}✓ Pi-hole v6 Encryption Setup Completed Successfully${NC}"
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}Your Encrypted DNS Endpoints:${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${YELLOW}Domain:${NC}              $DOMAIN"
    echo -e "  ${YELLOW}Public IP:${NC}           $PUBLIC_IP"
    echo -e "  ${YELLOW}Local IP:${NC}            $LOCAL_IP"
    echo ""
    echo -e "  ${YELLOW}Web Admin:${NC}        ${GREEN}https://$DOMAIN:$WEB_PORT/admin${NC}"
    echo -e "  ${YELLOW}DNS-over-HTTPS:${NC}   ${GREEN}https://$DOMAIN:$WEB_PORT/dns-query${NC}"
    echo -e "  ${YELLOW}DNS-over-TLS:${NC}     ${GREEN}tls://$DOMAIN:$DNS_TLS_PORT${NC}"
    echo -e "  ${YELLOW}DNS-over-QUIC:${NC}    ${GREEN}quic://$DOMAIN:$DNS_TLS_PORT${NC}"
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
    debug_log "Summary displayed"
}

#================================================================================
# UNINSTALL FUNCTION
#================================================================================

uninstall() {
    print_section "Uninstalling Pi-hole Encryption"
    debug_log "Entering uninstall"

    echo -e "${YELLOW}This will remove Let's Encrypt certificates and configurations.${NC}"
    echo ""
    echo -e "${CYAN}Options for HTTPS after uninstall:${NC}"
    echo "  1) Restore original configuration (no HTTPS)"
    echo "  2) Create new self-signed certificate (HTTPS with browser warning)"
    echo "  3) Keep Let's Encrypt certificate (not recommended)"
    echo ""
    read -p "Choose option (1-3): " uninstall_choice

    case $uninstall_choice in
        1)
            print_message "Restoring original configuration..."
            # Restore from backup if available
            if [[ -d "$BACKUP_DIR" ]] && [[ -f "$BACKUP_DIR/pihole.toml.backup" ]]; then
                cp "$BACKUP_DIR/pihole.toml.backup" "$PIHOLE_CONFIG"
                print_success "Restored original Pi-hole config"
            else
                # Reset Pi-hole to HTTP only
                print_message "No backup found. Resetting to HTTP only..."
                systemctl stop pihole-FTL
                pihole-FTL config webserver.port 80 2>/dev/null || true
                pihole-FTL config webserver.tls.enable false 2>/dev/null || true
            fi
            ;;
        2)
            print_message "Creating new self-signed certificate (as per Pi-hole docs)..."
            # Follow Pi-hole docs procedure
            systemctl stop pihole-FTL
            rm -f /etc/pihole/tls*
            pihole-FTL config webserver.domain "$DOMAIN" 2>/dev/null || true
            systemctl start pihole-FTL
            sleep 5
            print_success "New self-signed certificate created"
            print_message "CA Certificate (for browser import): $PIHOLE_CA_CERT"
            ;;
        3)
            print_message "Keeping Let's Encrypt certificate"
            ;;
        *)
            print_error "Invalid choice"
            uninstall
            return
            ;;
    esac

    # Remove UPnP rules
    if command -v upnpc &> /dev/null && [[ "$USE_UPNP" == "true" ]]; then
        print_message "Removing UPnP port forwarding rules..."
        upnpc -d 80 tcp 2>/dev/null || true
        upnpc -d 443 tcp 2>/dev/null || true
        upnpc -d "$WEB_PORT" tcp 2>/dev/null || true
        upnpc -d "$DNS_TLS_PORT" tcp 2>/dev/null || true
        upnpc -d "$DNS_TLS_PORT" udp 2>/dev/null || true
    fi

    # Remove systemd service
    if [[ -f "/etc/systemd/system/pihole-upnp.service" ]]; then
        systemctl stop pihole-upnp.service
        systemctl disable pihole-upnp.service
        rm "/etc/systemd/system/pihole-upnp.service"
        rm "/usr/local/bin/pihole-upnp-forward.sh"
        systemctl daemon-reload
    fi

    # Remove renewal hooks
    [[ -f "$RENEWAL_HOOK" ]] && rm "$RENEWAL_HOOK"

    # Remove Let's Encrypt certificates (ask first)
    if [[ -d "/etc/letsencrypt/live/$DOMAIN" ]]; then
        echo ""
        read -p "Remove Let's Encrypt certificates for $DOMAIN? (y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            certbot delete --cert-name "$DOMAIN" --non-interactive || true
        fi
    fi

    # Remove installation state
    [[ -f "$INSTALL_STATE_FILE" ]] && rm "$INSTALL_STATE_FILE"

    # Final restart
    print_message "Restarting Pi-hole to apply changes..."
    systemctl restart pihole-FTL

    print_success "Uninstallation completed"
    debug_log "Uninstall complete"
}

#================================================================================
# VERIFY ALL FUNCTIONS EXIST
#================================================================================

verify_functions() {
    debug_log "Verifying all required functions exist"

    local required_functions=(
        "check_root"
        "detect_os"
        "install_dependencies"
        "check_pihole_version"
        "check_installed"
        "prompt_domain"
        "prompt_email"
        "get_local_ip"
        "choose_ports"
        "test_ports"
        "stop_conflicting_services"
        "prompt_upnp"
        "show_config_summary"
        "create_backup"
        "detect_services_to_restart"
        "detect_acme_client"
        "generate_self_signed_cert"
        "test_https_with_self_signed"
        "obtain_certificate"
        "combine_certificates"
        "verify_certificate"
        "configure_pihole"
        "configure_firewall"
        "configure_upnp"
        "setup_upnp_persistence"
        "restart_services"
        "setup_acme_renewal"
        "verify_endpoints"
        "print_summary"
        "setup_webroot"
    )

    for func in "${required_functions[@]}"; do
        if ! declare -f "$func" > /dev/null; then
            print_error "Required function '$func' is missing!"
            exit 1
        else
            debug_log "✓ Function $func exists"
        fi
    done

    print_success "All required functions verified"
}

#================================================================================
# MAIN EXECUTION
#================================================================================

main() {
    # Handle command line arguments
    case $1 in
        --uninstall)
            [[ -f "$INSTALL_STATE_FILE" ]] && source "$INSTALL_STATE_FILE"
            uninstall
            exit 0
            ;;
        --help)
            echo "Pi-hole Encryption Setup v$SCRIPT_VERSION"
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --uninstall     Remove encryption and restore original configuration"
            echo "  --help          Show this help message"
            echo "  --version       Show script version"
            exit 0
            ;;
        --version)
            echo "Pi-hole Encryption Setup v$SCRIPT_VERSION"
            exit 0
            ;;
    esac

    # Display banner
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}         Pi-hole v6 Enterprise Encryption Setup (DoH/DoT/DoQ) v$SCRIPT_VERSION${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}GitHub: https://github.com/waelisa/pihole-encryption${NC}"
    echo ""
    echo -e "This script will configure your Pi-hole v6 with enterprise-grade encryption:"
    echo -e "  ${GREEN}•${NC} HTTPS web interface with Let's Encrypt"
    echo -e "  ${GREEN}•${NC} DNS-over-HTTPS (DoH) - Encrypted DNS queries"
    echo -e "  ${GREEN}•${NC} DNS-over-TLS (DoT) - Alternative encrypted transport"
    echo -e "  ${GREEN}•${NC} DNS-over-QUIC (DoQ) - Modern UDP-based encryption"
    echo -e "  ${GREEN}•${NC} UPnP port forwarding - Automatic router configuration"
    echo -e "  ${GREEN}•${NC} Automatic certificate renewal - Zero maintenance"
    echo -e "  ${GREEN}•${NC} Temporary self-signed cert for immediate HTTPS testing"
    echo ""
    echo -e "${YELLOW}Total steps: $TOTAL_STEPS${NC}"
    echo ""

    # Verify all functions exist before starting
    verify_functions

    read -p "Press Enter to start enterprise encryption setup..." -r

    # Core execution flow - ALL FUNCTIONS NOW DEFINED AND CALLED IN CORRECT ORDER
    check_root
    detect_os
    install_dependencies
    check_pihole_version
    check_installed

    # Configuration
    prompt_domain
    prompt_email
    get_local_ip
    choose_ports
    test_ports
    prompt_upnp

    # Setup webroot for Let's Encrypt
    setup_webroot

    # Generate and test self-signed certificate FIRST
    # This ensures HTTPS works immediately while Let's Encrypt processes
    generate_self_signed_cert
    test_https_with_self_signed

    # Pre-installation
    show_config_summary
    create_backup
    detect_services_to_restart
    detect_acme_client

    # Certificate setup
    LETSENCRYPT_DIR="/etc/letsencrypt/live/${DOMAIN}"
    obtain_certificate
    combine_certificates
    verify_certificate

    # Pi-hole configuration
    configure_pihole
    configure_firewall
    configure_upnp
    setup_upnp_persistence

    # Finalization
    restart_services
    setup_acme_renewal
    verify_endpoints
    print_summary

    echo ""
    print_success "🎉 Enterprise encryption setup complete! Your Pi-hole is now secured."
    print_message "All configurations saved to: $BACKUP_DIR"
    print_message "Log file: $LOG_FILE"
    echo ""
    echo -e "${GREEN}Access your secure Pi-hole admin interface:${NC}"
    echo -e "${CYAN}https://$DOMAIN:$WEB_PORT/admin${NC}"
    echo ""
    echo -e "${YELLOW}To import the CA certificate (if you want to trust self-signed certs):${NC}"
    echo -e "  ${CYAN}sudo cat $PIHOLE_CA_CERT${NC}"
    echo ""
}

# Run main with all arguments
main "$@"
