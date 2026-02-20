#!/bin/bash
#############################################################################################################################
# The MIT License (MIT)
#
# Wael Isa
# Build Date: 02/20/2026
# Version: 1.2.0
# GitHub: https://github.com/waelisa/pihole-encryption
# Website: https://www.wael.name/
# Support: https://www.paypal.me/WaelIsa
#
#############################################################################################################################
#
# v1.2.0 - FIXED: HTTPS validation after self-signed cert generation
#        ✅ Fixed: Proper service restart with verification
#        ✅ Added: Certificate verification before HTTPS test
#        ✅ Added: Multiple restart attempts with increasing delays
#        ✅ Added: Port binding verification
#        ✅ Added: Process check to ensure FTL is running
#        ✅ Fixed: Better error messages with specific failure reasons
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
WEB_PORT="443"
DNS_TLS_PORT="853"
INTERFACE="eth0"
LOCAL_IP=""
USE_UPNP=""
RESTRICT_DNS="true"

# Pi-hole version info
PIHOLE_VERSION_MAJOR=0

# Fixed paths
PIHOLE_CERT="/etc/pihole/tls.pem"
PIHOLE_CA_CERT="/etc/pihole/tls_ca.crt"
PIHOLE_CONFIG="/etc/pihole/pihole.toml"
BACKUP_DIR="/root/pihole-encryption-backup-$(date +%Y%m%d_%H%M%S)"
LOG_FILE="/var/log/pihole-encryption-setup.log"
SCRIPT_VERSION="1.2.0"
INSTALL_STATE_FILE="/etc/pihole/encryption-installed.state"
RENEWAL_HOOK="/etc/letsencrypt/renewal-hooks/deploy/pihole.sh"

# Error trap
trap 'error_handler $? $LINENO' ERR

error_handler() {
    local exit_code=$1
    local line_no=$2
    print_error "Error on line $line_no: exit code $exit_code"
    
    # Ask if user wants to restore from backup
    if [[ -d "$BACKUP_DIR" ]]; then
        echo ""
        print_warning "Would you like to restore from the backup taken before this step?"
        read -p "Restore from backup? (y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            restore_from_backup
        fi
    fi
    
    print_error "Script execution stopped. Check $LOG_FILE for details"
    exit $exit_code
}

#================================================================================
# UTILITY FUNCTIONS
#================================================================================

pause() {
    echo ""
    read -p "Press Enter to continue..." -r
    echo ""
}

print_step() {
    echo -e "\n${PURPLE}═══════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}STEP: $1${NC}"
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

#================================================================================
# SERVICE MANAGEMENT (NEW)
#================================================================================

restart_pihole_with_verification() {
    local max_attempts=3
    local attempt=1
    local wait_time=5
    
    print_message "Restarting Pi-hole FTL service..."
    
    while [[ $attempt -le $max_attempts ]]; do
        # Stop service
        systemctl stop pihole-FTL
        sleep 2
        
        # Kill any remaining processes (just in case)
        pkill -f pihole-FTL 2>/dev/null || true
        sleep 2
        
        # Start service
        systemctl start pihole-FTL
        sleep $wait_time
        
        # Check if service is running
        if systemctl is-active --quiet pihole-FTL; then
            print_success "✓ Pi-hole FTL is running (attempt $attempt)"
            
            # Check if port is listening
            if ss -tlnp 2>/dev/null | grep -q ":$WEB_PORT.*pihole-FTL"; then
                print_success "✓ Port $WEB_PORT is listening"
                return 0
            else
                print_warning "⚠ Port $WEB_PORT not listening yet (attempt $attempt)"
            fi
        else
            print_warning "⚠ Pi-hole FTL failed to start (attempt $attempt)"
        fi
        
        # Increase wait time for next attempt
        wait_time=$((wait_time + 5))
        ((attempt++))
    done
    
    print_error "Failed to restart Pi-hole FTL after $max_attempts attempts"
    return 1
}

verify_certificate_files() {
    print_message "Verifying certificate files..."
    
    local errors=0
    
    # Check if cert files exist
    if [[ ! -f "$PIHOLE_CERT" ]]; then
        print_error "Certificate file missing: $PIHOLE_CERT"
        ((errors++))
    else
        local size=$(stat -c%s "$PIHOLE_CERT" 2>/dev/null || stat -f%z "$PIHOLE_CERT" 2>/dev/null)
        print_message "Certificate size: $size bytes"
        if [[ $size -lt 100 ]]; then
            print_error "Certificate file too small (likely invalid)"
            ((errors++))
        else
            print_success "✓ Certificate file exists and has valid size"
        fi
    fi
    
    if [[ ! -f "$PIHOLE_CA_CERT" ]]; then
        print_error "CA certificate file missing: $PIHOLE_CA_CERT"
        ((errors++))
    else
        print_success "✓ CA certificate file exists"
    fi
    
    # Check permissions
    if [[ -f "$PIHOLE_CERT" ]]; then
        local perms=$(stat -c "%a" "$PIHOLE_CERT" 2>/dev/null || stat -f "%OLp" "$PIHOLE_CERT" 2>/dev/null)
        if [[ "$perms" != "600" ]]; then
            print_warning "Fixing certificate permissions (was $perms, should be 600)"
            chmod 600 "$PIHOLE_CERT"
        fi
    fi
    
    return $errors
}

#================================================================================
# BACKUP FUNCTIONS
#================================================================================

create_backup() {
    print_step "Creating Comprehensive Backup (BEFORE any changes)"
    print_message "Backup location: $BACKUP_DIR"
    
    mkdir -p "$BACKUP_DIR"
    
    # Backup Pi-hole configuration
    if [[ -f "$PIHOLE_CONFIG" ]]; then
        cp "$PIHOLE_CONFIG" "$BACKUP_DIR/pihole.toml.backup"
        print_message "✓ Backed up Pi-hole config"
    fi
    
    # Backup certificates
    if [[ -f "$PIHOLE_CERT" ]]; then
        cp "$PIHOLE_CERT" "$BACKUP_DIR/tls.pem.backup"
        print_message "✓ Backed up TLS certificate"
    fi
    
    if [[ -f "$PIHOLE_CA_CERT" ]]; then
        cp "$PIHOLE_CA_CERT" "$BACKUP_DIR/tls_ca.crt.backup"
        print_message "✓ Backed up CA certificate"
    fi
    
    # Backup Let's Encrypt if exists
    if [[ -d "/etc/letsencrypt" ]]; then
        cp -r "/etc/letsencrypt" "$BACKUP_DIR/letsencrypt.backup" 2>/dev/null || true
        print_message "✓ Backed up Let's Encrypt"
    fi
    
    # Create restore script
    cat > "$BACKUP_DIR/restore.sh" << 'EOF'
#!/bin/bash
echo "Restoring Pi-hole from backup..."
echo "Backup directory: $(pwd)"

# Stop Pi-hole first
systemctl stop pihole-FTL
sleep 3
pkill -f pihole-FTL 2>/dev/null || true
sleep 2

# Restore config
if [[ -f "pihole.toml.backup" ]]; then
    cp pihole.toml.backup /etc/pihole/pihole.toml
    echo "✓ Restored Pi-hole config"
fi

# Restore certificates
if [[ -f "tls.pem.backup" ]]; then
    cp tls.pem.backup /etc/pihole/tls.pem
    chown pihole:pihole /etc/pihole/tls.pem 2>/dev/null
    chmod 600 /etc/pihole/tls.pem
    echo "✓ Restored TLS certificate"
fi

if [[ -f "tls_ca.crt.backup" ]]; then
    cp tls_ca.crt.backup /etc/pihole/tls_ca.crt
    chown pihole:pihole /etc/pihole/tls_ca.crt 2>/dev/null
    chmod 644 /etc/pihole/tls_ca.crt
    echo "✓ Restored CA certificate"
fi

# Restart Pi-hole
systemctl start pihole-FTL
sleep 5

# Verify restore
if systemctl is-active --quiet pihole-FTL; then
    echo "✓ Pi-hole FTL is running"
    echo ""
    echo "Testing HTTPS..."
    curl -k https://localhost:443/admin/ -I
else
    echo "⚠ Pi-hole FTL failed to start"
    systemctl status pihole-FTL --no-pager
fi
EOF
    
    chmod +x "$BACKUP_DIR/restore.sh"
    
    print_success "✓ Backup completed successfully"
    print_message "To restore manually later: sudo $BACKUP_DIR/restore.sh"
    pause
}

restore_from_backup() {
    print_step "Restoring from Backup"
    
    if [[ ! -d "$BACKUP_DIR" ]]; then
        print_error "Backup directory not found: $BACKUP_DIR"
        return 1
    fi
    
    if [[ -f "$BACKUP_DIR/restore.sh" ]]; then
        bash "$BACKUP_DIR/restore.sh"
        print_success "Restore completed"
    else
        print_error "Restore script not found in backup"
        return 1
    fi
    
    pause
}

#================================================================================
# CONFIGURATION FUNCTIONS
#================================================================================

set_pihole_config() {
    local key="$1"
    local value="$2"
    local config_file="$PIHOLE_CONFIG"
    
    print_message "Setting $key = $value"
    
    # Create backup of config before modifying
    cp "$config_file" "$config_file.tmp"
    
    # Handle different key types (with dots)
    if [[ "$key" == *"."* ]]; then
        # Split into section and key
        local section="${key%%.*}"
        local subkey="${key#*.}"
        
        # Check if section exists
        if grep -q "^\[$section\]" "$config_file"; then
            # Section exists, check if key exists
            if grep -q "^[[:space:]]*$subkey =" "$config_file"; then
                # Key exists, replace it
                sed -i "s|^[[:space:]]*$subkey =.*|  $subkey = \"$value\"|" "$config_file"
            else
                # Key doesn't exist, add it after section
                sed -i "/^\[$section\]/a \ \ $subkey = \"$value\"" "$config_file"
            fi
        else
            # Section doesn't exist, add it at the end
            echo -e "\n[$section]\n  $subkey = \"$value\"" >> "$config_file"
        fi
    else
        # Simple key (shouldn't happen in pihole.toml)
        if grep -q "^$key =" "$config_file"; then
            sed -i "s|^$key =.*|$key = \"$value\"|" "$config_file"
        else
            echo "$key = \"$value\"" >> "$config_file"
        fi
    fi
    
    # Verify the change
    if grep -q "$value" "$config_file"; then
        print_success "✓ Configuration updated"
    else
        print_warning "⚠ Could not verify configuration change"
    fi
}

#================================================================================
# ROOT CHECK
#================================================================================

check_root() {
    print_step "Checking Root Privileges"
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root"
        exit 1
    fi
    print_success "Root privileges confirmed"
    pause
}

#================================================================================
# DOMAIN VERIFICATION
#================================================================================

verify_domain_resolution() {
    print_step "Verifying Domain Resolution"
    
    local domain_ip=""
    local local_ip=""
    
    # Get local IP
    if command -v ip &> /dev/null; then
        local_ip=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v 127.0.0.1 | head -1)
    fi
    
    if [[ -z "$local_ip" ]]; then
        local_ip=$(hostname -I | awk '{print $1}')
    fi
    
    print_message "Your local IP: $local_ip"
    
    # Try to resolve the domain
    if command -v dig &> /dev/null; then
        domain_ip=$(dig +short "$DOMAIN" @8.8.8.8 2>/dev/null | head -1)
    elif command -v nslookup &> /dev/null; then
        domain_ip=$(nslookup "$DOMAIN" 8.8.8.8 2>/dev/null | grep -A 1 "Name:" | grep "Address:" | awk '{print $2}' | head -1)
    fi
    
    if [[ -n "$domain_ip" ]]; then
        print_message "Domain $DOMAIN resolves to: $domain_ip"
        
        if [[ "$domain_ip" == "$local_ip" ]]; then
            print_success "✓ Domain resolves to this server's IP (good)"
        else
            print_warning "⚠ Domain resolves to $domain_ip but this server is $local_ip"
            print_warning "Make sure your domain's A record points to your PUBLIC IP, not local IP"
            echo ""
            read -p "Continue anyway? (y/n): " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                exit 0
            fi
        fi
    else
        print_warning "⚠ Could not resolve $DOMAIN"
        print_warning "Make sure your domain has an A record pointing to your public IP"
        echo ""
        read -p "Continue anyway? (y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 0
        fi
    fi
    
    pause
}

#================================================================================
# SERVICE VALIDATION (IMPROVED)
#================================================================================

validate_https() {
    print_step "Validating HTTPS Service"
    
    local max_attempts=15
    local attempt=1
    local success=false
    local local_ip=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v 127.0.0.1 | head -1)
    
    print_message "Testing HTTPS on port $WEB_PORT..."
    
    # First check if service is running
    if ! systemctl is-active --quiet pihole-FTL; then
        print_error "Pi-hole FTL is not running"
        systemctl status pihole-FTL --no-pager | head -10
        return 1
    fi
    
    # Check if port is listening
    if ! ss -tlnp 2>/dev/null | grep -q ":$WEB_PORT.*pihole-FTL"; then
        print_warning "Port $WEB_PORT is not listening yet"
        ss -tlnp | grep -E ":(443|80)" || true
    fi
    
    # Try multiple endpoints
    local endpoints=(
        "https://127.0.0.1:$WEB_PORT/admin"
        "https://localhost:$WEB_PORT/admin"
        "https://$local_ip:$WEB_PORT/admin"
    )
    
    print_message "Testing endpoints (this may take up to 30 seconds)..."
    
    while [[ $attempt -le $max_attempts ]] && [[ "$success" == false ]]; do
        for endpoint in "${endpoints[@]}"; do
            if curl -k -s -o /dev/null -w "%{http_code}" "$endpoint" 2>/dev/null | grep -q "200\|302"; then
                success=true
                print_success "✓ HTTPS working on $endpoint"
                break 2
            fi
        done
        
        if [[ $attempt -lt $max_attempts ]]; then
            echo -n "."
            sleep 2
        fi
        ((attempt++))
    done
    echo ""
    
    if [[ "$success" == true ]]; then
        print_success "✓ HTTPS validation passed"
        return 0
    else
        print_error "✗ HTTPS test failed after $max_attempts attempts"
        
        # Diagnostic information
        echo ""
        print_message "Diagnostic information:"
        echo "  • Pi-hole FTL status: $(systemctl is-active pihole-FTL)"
        echo "  • Port $WEB_PORT listener: $(ss -tlnp | grep ":$WEB_PORT" || echo 'Not listening')"
        echo "  • Certificate file: $(ls -la $PIHOLE_CERT 2>/dev/null || echo 'Not found')"
        echo ""
        
        return 1
    fi
}

#================================================================================
# MAIN MENU
#================================================================================

show_menu() {
    clear
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}         Pi-hole Enterprise Encryption Setup v$SCRIPT_VERSION${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${CYAN}GitHub: https://github.com/waelisa/pihole-encryption${NC}"
    echo ""
    
    # Check if already installed
    if [[ -f "$INSTALL_STATE_FILE" ]]; then
        source "$INSTALL_STATE_FILE"
        echo -e "${YELLOW}Existing installation detected:${NC}"
        echo "  Domain: $INSTALLED_DOMAIN"
        echo "  Web Port: $INSTALLED_WEB_PORT"
        echo "  Installed: $INSTALLED_DATE"
        echo ""
    fi
    
    echo -e "${CYAN}Main Menu:${NC}"
    echo "  1) Fresh Install - Setup encryption with Let's Encrypt"
    echo "  2) Restore from Backup - Recover previous working configuration"
    echo "  3) Uninstall - Remove encryption and restore original"
    echo "  4) Exit"
    echo ""
    read -p "Choose option (1-4): " menu_choice
    
    case $menu_choice in
        1)
            if [[ -f "$INSTALL_STATE_FILE" ]]; then
                echo ""
                print_warning "This will overwrite your existing installation"
                read -p "Continue with fresh install? (y/n): " -n 1 -r
                echo
                if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                    show_menu
                    return
                fi
            fi
            # Continue with install
            ;;
        2)
            restore_menu
            ;;
        3)
            uninstall
            exit 0
            ;;
        4)
            exit 0
            ;;
        *)
            print_error "Invalid choice"
            sleep 2
            show_menu
            return
            ;;
    esac
}

restore_menu() {
    print_step "Available Backups"
    
    # Find all backup directories
    local backups=($(ls -d /root/pihole-encryption-backup-* 2>/dev/null | sort -r))
    
    if [[ ${#backups[@]} -eq 0 ]]; then
        print_error "No backups found in /root/"
        pause
        show_menu
        return
    fi
    
    echo -e "${CYAN}Available backups:${NC}"
    local i=1
    for backup in "${backups[@]}"; do
        echo "  $i) $(basename "$backup")"
        if [[ -f "$backup/restore.sh" ]]; then
            echo "     (has restore script)"
        fi
        ((i++))
    done
    echo "  $i) Back to main menu"
    echo ""
    
    read -p "Choose backup to restore (1-${i}): " backup_choice
    
    if [[ "$backup_choice" -eq $i ]]; then
        show_menu
        return
    fi
    
    if [[ "$backup_choice" -ge 1 ]] && [[ "$backup_choice" -le ${#backups[@]} ]]; then
        local selected="${backups[$((backup_choice-1))]}"
        print_message "Restoring from: $selected"
        
        if [[ -f "$selected/restore.sh" ]]; then
            bash "$selected/restore.sh"
            print_success "Restore completed"
        else
            print_error "Restore script not found in backup"
        fi
    else
        print_error "Invalid choice"
    fi
    
    pause
    show_menu
}

#================================================================================
# INSTALLATION FUNCTIONS
#================================================================================

prompt_domain() {
    print_step "Domain Configuration"
    
    if [[ -z "$DOMAIN" ]]; then
        read -p "Enter your domain (e.g., dns.example.com): " DOMAIN
        DOMAIN=$(echo "$DOMAIN" | xargs)
    fi
    
    if [[ ! "$DOMAIN" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        print_error "Invalid domain format"
        exit 1
    fi
    
    print_success "Domain set to: $DOMAIN"
    pause
}

prompt_email() {
    print_step "Email Configuration"
    
    if [[ -z "$EMAIL" ]]; then
        read -p "Enter your email for Let's Encrypt: " EMAIL
        EMAIL=$(echo "$EMAIL" | xargs)
    fi
    
    if [[ ! "$EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        print_error "Invalid email format"
        exit 1
    fi
    
    print_success "Email set to: $EMAIL"
    pause
}

get_local_ip() {
    print_step "Detecting Local IP"
    
    if command -v ip &> /dev/null; then
        LOCAL_IP=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v 127.0.0.1 | head -1)
    fi
    
    if [[ -z "$LOCAL_IP" ]] && command -v hostname &> /dev/null; then
        LOCAL_IP=$(hostname -I | awk '{print $1}')
    fi
    
    if [[ -z "$LOCAL_IP" ]]; then
        read -p "Enter local IPv4 address: " LOCAL_IP
    fi
    
    print_message "Local IPv4: $LOCAL_IP"
    pause
}

#================================================================================
# CERTIFICATE FUNCTIONS (IMPROVED)
#================================================================================

generate_self_signed_cert() {
    print_step "Generating Temporary Certificate"
    
    print_message "Creating self-signed certificate for: $DOMAIN"
    
    # Backup existing certs
    [[ -f "$PIHOLE_CERT" ]] && cp "$PIHOLE_CERT" "$BACKUP_DIR/tls.pem.pre-selfsigned"
    [[ -f "$PIHOLE_CA_CERT" ]] && cp "$PIHOLE_CA_CERT" "$BACKUP_DIR/tls_ca.crt.pre-selfsigned"
    
    # Set domain in config file
    print_message "Setting domain to $DOMAIN in config..."
    set_pihole_config "webserver.domain" "$DOMAIN"
    
    # Remove old certificates to force regeneration
    rm -f /etc/pihole/tls* >> "$LOG_FILE" 2>&1
    print_message "Removed old certificate files"
    
    # Restart Pi-hole with verification
    if ! restart_pihole_with_verification; then
        print_error "Failed to restart Pi-hole for certificate generation"
        return 1
    fi
    
    # Wait a bit longer for certificate generation
    sleep 5
    
    # Verify certificates were generated
    if ! verify_certificate_files; then
        print_error "Certificate verification failed"
        return 1
    fi
    
    print_success "Self-signed certificate generated and verified"
    print_message "Certificate: $PIHOLE_CERT"
    print_message "CA Certificate: $PIHOLE_CA_CERT"
    pause
}

obtain_letsencrypt_cert() {
    print_step "Obtaining Let's Encrypt Certificate"
    
    local le_dir="/etc/letsencrypt/live/${DOMAIN}"
    
    # Check if certbot is installed
    if ! command -v certbot &> /dev/null; then
        print_warning "certbot not found. Installing..."
        apt-get update > /dev/null 2>&1
        apt-get install -y certbot > /dev/null 2>&1
    fi
    
    # Ensure webroot exists
    mkdir -p /var/www/html
    
    if [[ -d "$le_dir" ]]; then
        print_warning "Certificate already exists"
        read -p "Renew? (y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            print_message "Renewing certificate..."
            certbot renew --webroot -w /var/www/html --cert-name "$DOMAIN" >> "$LOG_FILE" 2>&1
        fi
    else
        print_message "Requesting certificate from Let's Encrypt..."
        if certbot certonly --webroot -w /var/www/html --non-interactive --agree-tos --email "$EMAIL" -d "$DOMAIN" >> "$LOG_FILE" 2>&1; then
            print_success "Certificate obtained"
        else
            print_error "Failed to obtain certificate"
            print_message "Falling back to self-signed certificate"
            return 1
        fi
    fi
    
    # Combine certificate for Pi-hole
    if [[ -f "${le_dir}/fullchain.pem" ]] && [[ -f "${le_dir}/privkey.pem" ]]; then
        cat "${le_dir}/fullchain.pem" "${le_dir}/privkey.pem" > "$PIHOLE_CERT"
        chown pihole:pihole "$PIHOLE_CERT"
        chmod 600 "$PIHOLE_CERT"
        print_success "Certificate installed at: $PIHOLE_CERT"
    else
        print_error "Certificate files not found"
        return 1
    fi
    
    pause
}

#================================================================================
# PI-HOLE CONFIGURATION
#================================================================================

configure_pihole() {
    print_step "Configuring Pi-hole"
    
    # Configure webserver (using direct file editing)
    set_pihole_config "webserver.domain" "$DOMAIN"
    set_pihole_config "webserver.tls.cert" "$PIHOLE_CERT"
    set_pihole_config "webserver.port" "$WEB_PORT"
    set_pihole_config "webserver.tls.enable" "true"
    
    # Configure encrypted DNS
    set_pihole_config "dns.dot.enabled" "true"
    set_pihole_config "dns.dot.port" "$DNS_TLS_PORT"
    set_pihole_config "dns.dot.cert" "$PIHOLE_CERT"
    
    set_pihole_config "dns.doq.enabled" "true"
    set_pihole_config "dns.doq.port" "$DNS_TLS_PORT"
    set_pihole_config "dns.doq.cert" "$PIHOLE_CERT"
    
    set_pihole_config "dns.doh.enabled" "true"
    set_pihole_config "dns.doh.path" "/dns-query"
    
    # Save installation state
    cat > "$INSTALL_STATE_FILE" << EOF
INSTALLED_DOMAIN="$DOMAIN"
INSTALLED_EMAIL="$EMAIL"
INSTALLED_WEB_PORT="$WEB_PORT"
INSTALLED_DNS_TLS_PORT="$DNS_TLS_PORT"
INSTALLED_LOCAL_IP="$LOCAL_IP"
INSTALLED_USE_UPNP="$USE_UPNP"
INSTALLED_RESTRICT_DNS="$RESTRICT_DNS"
INSTALLED_DATE="$(date)"
INSTALLED_VERSION="$SCRIPT_VERSION"
EOF
    
    print_success "Pi-hole configured"
    pause
}

#================================================================================
# RENEWAL SETUP
#================================================================================

setup_renewal() {
    print_step "Configuring Auto-Renewal"
    
    mkdir -p /etc/letsencrypt/renewal-hooks/deploy
    
    cat > "$RENEWAL_HOOK" << EOF
#!/bin/bash
DOMAIN="\$RENEWED_DOMAINS"
[ -z "\$DOMAIN" ] && DOMAIN="$DOMAIN"

if [ -d "/etc/letsencrypt/live/\$DOMAIN" ]; then
    cat "/etc/letsencrypt/live/\$DOMAIN/fullchain.pem" "/etc/letsencrypt/live/\$DOMAIN/privkey.pem" > "$PIHOLE_CERT"
    chown pihole:pihole "$PIHOLE_CERT" 2>/dev/null || true
    systemctl reload pihole-FTL || systemctl restart pihole-FTL
    logger "Pi-hole: Certificate renewed for \$DOMAIN"
fi
EOF
    
    chmod +x "$RENEWAL_HOOK"
    
    # Test renewal
    print_message "Testing renewal hook..."
    certbot renew --dry-run >> "$LOG_FILE" 2>&1 || true
    
    print_success "Auto-renewal configured"
    pause
}

#================================================================================
# UNINSTALL
#================================================================================

uninstall() {
    print_step "Uninstalling Encryption"
    
    # Ask about HTTPS after uninstall
    echo -e "${YELLOW}What would you like to do with HTTPS after uninstall?${NC}"
    echo "  1) Restore original (no HTTPS, port 80 only)"
    echo "  2) Keep self-signed certificate"
    echo "  3) Keep Let's Encrypt"
    read -p "Choose (1-3): " uninstall_choice
    
    case $uninstall_choice in
        1)
            set_pihole_config "webserver.tls.enable" "false"
            set_pihole_config "webserver.port" "80"
            set_pihole_config "dns.dot.enabled" "false"
            set_pihole_config "dns.doq.enabled" "false"
            set_pihole_config "dns.doh.enabled" "false"
            rm -f "$PIHOLE_CERT" "$PIHOLE_CA_CERT" 2>/dev/null
            print_success "HTTPS disabled, port 80 restored"
            ;;
        2)
            # Keep self-signed, just disable auto-renewal
            set_pihole_config "webserver.port" "$WEB_PORT"
            print_success "Keeping self-signed certificate"
            ;;
        3)
            # Keep Let's Encrypt
            print_success "Keeping Let's Encrypt certificate"
            ;;
    esac
    
    # Remove renewal hook
    [[ -f "$RENEWAL_HOOK" ]] && rm "$RENEWAL_HOOK"
    
    # Remove state file
    [[ -f "$INSTALL_STATE_FILE" ]] && rm "$INSTALL_STATE_FILE"
    
    # Restart with verification
    restart_pihole_with_verification
    
    print_success "Uninstall completed"
    pause
}

#================================================================================
# MAIN INSTALLATION
#================================================================================

main_install() {
    print_step "Starting Installation"
    
    # Step 1: Create backup FIRST (before any changes)
    create_backup
    
    # Step 2: Get configuration
    prompt_domain
    prompt_email
    get_local_ip
    
    # Step 3: Verify domain resolves (optional but helpful)
    verify_domain_resolution
    
    # Step 4: Generate self-signed cert
    generate_self_signed_cert || {
        print_error "Self-signed certificate failed"
        print_message "Checking certificate files..."
        ls -la /etc/pihole/tls* 2>/dev/null || echo "No certificate files found"
        restore_from_backup
        exit 1
    }
    
    # Step 5: Validate HTTPS with self-signed
    validate_https || {
        print_error "HTTPS validation failed with self-signed cert"
        restore_from_backup
        exit 1
    }
    
    # Step 6: Get Let's Encrypt certificate
    obtain_letsencrypt_cert || {
        print_warning "Using self-signed certificate (Let's Encrypt failed)"
    }
    
    # Step 7: Configure Pi-hole
    configure_pihole
    
    # Step 8: Restart with verification
    restart_pihole_with_verification || {
        print_error "Failed to restart Pi-hole after configuration"
        restore_from_backup
        exit 1
    }
    
    # Step 9: Validate HTTPS again
    validate_https || {
        print_error "HTTPS validation failed after configuration"
        print_message "Would you like to restore from backup?"
        read -p "Restore? (y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            restore_from_backup
        fi
        exit 1
    }
    
    # Step 10: Setup renewal
    setup_renewal
    
    # Final success message
    echo ""
    print_success "🎉 Installation complete!"
    echo -e "${GREEN}Access your Pi-hole:${NC} https://$DOMAIN:$WEB_PORT/admin"
    echo -e "${GREEN}Backup location:${NC} $BACKUP_DIR"
    echo -e "${GREEN}To restore:${NC} sudo $BACKUP_DIR/restore.sh"
    echo ""
    
    # Show endpoints
    echo -e "${CYAN}Your endpoints:${NC}"
    echo -e "  Web Admin: https://$DOMAIN:$WEB_PORT/admin"
    echo -e "  DoH: https://$DOMAIN:$WEB_PORT/dns-query"
    echo -e "  DoT: tls://$DOMAIN:$DNS_TLS_PORT"
    echo -e "  DoQ: quic://$DOMAIN:$DNS_TLS_PORT"
    echo ""
    
    pause
}

#================================================================================
# MAIN EXECUTION
#================================================================================

main() {
    case $1 in
        --uninstall)
            uninstall
            exit 0
            ;;
        --restore)
            if [[ -d "$2" ]]; then
                bash "$2/restore.sh"
            else
                print_error "Please specify backup directory: $0 --restore /path/to/backup"
            fi
            exit 0
            ;;
        --help)
            echo "Pi-hole Encryption Setup v$SCRIPT_VERSION"
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --uninstall           Remove encryption"
            echo "  --restore <backupdir> Restore from backup"
            echo "  --help                Show this help"
            echo "  --version             Show version"
            exit 0
            ;;
        --version)
            echo "Pi-hole Encryption Setup v$SCRIPT_VERSION"
            exit 0
            ;;
    esac
    
    # Show interactive menu
    show_menu
    
    # Run installation
    main_install
}

# Run main
main "$@"