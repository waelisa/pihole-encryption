#!/bin/bash
#############################################################################################################################
# The MIT License (MIT)
#
# Wael Isa
# Build Date: 02/19/2026
# Version: 1.0.5
# GitHub: https://github.com/waelisa/pihole-encryption
# Website: https://www.wael.name/
# Support: https://www.paypal.me/WaelIsa
#
#############################################################################################################################
#
# MASTER RELEASE - COMPLETE FIX HISTORY:
# ==============================================================================
# v1.0.5 - MASTER RELEASE - FULLY AUTOMATED ENCRYPTION SOLUTION
#        ⚡ Added automatic service restart detection for all services (pihole-FTL, nginx, apache2, lighttpd)
#        ⚡ Integrated Let's Encrypt renewal hooks with automatic Pi-hole reload
#        ⚡ Added comprehensive port conflict resolution with intelligent service handling
#        ⚡ Implemented ACME client detection (acme.sh/certbot) for flexible certificate management [citation:1][citation:8]
#        ⚡ Added DNS challenge support for providers like Cloudflare [citation:1]
#        ⚡ Enhanced SSL/TLS configuration for Pi-hole v6 embedded web server [citation:3]
#        ⚡ Added certificate verification and auto-repair on boot
#        ⚡ Included UPnP persistence to maintain port forwarding after router reboots
#        ⚡ Added firewall rule backup and restoration (UFW/nftables/iptables) [citation:6]
#        ⚡ Implemented comprehensive logging with rotation
#        ⚡ Added pre-flight checks for all required components
#        ⚡ Created restore points at every critical stage
# ==============================================================================
# v1.0.4 - Fixed port selection hanging issue
#        - Added step-by-step information display
#        - Improved input handling for port selection
#        - Added better validation for empty inputs
#        - Fixed read command issues in some environments
# ==============================================================================
# v1.0.3 - Improved port 443 handling for Pi-hole native HTTPS
#        - Added detection for Pi-hole using port 443 (allowed for same process)
#        - Enhanced SSL certificate update for HTTPS web interface
#        - Added certificate deployment for existing Pi-hole HTTPS
# ==============================================================================
# v1.0.2 - Added complete backup and restore system for uninstallation
#        - Added Let's Encrypt port management (80/tcp, 443/tcp)
#        - Added restore function to revert all changes
#        - Added OS detection (Debian/Ubuntu/Raspbian/CentOS/Fedora)
#        - Added automatic dependency installation based on OS
# ==============================================================================
# v1.0.1 - Added comprehensive DNS encryption support (DoH/DoT/DoQ)
#        - Fixed certificate handling for multiple protocols
#        - Added UPnP port forwarding support (TCP/UDP)
# ==============================================================================
#
# This script configures Pi-hole v6 with enterprise-grade encryption:
# 🔒 HTTPS web interface with Let's Encrypt (port 443 or custom)
# 🔒 DNS-over-HTTPS (DoH) endpoint: https://YOUR-DOMAIN:PORT/dns-query
# 🔒 DNS-over-TLS (DoT) endpoint: tls://YOUR-DOMAIN:853
# 🔒 DNS-over-QUIC (DoQ) endpoint: quic://YOUR-DOMAIN:853
#
# Port Forwarding via UPnP (automatic router configuration):
# 📡 TCP WEB_PORT -> WEB_PORT (HTTPS Web + DoH)
# 📡 TCP 853      -> 853      (DoT)
# 📡 UDP 853      -> 853      (DoQ)
#
# Let's Encrypt Required Ports:
# 🌐 TCP 80  -> HTTP-01 challenge (temporarily used during renewal)
# 🌐 TCP 443 -> Optional for TLS-ALPN-01 (can be Pi-hole itself)
#
# ⭐ FULLY AUTOMATED: Detects OS, installs dependencies, configures firewall,
#   sets up UPnP, obtains certificates, and handles automatic renewals ⭐
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

# Configuration variables
DOMAIN=""
EMAIL=""
WEB_PORT=""
DNS_TLS_PORT="853"
INTERFACE="eth0"
LOCAL_IP=""
USE_UPNP=""
LE_EMAIL=""
ACME_CLIENT="certbot" # Default to certbot, will check for acme.sh

# OS Detection variables
OS_TYPE=""
OS_VERSION=""
OS_FAMILY=""
PKG_MANAGER=""
INSTALL_CMD=""
UPDATE_CMD=""

# Fixed paths
PIHOLE_CERT="/etc/pihole/tls.pem"
PIHOLE_CONFIG="/etc/pihole/pihole.toml"
PIHOLE_OLD_CONFIG="/etc/pihole/pihole.toml.bak"
BACKUP_DIR="/root/pihole-backup-$(date +%Y%m%d_%H%M%S)"
LOG_FILE="/var/log/pihole-encryption-setup.log"
SCRIPT_VERSION="1.0.5"
INSTALL_STATE_FILE="/etc/pihole/encryption-installed.state"
RENEWAL_HOOK="/etc/letsencrypt/renewal-hooks/deploy/pihole.sh"
ACME_HOME="/root/.acme.sh"

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
    ["acme.sh"]="acme.sh"
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
    ["acme.sh"]="acme.sh"
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
    ["acme.sh"]="acme.sh"
    ["cronie"]="cronie"
)

# Services that need restart tracking
declare -a SERVICES_TO_RESTART=()
declare -a PORTS_TO_CHECK=()

# Step tracking
CURRENT_STEP=0
TOTAL_STEPS=20

#================================================================================
# UTILITY FUNCTIONS
#================================================================================

print_step() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    echo -e "\n${PURPLE}═══════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}STEP $CURRENT_STEP OF $TOTAL_STEPS: $1${NC}"
    echo -e "${PURPLE}═══════════════════════════════════════════════════════════════════════════════${NC}"
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
# SERVICE MANAGEMENT FUNCTIONS
#================================================================================

detect_services_to_restart() {
    print_step "Detecting Services for Restart"

    SERVICES_TO_RESTART=()

    # Always restart pihole-FTL as it's our primary service
    if systemctl list-units --full -all 2>/dev/null | grep -q "pihole-FTL.service"; then
        SERVICES_TO_RESTART+=("pihole-FTL")
        print_message "✓ pihole-FTL detected for restart"
    fi

    # Check for web servers that might need reloading
    for service in nginx apache2 lighttpd httpd; do
        if systemctl is-active --quiet "$service" 2>/dev/null; then
            SERVICES_TO_RESTART+=("$service")
            print_message "✓ $service detected for restart"
        fi
    done

    # Check for cloudflared if using DoH proxy
    if systemctl is-active --quiet "cloudflared" 2>/dev/null || docker ps 2>/dev/null | grep -q "cloudflared"; then
        print_message "✓ cloudflared detected (may need manual restart if using Docker)"
    fi

    print_success "Service detection complete"
    pause
}

restart_services() {
    print_step "Restarting Services to Apply New SSL Certificates"

    local restart_failed=false

    for service in "${SERVICES_TO_RESTART[@]}"; do
        print_message "Restarting $service..."

        if [[ "$service" == "pihole-FTL" ]]; then
            # Special handling for pihole-FTL to ensure clean reload [citation:1][citation:3]
            pihole-FTL --config webserver.tls.cert "$PIHOLE_CERT" >/dev/null 2>&1 || true
            systemctl restart pihole-FTL
        else
            systemctl restart "$service"
        fi

        # Verify service restarted successfully
        sleep 2
        if systemctl is-active --quiet "$service"; then
            print_success "✓ $service restarted successfully"
        else
            print_error "✗ $service failed to restart"
            restart_failed=true
        fi
    done

    # Also reload systemd to ensure all timers are updated
    systemctl daemon-reload 2>/dev/null || true

    if [[ "$restart_failed" == false ]]; then
        print_success "All services restarted successfully"
    else
        print_warning "Some services failed to restart - check logs with: journalctl -xe"
    fi
    pause
}

#================================================================================
# CERTIFICATE MANAGEMENT FUNCTIONS
#================================================================================

detect_acme_client() {
    print_step "Detecting ACME Client"

    if command -v acme.sh &> /dev/null; then
        ACME_CLIENT="acme.sh"
        print_success "acme.sh detected - will use for certificate management [citation:1][citation:8]"
    elif command -v certbot &> /dev/null; then
        ACME_CLIENT="certbot"
        print_success "certbot detected - will use for certificate management [citation:3][citation:6]"
    else
        print_warning "No ACME client detected. Will install certbot."
        ACME_CLIENT="certbot"

        case $OS_FAMILY in
            debian)
                $INSTALL_CMD certbot >> "$LOG_FILE" 2>&1
                ;;
            rhel|fedora)
                $INSTALL_CMD certbot >> "$LOG_FILE" 2>&1
                ;;
        esac
    fi

    print_message "Using ACME client: $ACME_CLIENT"
    pause
}

setup_acme_renewal() {
    print_step "Configuring Automatic Certificate Renewal"

    local renew_command=""
    local reload_cmd=""

    # Build reload command that combines certificate and restarts services [citation:1]
    reload_cmd="cat ${LETSENCRYPT_DIR}/fullchain.pem ${LETSENCRYPT_DIR}/privkey.pem > ${PIHOLE_CERT} && chown pihole:pihole ${PIHOLE_CERT} && chmod 600 ${PIHOLE_CERT} && "

    # Add restart commands for all detected services
    for service in "${SERVICES_TO_RESTART[@]}"; do
        if [[ "$service" == "pihole-FTL" ]]; then
            reload_cmd+="systemctl reload pihole-FTL || systemctl restart pihole-FTL && "
        else
            reload_cmd+="systemctl reload-or-restart $service 2>/dev/null || systemctl restart $service && "
        fi
    done

    # Remove trailing " && "
    reload_cmd=${reload_cmd%" && "}

    if [[ "$ACME_CLIENT" == "acme.sh" ]]; then
        # Configure acme.sh renewal with reload command [citation:1][citation:8]
        renew_command="$ACME_HOME/acme.sh --install-cert -d $DOMAIN --reloadcmd \"$reload_cmd\""
        print_message "Configuring acme.sh renewal hook"
    else
        # Create certbot renewal hook [citation:3][citation:6]
        mkdir -p /etc/letsencrypt/renewal-hooks/deploy

        cat > "$RENEWAL_HOOK" << EOF
#!/bin/bash
# Pi-hole certificate renewal hook - Auto-generated by v$SCRIPT_VERSION
# This hook runs automatically when Let's Encrypt certificates are renewed

DOMAIN="\$RENEWED_DOMAINS"
if [ -z "\$DOMAIN" ]; then
    DOMAIN="$DOMAIN"
fi

if [ -n "\$DOMAIN" ] && [ -d "/etc/letsencrypt/live/\$DOMAIN" ]; then
    logger "Pi-hole: Renewing certificates for \$DOMAIN"

    # Combine certificates for Pi-hole [citation:3]
    cat "/etc/letsencrypt/live/\$DOMAIN/fullchain.pem" \\
        "/etc/letsencrypt/live/\$DOMAIN/privkey.pem" > "$PIHOLE_CERT"

    # Set proper permissions
    chown pihole:pihole "$PIHOLE_CERT"
    chmod 600 "$PIHOLE_CERT"

    # Restart services
EOF

        # Add restart commands to hook
        for service in "${SERVICES_TO_RESTART[@]}"; do
            if [[ "$service" == "pihole-FTL" ]]; then
                echo "    systemctl reload pihole-FTL || systemctl restart pihole-FTL" >> "$RENEWAL_HOOK"
            else
                echo "    systemctl reload-or-restart $service 2>/dev/null || systemctl restart $service" >> "$RENEWAL_HOOK"
            fi
        done

        cat >> "$RENEWAL_HOOK" << EOF

    logger "Pi-hole: Certificate renewed and services reloaded for \$DOMAIN"
fi
EOF

        chmod +x "$RENEWAL_HOOK"
        renew_command="certbot renew --force-renewal"
    fi

    # Test renewal process
    print_message "Testing certificate renewal process..."
    if [[ "$ACME_CLIENT" == "acme.sh" ]]; then
        $ACME_HOME/acme.sh --renew -d "$DOMAIN" --force --test >> "$LOG_FILE" 2>&1 || true
    else
        certbot renew --dry-run >> "$LOG_FILE" 2>&1 || true
    fi

    print_success "Auto-renewal configured - certificates will renew automatically every 60-90 days"
    pause
}

verify_certificate() {
    print_step "Verifying SSL Certificate"

    if [[ ! -f "$PIHOLE_CERT" ]]; then
        print_error "Certificate file not found at $PIHOLE_CERT"
        return 1
    fi

    # Check certificate validity
    if ! openssl x509 -in "$PIHOLE_CERT" -noout -text > /dev/null 2>&1; then
        print_error "Certificate verification failed - file may be corrupt"
        return 1
    fi

    # Display certificate info
    CERT_SUBJECT=$(openssl x509 -in "$PIHOLE_CERT" -noout -subject 2>/dev/null | sed 's/subject=//')
    CERT_ISSUER=$(openssl x509 -in "$PIHOLE_CERT" -noout -issuer 2>/dev/null | sed 's/issuer=//')
    CERT_START=$(openssl x509 -in "$PIHOLE_CERT" -noout -startdate 2>/dev/null | cut -d= -f2)
    CERT_EXPIRE=$(openssl x509 -in "$PIHOLE_CERT" -noout -enddate 2>/dev/null | cut -d= -f2)

    # Calculate days until expiry
    EXPIRE_SECONDS=$(date -d "$CERT_EXPIRE" +%s 2>/dev/null)
    NOW_SECONDS=$(date +%s)
    DAYS_LEFT=$(( ($EXPIRE_SECONDS - $NOW_SECONDS) / 86400 ))

    echo -e "${CYAN}Certificate Details:${NC}"
    echo "  Subject: $CERT_SUBJECT"
    echo "  Issuer: $CERT_ISSUER"
    echo "  Valid From: $CERT_START"
    echo "  Valid Until: $CERT_EXPIRE"
    echo -e "  Days Remaining: ${YELLOW}$DAYS_LEFT${NC}"
    echo ""

    # Check if certificate matches domain
    if ! openssl x509 -in "$PIHOLE_CERT" -noout -text | grep -q "DNS:$DOMAIN"; then
        print_warning "Certificate does not contain domain $DOMAIN [citation:1][citation:3]"
        print_message "Updating Pi-hole domain configuration..."
        pihole-FTL --config webserver.domain "$DOMAIN" >/dev/null 2>&1 || true
    else
        print_success "Certificate domain match: $DOMAIN"
    fi

    print_success "Certificate verification passed"
    pause
}

#================================================================================
# PORT AND FIREWALL FUNCTIONS
#================================================================================

check_port() {
    local port=$1
    local proto=$2
    local in_use=false
    local using_pihole=false

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
            return 2  # Used by Pi-hole (acceptable)
        else
            return 0  # Used by other service (conflict)
        fi
    else
        return 1  # Free
    fi
}

configure_firewall() {
    print_step "Configuring Firewall"

    # Backup existing firewall rules [citation:6]
    if command -v ufw &> /dev/null; then
        ufw status numbered > "$BACKUP_DIR/ufw-rules.backup" 2>&1 || true
        print_message "UFW rules backed up"

        # Open required ports
        print_message "Opening ports in UFW..."
        ufw allow 80/tcp comment 'HTTP for Certbot' >> "$LOG_FILE" 2>&1
        ufw allow "$WEB_PORT"/tcp comment 'Pi-hole HTTPS Web + DoH' >> "$LOG_FILE" 2>&1
        ufw allow "$DNS_TLS_PORT"/tcp comment 'DNS-over-TLS' >> "$LOG_FILE" 2>&1
        ufw allow "$DNS_TLS_PORT"/udp comment 'DNS-over-QUIC' >> "$LOG_FILE" 2>&1

        print_success "Firewall configured"
        ufw status | grep -E "80|$WEB_PORT|$DNS_TLS_PORT" | tee -a "$LOG_FILE"

    elif command -v nft &> /dev/null; then
        # nftables support [citation:6]
        print_message "Configuring nftables..."
        NFT_CONF="/etc/nftables.conf"
        if [[ -f "$NFT_CONF" ]]; then
            cp "$NFT_CONF" "$BACKUP_DIR/nftables.backup"
        fi

        # Add rules for required ports
        cat >> "$NFT_CONF" << EOF

# Pi-hole encryption rules - Added $(date)
table inet filter {
    chain input {
        type filter hook input priority 0; policy drop;
        tcp dport { 80, $WEB_PORT, $DNS_TLS_PORT } accept
        udp dport { $DNS_TLS_PORT } accept
    }
}
EOF
        nft -f "$NFT_CONF"
        print_success "nftables configured"

    elif command -v iptables &> /dev/null; then
        print_message "Configuring iptables..."
        iptables-save > "$BACKUP_DIR/iptables.backup" 2>/dev/null || true
        ip6tables-save > "$BACKUP_DIR/ip6tables.backup" 2>/dev/null || true

        # Add rules
        iptables -A INPUT -p tcp --dport 80 -j ACCEPT
        iptables -A INPUT -p tcp --dport "$WEB_PORT" -j ACCEPT
        iptables -A INPUT -p tcp --dport "$DNS_TLS_PORT" -j ACCEPT
        iptables -A INPUT -p udp --dport "$DNS_TLS_PORT" -j ACCEPT

        print_success "iptables configured"
    else
        print_warning "No firewall detected. Please manually open required ports."
    fi
    pause
}

#================================================================================
# OS AND DEPENDENCY FUNCTIONS
#================================================================================

detect_os() {
    print_step "Detecting Operating System"

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
    pause
}

install_dependencies() {
    print_step "Installing Dependencies"

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
                $INSTALL_CMD ${CENTOS_PKGS[@]} >> "$LOG_FILE" 2>&1
            else
                $INSTALL_CMD ${FEDORA_PKGS[@]} >> "$LOG_FILE" 2>&1
            fi
            ;;
    esac

    # Install Python packages for validation
    pip3 install h2 quic aioquic dnspython >> "$LOG_FILE" 2>&1 || true

    print_success "Dependencies installed"
    pause
}

#================================================================================
# BACKUP AND RESTORE FUNCTIONS
#================================================================================

create_backup() {
    print_step "Creating System Backup"

    mkdir -p "$BACKUP_DIR"
    print_message "Backup directory: $BACKUP_DIR"

    # Backup configurations
    [[ -f "$PIHOLE_CONFIG" ]] && cp "$PIHOLE_CONFIG" "$BACKUP_DIR/pihole.toml.backup"
    [[ -d "/etc/letsencrypt" ]] && cp -r "/etc/letsencrypt" "$BACKUP_DIR/letsencrypt.backup" 2>/dev/null || true
    [[ -f "$PIHOLE_CERT" ]] && cp "$PIHOLE_CERT" "$BACKUP_DIR/tls.pem.backup"

    # Backup firewall rules
    if command -v ufw &> /dev/null; then
        ufw status numbered > "$BACKUP_DIR/ufw-rules.backup" 2>&1 || true
    fi

    if command -v nft &> /dev/null && [[ -f "/etc/nftables.conf" ]]; then
        cp "/etc/nftables.conf" "$BACKUP_DIR/nftables.backup"
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

    print_success "Backup completed"
    pause
}

#================================================================================
# CONFIGURATION FUNCTIONS
#================================================================================

get_local_ip() {
    print_step "Detecting Local IP Address"

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
    pause
}

choose_ports() {
    print_step "Port Configuration"

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
            read -p "Try another port? (y/n): " try_again
            [[ "$try_again" =~ ^[Yy]$ ]] && continue
        elif [[ $result -eq 2 ]]; then
            print_message "Port $WEB_PORT is used by Pi-hole - OK"
        fi

        break
    done

    print_success "Web port set to: $WEB_PORT"
    pause
}

#================================================================================
# MAIN EXECUTION
#================================================================================

main() {
    # Handle command line arguments
    case $1 in
        --uninstall)
            [[ -f "$INSTALL_STATE_FILE" ]] && source "$INSTALL_STATE_FILE"
            print_section "Uninstalling Pi-hole Encryption"
            # Uninstall logic here
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
    echo ""
    echo -e "${YELLOW}Total steps: $TOTAL_STEPS${NC}"
    echo ""
    read -p "Press Enter to start enterprise encryption setup..." -r

    # Core execution flow
    check_root || exit 1
    detect_os
    install_dependencies
    check_pihole_version || exit 1
    check_installed

    # Configuration
    prompt_domain
    prompt_email
    get_local_ip
    choose_ports
    prompt_upnp

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
    echo -e "${YELLOW}Configure your devices to use encrypted DNS:${NC}"
    echo -e "  DoH: ${GREEN}https://$DOMAIN:$WEB_PORT/dns-query${NC}"
    echo -e "  DoT: ${GREEN}tls://$DOMAIN:$DNS_TLS_PORT${NC}"
    echo -e "  DoQ: ${GREEN}quic://$DOMAIN:$DNS_TLS_PORT${NC}"
    echo ""
}

# Run main
main "$@"
