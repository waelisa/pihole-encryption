#!/bin/bash
#############################################################################################################################
# The MIT License (MIT)
#
# Wael Isa
# Build Date: 02/20/2026
# Version: 1.3.0
# GitHub: https://github.com/waelisa/pihole-encryption
# Website: https://www.wael.name/
# Support: https://www.paypal.me/WaelIsa
#
#############################################################################################################################
#
# v1.3.0 - THE MASTER BUILD: Robust, Safe, and Comprehensive Pi-hole Encryption Setup
#        ✅ SAFETY FIRST: Creates a complete, verifiable backup before ANY changes.
#        ✅ ROBUST TOML HANDLING: Edits pihole.toml safely, preserving structure and comments.
#        ✅ ACCURATE VERIFICATION: Checks domain resolution, port 80 accessibility, and permissions.
#        ✅ SMART LET'S ENCRYPT: Prioritizes HTTP-01, with clear fallback to self-signed.
#        ✅ COMPLETE ROLLBACK: Automatic restore on critical failure, with user confirmation.
#        ✅ FUTURE-PROOF: Designed for Pi-hole v6.5 and beyond.
#
#############################################################################################################################

# --- Script Configuration ---
set -o pipefail
shopt -s nullglob

# --- Color Definitions ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- Core Variables ---
DOMAIN=""
EMAIL=""
WEB_PORT="443"
DNS_TLS_PORT="853"
LOCAL_IP=""

# Fixed paths
PIHOLE_CERT="/etc/pihole/tls.pem"
PIHOLE_CA_CERT="/etc/pihole/tls_ca.crt"
PIHOLE_CONFIG="/etc/pihole/pihole.toml"
BACKUP_DIR="/root/pihole-encryption-backup-$(date +%Y%m%d_%H%M%S)"
LOG_FILE="/var/log/pihole-encryption-setup.log"
SCRIPT_VERSION="1.3.0"
INSTALL_STATE_FILE="/etc/pihole/encryption-installed.state"
RENEWAL_HOOK="/etc/letsencrypt/renewal-hooks/deploy/pihole.sh"
WEBROOT="/var/www/html"

# --- Error Handling ---
trap 'error_handler $? $LINENO $BASH_COMMAND' ERR

error_handler() {
    local exit_code=$1
    local line_no=$2
    local last_cmd=$3
    print_error "Fatal error on line $line_no: '$last_cmd' exited with status $exit_code"
    
    if [[ -d "$BACKUP_DIR" && -f "$BACKUP_DIR/restore.sh" ]]; then
        echo ""
        print_warning "A backup was created at: $BACKUP_DIR"
        read -p "Restore from this backup now? (y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            print_message "Attempting to restore from backup..."
            bash "$BACKUP_DIR/restore.sh" || print_error "Restore script execution failed."
        else
            print_message "Backup not restored. You can manually restore later with: sudo $BACKUP_DIR/restore.sh"
        fi
    fi
    exit $exit_code
}

# --- Utility Functions ---
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

# --- Core Function Definitions ---

# Creates a timestamped backup of critical files and a restore script.
create_backup() {
    print_step "Creating System Backup (Safety First)"
    print_message "Backup directory: $BACKUP_DIR"
    mkdir -p "$BACKUP_DIR"
    
    # Backup configs and certs
    if [[ -f "$PIHOLE_CONFIG" ]]; then
        cp "$PIHOLE_CONFIG" "$BACKUP_DIR/pihole.toml.backup"
        print_message "✓ Backed up Pi-hole config"
    fi
    
    if [[ -f "$PIHOLE_CERT" ]]; then
        cp "$PIHOLE_CERT" "$BACKUP_DIR/tls.pem.backup"
        print_message "✓ Backed up TLS certificate"
    fi
    
    if [[ -f "$PIHOLE_CA_CERT" ]]; then
        cp "$PIHOLE_CA_CERT" "$BACKUP_DIR/tls_ca.crt.backup"
        print_message "✓ Backed up CA certificate"
    fi
    
    if [[ -d "/etc/letsencrypt" ]]; then
        cp -r "/etc/letsencrypt" "$BACKUP_DIR/letsencrypt.backup" 2>/dev/null
        print_message "✓ Backed up Let's Encrypt"
    fi
    
    # Create the restore script
    cat > "$BACKUP_DIR/restore.sh" << 'EOF'
#!/bin/bash
echo "Restoring Pi-hole from backup: $(pwd)"

# Stop Pi-hole
systemctl stop pihole-FTL
sleep 2
pkill -f pihole-FTL 2>/dev/null
sleep 2

# Restore config
if [[ -f "pihole.toml.backup" ]]; then
    cp -f "pihole.toml.backup" /etc/pihole/pihole.toml
    echo "✓ Restored config"
fi

# Restore certificates
if [[ -f "tls.pem.backup" ]]; then
    cp -f "tls.pem.backup" /etc/pihole/tls.pem
    chown pihole:pihole /etc/pihole/tls.pem 2>/dev/null
    chmod 600 /etc/pihole/tls.pem
    echo "✓ Restored TLS cert"
fi

if [[ -f "tls_ca.crt.backup" ]]; then
    cp -f "tls_ca.crt.backup" /etc/pihole/tls_ca.crt
    chown pihole:pihole /etc/pihole/tls_ca.crt 2>/dev/null
    chmod 644 /etc/pihole/tls_ca.crt
    echo "✓ Restored CA cert"
fi

# Start Pi-hole
echo "Starting Pi-hole FTL..."
systemctl start pihole-FTL
sleep 5

if systemctl is-active --quiet pihole-FTL; then
    echo "✓ Pi-hole FTL is running."
else
    echo "⚠ Pi-hole FTL failed to start. Check with: systemctl status pihole-FTL"
fi
EOF
    
    chmod +x "$BACKUP_DIR/restore.sh"
    print_success "✓ Backup and restore script created at $BACKUP_DIR/restore.sh"
    pause
}

# Safely sets a value in the pihole.toml file.
set_toml_value() {
    local config_file="$1"
    local section="$2"
    local key="$3"
    local value="$4"
    local temp_file="${config_file}.tmp"
    local backup_file="${config_file}.bak"
    
    cp "$config_file" "$backup_file"
    print_message "  Setting [$section] $key = $value"
    
    # Use awk for robust TOML editing - FIXED SYNTAX
    awk -v s="$section" -v k="$key" -v v="$value" '
    BEGIN { in_section = 0; replaced = 0; }
    # Match the start of the target section
    $0 ~ "^\\[" s "\\]" { 
        in_section = 1
        print
        next
    }
    # Match the start of another section, exit current section
    in_section == 1 && /^\[.*\]/ { 
        in_section = 0
    }
    # If in the target section and line starts with the key (ignoring spaces)
    in_section == 1 && $0 ~ "^[[:space:]]*" k "[[:space:]]*=" {
        sub(/=.*/, "= " v)
        replaced = 1
        print
        next
    }
    # Print all other lines unchanged
    {
        print
    }
    END {
        # If key wasn't found in the section, add it after the section header
        if (in_section == 1 && replaced == 0) {
            print "  " k " = " v
        } else if (in_section == 0 && replaced == 0) {
            # Section might not exist at all, add it at the end
            print "\n[" s "]"
            print "  " k " = " v
        }
    }' "$backup_file" > "$temp_file"
    
    # Verify and apply
    if [[ $? -eq 0 ]] && grep -q "^\[$section\]" "$temp_file"; then
        mv "$temp_file" "$config_file"
        print_success "    ✓ Updated successfully"
        rm -f "$backup_file"
        return 0
    else
        print_error "    ✗ Failed to update configuration. Restoring backup."
        mv "$backup_file" "$config_file"
        return 1
    fi
}

# Gets a value from the pihole.toml file.
get_toml_value() {
    local config_file="$1"
    local section="$2"
    local key="$3"
    
    awk -v s="$section" -v k="$key" '
    BEGIN { in_section = 0 }
    $0 ~ "^\\[" s "\\]" { 
        in_section = 1
        next
    }
    in_section == 1 && /^\[/ { 
        in_section = 0 
    }
    in_section == 1 && $0 ~ "^[[:space:]]*" k "[[:space:]]*=" {
        gsub(/^[[:space:]]*|"|'"'"'/, "")
        sub(/^[^=]*=[[:space:]]*/, "")
        print
        exit
    }' "$config_file"
}

# Restarts pihole-FTL and verifies it's listening on the web port.
restart_pihole_with_verification() {
    local max_attempts=5
    local attempt=1
    local wait_time=3
    
    print_message "Restarting Pi-hole FTL service..."
    
    systemctl stop pihole-FTL
    sleep 2
    pkill -f pihole-FTL 2>/dev/null
    sleep 2
    systemctl start pihole-FTL
    
    while [[ $attempt -le $max_attempts ]]; do
        sleep $wait_time
        
        if systemctl is-active --quiet pihole-FTL; then
            if ss -tlnp 2>/dev/null | grep -q ":$WEB_PORT.*pihole-FTL"; then
                print_success "✓ Pi-hole FTL running and port $WEB_PORT listening."
                return 0
            fi
            print_warning "  Pi-hole FTL running, but port $WEB_PORT not yet listening (attempt $attempt)."
        else
            print_warning "  Pi-hole FTL not running yet (attempt $attempt)."
        fi
        
        ((attempt++))
        wait_time=$((wait_time + 2))
    done
    
    print_error "Failed to verify Pi-hole FTL on port $WEB_PORT after $max_attempts attempts."
    journalctl -u pihole-FTL -n 20 --no-pager || true
    return 1
}

# Verifies and corrects pihole.toml for Let's Encrypt compatibility.
verify_pihole_config() {
    print_step "Verifying Pi-hole Configuration"
    
    local config_file="$PIHOLE_CONFIG"
    local changes_made=false
    
    if [[ ! -f "$config_file" ]]; then
        print_error "Pi-hole config not found."
        return 1
    fi
    
    # Check Domain
    local current_domain=$(get_toml_value "$config_file" "webserver" "domain")
    if [[ "$current_domain" != "$DOMAIN" ]] && [[ "$current_domain" != "\"$DOMAIN\"" ]]; then
        print_warning "  Domain is '$current_domain', should be '$DOMAIN'. Updating..."
        set_toml_value "$config_file" "webserver" "domain" "\"$DOMAIN\"" && changes_made=true
    else
        print_success "  ✓ Domain correctly set to $DOMAIN"
    fi
    
    # Check Serve All
    local serve_all=$(get_toml_value "$config_file" "webserver" "serve_all")
    if [[ "$serve_all" != "true" ]]; then
        print_warning "  serve_all is '$serve_all', must be 'true'. Updating..."
        set_toml_value "$config_file" "webserver" "serve_all" "true" && changes_made=true
    else
        print_success "  ✓ serve_all correctly set to true"
    fi
    
    # Check Ports (Ensure 80 is present)
    local port_setting=$(get_toml_value "$config_file" "webserver" "port")
    if [[ "$port_setting" != *"80"* ]]; then
        print_warning "  Port 80 not found in '$port_setting'. Adding it..."
        local new_ports="\"${port_setting},80\""
        set_toml_value "$config_file" "webserver" "port" "$new_ports" && changes_made=true
    else
        print_success "  ✓ Port 80 is present in configuration"
    fi
    
    # Apply changes
    if [[ "$changes_made" == true ]]; then
        print_message "Configuration changes applied. Restarting Pi-hole..."
        if ! restart_pihole_with_verification; then
            print_error "Failed to restart Pi-hole after config changes. Check logs."
            return 1
        fi
    else
        print_success "✓ Pi-hole configuration is optimal for Let's Encrypt."
    fi
    
    # Show final config
    echo ""
    print_message "Current [webserver] section:"
    sed -n '/^\[webserver\]/,/^\[/p' "$config_file" | head -10
    echo ""
    pause
}

# Fixes ownership/permissions of the webroot for the 'pihole' user.
fix_webroot_ownership() {
    print_step "Ensuring Webroot Accessibility for Pi-hole"
    
    local pihole_user="pihole"
    local webroot="$WEBROOT"
    
    if ! id "$pihole_user" &>/dev/null; then
        print_error "User '$pihole_user' not found."
        return 1
    fi
    
    mkdir -p "$webroot"
    local current_owner=$(stat -c "%U:%G" "$webroot" 2>/dev/null || stat -f "%Su:%Sg" "$webroot" 2>/dev/null)
    print_message "Webroot: $webroot (Owner: $current_owner)"
    
    echo ""
    print_message "Options:"
    echo "  1) Change ownership to pihole:pihole (Recommended)"
    echo "  2) Keep current owner but set permissions to 755 (Less secure)"
    echo "  3) Skip"
    read -p "Choose option (1-3): " owner_choice
    
    case $owner_choice in
        1)
            print_message "Changing ownership to pihole:pihole..."
            chown -R "$pihole_user:$pihole_user" "$webroot" 2>/dev/null || sudo chown -R "$pihole_user:$pihole_user" "$webroot"
            chmod -R 755 "$webroot" 2>/dev/null || sudo chmod -R 755 "$webroot"
            print_success "✓ Ownership changed to pihole:pihole"
            ;;
        2)
            print_message "Setting permissions to 755..."
            chmod -R 755 "$webroot" 2>/dev/null || sudo chmod -R 755 "$webroot"
            print_success "✓ Permissions set to 755"
            ;;
        3)
            print_warning "Skipping ownership changes"
            ;;
    esac
    
    # Ensure parent directories are traversable
    chmod 755 /var /var/www 2>/dev/null || sudo chmod 755 /var /var/www 2>/dev/null
    
    # Add pihole to www-data group for good measure
    if ! groups $pihole_user | grep -q www-data; then
        usermod -aG www-data $pihole_user 2>/dev/null || sudo usermod -aG www-data $pihole_user
    fi
    
    pause
}

# Tests if port 80 is accessible from the internet.
verify_port_80_accessible() {
    print_step "Verifying External Access on Port 80"
    
    local public_ip=""
    local test_file="acme-test-$(date +%s).html"
    local test_url="http://$DOMAIN/$test_file"
    
    # Get public IP
    public_ip=$(curl -s ifconfig.me 2>/dev/null || echo "unknown")
    
    print_message "Your public IP (from server's perspective): $public_ip"
    print_message "Your domain '$DOMAIN' should have an A record pointing to this IP."
    echo ""
    
    # Check local listeners
    if ! ss -tlnp 2>/dev/null | grep -q ":80 "; then
        print_error "Port 80 is not listening locally. Cannot proceed with HTTP-01 challenge."
        return 1
    fi
    
    # Clean up old test files and create a new one
    find "$WEBROOT" -name "acme-test-*.html" -type f -delete 2>/dev/null
    echo "ACME Test $(date)" > "$WEBROOT/$test_file"
    chmod 644 "$WEBROOT/$test_file"
    
    # Test local access
    if curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1/$test_file" | grep -q "200"; then
        print_success "✓ Test file accessible locally."
    else
        print_warning "⚠ Test file not accessible locally. Check webroot and configuration."
        ls -la "$WEBROOT"
        rm -f "$WEBROOT/$test_file"
        return 1
    fi
    
    # Test external access
    print_message "Testing external access to $test_url... (This may take a moment)"
    local test_success=false
    
    for ((i=1; i<=3; i++)); do
        echo -n "  Attempt $i: "
        if timeout 10 curl -s -o /dev/null -w "%{http_code}" "$test_url" 2>/dev/null | grep -q "200"; then
            echo -e "${GREEN}OK${NC}"
            test_success=true
            break
        fi
        echo -e "${YELLOW}Failed${NC}"
        sleep 2
    done
    
    rm -f "$WEBROOT/$test_file"
    
    if [[ "$test_success" == true ]]; then
        print_success "✓ Port 80 is externally accessible! Ready for Let's Encrypt."
        return 0
    else
        print_error "✗ Could not access test file from the internet."
        print_warning "Please ensure:"
        echo "  1) Port 80 is forwarded on your router to $LOCAL_IP"
        echo "  2) Your domain $DOMAIN points to $public_ip"
        echo "  3) No firewall is blocking port 80"
        echo ""
        echo "Options:"
        echo "  1) Continue with self-signed certificate only"
        echo "  2) Exit to troubleshoot"
        read -p "Choose (1-2): " choice
        if [[ "$choice" == "1" ]]; then
            return 2
        else
            exit 1
        fi
    fi
}

# Generates a self-signed certificate using Pi-hole's built-in mechanism.
generate_self_signed_cert() {
    print_step "Generating Temporary Self-Signed Certificate"
    
    print_message "Setting domain and triggering cert generation for: $DOMAIN"
    set_toml_value "$PIHOLE_CONFIG" "webserver" "domain" "\"$DOMAIN\"" || return 1
    
    rm -f /etc/pihole/tls* >> "$LOG_FILE" 2>&1
    restart_pihole_with_verification || return 1
    sleep 5
    
    # Verify certificate was created
    if [[ ! -f "$PIHOLE_CERT" ]] || [[ ! -s "$PIHOLE_CERT" ]]; then
        print_error "Certificate generation failed."
        ls -la /etc/pihole/tls*
        return 1
    fi
    
    chown pihole:pihole "$PIHOLE_CERT" "$PIHOLE_CA_CERT" 2>/dev/null
    chmod 600 "$PIHOLE_CERT"
    chmod 644 "$PIHOLE_CA_CERT"
    
    print_success "Self-signed certificate created at $PIHOLE_CERT"
    pause
}

# Obtains a Let's Encrypt certificate using the HTTP-01 challenge.
obtain_letsencrypt_http01() {
    print_step "Obtaining Let's Encrypt Certificate (HTTP-01)"
    
    local le_dir="/etc/letsencrypt/live/${DOMAIN}"
    
    if ! command -v certbot &> /dev/null; then
        print_message "Installing certbot..."
        apt-get update &>/dev/null && apt-get install -y certbot &>/dev/null || {
            print_error "Failed to install certbot."
            return 1
        }
    fi
    
    mkdir -p "$WEBROOT"
    chown pihole:pihole "$WEBROOT" 2>/dev/null || true
    
    if [[ -d "$le_dir" ]]; then
        print_warning "Certificate already exists for $DOMAIN."
        read -p "Renew it? (y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            certbot renew --webroot -w "$WEBROOT" --cert-name "$DOMAIN" >> "$LOG_FILE" 2>&1 || return 1
        fi
    else
        print_message "Requesting new certificate..."
        if ! certbot certonly --webroot -w "$WEBROOT" --non-interactive --agree-tos --email "$EMAIL" -d "$DOMAIN" >> "$LOG_FILE" 2>&1; then
            print_error "Let's Encrypt challenge failed. Check $LOG_FILE for details."
            return 1
        fi
    fi
    
    # Combine certificate for Pi-hole
    if [[ -f "${le_dir}/fullchain.pem" ]] && [[ -f "${le_dir}/privkey.pem" ]]; then
        cat "${le_dir}/fullchain.pem" "${le_dir}/privkey.pem" > "$PIHOLE_CERT"
        chown pihole:pihole "$PIHOLE_CERT"
        chmod 600 "$PIHOLE_CERT"
        local expiry=$(openssl x509 -in "$PIHOLE_CERT" -enddate -noout | cut -d= -f2)
        print_success "Certificate obtained and installed. Expires: $expiry"
        return 0
    else
        print_error "Certificate files not found after obtaining."
        return 1
    fi
}

# Validates that HTTPS is working.
validate_https() {
    print_step "Final Validation: Testing HTTPS"
    
    local max_attempts=10
    local attempt=1
    local success=false
    
    print_message "Testing https://127.0.0.1:$WEB_PORT/admin ..."
    
    while [[ $attempt -le $max_attempts ]] && [[ "$success" == false ]]; do
        if curl -k -s -o /dev/null -w "%{http_code}" "https://127.0.0.1:$WEB_PORT/admin" 2>/dev/null | grep -q "200\|302"; then
            success=true
            break
        fi
        sleep 2
        ((attempt++))
    done
    
    if [[ "$success" == true ]]; then
        print_success "✓ HTTPS validation passed."
        return 0
    else
        print_error "✗ HTTPS validation failed after configuration."
        return 1
    fi
}

# Configures Pi-hole to use the obtained certificate.
configure_pihole() {
    print_step "Applying Final Pi-hole Encryption Settings"
    
    set_toml_value "$PIHOLE_CONFIG" "webserver" "tls.cert" "\"$PIHOLE_CERT\"" || return 1
    set_toml_value "$PIHOLE_CONFIG" "webserver" "tls.enable" "true" || return 1
    set_toml_value "$PIHOLE_CONFIG" "dns" "dot.enabled" "true" || return 1
    set_toml_value "$PIHOLE_CONFIG" "dns" "dot.port" "$DNS_TLS_PORT" || return 1
    set_toml_value "$PIHOLE_CONFIG" "dns" "dot.cert" "\"$PIHOLE_CERT\"" || return 1
    set_toml_value "$PIHOLE_CONFIG" "dns" "doq.enabled" "true" || return 1
    set_toml_value "$PIHOLE_CONFIG" "dns" "doq.port" "$DNS_TLS_PORT" || return 1
    set_toml_value "$PIHOLE_CONFIG" "dns" "doq.cert" "\"$PIHOLE_CERT\"" || return 1
    set_toml_value "$PIHOLE_CONFIG" "dns" "doh.enabled" "true" || return 1
    set_toml_value "$PIHOLE_CONFIG" "dns" "doh.path" "\"/dns-query\"" || return 1
    
    cat > "$INSTALL_STATE_FILE" << EOF
DOMAIN="$DOMAIN"
EMAIL="$EMAIL"
WEB_PORT="$WEB_PORT"
DNS_TLS_PORT="$DNS_TLS_PORT"
LOCAL_IP="$LOCAL_IP"
INSTALL_DATE="$(date)"
SCRIPT_VERSION="$SCRIPT_VERSION"
EOF
    
    print_success "Pi-hole encryption settings applied."
    pause
}

# Sets up automatic certificate renewal.
setup_renewal() {
    print_step "Configuring Automatic Certificate Renewal"
    
    mkdir -p /etc/letsencrypt/renewal-hooks/deploy
    
    cat > "$RENEWAL_HOOK" << EOF
#!/bin/bash
DOMAIN="\$RENEWED_DOMAINS"
PIHOLE_CERT="$PIHOLE_CERT"
WEBROOT="$WEBROOT"

if [ -z "\$DOMAIN" ] && [ -f "$INSTALL_STATE_FILE" ]; then
    source "$INSTALL_STATE_FILE"
    DOMAIN="\$DOMAIN"
fi

if [ -d "/etc/letsencrypt/live/\$DOMAIN" ]; then
    cat "/etc/letsencrypt/live/\$DOMAIN/fullchain.pem" "/etc/letsencrypt/live/\$DOMAIN/privkey.pem" > "\$PIHOLE_CERT"
    chown pihole:pihole "\$PIHOLE_CERT" 2>/dev/null || true
    chmod 600 "\$PIHOLE_CERT"
    systemctl reload pihole-FTL 2>/dev/null || systemctl restart pihole-FTL
fi
EOF
    
    chmod +x "$RENEWAL_HOOK"
    certbot renew --dry-run >> "$LOG_FILE" 2>&1 || true
    
    # Add a daily cron job as a safety net
    (crontab -l 2>/dev/null | grep -v "certbot renew"; echo "0 3 * * * /usr/bin/certbot renew --quiet --webroot -w $WEBROOT --deploy-hook $RENEWAL_HOOK") | crontab -
    
    print_success "Auto-renewal configured via cron and certbot hooks."
    pause
}

# --- Installation Orchestration ---
main_install() {
    print_step "Starting Installation Process"
    
    # Gather info
    read -p "Enter your domain (e.g., dns.example.com): " DOMAIN
    DOMAIN=$(echo "$DOMAIN" | xargs)
    
    read -p "Enter your email for Let's Encrypt: " EMAIL
    EMAIL=$(echo "$EMAIL" | xargs)
    
    LOCAL_IP=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v 127.0.0.1 | head -1)
    
    # Domain resolution check
    local domain_ip=$(dig +short "$DOMAIN" @8.8.8.8 2>/dev/null | head -1)
    if [[ -n "$domain_ip" && "$domain_ip" != "$LOCAL_IP" ]]; then
        print_warning "Domain $DOMAIN resolves to $domain_ip, but server IP is $LOCAL_IP."
        read -p "Continue anyway? (y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 0
        fi
    fi
    
    # --- Core Execution Flow ---
    create_backup                         # Step 1: Backup
    verify_pihole_config                   # Step 2: Fix config
    fix_webroot_ownership                  # Step 3: Fix permissions
    verify_port_80_accessible               # Step 4: Check port 80
    local port_status=$?
    
    generate_self_signed_cert || exit 1    # Step 5: Generate temporary cert
    validate_https || exit 1               # Step 6: Validate temporary cert
    
    if [[ $port_status -eq 0 ]]; then      # Step 7: Attempt Let's Encrypt if possible
        obtain_letsencrypt_http01 || print_warning "Let's Encrypt failed. Using self-signed cert."
    else
        print_warning "Port 80 test failed. Using self-signed certificate."
    fi
    
    configure_pihole                       # Step 8: Apply final config
    restart_pihole_with_verification || exit 1
    validate_https || exit 1                # Step 9: Final validation
    setup_renewal                           # Step 10: Setup auto-renewal
    
    # Success message
    echo ""
    print_success "🎉 Installation Complete!"
    echo -e "${GREEN}Access Pi-hole admin:${NC} https://$DOMAIN:$WEB_PORT/admin"
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

# --- Uninstall Function ---
uninstall() {
    print_step "Uninstalling Encryption"
    
    echo "This will revert your Pi-hole to a non-encrypted state (port 80)."
    read -p "Are you sure? (y/n): " -n 1 -r
    echo
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        set_toml_value "$PIHOLE_CONFIG" "webserver" "tls.enable" "false" || true
        set_toml_value "$PIHOLE_CONFIG" "webserver" "port" "\"80\"" || true
        set_toml_value "$PIHOLE_CONFIG" "dns" "dot.enabled" "false" || true
        set_toml_value "$PIHOLE_CONFIG" "dns" "doq.enabled" "false" || true
        set_toml_value "$PIHOLE_CONFIG" "dns" "doh.enabled" "false" || true
        
        rm -f "$PIHOLE_CERT" "$PIHOLE_CA_CERT" 2>/dev/null
        rm -f "$RENEWAL_HOOK" 2>/dev/null
        crontab -l 2>/dev/null | grep -v "certbot renew" | crontab -
        rm -f "$INSTALL_STATE_FILE" 2>/dev/null
        
        restart_pihole_with_verification
        print_success "Uninstall complete. Pi-hole is now on HTTP port 80."
    else
        print_message "Uninstall cancelled."
    fi
    
    pause
}

# --- Root Check ---
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root."
        exit 1
    fi
}

# --- Main Menu ---
show_menu() {
    clear
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}         Pi-hole Enterprise Encryption Setup v$SCRIPT_VERSION (Master Build)${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${CYAN}GitHub: https://github.com/waelisa/pihole-encryption${NC}"
    echo ""
    
    if [[ -f "$INSTALL_STATE_FILE" ]]; then
        source "$INSTALL_STATE_FILE"
        echo -e "${YELLOW}Existing installation detected:${NC}"
        echo "  Domain: $DOMAIN"
        echo "  Web Port: $WEB_PORT"
        echo "  Installed: $INSTALL_DATE"
        echo ""
    fi
    
    echo "Main Menu:"
    echo "  1) Fresh Install"
    echo "  2) Uninstall"
    echo "  3) Exit"
    echo ""
    read -p "Choose option (1-3): " menu_choice
    
    case $menu_choice in
        1)
            if [[ -f "$INSTALL_STATE_FILE" ]]; then
                echo ""
                print_warning "This will overwrite your existing installation"
                print_warning "A backup will be created before making changes"
                read -p "Continue with fresh install? (y/n): " -n 1 -r
                echo
                if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                    show_menu
                    return
                fi
            fi
            main_install
            ;;
        2)
            uninstall
            show_menu
            ;;
        3)
            exit 0
            ;;
        *)
            print_error "Invalid choice"
            sleep 2
            show_menu
            ;;
    esac
}

# --- Main Entry Point ---
main() {
    case $1 in
        --uninstall)
            check_root
            uninstall
            exit 0
            ;;
        --help|--version)
            echo "Pi-hole Encryption Setup v$SCRIPT_VERSION"
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --uninstall           Remove encryption"
            echo "  --help                Show this help"
            echo "  --version             Show version"
            exit 0
            ;;
    esac
    
    check_root
    show_menu
}

# Run main
main "$@"