#!/bin/bash

# 脚本版本
current_version="1.3.0"

# Define standard color codes
PLAIN=$'\033[0m'
RED=$'\033[31m'
GREEN=$'\033[92m'
YELLOW=$'\033[33m'
BLUE=$'\033[34m'
CYAN=$'\033[96m'
PURPLE=$'\033[35m'
BOLD=$'\033[1m'
BG_BLUE=$'\033[44m'
BG_RED=$'\033[41m'

# Backward compatibility - keep old variable names
red="$RED"
green="$GREEN"
yellow="$YELLOW"
reset="$PLAIN"
underline=$'\033[4m'
blink=$'\033[5m'
cyan="$CYAN"
purple="$PURPLE"

# Standard message symbols (极简风格，不使用图标)
SUCCESS_SYMBOL="${GREEN}[OK]${PLAIN}"
ERROR_SYMBOL="${RED}[ERROR]${PLAIN}"
INFO_SYMBOL="${BLUE}[INFO]${PLAIN}"
WARN_SYMBOL="${YELLOW}[WARN]${PLAIN}"

# Color print functions (backward compatibility)
_red() { echo -e "${RED}$@${PLAIN}"; }
_green() { echo -e "${GREEN}$@${PLAIN}"; }
_yellow() { echo -e "${YELLOW}$@${PLAIN}"; }  
_cyan() { echo -e "${CYAN}$@${PLAIN}"; }
_magenta() { echo -e "${PURPLE}$@${PLAIN}"; }  
_red_bg() { echo -e "${BG_RED}$@${PLAIN}"; }
_blue_bg() { echo -e "${BG_BLUE}$@${PLAIN}"; }
_bold() { echo -e "${BOLD}$@${PLAIN}"; }

is_err=$(_red_bg "ERROR!")
is_warn=$(_red_bg "WARNING!")

err() {  
    echo -e "\n$is_err $@\n" && return 1
}

warn() {
    echo -e "\n$is_warn $@\n"  
}

# Global breadcrumb variable for navigation
BREADCRUMB_PATH="Main"

# Breadcrumb navigation functions (简化显示)
show_breadcrumb() {
    printf "\n${BOLD}%s${PLAIN}\n" "$BREADCRUMB_PATH"
}

set_breadcrumb() {
    BREADCRUMB_PATH="$1"
}

# Function to display log messages with standardized symbols
msg() {
    case $1 in
        err) echo -e "${ERROR_SYMBOL} $2" ;;
        warn) echo -e "${WARN_SYMBOL} $2" ;;
        ok) echo -e "${SUCCESS_SYMBOL} $2" ;;
        info) echo -e "${INFO_SYMBOL} $2" ;;
        *) echo -e "$2" ;;
    esac
}

# Enhanced system status dashboard (极简风格)
check_snell_status() {
    printf "\n${BOLD}System Status${PLAIN}\n"
    printf "%-15s %-15s %-10s %-15s\n" "Service" "Status" "Port" "Version"
    printf "%-15s %-15s %-10s %-15s\n" "-------" "------" "----" "-------"
    
    # Snell service status
    local snell_status="${RED}Stopped${PLAIN}"
    local snell_port="N/A"
    local snell_version="N/A"

    if [[ -f "${snell_workspace}/snell-server.conf" ]]; then
        snell_port=$(grep -oP 'listen = .*?:\K\d+' "${snell_workspace}/snell-server.conf" 2>/dev/null || echo "N/A")

        if [[ -f "${snell_workspace}/snell-server" ]]; then
            snell_version=$("${snell_workspace}/snell-server" --version 2>&1 | grep -oP 'v\K[0-9]+\.[0-9]+(\.[0-9]+[a-zA-Z0-9]*)?' || echo "N/A")
        fi

        if systemctl is-active --quiet snell; then
            snell_status="${GREEN}Running${PLAIN}"
        fi
    else
        snell_status="${YELLOW}Not installed${PLAIN}"
    fi

    printf "%-15s %-20s %-10s %-15s\n" "Snell" "$snell_status" "$snell_port" "v$snell_version"

    # Shadow-TLS service status
    local shadow_status="${YELLOW}Not installed${PLAIN}"
    local shadow_port="N/A"
    local shadow_version="N/A"

    if [[ -f "/usr/local/bin/shadow-tls" ]]; then
        shadow_version=$(/usr/local/bin/shadow-tls --version 2>&1 | grep -oP 'v\K[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "N/A")

        if systemctl list-unit-files | grep -q shadow-tls.service; then
            local shadow_config=$(systemctl cat shadow-tls 2>/dev/null | grep ExecStart)
            shadow_port=$(echo "$shadow_config" | grep -oP '\--listen [^\s]*:\K\d+' || echo "N/A")

            if systemctl is-active --quiet shadow-tls; then
                shadow_status="${GREEN}Running${PLAIN}"
            else
                shadow_status="${RED}Stopped${PLAIN}"
            fi
        fi
    fi

    printf "%-15s %-20s %-10s %-15s\n" "Shadow-TLS" "$shadow_status" "$shadow_port" "v$shadow_version"
    
    echo ""
}

# Function to check server IP (supports both IPv4 and IPv6)
get_ip() {
    # Add timeout for IPv4
    trace_info_v4=$(curl -s4 --connect-timeout 5 https://cloudflare.com/cdn-cgi/trace)
    # Add timeout for IPv6: --connect-timeout 5s connection timeout, --max-time 10s total timeout
    trace_info_v6=$(curl -s6 --connect-timeout 5 --max-time 10 https://cloudflare.com/cdn-cgi/trace)
    ipv4=$(echo "$trace_info_v4" | grep -oP '(?<=ip=)[^\n]*')
    ipv6=$(echo "$trace_info_v6" | grep -oP '(?<=ip=)[^\n]*')
    colo=$(echo "$trace_info_v4" | grep -oP '(?<=colo=)[^\n]*')

    if [[ -n $ipv4 && -n $ipv6 ]]; then
        ip_type="both"
    elif [[ -n $ipv4 ]]; then
        ip_type="ipv4"
        msg info "IPv6 unavailable or detection timeout."
    elif [[ -n $ipv6 ]]; then
        ip_type="ipv6"
    else
        msg err "Unable to get server IP address." && exit 1
    fi

    server_ip=${ipv4:-$ipv6}

    if [[ -z $colo ]]; then
        # Try to get colo from IPv6 info
        colo=$(echo "$trace_info_v6" | grep -oP '(?<=colo=)[^\n]*')
        if [[ -z $colo ]]; then
            msg warn "Unable to get datacenter location, using default settings."
            colo="unknown"
        else
            msg ok "Datacenter location: ${colo}"
        fi
    else
        msg ok "Datacenter location: ${colo}"
    fi
}

# Detect server IP (wrapper for get_ip)
detect_server_ip() {
    get_ip
}

# Check IPv6 support
check_ipv6_support() {
    msg info "Checking IPv6 support..."
    if [[ $ip_type == "both" ]] || [[ $ip_type == "ipv6" ]]; then
        ipv6_enabled="true"
        msg ok "IPv6 is supported on this server"
    else
        ipv6_enabled="false"
        msg info "IPv6 is not available on this server"
    fi
}

check_preconditions() {
    # Check for root privileges
    [[ $EUID -ne 0 ]] && err "Root privileges are required to run this script."

    # Detect package manager
    if ! command -v apt-get >/dev/null 2>&1 && ! command -v yum >/dev/null 2>&1; then
        err "This script only supports Ubuntu or Debian."
    fi

    # Check for systemd
    if ! command -v systemctl >/dev/null 2>&1; then
        err "Systemd is required but not found. Please install it with:\n${cmd} update -y; ${cmd} install -y systemd"
    fi
}

# Global error handling and cleanup
cleanup_on_error() {
    printf "\n${ERROR_SYMBOL} An error occurred. Cleaning up...\n"
    # Cleanup temporary files
    rm -f "${snell_workspace}/"*.zip 2>/dev/null
    rm -f "${shadow_tls_workspace}/"*.tar.gz 2>/dev/null
    # Reset terminal colors
    printf "${PLAIN}"
}

# Set error trap
trap cleanup_on_error ERR

# Call the function early in the script
check_preconditions

# Initialization  
snell_workspace="/etc/snell-server"
snell_service="/etc/systemd/system/snell.service"
shadow_tls_workspace="/etc/shadow-tls"  
shadow_tls_service="/etc/systemd/system/shadow-tls.service"
dependencies="wget unzip jq net-tools curl cron"

# Simplified installation of missing packages  
install_pkg() {
    msg info "Checking and installing missing dependencies..."  
    apt-get update -qq
    apt-get install -y dnsutils $dependencies
}

# Function to generate a random PSK
generate_random_psk() {
    echo "$(openssl rand -base64 32)"
}

# Function to generate a random password  
generate_random_password() {
    echo "$(openssl rand -base64 16)"
}

# Input validation functions
validate_port() {
    local port=$1
    if [[ ! "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        msg err "Invalid port number: $port (must be 1-65535)"
        return 1
    fi
    return 0
}

validate_domain() {
    local domain=$1
    if [[ -z "$domain" ]]; then
        msg err "Domain cannot be empty"
        return 1
    fi
    if [[ ! "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
        msg err "Invalid domain format: $domain"
        return 1
    fi
    return 0
}

# Progress indicator for background processes
show_loading() {
    local pid=$1
    local message=${2:-"Processing"}
    local delay=0.15
    local spinstr='|/-\'
    
    printf "${INFO_SYMBOL} %s " "$message"
    while ps -p "$pid" &>/dev/null; do
        local temp=${spinstr#?}
        printf "%c\b" "$spinstr"
        spinstr=$temp${spinstr%"$temp"}
        sleep $delay
    done
    printf "\r${SUCCESS_SYMBOL} %s completed\n" "$message"
}

# Operation confirmation with preview
confirm_operation() {
    local operation="$1"
    local details="$2"
    local warning="$3"

    printf "\n${BOLD}${YELLOW}About to %s:${PLAIN}\n" "$operation"
    if [ -n "$details" ]; then
        printf "%s\n" "$details"
    fi

    if [ -n "$warning" ]; then
        printf "\n${WARN_SYMBOL} ${YELLOW}%s${PLAIN}\n" "$warning"
    fi

    printf "\nContinue? [y/N]: "
    read -r confirm
    case "$confirm" in
        [yY]|[yY][eE][sS]) return 0 ;;
        *) msg info "Operation cancelled"; return 1 ;;
    esac
}

# Function to find an unused port  
find_unused_port() {
    local port
    while true; do  
        port=$(shuf -i 10000-65535 -n 1)
        if ! ss -tuln | grep -q ":$port "; then
            echo "$port"  
            break
        fi
    done
}

# Function to create Snell configuration file
create_snell_conf() {
    # Get port with validation
    while true; do
        read -rp "Assign a port for Snell (Leave blank for random, 1-65535): " snell_port
        if [[ -z ${snell_port} ]]; then
            snell_port=$(find_unused_port)
            msg info "Assigned random port for Snell: $snell_port"
            break
        elif validate_port "$snell_port"; then
            # Check if port is already in use
            if ss -tuln | grep -q ":${snell_port} "; then
                msg err "Port $snell_port is already in use"
                continue
            fi
            break
        fi
    done
    
    # Determine listen address based on whether Shadow-TLS will be installed
    local listen_addr
    if [[ "${install_with_shadow_tls}" == "true" ]]; then
        # If installing with Shadow-TLS, Snell should listen on localhost only
        if [[ $ipv6_enabled == "true" ]] && [[ $ip_type == "ipv6" ]]; then
            listen_addr="[::1]:${snell_port}"
        else
            listen_addr="127.0.0.1:${snell_port}"
        fi
        msg info "Installing with Shadow-TLS, Snell will listen on localhost: ${listen_addr}"
    else
        # If installing Snell only, listen on all interfaces
        if [[ $ipv6_enabled == "true" ]] && [[ $ip_type != "ipv4" ]]; then
            listen_addr="[::]:${snell_port}"
        else
            listen_addr="0.0.0.0:${snell_port}"
        fi
    fi
    
    # Get PSK
    read -rp "Enter PSK for Snell (Leave it blank to generate a random one): " snell_psk
    [[ -z ${snell_psk} ]] && snell_psk=$(generate_random_psk) && echo "[INFO] Generated a random PSK for Snell: $snell_psk"
    
    # Get DNS settings with improved messaging
    printf "\n${BOLD}DNS Configuration${PLAIN}\n"
    
    system_dns=$(grep -oP '(?<=nameserver\s)\S+' /etc/resolv.conf | grep -v '^127\.0\.0\.' | sort -u | tr '\n' ',' | sed 's/,$//')
    
    # If system DNS is empty or only contains local addresses, try to get real DNS from systemd-resolved
    if [[ -z "$system_dns" ]] && command -v resolvectl &>/dev/null; then
        system_dns=$(resolvectl status | grep -oP '(?<=DNS Servers:\s)[\d\.:a-f]+' | tr '\n' ',' | sed 's/,$//')
    fi
    
    # Show DNS priority information
    msg info "DNS Priority: Custom > System > Default"
    
    local prompt_dns=""
    if [[ -n "$system_dns" ]]; then
        msg ok "System DNS detected: ${system_dns}"
        prompt_dns="Enter custom DNS (comma-separated, leave blank for system DNS): "
    else
        msg warn "No system DNS detected, will use default DNS"
        prompt_dns="Enter custom DNS (comma-separated, leave blank for default): "
    fi
    
    read -rp "$prompt_dns" custom_dns

    local final_dns=""
    if [[ -n "$custom_dns" ]]; then
        final_dns="$custom_dns"
        msg ok "Using custom DNS: $final_dns"
    elif [[ -n "$system_dns" ]]; then
        final_dns="$system_dns"
        msg ok "Using system DNS: $final_dns"
    else
        if [[ $ip_type == "both" || $ip_type == "ipv6" ]]; then
            final_dns="1.1.1.1,2606:4700:4700::1111" # Cloudflare with IPv6
            msg info "Using default DNS: Cloudflare (IPv4 + IPv6)"
        else
            final_dns="1.1.1.1,8.8.8.8" # Cloudflare + Google for IPv4
            msg info "Using default DNS: Cloudflare + Google (IPv4)"
        fi
    fi
    dns_config="dns = $final_dns"

    # Write the configuration file
    cat > "${snell_workspace}/snell-server.conf" << EOF
[snell-server]
listen = ${listen_addr}
psk = ${snell_psk}
ipv6 = ${ipv6_enabled:-true}
${dns_config}
EOF

    msg ok "Snell configuration file created: ${snell_workspace}/snell-server.conf"
    msg ok "Snell configuration completed."
}

create_shadow_tls_systemd() {
    if [[ -z ${snell_port} ]]; then
        read -rp "Input ShadowTLS forwarding port (default: random unused port): " shadow_tls_f_port
        [[ -z ${shadow_tls_f_port} ]] && shadow_tls_f_port=$(find_unused_port) && echo "[INFO] Randomly selected port for ShadowTLS forwarding: $shadow_tls_f_port"
    else
        shadow_tls_f_port=${snell_port}
        echo "[INFO] Using Snell port as ShadowTLS forwarding port: $shadow_tls_f_port"
    fi

    # Determine listening address based on IPv6 support
    if [[ $ip_type == "both" ]]; then
        read -rp "Enable IPv6 listening? (y/n): " ipv6_listen
        if [[ $ipv6_listen =~ ^[Yy]$ ]]; then
            listen_addr="[::]:${shadow_tls_port}"
        else
            listen_addr="0.0.0.0:${shadow_tls_port}"
        fi
    elif [[ $ip_type == "ipv6" ]]; then
        listen_addr="[::]:${shadow_tls_port}"
    else
        listen_addr="0.0.0.0:${shadow_tls_port}"
    fi

    # Set forwarding address
    if [[ $ip_type == "ipv6" ]]; then
        server_addr="[::1]:${shadow_tls_f_port}" 
    else
        server_addr="127.0.0.1:${shadow_tls_f_port}"
    fi

    # Ask if enabling wildcard-sni
    read -rp "Enable wildcard-sni? (y/n, allows client to customize SNI): " enable_wildcard
    if [[ $enable_wildcard =~ ^[Yy]$ ]]; then
        wildcard_option="--wildcard-sni=authed"
        msg info "Wildcard-sni enabled, client can customize SNI"
    else
        wildcard_option=""
    fi

    # Ask if enabling strict mode
    read -rp "Enable TLS strict mode? (y/n, enhances security): " enable_strict
    if [[ $enable_strict =~ ^[Yy]$ ]]; then
        strict_option="--strict"
        msg info "Strict mode enabled, enhances TLS handshake security"
    else
        strict_option=""
    fi

    # Create shadowtls user if not exists
    if ! id "shadowtls" &>/dev/null; then
        useradd --system --no-create-home --shell /usr/sbin/nologin shadowtls
        msg info "Created shadowtls system user"
    fi

    cat > $shadow_tls_service << EOF
[Unit]
Description=Shadow-TLS Server Service
Documentation=https://github.com/ihciah/shadow-tls
After=network.target nss-lookup.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=shadowtls
Group=shadowtls
StateDirectory=shadow-tls
ExecStart=/usr/local/bin/shadow-tls --fastopen --v3 ${strict_option} server ${wildcard_option} --listen ${listen_addr} --server ${server_addr} --tls ${shadow_tls_tls_domain}:443 --password ${shadow_tls_password}
Restart=always
RestartSec=3s
# Harden and increase resource limits for high concurrency
LimitNOFILE=1048576
NoNewPrivileges=true
MemoryLimit=512M
TasksMax=infinity
CPUQuota=200%
AmbientCapabilities=CAP_NET_BIND_SERVICE
StandardOutput=journal
StandardError=journal
SyslogIdentifier=shadow-tls

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable shadow-tls
    msg ok "Shadow-TLS systemd service created."
}

# Configure Shadow-TLS  
config_shadow_tls() {
    # Get Shadow-TLS port with validation
    while true; do
        read -rp "Choose port for Shadow-TLS (default: 443): " shadow_tls_port
        if [[ -z ${shadow_tls_port} ]]; then
            shadow_tls_port="443"
            msg info "Using default port 443 for Shadow-TLS"
            break
        elif validate_port "$shadow_tls_port"; then
            # Check if port is already in use
            if ss -tuln | grep -q ":${shadow_tls_port} "; then
                msg err "Port $shadow_tls_port is already in use"
                continue
            fi
            break
        fi
    done
    
    echo -e "${YELLOW}Recommended TLS domain list (supports TLS 1.3):${PLAIN}"
    echo -e "1) gateway.icloud.com (Apple services)"
    echo -e "2) p11.douyinpic.com (Douyin related, recommended for free flow)"
    echo -e "3) mp.weixin.qq.com (WeChat related)"
    echo -e "4) sns-img-qc.xhscdn.com (Xiaohongshu related)"
    echo -e "5) p9-dy.byteimg.com (Byte related)"
    echo -e "6) weather-data.apple.com (Apple weather service)"
    echo -e "7) Custom"
    read -rp "Select TLS domain [1-7]: " domain_choice
    
    case $domain_choice in
        1) shadow_tls_tls_domain="gateway.icloud.com" ;;
        2) shadow_tls_tls_domain="p11.douyinpic.com" ;;
        3) shadow_tls_tls_domain="mp.weixin.qq.com" ;;
        4) shadow_tls_tls_domain="sns-img-qc.xhscdn.com" ;;
        5) shadow_tls_tls_domain="p9-dy.byteimg.com" ;;
        6) shadow_tls_tls_domain="weather-data.apple.com" ;;
        7) 
            while true; do
                read -rp "Enter custom TLS domain: " shadow_tls_tls_domain
                if [[ -z ${shadow_tls_tls_domain} ]]; then
                    shadow_tls_tls_domain="gateway.icloud.com"
                    msg info "Using default domain: $shadow_tls_tls_domain"
                    break
                elif validate_domain "$shadow_tls_tls_domain"; then
                    msg ok "Using custom domain: $shadow_tls_tls_domain"
                    break
                fi
            done
            ;;
        *) 
            shadow_tls_tls_domain="gateway.icloud.com"
            msg info "Using default domain: $shadow_tls_tls_domain"
            ;;
    esac
    
    read -rp "Input Shadow-TLS password (leave blank to generate a random one): " shadow_tls_password
    [[ -z ${shadow_tls_password} ]] && shadow_tls_password=$(generate_random_password) && echo "[INFO] Generated a random password for Shadow-TLS: $shadow_tls_password"

    # Determine Snell PSK for client configuration
    local client_snell_psk="${snell_psk}" # Prioritize PSK set during script execution
    if [[ -z "${client_snell_psk}" && -f "${snell_workspace}/snell-server.conf" ]]; then
        # If no PSK is set and configuration file exists, read from file
        client_snell_psk=$(grep -oP 'psk = \K.*' "${snell_workspace}/snell-server.conf")
    fi

    # Client configuration options
    read -rp "Enable TFO (TCP Fast Open) for client? (Y/n): " client_tfo_choice
    local client_tfo_value="true"
    if [[ $client_tfo_choice =~ ^[Nn]$ ]]; then
        client_tfo_value="false"
    fi

    read -rp "Enable Session Reuse for client? (y/N): " client_reuse_choice
    local client_reuse_value="false"
    if [[ $client_reuse_choice =~ ^[Yy]$ ]]; then
        client_reuse_value="true"
    fi

    # Get Snell version
    local snell_version_num="4"
    if [[ -f "${snell_workspace}/snell-server" ]]; then
        local installed_version=$("${snell_workspace}/snell-server" --version 2>&1 | grep -oP 'v\K[0-9]+')
        if [[ "$installed_version" == "5" ]]; then
            snell_version_num="5"
        fi
    fi

    echo -e "${colo} = snell, ${server_ip}, ${shadow_tls_port}, psk=${client_snell_psk}, version=${snell_version_num}, reuse=${client_reuse_value}, tfo=${client_tfo_value}, shadow-tls-password=${shadow_tls_password}, shadow-tls-sni=${shadow_tls_tls_domain}, shadow-tls-version=3"
    msg ok "Shadow-TLS configuration completed."
}

# Install Snell without IP detection (core installation function)
install_snell_without_ip() {
    install_pkg
    
    # Ask for Snell version
    msg info "Choose Snell version to install:"
    echo -e "${GREEN}1) Snell v4 (Stable)${PLAIN}"
    echo -e "${YELLOW}2) Snell v5 (Beta)${PLAIN}"
    read -rp "Select version [1-2] (default: 1): " version_choice
    
    local snell_version=""
    local is_beta=false
    
    case ${version_choice:-1} in
        1)
            # Get latest v4 version from official page
            snell_version=$(curl -s https://manual.nssurge.com/others/snell.html | grep -oP 'snell-server-v\K[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
            if [[ -z "$snell_version" ]]; then
                msg err "Failed to get latest Snell v4 version"
                return 1
            fi
            msg info "Installing Snell v${snell_version} (Stable)"
            ;;
        2)
            snell_version="5.0.0b1"
            is_beta=true
            msg info "Installing Snell v${snell_version} (Beta)"
            ;;
        *)
            msg err "Invalid selection"
            return 1
            ;;
    esac
    
    mkdir -p "${snell_workspace}"
    cd "${snell_workspace}" || exit 1
    
    # Download Snell based on architecture and version
    arch=$(uname -m)
    case $arch in
        x86_64) snell_url="https://dl.nssurge.com/snell/snell-server-v${snell_version}-linux-amd64.zip" ;;
        aarch64) snell_url="https://dl.nssurge.com/snell/snell-server-v${snell_version}-linux-aarch64.zip" ;;
        armv7l) snell_url="https://dl.nssurge.com/snell/snell-server-v${snell_version}-linux-armv7l.zip" ;;
        i386) snell_url="https://dl.nssurge.com/snell/snell-server-v${snell_version}-linux-i386.zip" ;;
        *) msg err "Unsupported architecture: $arch" && exit 1 ;;
    esac
    
    msg info "Downloading Snell from: ${snell_url}"
    wget -O snell-server.zip "${snell_url}"
    
    if [ $? -ne 0 ]; then
        msg err "Failed to download Snell. Please check your network connection."
        return 1
    fi
    
    unzip -o snell-server.zip
    rm snell-server.zip
    chmod +x snell-server
    
    # Verify installation
    if [[ -f snell-server ]]; then
        local installed_version=$("${snell_workspace}/snell-server" --version 2>&1 | grep -oP 'v\K[0-9]+\.[0-9]+(\.[0-9]+)?')
        msg ok "Snell server binary installed successfully (version: ${installed_version})"
    else
        msg err "Failed to install Snell server binary"
        return 1
    fi
    
    # Create configuration
    create_snell_conf
    
    # Create systemd service
    create_snell_systemd
    
    # Start service
    systemctl start snell
    sleep 2
    
    if systemctl is-active --quiet snell; then
        msg ok "Snell service started successfully"
    else
        msg err "Failed to start Snell service, please check logs with: journalctl -u snell"
    fi
}

# Install Snell and Shadow-TLS
install_snell_and_shadow_tls() {
    msg info "Installing Snell and Shadow-TLS..."
    
    # Detect IP and check IPv6
    detect_server_ip
    check_ipv6_support
    
    # Set flag for create_snell_conf
    install_with_shadow_tls="true"
    
    # Install Snell
    install_snell_without_ip
    
    # Install Shadow-TLS
    install_shadow_tls_without_ip
}

# Install Snell only with IP detection
install_snell() {
    msg info "Installing Snell..."
    
    # Detect IP and check IPv6
    detect_server_ip
    check_ipv6_support
    
    # Set flag for create_snell_conf
    install_with_shadow_tls="false"
    
    # Install Snell
    install_snell_without_ip
}

# Install Shadow-TLS only without IP detection
install_shadow_tls_without_ip() {
    install_pkg

    # Check if Snell is installed and get its configuration
    local need_update_snell=false
    local current_snell_port=""
    local current_snell_listen=""
    
    if [[ -f "${snell_workspace}/snell-server.conf" ]]; then
        current_snell_listen=$(grep -oP 'listen = \K.*' "${snell_workspace}/snell-server.conf")
        current_snell_port=$(echo "$current_snell_listen" | grep -oP ':\K\d+$')
        
        # Check if Snell is listening on public interface
        if [[ "$current_snell_listen" =~ ^(0\.0\.0\.0|::0): ]]; then
            msg warn "Detected Snell is listening on public interface"
            msg info "When using Shadow-TLS, Snell should listen on localhost only"
            read -rp "Update Snell to listen on localhost only? (Y/n): " update_choice
            if [[ ! "$update_choice" =~ ^[Nn]$ ]]; then
                need_update_snell=true
            fi
        fi
    else
        msg err "Snell is not installed. Please install Snell first."
        return
    fi

    msg info "Downloading Shadow-TLS..."
    mkdir -p "${shadow_tls_workspace}"
    cd "${shadow_tls_workspace}" || exit 1

    # Get latest Shadow-TLS version
    latest_release=$(wget -qO- https://api.github.com/repos/ihciah/shadow-tls/releases/latest)
    latest_version=$(echo "$latest_release" | jq -r '.tag_name')
    arch=$(uname -m)
    case $arch in
        x86_64) shadow_tls_url=$(echo "$latest_release" | jq -r '.assets[] | select(.name | contains("x86_64-unknown-linux-musl")) | .browser_download_url') ;;
        aarch64) shadow_tls_url=$(echo "$latest_release" | jq -r '.assets[] | select(.name | contains("aarch64-unknown-linux-musl")) | .browser_download_url') ;;
        *) msg err "Unsupported architecture: $arch" && exit 1 ;;
    esac

    wget -O shadow-tls "${shadow_tls_url}"
    chmod +x shadow-tls
    mv shadow-tls /usr/local/bin/

    # Update Snell configuration if needed
    if [[ "$need_update_snell" == true ]]; then
        msg info "Updating Snell configuration to listen on localhost..."
        
        # Stop Snell service
        systemctl stop snell
        
        # Update Snell configuration
        local new_listen_addr
        if [[ $ip_type == "ipv6" ]]; then
            new_listen_addr="[::1]:${current_snell_port}"
        else
            new_listen_addr="127.0.0.1:${current_snell_port}"
        fi
        
        # Backup current configuration
        cp "${snell_workspace}/snell-server.conf" "${snell_workspace}/snell-server.conf.bak"
        
        # Update listen address
        sed -i "s/^listen = .*/listen = ${new_listen_addr}/" "${snell_workspace}/snell-server.conf"
        
        msg ok "Snell configuration updated to listen on: ${new_listen_addr}"
        
        # Restart Snell
        systemctl start snell
        sleep 2
        
        if systemctl is-active --quiet snell; then
            msg ok "Snell service restarted successfully"
        else
            msg err "Failed to restart Snell service"
            msg info "Restoring original configuration..."
            mv "${snell_workspace}/snell-server.conf.bak" "${snell_workspace}/snell-server.conf"
            systemctl start snell
            return
        fi
    fi

    # Set snell_port for Shadow-TLS configuration
    snell_port="${current_snell_port}"
    
    config_shadow_tls
    create_shadow_tls_systemd
}

# Install Shadow-TLS only
install_shadow_tls() {
    # Detect IP
    get_ip
    
    # Install Shadow-TLS
    install_shadow_tls_without_ip
}

# Install menu (极简风格)
install() {
    while true; do
        clear
        set_breadcrumb "Main > Install"
        show_breadcrumb

        printf "\n${BOLD}Installation Options${PLAIN}\n\n"
        printf "  1) Install Snell Only\n"
        printf "  2) Install Snell + Shadow-TLS\n"
        printf "  3) Install Shadow-TLS Only (Snell required)\n"
        printf "  0) Back\n\n"

        printf "Choice [0-3]: "
        read -r option
        
        case $option in
            1) set_breadcrumb "Main > Install > Snell Only"; install_snell; break ;;
            2) set_breadcrumb "Main > Install > Snell + Shadow-TLS"; install_snell_and_shadow_tls; break ;;
            3) set_breadcrumb "Main > Install > Shadow-TLS Only"; install_shadow_tls; break ;;
            0) break ;;
            *) msg warn "Invalid option"; sleep 1 ;;
        esac
    done
}

# Uninstall Snell and Shadow-TLS (极简风格)
uninstall() {
    while true; do
        clear
        set_breadcrumb "Main > Uninstall"
        show_breadcrumb

        printf "\n${BOLD}Uninstall Options${PLAIN}\n\n"
        printf "  1) Uninstall Snell and Shadow-TLS\n"
        printf "  2) Uninstall Snell Only\n"
        printf "  3) Uninstall Shadow-TLS Only\n"
        printf "  0) Back\n\n"

        printf "Choice [0-3]: "
        read -r option

        case $option in
            1) set_breadcrumb "Main > Uninstall > All"; uninstall_all; break ;;
            2) set_breadcrumb "Main > Uninstall > Snell"; uninstall_snell; break ;;
            3) set_breadcrumb "Main > Uninstall > Shadow-TLS"; uninstall_shadow_tls; break ;;
            0) break ;;
            *) msg warn "Invalid option"; sleep 1 ;;
        esac
    done
}

# Uninstall both Snell and Shadow-TLS
uninstall_all() {
    if ! confirm_operation "uninstall Snell and Shadow-TLS" \
        "• Snell service and configuration\n• Shadow-TLS service and configuration\n• All related files" \
        "This action cannot be undone!"; then
        return
    fi
    
    uninstall_snell_internal
    uninstall_shadow_tls_internal
    msg ok "Snell and Shadow-TLS uninstalled successfully."
    sleep 2
}

# Uninstall Snell only
uninstall_snell() {
    if ! confirm_operation "uninstall Snell" \
        "• Snell service\n• Configuration files\n• Binary files" \
        "This action cannot be undone!"; then
        return
    fi
    
    uninstall_snell_internal
    msg ok "Snell uninstalled successfully."
    sleep 2
}

# Internal uninstall Snell function (no confirmation)
uninstall_snell_internal() {
    systemctl stop snell 2>/dev/null || true
    systemctl disable snell 2>/dev/null || true
    rm -f "${snell_service}"
    rm -rf "${snell_workspace}"
    systemctl daemon-reload
}

# Uninstall Shadow-TLS only
uninstall_shadow_tls() {
    if ! confirm_operation "uninstall Shadow-TLS" \
        "• Shadow-TLS service\n• Configuration files\n• Binary files" \
        "This action cannot be undone!"; then
        return
    fi
    
    uninstall_shadow_tls_internal
    msg ok "Shadow-TLS uninstalled successfully."
    sleep 2
}

# Internal uninstall Shadow-TLS function (no confirmation)
uninstall_shadow_tls_internal() {
    systemctl stop shadow-tls 2>/dev/null || true
    systemctl disable shadow-tls 2>/dev/null || true
    rm -f "${shadow_tls_service}"
    rm -rf "${shadow_tls_workspace}"
    rm -f "/usr/local/bin/shadow-tls"
    systemctl daemon-reload
}

# Run Snell and Shadow-TLS  
run() {
    systemctl start snell  
    systemctl start shadow-tls
    sleep 2
    if systemctl is-active --quiet snell && systemctl is-active --quiet shadow-tls; then  
        msg ok "Snell and Shadow-TLS are now running."
    else
        msg err "Failed to start Snell or Shadow-TLS, please check logs."  
    fi
}

# Stop Snell and Shadow-TLS
stop() {  
    systemctl stop snell
    systemctl stop shadow-tls
    msg ok "Snell and Shadow-TLS have been stopped."  
}

# Restart Snell and Shadow-TLS  
restart() {
    systemctl restart snell
    systemctl restart shadow-tls  
    sleep 2
    if systemctl is-active --quiet snell && systemctl is-active --quiet shadow-tls; then
        msg ok "Snell and Shadow-TLS have been restarted."  
    else
        msg err "Failed to restart Snell or Shadow-TLS, please check logs."
    fi  
}

# Check Snell and Shadow-TLS configuration  
checkconfig() {
    if [ -f "${snell_workspace}/snell-server.conf" ]; then  
        echo "Snell configuration:"
        cat "${snell_workspace}/snell-server.conf"
    else
        msg err "Snell configuration file not found."  
    fi

    echo "Shadow-TLS configuration:"  
    systemctl cat shadow-tls | grep -E "listen|server|tls|password"
}

show_snell_log() {
    if [ -f "/var/log/snell.log" ]; then
        echo "Snell Server Log:"
        cat /var/log/snell.log
    else
        msg err "Snell log file not found."
    fi
}

show_logs() {
    clear
    set_breadcrumb "Main > Manage > Logs"
    show_breadcrumb

    printf "\n${BOLD}Service Logs${PLAIN}\n\n"

    printf "${BOLD}Recent Snell Logs:${PLAIN}\n"
    journalctl -u snell --no-pager -n 20
    echo ""

    printf "${BOLD}Recent Shadow-TLS Logs:${PLAIN}\n"
    journalctl -u shadow-tls --no-pager -n 20
    echo ""

    read -p "Press any key to return..." _
}

# Modify Snell and Shadow-TLS configuration (极简风格)
modify() {
    while true; do
        clear
        set_breadcrumb "Main > Configuration"
        show_breadcrumb

        printf "\n${BOLD}Configuration Editor${PLAIN}\n\n"
        printf "  1) Modify Snell Configuration\n"
        printf "  2) Modify Shadow-TLS Configuration\n"
        printf "  0) Back\n\n"

        printf "Choice [0-2]: "
        read -r operation
        
        case $operation in  
            1) 
                if [[ -f "${snell_workspace}/snell-server.conf" ]]; then
                    nano "${snell_workspace}/snell-server.conf"
                    msg info "Don't forget to restart services to apply changes!"
                    read -p "Press any key to continue..." _
                else
                    msg err "Snell configuration file not found"
                    sleep 2
                fi
                ;;
            2) 
                if [[ -f "${shadow_tls_service}" ]]; then
                    nano "${shadow_tls_service}"
                    msg info "Don't forget to restart services to apply changes!"
                    read -p "Press any key to continue..." _
                else
                    msg err "Shadow-TLS service file not found"
                    sleep 2
                fi
                ;;
            0) break ;;  
            *) msg warn "Invalid operation"; sleep 1 ;;
        esac
    done
}

# Manage Snell and Shadow-TLS services (极简风格)
manage() {
    while true; do
        clear
        set_breadcrumb "Main > Manage"
        show_breadcrumb

        # Display service status
        check_snell_status

        printf "\n${BOLD}Service Management${PLAIN}\n\n"
        printf "  1) Start Services\n"
        printf "  2) Stop Services\n"
        printf "  3) Restart Services\n"
        printf "  4) View Detailed Status\n"
        printf "  5) View Service Logs\n"
        printf "  6) Modify Configuration\n"
        printf "  0) Back\n\n"

        printf "Choice [0-6]: "
        read -r operation
        
        case $operation in
            1) set_breadcrumb "Main > Manage > Start"; run; sleep 2 ;;  
            2) set_breadcrumb "Main > Manage > Stop"; stop; sleep 2 ;;
            3) set_breadcrumb "Main > Manage > Restart"; restart_services ;;
            4) set_breadcrumb "Main > Manage > Status"; check_service ;; 
            5) set_breadcrumb "Main > Manage > Logs"; show_logs ;;
            6) set_breadcrumb "Main > Manage > Config"; modify ;; 
            0) break ;;
            *) msg warn "Invalid selection"; sleep 1 ;;
        esac
    done
}

# Create systemd service file for Snell
create_snell_systemd() {
    # Create snell user if not exists
    if ! id "snell" &>/dev/null; then
        useradd --system --no-create-home --shell /usr/sbin/nologin snell
        msg info "Created snell system user"
    fi
    
    # Set proper permissions for snell workspace
    chown -R snell:snell "${snell_workspace}"
    chmod 755 "${snell_workspace}"
    chmod 644 "${snell_workspace}/snell-server.conf"
    
    cat > $snell_service << EOF
[Unit]
Description=Snell Proxy Service
Documentation=https://manual.nssurge.com/others/snell.html
After=network.target nss-lookup.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=snell
Group=snell
StateDirectory=snell-server
WorkingDirectory=${snell_workspace}
ExecStart=${snell_workspace}/snell-server -c snell-server.conf
Restart=always
RestartSec=3s
# Harden and increase resource limits for high concurrency
LimitNOFILE=1048576
NoNewPrivileges=true
MemoryLimit=1G
TasksMax=infinity
CPUQuota=200%
AmbientCapabilities=CAP_NET_BIND_SERVICE
StandardOutput=journal
StandardError=journal
SyslogIdentifier=snell-server

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable snell
    msg ok "Snell systemd service created."
}

# Display beautified main menu (极简风格)
menu() {
    while true; do
        clear
        set_breadcrumb "Main"
        show_breadcrumb

        printf "\n${BOLD}ShadowTLS + Snell Management v%s${PLAIN}\n" "${current_version}"

        # Display service status
        check_snell_status

        printf "\n${BOLD}Main Menu${PLAIN}\n\n"
        printf "  1) Install Services\n"
        printf "  2) Uninstall Services\n"
        printf "  3) Manage Services\n"
        printf "  4) Modify Configuration\n"
        printf "  5) Display Configuration\n"
        printf "  6) Update Snell\n"
        printf "  0) Exit\n\n"

        printf "Choice [0-6]: "
        read -r operation

        case $operation in  
            1) install ;;
            2) uninstall ;;
            3) manage ;;
            4) modify ;;
            5) display_config ;;
            6) update_snell ;;
            0) printf "\n${SUCCESS_SYMBOL} Thank you for using this script! Goodbye!\n\n"; exit 0 ;;
            *) msg warn "Invalid selection"; sleep 1 ;;
        esac
    done
}

# New function to display configuration information (极简风格)
display_config() {
    clear
    set_breadcrumb "Main > Display Configuration"
    show_breadcrumb

    printf "\n${BOLD}Configuration Information${PLAIN}\n\n"
    
    if [[ ! -f "${snell_workspace}/snell-server.conf" ]]; then
        msg err "Snell not installed or configuration file not found"
        read -p "Press any key to return..." _
        return
    fi
    
    # Display Snell configuration
    printf "${BOLD}Snell Configuration${PLAIN}\n"
    
    local snell_config=$(cat "${snell_workspace}/snell-server.conf")
    local snell_listen=$(echo "$snell_config" | grep -oP 'listen = \K.*')
    local snell_psk=$(echo "$snell_config" | grep -oP 'psk = \K.*')
    local snell_ipv6=$(echo "$snell_config" | grep -oP 'ipv6 = \K.*')
    
    echo -e "${GREEN}Listen Address:${PLAIN} $snell_listen"
    echo -e "${GREEN}PSK:${PLAIN} $snell_psk"
    echo -e "${GREEN}IPv6 Support:${PLAIN} $snell_ipv6"
    
    # Get Snell version
    local snell_version_num="4"
    if [[ -f "${snell_workspace}/snell-server" ]]; then
        local installed_version=$("${snell_workspace}/snell-server" --version 2>&1 | grep -oP 'v\K[0-9]+')
        if [[ "$installed_version" == "5" ]]; then
            snell_version_num="5"
            echo -e "${GREEN}Version:${PLAIN} Snell v5 (Beta)"
        else
            echo -e "${GREEN}Version:${PLAIN} Snell v4"
        fi
    fi
    
    # Display ShadowTLS configuration (if exists)
    if systemctl is-active --quiet shadow-tls; then
        printf "\n${BOLD}ShadowTLS Configuration${PLAIN}\n"
        
        local shadow_tls_config=$(systemctl cat shadow-tls | grep ExecStart)
        local shadow_listen=$(echo "$shadow_tls_config" | grep -oP '\--listen \K[^ ]+')
        local shadow_server=$(echo "$shadow_tls_config" | grep -oP '\--server \K[^ ]+')
        local shadow_tls=$(echo "$shadow_tls_config" | grep -oP '\--tls \K[^ ]+')
        local shadow_password=$(echo "$shadow_tls_config" | grep -oP '\--password \K[^ ]+')
        
        echo -e "${GREEN}Listen Address:${PLAIN} $shadow_listen"
        echo -e "${GREEN}Server Address:${PLAIN} $shadow_server"
        echo -e "${GREEN}TLS Domain:${PLAIN} $shadow_tls"
        echo -e "${GREEN}Password:${PLAIN} $shadow_password"
        
        # Check if wildcard-sni is enabled
        if echo "$shadow_tls_config" | grep -q "wildcard-sni"; then
            echo -e "${GREEN}Wildcard SNI:${PLAIN} Enabled (Client can customize SNI)"
        else
            echo -e "${GREEN}Wildcard SNI:${PLAIN} Disabled"
        fi
        
        # Check if strict mode is enabled
        if echo "$shadow_tls_config" | grep -q "\--strict"; then
            echo -e "${GREEN}Strict Mode:${PLAIN} Enabled"
        else
            echo -e "${GREEN}Strict Mode:${PLAIN} Disabled"
        fi
    fi
    
    # Display client configuration
    printf "\n${BOLD}Client Configuration Example${PLAIN}\n"
    
    # Get server IP
    local server_ip=$(curl -s4 --connect-timeout 5 https://api.ipify.org)
    if [[ -z "$server_ip" ]]; then
        server_ip=$(curl -s6 --connect-timeout 5 https://api6.ipify.org)
    fi
    
    local port=$(echo "$snell_listen" | grep -oP ':\K\d+$')
    
    # Client configuration options
    msg info "Please select options for the client configuration:"
    read -rp "Enable TFO (TCP Fast Open)? (Y/n): " client_tfo_choice
    local client_tfo_value="true"
    if [[ $client_tfo_choice =~ ^[Nn]$ ]]; then
        client_tfo_value="false"
    fi

    read -rp "Enable Session Reuse? (y/N): " client_reuse_choice
    local client_reuse_value="false"
    if [[ $client_reuse_choice =~ ^[Yy]$ ]]; then
        client_reuse_value="true"
    fi
    
    if systemctl is-active --quiet shadow-tls; then
        local shadow_port=$(echo "$shadow_listen" | grep -oP ':\K\d+$')
        echo -e "${CYAN}Surge Configuration:${PLAIN}"
        echo -e "[Proxy]"
        echo -e "Snell = snell, ${server_ip}, ${shadow_port}, psk=${snell_psk}, version=${snell_version_num}, reuse=${client_reuse_value}, tfo=${client_tfo_value}, shadow-tls-password=${shadow_password}, shadow-tls-sni=${shadow_tls%%:*}, shadow-tls-version=3"
    else
        echo -e "${CYAN}Surge Configuration:${PLAIN}"
        echo -e "[Proxy]"
        echo -e "Snell = snell, ${server_ip}, ${port}, psk=${snell_psk}, version=${snell_version_num}, reuse=${client_reuse_value}, tfo=${client_tfo_value}"
    fi
    
    echo ""
    msg warn "Please replace the server address in the configuration with the actual available address"
    
    echo ""
    read -p "Press any key to return..." _
}

# Check Snell and ShadowTLS service status command (极简风格)
check_service() {
    clear
    set_breadcrumb "Main > Manage > Detailed Status"
    show_breadcrumb

    printf "\n${BOLD}Detailed Service Status${PLAIN}\n\n"

    printf "${BOLD}Snell Service Status:${PLAIN}\n"
    systemctl status snell

    printf "\n${BOLD}ShadowTLS Service Status:${PLAIN}\n"
    if systemctl is-active --quiet shadow-tls; then
        systemctl status shadow-tls
    else
        msg warn "ShadowTLS is not installed or not running"
    fi
    
    printf "\n${BOLD}Port Listening Status:${PLAIN}\n"
    ss -tuln | grep -E ':(10000|2000|8388|443)' || echo "No matching ports found"

    printf "\n${BOLD}System Resource Usage:${PLAIN}\n"
    local snell_pid=$(pgrep -f "snell-server" 2>/dev/null)
    local shadow_pid=$(pgrep -f "shadow-tls" 2>/dev/null)
    if [[ -n "$snell_pid" || -n "$shadow_pid" ]]; then
        ps -o pid,ppid,%cpu,%mem,cmd -p $snell_pid $shadow_pid 2>/dev/null || msg info "No active processes found"
    else
        msg info "No active processes found"
    fi
    
    printf "\n${SUCCESS_SYMBOL} Check completed!\n"
    
    read -p "Press any key to return..." _
}

# Restart services (极简风格)
restart_services() {
    clear
    set_breadcrumb "Main > Manage > Restart"
    show_breadcrumb

    printf "\n${BOLD}Restart Services${PLAIN}\n\n"
    
    msg info "Restarting services..."
    echo ""
    
    # Restart Snell
    if systemctl is-active --quiet snell; then
        printf "Restarting Snell... "
        systemctl restart snell
        sleep 1
        if systemctl is-active --quiet snell; then
            msg ok "Snell service restarted successfully"
        else
            msg err "Snell service restart failed"
        fi
    else
        msg warn "Snell service is not running"
    fi
    
    # Restart ShadowTLS
    if systemctl is-active --quiet shadow-tls; then
        printf "Restarting Shadow-TLS... "
        systemctl restart shadow-tls
        sleep 1
        if systemctl is-active --quiet shadow-tls; then
            msg ok "Shadow-TLS service restarted successfully"
        else
            msg err "Shadow-TLS service restart failed"
        fi
    else
        msg warn "Shadow-TLS service is not installed or not running"
    fi
    
    echo ""
    check_snell_status

    read -p "Press any key to return..." _
}

# Update Snell (极简风格)
update_snell() {
    clear
    set_breadcrumb "Main > Update Snell"
    show_breadcrumb

    printf "\n${BOLD}Update Snell${PLAIN}\n\n"
    
    if [[ ! -f "${snell_workspace}/snell-server" ]]; then
        msg err "Snell is not installed, cannot update."
        sleep 2
        return
    fi

    # Get current version
    local snell_current_version=$("${snell_workspace}/snell-server" --version 2>&1 | grep -oP 'v\K[0-9]+\.[0-9]+(\.[0-9]+[a-zA-Z0-9]*)?')
    if [ -z "$snell_current_version" ]; then
        msg err "Failed to get current Snell version."
        sleep 2
        return
    fi
    msg info "Current Snell version: v${snell_current_version}"
    echo ""

    # Ask which version to update to
    printf "${BOLD}Choose version to update to:${PLAIN}\n\n"
    printf "  1) Latest Snell v4 (Stable)\n"
    printf "  2) Snell v5 Beta (v5.0.0b1)\n"
    printf "  0) Cancel\n\n"
    printf "Choice [0-2]: "
    read -rp "" update_choice

    local target_version=""
    case $update_choice in
        0)
            msg info "Update cancelled"
            sleep 1
            return
            ;;
        1)
            # Get latest v4 version
            msg info "Fetching latest v4 version..."
            target_version=$(curl -s https://manual.nssurge.com/others/snell.html | grep -oP 'snell-server-v\K[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
            if [ -z "$target_version" ]; then
                msg err "Failed to get latest Snell v4 version."
                sleep 2
                return
            fi
            msg ok "Latest Snell v4 version: v${target_version}"
            ;;
        2)
            target_version="5.0.0b1"
            msg info "Target Snell v5 Beta version: v${target_version}"
            ;;
        *)
            msg err "Invalid selection"
            sleep 1
            return
            ;;
    esac

    if [[ "$snell_current_version" == "$target_version" ]]; then
        msg ok "Snell is already at version v${target_version}."
        sleep 2
        return
    fi

    echo ""
    if ! confirm_operation "update Snell" \
        "• Current version: v${snell_current_version}\n• Target version: v${target_version}\n• Service will be restarted" \
        ""; then
        return
    fi

    echo ""
    msg info "Stopping Snell service..."
    systemctl stop snell

    cd "${snell_workspace}" || exit 1
    
    arch=$(uname -m)
    case $arch in
    x86_64) snell_url="https://dl.nssurge.com/snell/snell-server-v${target_version}-linux-amd64.zip" ;;
    aarch64) snell_url="https://dl.nssurge.com/snell/snell-server-v${target_version}-linux-aarch64.zip" ;;
    armv7l) snell_url="https://dl.nssurge.com/snell/snell-server-v${target_version}-linux-armv7l.zip" ;;
    i386) snell_url="https://dl.nssurge.com/snell/snell-server-v${target_version}-linux-i386.zip" ;;
    *) msg err "Unsupported architecture: $arch"; sleep 2; return ;;
    esac

    msg info "Downloading Snell v${target_version}..."
    wget -q --show-progress -O snell-server.zip "${snell_url}"
    if [ $? -ne 0 ]; then
        msg err "Failed to download Snell. Restarting old version."
        systemctl start snell
        sleep 2
        return
    fi

    msg info "Extracting files..."
    unzip -qo snell-server.zip
    rm snell-server.zip
    chmod +x snell-server
    
    # Ensure snell user can execute the binary
    chown snell:snell snell-server

    msg info "Starting Snell service..."
    systemctl start snell
    sleep 2
    
    if systemctl is-active --quiet snell; then
        new_version=$("${snell_workspace}/snell-server" --version 2>&1 | grep -oP 'v\K[0-9]+\.[0-9]+(\.[0-9]+[a-zA-Z0-9]*)?')
        msg ok "Snell updated successfully to v${new_version}!"
    else
        msg err "Failed to start Snell after update. Check logs with: journalctl -u snell"
    fi
    
    echo ""
    read -p "Press any key to continue..." _
}

# Script starts here  
menu 
