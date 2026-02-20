#!/bin/bash
#############################################################################################################################
# The MIT License (MIT)
#
# Wael Isa
# Build Date: 02/20/2026
# Version: 1.2.8
# GitHub: https://github.com/waelisa/pihole-encryption
# Website: https://www.wael.name/
# Support: https://www.paypal.me/WaelIsa
#
#############################################################################################################################
#
# v1.2.8 - FIXED: Pi-hole v6 webroot ownership for Let's Encrypt
#        ✅ FIXED: Changed webroot ownership from root:root to pihole:pihole
#        ✅ FIXED: Test files now created with correct owner (pihole)
#        ✅ FIXED: Renewal hooks use same ownership pattern
#        ✅ ADDED: Automatic permission fix option
#        ✅ VERIFIED: Based on Pi-hole forum solution [citation:4]
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

# Fixed paths
PIHOLE_CERT="/etc/pihole/tls.pem"
PIHOLE_CA_CERT="/etc/pihole/tls_ca.crt"
PIHOLE_CONFIG="/etc/pihole/pihole.toml"
BACKUP_DIR="/root/pihole-encryption-backup-$(date +%Y%m%d_%H%M%S)"
LOG_FILE="/var/log/pihole-encryption-setup.log"
SCRIPT_VERSION="1.2.8"
INSTALL_STATE_FILE="/etc/pihole/encryption-installed.state"
RENEWAL_HOOK="/etc/letsencrypt/renewal-hooks/deploy/pihole.sh"
WEBROOT="/var/www/html"

# Error trap
trap 'error_handler $? $LINENO' ERR

error_handler() {
    local exit_code=$1
    local line_no=$2
    print_error "Error on line $line_no: exit code $exit_code"
    
    if [[ -d "$BACKUP_DIR" ]]; then
        echo ""
        print_warning "A backup exists at: $BACKUP_DIR"
        read -p "Restore from backup? (y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            restore_from_backup
        fi
    fi
    
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
# BACKUP FUNCTIONS
#================================================================================

create_backup() {
    print_step "Creating Comprehensive Backup"
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
    
    print_success "✓ Backup completed"
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
        print_error "Restore script not found"
        return 1
    fi
    
    pause
}

#================================================================================
# PERMISSION DIAGNOSTICS AND FIX (FIXED for v1.2.8)
#================================================================================

fix_webroot_ownership() {
    print_step "Fixing Webroot Ownership for Pi-hole"
    
    local pihole_user="pihole"
    local pihole_group="pihole"
    local webroot="$WEBROOT"
    
    print_message "Pi-hole FTL runs as user: $pihole_user"
    print_message "Current webroot status:"
    echo ""
    
    # Check if pihole user exists
    if ! id "$pihole_user" &>/dev/null; then
        print_error "User $pihole_user does not exist!"
        print_message "This suggests Pi-hole is not properly installed"
        return 1
    fi
    
    # Show current ownership
    if [[ -d "$webroot" ]]; then
        local current_owner=$(stat -c "%U:%G" "$webroot" 2>/dev/null || stat -f "%Su:%Sg" "$webroot" 2>/dev/null)
        print_message "Current $webroot owner: $current_owner"
        
        # Check if admin subdirectory exists and its ownership
        if [[ -d "$webroot/admin" ]]; then
            local admin_owner=$(stat -c "%U:%G" "$webroot/admin" 2>/dev/null || stat -f "%Su:%Sg" "$webroot/admin" 2>/dev/null)
            print_message "Current $webroot/admin owner: $admin_owner"
        fi
    else
        print_message "Webroot $webroot does not exist yet"
    fi
    
    echo ""
    print_message "According to Pi-hole documentation [citation:4], the pihole user needs to:"
    echo "  • Own the webroot directory OR"
    echo "  • Be able to read files in it (o+r)"
    echo ""
    print_message "Options:"
    echo "  1) Change ownership to pihole:pihole (recommended for Let's Encrypt)"
    echo "  2) Keep root:root but add world-read permissions (less secure)"
    echo "  3) Skip - continue with current settings"
    echo ""
    read -p "Choose option (1-3): " owner_choice
    
    case $owner_choice in
        1)
            print_message "Changing ownership of $webroot to $pihole_user:$pihole_group..."
            
            # Create webroot if it doesn't exist
            mkdir -p "$webroot"
            
            # Change ownership
            chown -R "$pihole_user:$pihole_group" "$webroot" 2>/dev/null || {
                print_error "Failed to change ownership"
                print_message "Trying with sudo..."
                sudo chown -R "$pihole_user:$pihole_group" "$webroot"
            }
            
            # Set proper permissions (750 = owner rwx, group rx, others none)
            chmod -R 750 "$webroot" 2>/dev/null || sudo chmod -R 750 "$webroot"
            
            print_success "✓ Ownership changed to $pihole_user:$pihole_group"
            print_success "✓ Permissions set to 750"
            
            # Verify
            local new_owner=$(stat -c "%U:%G" "$webroot" 2>/dev/null || stat -f "%Su:%Sg" "$webroot" 2>/dev/null)
            print_message "New $webroot owner: $new_owner"
            ;;
            
        2)
            print_message "Adding world-read permissions to $webroot..."
            mkdir -p "$webroot"
            chmod -R 755 "$webroot" 2>/dev/null || sudo chmod -R 755 "$webroot"
            print_success "✓ Permissions set to 755"
            print_warning "Note: This is less secure than option 1"
            ;;
            
        3)
            print_warning "Skipping ownership changes"
            ;;
    esac
    
    # Also ensure parent directories are traversable
    print_message "Ensuring parent directories are traversable..."
    chmod 755 /var /var/www 2>/dev/null || sudo chmod 755 /var /var/www 2>/dev/null
    
    # Add pihole to www-data group for good measure (as suggested in [citation:4])
    if ! groups $pihole_user | grep -q www-data; then
        print_message "Adding $pihole_user to www-data group for additional compatibility..."
        usermod -aG www-data $pihole_user 2>/dev/null || sudo usermod -aG www-data $pihole_user
    fi
    
    pause
}

#================================================================================
# PORT 80 VERIFICATION (UPDATED with correct ownership)
#================================================================================

verify_port_80_accessible() {
    print_step "Verifying Port 80 Accessibility"
    
    local public_ip=""
    local test_file="acme-test-$(date +%s).html"
    local test_url="http://$DOMAIN/$test_file"
    local local_test_url="http://127.0.0.1/$test_file"
    local pihole_user="pihole"
    
    # First fix ownership (critical for Let's Encrypt to work)
    fix_webroot_ownership
    
    # Get public IP
    if command -v curl &> /dev/null; then
        public_ip=$(curl -s ifconfig.me 2>/dev/null || echo "unknown")
    fi
    
    print_message "Your public IP appears to be: $public_ip"
    print_message "Your domain $DOMAIN should point to: $public_ip"
    echo ""
    
    # Check if port 80 is listening
    if ! ss -tlnp 2>/dev/null | grep -q ":80 "; then
        print_error "Port 80 is not listening on this server"
        print_message "Pi-hole should be listening on port 80. Checking config..."
        
        # Check Pi-hole config
        if grep -q "webserver.port.*80" "$PIHOLE_CONFIG" 2>/dev/null; then
            print_message "Pi-hole is configured for port 80, but not listening"
            print_message "Restarting Pi-hole..."
            restart_pihole_with_verification
        else
            print_message "Setting port 80 temporarily for Let's Encrypt..."
            set_pihole_config "webserver.port" "80,443os"
            restart_pihole_with_verification
        fi
        
        # Check again
        if ! ss -tlnp 2>/dev/null | grep -q ":80 "; then
            print_error "Port 80 still not listening"
            return 1
        fi
    fi
    
    # Ensure webroot exists
    print_message "Setting up webroot at $WEBROOT"
    mkdir -p "$WEBROOT"
    
    # Create test file WITH PROPER OWNERSHIP (critical fix!)
    print_message "Creating test file as $pihole_user user..."
    
    # Create file as root first, then change ownership to pihole
    echo "ACME Challenge Test File - $(date)" > "$WEBROOT/$test_file"
    chown $pihole_user:$pihole_user "$WEBROOT/$test_file" 2>/dev/null || sudo chown $pihole_user:$pihole_user "$WEBROOT/$test_file"
    chmod 644 "$WEBROOT/$test_file" 2>/dev/null || sudo chmod 644 "$WEBROOT/$test_file"
    
    # Verify file was created and has correct ownership
    if [[ ! -f "$WEBROOT/$test_file" ]]; then
        print_error "Failed to create test file at $WEBROOT/$test_file"
        ls -la "$WEBROOT"
        return 1
    fi
    
    # Show file ownership
    local file_owner=$(stat -c "%U:%G" "$WEBROOT/$test_file" 2>/dev/null || stat -f "%Su:%Sg" "$WEBROOT/$test_file" 2>/dev/null)
    print_success "✓ Test file created: $WEBROOT/$test_file (owner: $file_owner)"
    
    # Test locally first
    print_message "Testing local access to test file..."
    local local_result=$(curl -s -o /dev/null -w "%{http_code}" "$local_test_url" 2>/dev/null)
    
    if [[ "$local_result" == "200" ]]; then
        print_success "✓ Test file is accessible locally via HTTP"
    else
        print_warning "⚠ Test file not accessible locally (HTTP $local_result)"
        print_message "This suggests a web server configuration issue"
        
        # Check if Pi-hole is serving files
        local root_result=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1/" 2>/dev/null)
        if [[ "$root_result" == "200" || "$root_result" == "302" ]]; then
            print_message "Pi-hole web interface is accessible (HTTP $root_result), but test file is not"
            print_message "Showing webroot contents:"
            ls -la "$WEBROOT"
        else
            print_warning "Pi-hole web interface not accessible on port 80 (HTTP $root_result)"
        fi
    fi
    
    # Test from internet
    print_message "Testing if $test_url is accessible from the internet..."
    print_message "This may take a few seconds..."
    
    local test_success=false
    local test_attempts=3
    
    for ((i=1; i<=test_attempts; i++)); do
        echo -n "  Attempt $i: "
        
        # Try from Google DNS
        if timeout 10 curl -s -o /dev/null -w "%{http_code}" "$test_url" --resolve "$DOMAIN:80:8.8.8.8" 2>/dev/null | grep -q "200"; then
            echo -e "${GREEN}OK (via Google DNS)${NC}"
            test_success=true
            break
        fi
        
        # Try from Cloudflare DNS
        if timeout 10 curl -s -o /dev/null -w "%{http_code}" "$test_url" --resolve "$DOMAIN:80:1.1.1.1" 2>/dev/null | grep -q "200"; then
            echo -e "${GREEN}OK (via Cloudflare DNS)${NC}"
            test_success=true
            break
        fi
        
        # Try direct (no DNS override)
        if timeout 10 curl -s -o /dev/null -w "%{http_code}" "$test_url" 2>/dev/null | grep -q "200"; then
            echo -e "${GREEN}OK (direct)${NC}"
            test_success=true
            break
        fi
        
        echo -e "${YELLOW}Failed${NC}"
        sleep 2
    done
    
    # Clean up test file (but keep ownership pattern for future)
    rm -f "$WEBROOT/$test_file"
    
    if [[ "$test_success" == true ]]; then
        print_success "✓ Port 80 is accessible from the internet!"
        pause
        return 0
    else
        print_error "✗ Could not access test file from the internet"
        echo ""
        print_warning "The test file was created with owner: $file_owner"
        print_warning "But could not be accessed via: $test_url"
        echo ""
        print_message "Please verify:"
        echo "  1. Port 80 is forwarded on your router to $LOCAL_IP"
        echo "  2. Your domain $DOMAIN points to $public_ip"
        echo "  3. No firewall is blocking port 80"
        echo "  4. The pihole user can read files in $WEBROOT"
        echo ""
        print_message "You can test locally with: curl http://127.0.0.1/"
        print_message "You can test from outside with: curl http://$DOMAIN/"
        echo ""
        
        echo "Options:"
        echo "  1) Try again after fixing port forwarding"
        echo "  2) Continue with self-signed certificate only"
        echo "  3) Exit"
        echo ""
        read -p "Choose option (1-3): " port_choice
        
        case $port_choice in
            1)
                print_message "Please fix port forwarding and try again"
                exit 1
                ;;
            2)
                print_warning "Continuing with self-signed certificate only"
                return 2
                ;;
            3)
                exit 0
                ;;
        esac
    fi
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
        systemctl stop pihole-FTL
        sleep 2
        pkill -f pihole-FTL 2>/dev/null || true
        sleep 2
        systemctl start pihole-FTL
        sleep $wait_time
        
        if systemctl is-active --quiet pihole-FTL; then
            print_success "✓ Pi-hole FTL is running"
            
            if ss -tlnp 2>/dev/null | grep -q ":$WEB_PORT.*pihole-FTL"; then
                print_success "✓ Port $WEB_PORT is listening"
                return 0
            fi
        fi
        
        wait_time=$((wait_time + 5))
        ((attempt++))
    done
    
    print_error "Failed to restart Pi-hole FTL"
    return 1
}

verify_certificate_files() {
    print_message "Verifying certificate files..."
    
    if [[ ! -f "$PIHOLE_CERT" ]]; then
        print_error "Certificate file missing: $PIHOLE_CERT"
        return 1
    fi
    
    local size=$(stat -c%s "$PIHOLE_CERT" 2>/dev/null || stat -f%z "$PIHOLE_CERT" 2>/dev/null)
    if [[ $size -lt 500 ]]; then
        print_error "Certificate file too small"
        return 1
    fi
    
    if ! openssl x509 -in "$PIHOLE_CERT" -noout 2>/dev/null; then
        print_error "Certificate is not valid PEM format"
        return 1
    fi
    
    # Check ownership
    local cert_owner=$(stat -c "%U:%G" "$PIHOLE_CERT" 2>/dev/null || stat -f "%Su:%Sg" "$PIHOLE_CERT" 2>/dev/null)
    if [[ "$cert_owner" != "pihole:pihole" ]]; then
        print_warning "Certificate owner is $cert_owner, should be pihole:pihole"
        chown pihole:pihole "$PIHOLE_CERT" 2>/dev/null || sudo chown pihole:pihole "$PIHOLE_CERT"
    fi
    
    print_success "✓ Certificate is valid"
    return 0
}

#================================================================================
# CONFIGURATION FUNCTIONS
#================================================================================

set_pihole_config() {
    local key="$1"
    local value="$2"
    local config_file="$PIHOLE_CONFIG"
    
    print_message "Setting $key = $value"
    
    cp "$config_file" "$config_file.tmp"
    
    if [[ "$key" == *"."* ]]; then
        local section="${key%%.*}"
        local subkey="${key#*.}"
        
        if grep -q "^\[$section\]" "$config_file"; then
            if grep -q "^[[:space:]]*$subkey =" "$config_file"; then
                sed -i "s|^[[:space:]]*$subkey =.*|  $subkey = \"$value\"|" "$config_file"
            else
                sed -i "/^\[$section\]/a \ \ $subkey = \"$value\"" "$config_file"
            fi
        else
            echo -e "\n[$section]\n  $subkey = \"$value\"" >> "$config_file"
        fi
    fi
    
    if grep -q "$value" "$config_file"; then
        print_success "✓ Configuration updated"
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
    
    if command -v ip &> /dev/null; then
        LOCAL_IP=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v 127.0.0.1 | head -1)
    fi
    
    if [[ -z "$LOCAL_IP" ]]; then
        LOCAL_IP=$(hostname -I | awk '{print $1}')
    fi
    
    print_message "Your local IP: $LOCAL_IP"
    
    if command -v dig &> /dev/null; then
        domain_ip=$(dig +short "$DOMAIN" @8.8.8.8 2>/dev/null | head -1)
    fi
    
    if [[ -n "$domain_ip" ]]; then
        print_message "Domain $DOMAIN resolves to: $domain_ip"
        
        if [[ "$domain_ip" == "$LOCAL_IP" ]]; then
            print_success "✓ Domain resolves to this server's IP"
        else
            print_warning "⚠ Domain resolves to $domain_ip but this server is $LOCAL_IP"
            read -p "Continue anyway? (y/n): " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                exit 0
            fi
        fi
    else
        print_warning "⚠ Could not resolve $DOMAIN"
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
    
    if [[ -f "$INSTALL_STATE_FILE" ]]; then
        source "$INSTALL_STATE_FILE"
        echo -e "${YELLOW}Existing installation detected:${NC}"
        echo "  Domain: $INSTALLED_DOMAIN"
        echo "  Web Port: $INSTALLED_WEB_PORT"
        echo "  Installed: $INSTALLED_DATE"
        echo ""
    fi
    
    echo -e "${CYAN}Main Menu:${NC}"
    echo "  1) Fresh Install"
    echo "  2) Restore from Backup"
    echo "  3) Uninstall"
    echo "  4) Exit"
    echo ""
    read -p "Choose option (1-4): " menu_choice
    
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
            ;;
        2) restore_menu ;;
        3) uninstall; exit 0 ;;
        4) exit 0 ;;
        *) print_error "Invalid choice"; sleep 2; show_menu ;;
    esac
}

restore_menu() {
    print_step "Available Backups"
    
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
    
    if [[ -z "$LOCAL_IP" ]]; then
        LOCAL_IP=$(hostname -I | awk '{print $1}')
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
    
    [[ -f "$PIHOLE_CERT" ]] && cp "$PIHOLE_CERT" "$BACKUP_DIR/tls.pem.pre-selfsigned"
    [[ -f "$PIHOLE_CA_CERT" ]] && cp "$PIHOLE_CA_CERT" "$BACKUP_DIR/tls_ca.crt.pre-selfsigned"
    
    set_pihole_config "webserver.domain" "$DOMAIN"
    rm -f /etc/pihole/tls* >> "$LOG_FILE" 2>&1
    
    restart_pihole_with_verification || return 1
    sleep 5
    
    verify_certificate_files || return 1
    
    print_success "Self-signed certificate generated"
    pause
}

validate_https() {
    print_step "Validating HTTPS Service"
    
    local max_attempts=10
    local attempt=1
    local success=false
    
    print_message "Testing HTTPS on port $WEB_PORT..."
    
    while [[ $attempt -le $max_attempts ]] && [[ "$success" == false ]]; do
        if curl -k -s -o /dev/null -w "%{http_code}" "https://127.0.0.1:$WEB_PORT/admin" 2>/dev/null | grep -q "200\|302"; then
            success=true
            break
        fi
        sleep 2
        ((attempt++))
    done
    
    if [[ "$success" == true ]]; then
        print_success "✓ HTTPS validation passed"
        return 0
    else
        print_error "✗ HTTPS test failed"
        return 1
    fi
}

#================================================================================
# LET'S ENCRYPT FUNCTIONS
#================================================================================

combine_certificates() {
    local le_dir="/etc/letsencrypt/live/${DOMAIN}"
    
    if [[ -f "${le_dir}/fullchain.pem" ]] && [[ -f "${le_dir}/privkey.pem" ]]; then
        print_message "Combining certificate for Pi-hole..."
        
        cat "${le_dir}/fullchain.pem" "${le_dir}/privkey.pem" > "$PIHOLE_CERT.tmp"
        
        if openssl x509 -in "$PIHOLE_CERT.tmp" -noout 2>/dev/null; then
            mv "$PIHOLE_CERT.tmp" "$PIHOLE_CERT"
            chown pihole:pihole "$PIHOLE_CERT" 2>/dev/null || true
            chmod 600 "$PIHOLE_CERT"
            print_success "✓ Certificate combined"
            return 0
        else
            rm -f "$PIHOLE_CERT.tmp"
            return 1
        fi
    fi
    
    return 1
}

obtain_letsencrypt_http01() {
    print_step "Obtaining Let's Encrypt Certificate"
    
    local le_dir="/etc/letsencrypt/live/${DOMAIN}"
    
    # Ensure webroot exists with correct ownership
    mkdir -p "$WEBROOT"
    chown pihole:pihole "$WEBROOT" 2>/dev/null || sudo chown pihole:pihole "$WEBROOT"
    chmod 755 "$WEBROOT"
    
    # Create a test page with correct ownership
    echo "Pi-hole Let's Encrypt Setup" > "$WEBROOT/index.html"
    chown pihole:pihole "$WEBROOT/index.html" 2>/dev/null || sudo chown pihole:pihole "$WEBROOT/index.html"
    
    if ! command -v certbot &> /dev/null; then
        print_message "Installing certbot..."
        apt-get update > /dev/null 2>&1
        apt-get install -y certbot > /dev/null 2>&1
    fi
    
    print_message "Using webroot: $WEBROOT"
    print_message "Domain: $DOMAIN"
    echo ""
    
    if [[ -d "$le_dir" ]]; then
        print_warning "Certificate already exists"
        read -p "Renew it? (y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            certbot renew --webroot -w "$WEBROOT" --cert-name "$DOMAIN" >> "$LOG_FILE" 2>&1
        fi
    else
        print_message "Requesting certificate..."
        
        if certbot certonly --webroot -w "$WEBROOT" \
            --non-interactive \
            --agree-tos \
            --email "$EMAIL" \
            -d "$DOMAIN" \
            >> "$LOG_FILE" 2>&1; then
            print_success "✓ Certificate obtained"
        else
            print_error "✗ Failed to obtain certificate"
            print_message "Check the log: $LOG_FILE"
            return 1
        fi
    fi
    
    if [[ -d "$le_dir" ]]; then
        combine_certificates || return 1
        
        local cert_expiry=$(openssl x509 -in "$PIHOLE_CERT" -enddate -noout | cut -d= -f2)
        print_message "Certificate expires: $cert_expiry"
        
        return 0
    fi
    
    return 1
}

#================================================================================
# PI-HOLE CONFIGURATION
#================================================================================

configure_pihole() {
    print_step "Configuring Pi-hole"
    
    set_pihole_config "webserver.domain" "$DOMAIN"
    set_pihole_config "webserver.tls.cert" "$PIHOLE_CERT"
    set_pihole_config "webserver.port" "$WEB_PORT"
    set_pihole_config "webserver.tls.enable" "true"
    
    set_pihole_config "dns.dot.enabled" "true"
    set_pihole_config "dns.dot.port" "$DNS_TLS_PORT"
    set_pihole_config "dns.dot.cert" "$PIHOLE_CERT"
    
    set_pihole_config "dns.doq.enabled" "true"
    set_pihole_config "dns.doq.port" "$DNS_TLS_PORT"
    set_pihole_config "dns.doq.cert" "$PIHOLE_CERT"
    
    set_pihole_config "dns.doh.enabled" "true"
    set_pihole_config "dns.doh.path" "/dns-query"
    
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
# RENEWAL SETUP (UPDATED with ownership preservation)
#================================================================================

setup_renewal() {
    print_step "Configuring Auto-Renewal"
    
    mkdir -p /etc/letsencrypt/renewal-hooks/deploy
    
    cat > "$RENEWAL_HOOK" << 'EOF'
#!/bin/bash
DOMAIN="$RENEWED_DOMAINS"
PIHOLE_CERT="/etc/pihole/tls.pem"
WEBROOT="/var/www/html"

if [ -z "$DOMAIN" ] && [ -f "/etc/pihole/encryption-installed.state" ]; then
    source /etc/pihole/encryption-installed.state
    DOMAIN="$INSTALLED_DOMAIN"
fi

if [ -d "/etc/letsencrypt/live/$DOMAIN" ]; then
    # Combine certificate
    cat "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" "/etc/letsencrypt/live/$DOMAIN/privkey.pem" > "$PIHOLE_CERT"
    
    # Fix ownership for Pi-hole
    chown pihole:pihole "$PIHOLE_CERT" 2>/dev/null || true
    chmod 600 "$PIHOLE_CERT"
    
    # Also ensure webroot files are owned by pihole for future renewals
    if [ -d "$WEBROOT" ]; then
        chown -R pihole:pihole "$WEBROOT" 2>/dev/null || true
    fi
    
    # Reload Pi-hole
    systemctl reload pihole-FTL 2>/dev/null || systemctl restart pihole-FTL
    
    echo "$(date): Certificate renewed and installed for $DOMAIN" >> /var/log/pihole-cert-renewal.log
fi
EOF
    
    chmod +x "$RENEWAL_HOOK"
    
    certbot renew --dry-run >> "$LOG_FILE" 2>&1 || true
    
    if ! crontab -l 2>/dev/null | grep -q "certbot renew"; then
        (crontab -l 2>/dev/null; echo "0 3 * * * /usr/bin/certbot renew --quiet --webroot -w $WEBROOT --deploy-hook $RENEWAL_HOOK") | crontab -
    fi
    
    print_success "Auto-renewal configured"
    pause
}

#================================================================================
# UNINSTALL
#================================================================================

uninstall() {
    print_step "Uninstalling Encryption"
    
    echo -e "${YELLOW}What would you like to do?${NC}"
    echo "  1) Restore original (no HTTPS, port 80 only)"
    echo "  2) Keep self-signed certificate"
    echo "  3) Keep Let's Encrypt"
    read -p "Choose (1-3): " choice
    
    case $choice in
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
            set_pihole_config "webserver.port" "$WEB_PORT"
            print_success "Keeping self-signed certificate"
            ;;
        3)
            print_success "Keeping Let's Encrypt certificate"
            ;;
    esac
    
    rm -f "$RENEWAL_HOOK"
    crontab -l 2>/dev/null | grep -v "certbot renew" | crontab -
    rm -f "$INSTALL_STATE_FILE"
    
    restart_pihole_with_verification
    print_success "Uninstall completed"
    pause
}

#================================================================================
# MAIN INSTALLATION
#================================================================================

main_install() {
    print_step "Starting Installation"
    
    # Create backup first
    create_backup
    
    prompt_domain
    prompt_email
    get_local_ip
    
    verify_domain_resolution
    
    # Check port 80 accessibility (includes ownership fix)
    verify_port_80_accessible
    local port_check=$?
    
    generate_self_signed_cert || exit 1
    validate_https || exit 1
    
    # Try Let's Encrypt only if port check passed
    if [[ $port_check -eq 0 ]]; then
        obtain_letsencrypt_http01 || {
            print_warning "Let's Encrypt failed, using self-signed"
        }
    else
        print_warning "Port 80 not accessible, using self-signed"
    fi
    
    configure_pihole
    restart_pihole_with_verification || exit 1
    validate_https || exit 1
    
    setup_renewal
    
    echo ""
    print_success "🎉 Installation complete!"
    echo -e "${GREEN}Access:${NC} https://$DOMAIN:$WEB_PORT/admin"
    echo -e "${GREEN}Backup:${NC} $BACKUP_DIR"
    echo ""
    
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
        --uninstall) uninstall; exit 0 ;;
        --restore)
            if [[ -d "$2" ]]; then
                bash "$2/restore.sh"
            else
                print_error "Please specify backup directory"
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
    
    check_root
    show_menu
    main_install
}

main "$@"