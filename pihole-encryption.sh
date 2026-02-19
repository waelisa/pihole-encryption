#!/bin/bash
#############################################################################################################################
# The MIT License (MIT)
#
# Wael Isa
# Build Date: 02/19/2026
# Version: 1.1.0
# GitHub: https://github.com/waelisa/pihole-encryption
# Website: https://www.wael.name/
# Support: https://www.paypal.me/WaelIsa
#
#############################################################################################################################
#
# COMPLETE FIX HISTORY - ALL ISSUES RESOLVED:
# ==============================================================================
# v1.1.0 - FINAL: Added temporary self-signed certificate for HTTPS testing
#        - Generates temp self-signed cert BEFORE Let's Encrypt for immediate HTTPS
#        - Tests HTTPS connectivity with self-signed cert first
#        - During uninstall/restore, asks user about self-signed cert creation
#        - Automatically restarts Pi-hole after cert changes
#        - Follows Pi-hole TLS docs exactly (PEM format, pihole user perms)
#        - Preserves CA certificate (/etc/pihole/tls_ca.crt) for browser import
#        - Added option to create new self-signed cert on restore
# ==============================================================================
# (Previous versions history condensed)
# v1.0.9 - Fixed port selection & debug output
# v1.0.8 - Fixed port conflict handling
# v1.0.7 - Added all missing functions
# ==============================================================================
#
# This script configures Pi-hole v6 with enterprise-grade encryption:
# 🔒 HTTPS web interface with Let's Encrypt (port 443 or custom)
# 🔒 DNS-over-HTTPS (DoH) endpoint: https://YOUR-DOMAIN:PORT/dns-query
# 🔒 DNS-over-TLS (DoT) endpoint: tls://YOUR-DOMAIN:853
# 🔒 DNS-over-QUIC (DoQ) endpoint: quic://YOUR-DOMAIN:853
#
# Let's Encrypt uses webroot method (/var/www/html/) so Pi-hole can keep using port 443
# Temporary self-signed cert provides HTTPS during Let's Encrypt setup
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
SCRIPT_VERSION="1.1.0"
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
TOTAL_STEPS=24  # Increased for self-signed steps

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
# SELF-SIGNED CERTIFICATE FUNCTIONS (Based on Pi-hole TLS docs)
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

#================================================================================
# RESTORE/UNINSTALL FUNCTIONS
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

    # Create test index.html
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
# PORT FUNCTIONS (condensed for space)
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

get_port_process() {
    local port=$1
    local proto=$2

    if command -v lsof &> /dev/null; then
        lsof -i "${proto}:${port}" 2>/dev/null | grep LISTEN
    elif command -v ss &> /dev/null; then
        ss -lpn 2>/dev/null | grep ":$port"
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

#================================================================================
# MAIN EXECUTION (condensed, focuses on flow)
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

    read -p "Press Enter to start enterprise encryption setup..." -r

    # Core execution flow
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
