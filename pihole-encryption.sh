#!/bin/bash
#############################################################################################################################
# The MIT License (MIT)
#
# Wael Isa
# Build Date: 02/20/2026
# Version: 1.2.2
# GitHub: https://github.com/waelisa/pihole-encryption
# Website: https://www.wael.name/
# Support: https://www.paypal.me/WaelIsa
#
#############################################################################################################################
#
# v1.2.2 - IMPROVED: Let's Encrypt certificate handling
#        ✅ Fixed: Proper certificate combination for Pi-hole v6.5
#        ✅ Added: DNS-01 challenge support for providers
#        ✅ Added: Certificate format validation
#        ✅ Added: Better error messages with specific failure reasons
#        ✅ Added: Option to test different validation methods
#        ✅ Fixed: Permissions and ownership for certificate files
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
USE_UPNP="false"
RESTRICT_DNS="true"

# Pi-hole version info
PIHOLE_VERSION_MAJOR=0

# Fixed paths
PIHOLE_CERT="/etc/pihole/tls.pem"
PIHOLE_CA_CERT="/etc/pihole/tls_ca.crt"
PIHOLE_CONFIG="/etc/pihole/pihole.toml"
BACKUP_DIR="/root/pihole-encryption-backup-$(date +%Y%m%d_%H%M%S)"
LOG_FILE="/var/log/pihole-encryption-setup.log"
SCRIPT_VERSION="1.2.2"
INSTALL_STATE_FILE="/etc/pihole/encryption-installed.state"
RENEWAL_HOOK="/etc/letsencrypt/renewal-hooks/deploy/pihole.sh"

# Error trap
trap 'error_handler $? $LINENO' ERR

error_handler() {
    local exit_code=$1
    local line_no=$2
    print_error "Error on line $line_no: exit code $exit_code"
    
    # Ask if user wants to restore from backup - NEVER auto-restore!
    if [[ -d "$BACKUP_DIR" ]]; then
        echo ""
        print_warning "An error occurred. A backup exists at: $BACKUP_DIR"
        print_warning "You can restore manually later with: sudo $BACKUP_DIR/restore.sh"
        echo ""
        read -p "Would you like to restore from backup NOW? (y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            restore_from_backup
        else
            print_message "Continuing without restore. You can run the script again later."
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
# SERVICE MANAGEMENT
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
        if [[ $size -lt 500 ]]; then
            print_error "Certificate file too small (likely invalid)"
            ((errors++))
        else
            # Check if it's a valid PEM file
            if openssl x509 -in "$PIHOLE_CERT" -noout 2>/dev/null; then
                print_success "✓ Certificate is valid PEM format"
            else
                print_error "Certificate is not valid PEM format"
                ((errors++))
            fi
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
# IMPROVED HTTPS VALIDATION
#================================================================================

check_http_status() {
    local url="$1"
    local timeout=5
    
    # Try curl first (most reliable)
    if command -v curl &> /dev/null; then
        local status
        status=$(curl -k -s -o /dev/null -w "%{http_code}" --connect-timeout "$timeout" --max-time "$timeout" "$url" 2>/dev/null)
        local curl_exit=$?
        
        if [[ $curl_exit -eq 0 ]]; then
            echo "$status"
            return 0
        elif [[ $curl_exit -eq 7 ]]; then
            echo "CONNECTION_REFUSED"
            return 1
        elif [[ $curl_exit -eq 28 ]]; then
            echo "TIMEOUT"
            return 1
        else
            echo "CURL_ERROR_$curl_exit"
            return 1
        fi
    fi
    
    echo "NO_TOOL"
    return 1
}

check_tls_handshake() {
    local host="$1"
    local port="$2"
    local timeout=5
    
    if command -v openssl &> /dev/null; then
        # Use openssl s_client with timeout
        if timeout "$timeout" openssl s_client -connect "$host:$port" -servername "$host" 2>&1 < /dev/null | grep -q "CONNECTED"; then
            return 0
        fi
    fi
    
    return 1
}

validate_https() {
    print_step "Validating HTTPS Service"
    
    local max_attempts=10
    local attempt=1
    local success=false
    local local_ip=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v 127.0.0.1 | head -1)
    
    print_message "Testing HTTPS on port $WEB_PORT..."
    print_message "This may take up to 30 seconds..."
    
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
    
    # Test endpoints with proper HTTP status checking
    local endpoints=(
        "https://127.0.0.1:$WEB_PORT/admin"
        "https://localhost:$WEB_PORT/admin"
        "https://$local_ip:$WEB_PORT/admin"
    )
    
    local valid_http_codes=("200" "302" "401" "403")
    
    echo ""
    print_message "Testing endpoints..."
    
    while [[ $attempt -le $max_attempts ]] && [[ "$success" == false ]]; do
        for endpoint in "${endpoints[@]}"; do
            echo -n "  Attempt $attempt: $(echo "$endpoint" | cut -d/ -f1-3)... "
            
            local status
            status=$(check_http_status "$endpoint")
            
            # Check if status is a valid HTTP code we accept
            local valid=false
            for code in "${valid_http_codes[@]}"; do
                if [[ "$status" == "$code" ]]; then
                    valid=true
                    break
                fi
            done
            
            if [[ "$valid" == true ]]; then
                echo -e "${GREEN}OK (HTTP $status)${NC}"
                success=true
                break 2
            elif [[ "$status" == "CONNECTION_REFUSED" ]]; then
                echo -e "${RED}Connection refused${NC}"
            elif [[ "$status" == "TIMEOUT" ]]; then
                echo -e "${YELLOW}Timeout${NC}"
            elif [[ "$status" == "000" ]]; then
                echo -e "${YELLOW}No response${NC}"
            else
                echo -e "${YELLOW}HTTP $status${NC}"
                # Accept any 2xx or 3xx status
                if [[ "$status" =~ ^[23][0-9][0-9]$ ]]; then
                    success=true
                    break 2
                fi
            fi
        done
        
        if [[ $attempt -lt $max_attempts ]]; then
            sleep 2
        fi
        ((attempt++))
    done
    
    echo ""
    
    if [[ "$success" == true ]]; then
        print_success "✓ HTTPS validation passed"
        
        # Also test TLS handshake
        print_message "Testing TLS handshake..."
        if check_tls_handshake "127.0.0.1" "$WEB_PORT"; then
            print_success "✓ TLS handshake successful"
        else
            print_warning "⚠ TLS handshake test failed (but HTTP works)"
        fi
        
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
        
        # Ask user what to do - NEVER auto-restore!
        print_warning "HTTPS validation failed, but your Pi-hole might still be working."
        print_warning "You can:"
        echo "  1) Continue anyway (skip this check)"
        echo "  2) Restore from backup"
        echo "  3) Exit and troubleshoot manually"
        echo ""
        read -p "Choose option (1-3): " validate_choice
        
        case $validate_choice in
            1)
                print_warning "Continuing despite HTTPS validation failure"
                return 0
                ;;
            2)
                restore_from_backup
                exit 0
                ;;
            3)
                print_message "Exiting as requested. Your backup is at: $BACKUP_DIR"
                exit 1
                ;;
            *)
                print_error "Invalid choice, exiting"
                exit 1
                ;;
        esac
    fi
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
# CERTIFICATE FUNCTIONS
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

#================================================================================
# IMPROVED LET'S ENCRYPT FUNCTION (v1.2.2)
#================================================================================

validate_certificate_format() {
    local cert_file="$1"
    
    # Check if it's a valid PEM file
    if ! openssl x509 -in "$cert_file" -noout 2>/dev/null; then
        return 1
    fi
    
    # Check if it contains both certificate and private key
    if grep -q "BEGIN RSA PRIVATE KEY\|BEGIN PRIVATE KEY" "$cert_file" && grep -q "BEGIN CERTIFICATE" "$cert_file"; then
        return 0
    else
        return 1
    fi
}

combine_certificates() {
    local le_dir="/etc/letsencrypt/live/${DOMAIN}"
    local combined_cert="$PIHOLE_CERT"
    
    if [[ -f "${le_dir}/fullchain.pem" ]] && [[ -f "${le_dir}/privkey.pem" ]]; then
        print_message "Combining certificate and private key..."
        
        # Create combined file
        cat "${le_dir}/fullchain.pem" "${le_dir}/privkey.pem" > "${combined_cert}.tmp"
        
        # Verify the combined format
        if validate_certificate_format "${combined_cert}.tmp"; then
            mv "${combined_cert}.tmp" "$combined_cert"
            chown pihole:pihole "$combined_cert" 2>/dev/null || true
            chmod 600 "$combined_cert"
            print_success "✓ Certificate combined successfully"
            return 0
        else
            print_error "Combined certificate format is invalid"
            rm -f "${combined_cert}.tmp"
            return 1
        fi
    fi
    
    return 1
}

obtain_letsencrypt_cert() {
    print_step "Obtaining Let's Encrypt Certificate"
    
    local le_dir="/etc/letsencrypt/live/${DOMAIN}"
    local combined_cert="$PIHOLE_CERT"
    local public_ip=""
    
    # Check if certbot is installed
    if ! command -v certbot &> /dev/null; then
        print_warning "certbot not found. Installing..."
        apt-get update > /dev/null 2>&1
        apt-get install -y certbot > /dev/null 2>&1
    fi
    
    # Get public IP for information
    if command -v curl &> /dev/null; then
        public_ip=$(curl -s ifconfig.me 2>/dev/null || echo "unknown")
    fi
    
    print_message "Your public IP appears to be: $public_ip"
    print_message "Make sure your domain $DOMAIN points to this IP"
    echo ""
    
    # Ensure webroot exists
    mkdir -p /var/www/html
    
    # Create a simple test page for Let's Encrypt verification
    echo "Pi-hole Let's Encrypt Validation" > /var/www/html/index.html
    
    # Check if certificate already exists
    if [[ -d "$le_dir" ]] && [[ -f "${le_dir}/fullchain.pem" ]]; then
        print_warning "Certificate already exists for $DOMAIN"
        echo ""
        echo "Options:"
        echo "  1) Renew existing certificate"
        echo "  2) Request new certificate (force)"
        echo "  3) Skip and use self-signed"
        echo ""
        read -p "Choose (1-3): " cert_choice
        
        case $cert_choice in
            1)
                print_message "Renewing certificate..."
                certbot renew --webroot -w /var/www/html --cert-name "$DOMAIN" >> "$LOG_FILE" 2>&1
                if [[ $? -eq 0 ]]; then
                    print_success "Certificate renewed"
                else
                    print_error "Renewal failed"
                    return 1
                fi
                ;;
            2)
                print_message "Requesting new certificate..."
                certbot delete --cert-name "$DOMAIN" >> "$LOG_FILE" 2>&1
                ;;
            3)
                print_warning "Skipping Let's Encrypt, using self-signed"
                return 1
                ;;
        esac
    fi
    
    # If we don't have a certificate yet, request one
    if [[ ! -d "$le_dir" ]] || [[ ! -f "${le_dir}/fullchain.pem" ]]; then
        echo ""
        print_message "Let's Encrypt needs to verify you control $DOMAIN"
        print_message "Choose verification method:"
        echo "  1) HTTP-01 challenge (requires port 80 publicly accessible)"
        echo "  2) DNS-01 challenge (requires DNS API access)"
        echo "  3) Manual DNS (create TXT record yourself)"
        echo "  4) Skip Let's Encrypt (use self-signed)"
        echo ""
        read -p "Choose method (1-4): " le_method
        
        case $le_method in
            1)
                print_message "Attempting HTTP-01 challenge..."
                if certbot certonly --webroot -w /var/www/html --non-interactive --agree-tos --email "$EMAIL" -d "$DOMAIN" >> "$LOG_FILE" 2>&1; then
                    print_success "Certificate obtained via HTTP-01"
                else
                    print_error "HTTP-01 challenge failed"
                    print_message "Common reasons:"
                    echo "  • Port 80 is not accessible from internet"
                    echo "  • Domain $DOMAIN doesn't point to this server"
                    echo "  • Firewall is blocking port 80"
                    echo ""
                    read -p "Try DNS-01 method instead? (y/n): " try_dns
                    if [[ $try_dns =~ ^[Yy]$ ]]; then
                        le_method=2
                    else
                        return 1
                    fi
                fi
                ;;
                
            2)
                print_message "DNS-01 challenge selected"
                print_message "Installing certbot DNS plugins..."
                apt-get update > /dev/null 2>&1
                
                echo ""
                print_message "Select your DNS provider:"
                echo "  1) Cloudflare"
                echo "  2) OVH"
                echo "  3) DigitalOcean"
                echo "  4) GoDaddy"
                echo "  5) Namecheap"
                echo "  6) Other (manual mode)"
                echo ""
                read -p "Choose (1-6): " dns_provider
                
                case $dns_provider in
                    1)
                        apt-get install -y python3-certbot-dns-cloudflare >> "$LOG_FILE" 2>&1
                        echo ""
                        print_message "Cloudflare API Token needed"
                        print_message "Create a token at: https://dash.cloudflare.com/profile/api-tokens"
                        echo "Token needs permissions: Zone:Read, DNS:Edit"
                        echo ""
                        read -p "Enter Cloudflare API token: " cf_token
                        mkdir -p ~/.secrets
                        echo "dns_cloudflare_api_token = $cf_token" > ~/.secrets/cloudflare.ini
                        chmod 600 ~/.secrets/cloudflare.ini
                        
                        certbot certonly --dns-cloudflare --dns-cloudflare-credentials ~/.secrets/cloudflare.ini -d "$DOMAIN" --non-interactive --agree-tos --email "$EMAIL" >> "$LOG_FILE" 2>&1
                        ;;
                        
                    2)
                        apt-get install -y python3-certbot-dns-ovh >> "$LOG_FILE" 2>&1
                        print_message "OVH requires application key and secret"
                        echo "Please create credentials at: https://www.ovh.com/auth/api/createToken"
                        echo ""
                        read -p "Enter OVH application key: " ovh_key
                        read -p "Enter OVH application secret: " ovh_secret
                        read -p "Enter OVH consumer key: " ovh_ck
                        
                        mkdir -p ~/.secrets
                        cat > ~/.secrets/ovh.ini << OVHEOF
dns_ovh_endpoint = ovh-eu
dns_ovh_application_key = $ovh_key
dns_ovh_application_secret = $ovh_secret
dns_ovh_consumer_key = $ovh_ck
OVHEOF
                        chmod 600 ~/.secrets/ovh.ini
                        
                        certbot certonly --dns-ovh --dns-ovh-credentials ~/.secrets/ovh.ini -d "$DOMAIN" --non-interactive --agree-tos --email "$EMAIL" >> "$LOG_FILE" 2>&1
                        ;;
                        
                    3)
                        apt-get install -y python3-certbot-dns-digitalocean >> "$LOG_FILE" 2>&1
                        print_message "DigitalOcean API token needed"
                        echo "Create token at: https://cloud.digitalocean.com/account/api/tokens"
                        echo ""
                        read -p "Enter DigitalOcean API token: " do_token
                        
                        mkdir -p ~/.secrets
                        echo "dns_digitalocean_token = $do_token" > ~/.secrets/digitalocean.ini
                        chmod 600 ~/.secrets/digitalocean.ini
                        
                        certbot certonly --dns-digitalocean --dns-digitalocean-credentials ~/.secrets/digitalocean.ini -d "$DOMAIN" --non-interactive --agree-tos --email "$EMAIL" >> "$LOG_FILE" 2>&1
                        ;;
                        
                    *)
                        print_message "Manual DNS mode selected"
                        print_message "Run this command manually:"
                        echo "  certbot certonly --manual --preferred-challenges dns -d $DOMAIN --email $EMAIL --agree-tos"
                        echo ""
                        read -p "Press Enter after obtaining certificate manually..."
                        ;;
                esac
                ;;
                
            3)
                print_message "Manual DNS challenge selected"
                print_message "You will need to create a TXT record in your DNS"
                echo ""
                certbot certonly --manual --preferred-challenges dns -d "$DOMAIN" --email "$EMAIL" --agree-tos
                ;;
                
            4)
                print_warning "Skipping Let's Encrypt, using self-signed"
                return 1
                ;;
        esac
    fi
    
    # Verify certificate was obtained
    if [[ -d "$le_dir" ]] && [[ -f "${le_dir}/fullchain.pem" ]] && [[ -f "${le_dir}/privkey.pem" ]]; then
        print_success "Let's Encrypt certificate obtained"
        
        # Combine for Pi-hole
        if combine_certificates; then
            print_success "Certificate installed for Pi-hole"
            
            # Show certificate info
            local cert_expiry=$(openssl x509 -in "$PIHOLE_CERT" -enddate -noout | cut -d= -f2)
            print_message "Certificate expires: $cert_expiry"
            
            return 0
        else
            print_error "Failed to combine certificate for Pi-hole"
            return 1
        fi
    else
        print_error "Failed to obtain Let's Encrypt certificate"
        return 1
    fi
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
    
    cat > "$RENEWAL_HOOK" << 'EOF'
#!/bin/bash
DOMAIN="$RENEWED_DOMAINS"
PIHOLE_CERT="/etc/pihole/tls.pem"

if [ -z "$DOMAIN" ] && [ -f "/etc/pihole/encryption-installed.state" ]; then
    source /etc/pihole/encryption-installed.state
    DOMAIN="$INSTALLED_DOMAIN"
fi

if [ -d "/etc/letsencrypt/live/$DOMAIN" ]; then
    echo "$(date): Renewing certificate for $DOMAIN" >> /var/log/pihole-cert-renewal.log
    cat "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" "/etc/letsencrypt/live/$DOMAIN/privkey.pem" > "$PIHOLE_CERT"
    chown pihole:pihole "$PIHOLE_CERT" 2>/dev/null || true
    chmod 600 "$PIHOLE_CERT"
    systemctl reload pihole-FTL 2>/dev/null || systemctl restart pihole-FTL
    echo "$(date): Certificate renewed and Pi-hole reloaded" >> /var/log/pihole-cert-renewal.log
fi
EOF
    
    chmod +x "$RENEWAL_HOOK"
    
    # Test renewal
    print_message "Testing renewal hook..."
    certbot renew --dry-run >> "$LOG_FILE" 2>&1 || true
    
    # Setup daily cron check (in case certbot timer fails)
    if ! crontab -l 2>/dev/null | grep -q "certbot renew"; then
        (crontab -l 2>/dev/null; echo "0 3 * * * /usr/bin/certbot renew --quiet --deploy-hook $RENEWAL_HOOK") | crontab -
        print_success "Added daily renewal check to cron"
    fi
    
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
    
    # Remove cron job
    crontab -l 2>/dev/null | grep -v "certbot renew" | crontab -
    
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
        # Ask before restoring
        read -p "Restore from backup? (y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            restore_from_backup
        fi
        exit 1
    }
    
    # Step 5: Validate HTTPS with self-signed
    validate_https || {
        # validate_https now handles user interaction
        # If it returns non-zero, user chose to exit
        exit 1
    }
    
    # Step 6: Get Let's Encrypt certificate
    obtain_letsencrypt_cert || {
        print_warning "Using self-signed certificate (Let's Encrypt skipped or failed)"
    }
    
    # Step 7: Configure Pi-hole
    configure_pihole
    
    # Step 8: Restart with verification
    restart_pihole_with_verification || {
        print_error "Failed to restart Pi-hole after configuration"
        read -p "Restore from backup? (y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            restore_from_backup
        fi
        exit 1
    }
    
    # Step 9: Validate HTTPS again
    validate_https || {
        # validate_https now handles user interaction
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