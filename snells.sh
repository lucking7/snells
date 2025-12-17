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
BOLD=$'\033[1m'

# Standard message symbols (极简风格，不使用图标)
SUCCESS_SYMBOL="${GREEN}[OK]${PLAIN}"
ERROR_SYMBOL="${RED}[ERROR]${PLAIN}"
INFO_SYMBOL="${BLUE}[INFO]${PLAIN}"
WARN_SYMBOL="${YELLOW}[WARN]${PLAIN}"

err() { echo -e "${ERROR_SYMBOL} $*"; return 1; }
warn() { echo -e "${WARN_SYMBOL} $*"; }

# Global breadcrumb variable for navigation
BREADCRUMB_PATH="主菜单"

# Breadcrumb navigation functions (简化显示)
show_breadcrumb() {
    printf "\n${BOLD}当前位置：%s${PLAIN}\n" "$BREADCRUMB_PATH"
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

# Enhanced system status dashboard with ASCII table borders
check_snell_status() {
    printf "\n${BOLD}System Status${PLAIN}\n\n"
    
    # ASCII table header
    printf "+%-17s+%-20s+%-12s+%-17s+\n" \
        "-----------------" "--------------------" "------------" "-----------------"
    printf "| %-15s | %-18s | %-10s | %-15s |\n" "Service" "Status" "Port" "Version"
    printf "+%-17s+%-20s+%-12s+%-17s+\n" \
        "-----------------" "--------------------" "------------" "-----------------"
    
    # Snell service status
    local snell_status="${RED}Stopped${PLAIN}"
    local snell_port="N/A"
    local snell_version="N/A"
    local snell_status_plain="Stopped"

    if [[ -f "${snell_workspace}/snell-server.conf" ]]; then
        snell_port=$(grep -oP 'listen = .*?:\K\d+' "${snell_workspace}/snell-server.conf" 2>/dev/null || echo "N/A")

        if [[ -f "${snell_workspace}/snell-server" ]]; then
            snell_version=$("${snell_workspace}/snell-server" --version 2>&1 | grep -oP 'v\K[0-9]+\.[0-9]+(\.[0-9]+[a-zA-Z0-9]*)?' || echo "N/A")
        fi

        if systemctl is-active --quiet snell; then
            snell_status="${GREEN}Running${PLAIN}"
            snell_status_plain="Running"
        fi
    else
        snell_status="${YELLOW}Not installed${PLAIN}"
        snell_status_plain="Not installed"
    fi

    # Calculate padding for colored status text
    local snell_padding=$((18 - ${#snell_status_plain}))
    printf "| %-15s | %s%${snell_padding}s | %-10s | %-15s |\n" \
        "Snell" "$snell_status" "" "$snell_port" "v$snell_version"

    # Shadow-TLS service status
    local shadow_status="${YELLOW}Not installed${PLAIN}"
    local shadow_port="N/A"
    local shadow_version="N/A"
    local shadow_status_plain="Not installed"

    if [[ -f "/usr/local/bin/shadow-tls" ]]; then
        shadow_version=$(/usr/local/bin/shadow-tls --version 2>&1 | grep -oP 'v\K[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "N/A")

        if systemctl list-unit-files | grep -q shadow-tls.service; then
            local shadow_config
            shadow_config=$(systemctl cat shadow-tls 2>/dev/null | grep ExecStart)
            shadow_port=$(echo "$shadow_config" | grep -oP '\--listen [^\s]*:\K\d+' || echo "N/A")

            if systemctl is-active --quiet shadow-tls; then
                shadow_status="${GREEN}Running${PLAIN}"
                shadow_status_plain="Running"
            else
                shadow_status="${RED}Stopped${PLAIN}"
                shadow_status_plain="Stopped"
            fi
        fi
    fi

    local shadow_padding=$((18 - ${#shadow_status_plain}))
    printf "| %-15s | %s%${shadow_padding}s | %-10s | %-15s |\n" \
        "Shadow-TLS" "$shadow_status" "" "$shadow_port" "v$shadow_version"
    
    printf "+%-17s+%-20s+%-12s+%-17s+\n" \
        "-----------------" "--------------------" "------------" "-----------------"
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

# Get server location (country/region) from IP
get_server_location() {
    local ip=${1:-$server_ip}
    
    msg info "Detecting server location..."
    
    # Try multiple APIs for reliability
    # API 1: ip-api.com (free, no key required, supports batch)
    local location
    location=$(curl -s --connect-timeout 3 "http://ip-api.com/json/${ip}?fields=country,countryCode" 2>/dev/null)
    if [[ -n "$location" ]]; then
        # Use sed for JSON parsing (macOS compatible)
        country=$(echo "$location" | sed -n 's/.*"country":"\([^"]*\)".*/\1/p')
        country_code=$(echo "$location" | sed -n 's/.*"countryCode":"\([^"]*\)".*/\1/p')
        
        if [[ -n "$country" && -n "$country_code" ]]; then
            msg ok "Server location: ${country} (${country_code})"
            log_success "SYSTEM" "Detected location: ${country} (${country_code})"
            return 0
        fi
    fi
    
    # API 2: ipapi.co (backup, rate limited)
    local location2
    location2=$(curl -s --connect-timeout 3 "https://ipapi.co/${ip}/json/" 2>/dev/null)
    if [[ -n "$location2" ]]; then
        country=$(echo "$location2" | sed -n 's/.*"country_name":"\([^"]*\)".*/\1/p')
        country_code=$(echo "$location2" | sed -n 's/.*"country_code":"\([^"]*\)".*/\1/p')
        
        if [[ -n "$country" && -n "$country_code" ]]; then
            msg ok "Server location: ${country} (${country_code})"
            log_success "SYSTEM" "Detected location: ${country} (${country_code})"
            return 0
        fi
    fi
    
    # Fallback: Use colo code if APIs fail
    country="${colo:-Unknown}"
    country_code="${colo:-XX}"
    msg warn "Unable to detect country, using datacenter code: ${country}"
    log_operation "WARN" "SYSTEM" "Location detection failed, using fallback: ${country}"
    
    return 0
}

# Detect server IP (wrapper for get_ip)
detect_server_ip() {
    get_ip
    # Also detect location after getting IP
    get_server_location "$server_ip"
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
    if [[ $EUID -ne 0 ]]; then
        err "需要 root 权限运行此脚本。"
        exit 1
    fi

    # Detect package manager
    if command -v apt-get >/dev/null 2>&1; then
        cmd="apt-get"
    elif command -v apt >/dev/null 2>&1; then
        cmd="apt"
    else
        err "仅支持 Debian/Ubuntu（需要 apt-get/apt）。"
        exit 1
    fi

    # Check for systemd
    if ! command -v systemctl >/dev/null 2>&1; then
        err "缺少 systemd。请先安装：\n${cmd} update -y; ${cmd} install -y systemd"
        exit 1
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
dependencies=(wget unzip jq net-tools curl cron openssl ca-certificates)
LOG_FILE="/var/log/snells-manager.log"

# Enhanced error handling with logging
handle_error() {
    local error_code=${1:-"E000"}
    local error_msg=${2:-"Unknown error"}
    local suggestion=${3:-""}
    
    msg err "$error_msg"
    [ -n "$suggestion" ] && msg info "Suggestion: $suggestion"
    
    # Log error
    log_operation "ERROR" "SYSTEM" "$error_code: $error_msg"
    
    return 1
}

# Log operations for troubleshooting
log_operation() {
    local level=${1:-"INFO"}    # INFO, WARN, ERROR
    local category=${2:-"GENERAL"} # INSTALL, CONFIG, MANAGE, SYSTEM
    local message=${3:-""}
    
    # Create log directory if doesn't exist
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null
    
    # Write to log file
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] [$category] $message" >> "$LOG_FILE" 2>/dev/null
}

# Success operation log
log_success() {
    local category=${1:-"GENERAL"}
    local message=${2:-""}
    log_operation "INFO" "$category" "$message"
}

# Simplified installation of missing packages  
install_pkg() {
    msg info "检查并安装依赖..."
    "$cmd" update -qq
    "$cmd" install -y dnsutils "${dependencies[@]}"
}

# Function to generate a random PSK
generate_random_psk() {
    openssl rand -base64 32
}

# Function to generate a random password  
generate_random_password() {
    openssl rand -base64 16
}

# Enhanced input validation functions with real-time feedback
validate_port() {
    local port=$1
    local show_usage=${2:-false}
    
    # Check if port is numeric
    if [[ ! "$port" =~ ^[0-9]+$ ]]; then
        msg err "Invalid port: '$port' is not a number"
        return 1
    fi
    
    # Check port range
    if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        msg err "Invalid port: $port (must be 1-65535)"
        return 1
    fi
    
    # Check if port is in use
    if [ "$show_usage" = true ]; then
        if ss -tuln | grep -q ":${port} "; then
            local process
            process=$(ss -tulpn 2>/dev/null | grep ":${port} " | grep -oP 'users:\(\(".*?"\)' | sed 's/users:((//' | sed 's/".*//' || echo "unknown")
            msg warn "Port $port is already in use"
            [ "$process" != "unknown" ] && msg info "Used by: $process"
            return 2  # Return 2 to indicate port is in use but valid format
        else
            msg ok "Port $port is available"
        fi
    fi
    
    return 0
}

validate_domain() {
    local domain=$1
    local check_dns=${2:-false}
    
    if [[ -z "$domain" ]]; then
        msg err "Domain cannot be empty"
        return 1
    fi
    
    # Check domain format
    if [[ ! "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
        msg err "Invalid domain format: $domain"
        msg info "Example: gateway.icloud.com"
        return 1
    fi
    
    # Optional DNS check
    if [ "$check_dns" = true ]; then
        msg info "Checking DNS resolution..."
        if host -W 2 "$domain" &>/dev/null; then
            local ip
            ip=$(host "$domain" 2>/dev/null | grep "has address" | head -1 | awk '{print $NF}')
            if [ -n "$ip" ]; then
                msg ok "Domain resolves to: $ip"
            else
                msg ok "Domain is valid"
            fi
        else
            msg warn "Cannot resolve domain (may still work for SNI)"
        fi
    fi
    
    return 0
}

# Progress indicator for background processes
show_loading() {
    local pid=$1
    local message=${2:-"处理中"}
    local delay=0.15
    local spinstr="|/-\\"
    
    printf "${INFO_SYMBOL} %s " "$message"
    while ps -p "$pid" &>/dev/null; do
        local temp=${spinstr#?}
        printf "%c\b" "$spinstr"
        spinstr=$temp${spinstr%"$temp"}
        sleep $delay
    done
    printf "\r${SUCCESS_SYMBOL} %s 完成\n" "$message"
}

# Operation confirmation with preview
confirm_operation() {
    local operation="$1"
    local details="$2"
    local warning="$3"

    printf "\n${BOLD}${YELLOW}即将执行：%s${PLAIN}\n" "$operation"
    if [ -n "$details" ]; then
        printf "%s\n" "$details"
    fi

    if [ -n "$warning" ]; then
        printf "\n${WARN_SYMBOL} ${YELLOW}%s${PLAIN}\n" "$warning"
    fi

    printf "\n继续执行？[y/N]: "
    read -r confirm
    case "$confirm" in
        [yY]|[yY][eE][sS]) return 0 ;;
        *) msg info "已取消"; return 1 ;;
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
    # Get port with enhanced validation
    printf "\n${BOLD}Port Configuration${PLAIN}\n"
    while true; do
        read -rp "Assign a port for Snell [1-65535] (blank for random): " snell_port
        if [[ -z ${snell_port} ]]; then
            snell_port=$(find_unused_port)
            msg info "Assigned random port: $snell_port"
            break
        elif validate_port "$snell_port" true; then
            local result=$?
            if [ $result -eq 2 ]; then
                # Port is in use, ask if want to continue
                read -rp "Use this port anyway? [y/N]: " force_port
                if [[ $force_port =~ ^[Yy]$ ]]; then
                    msg warn "Using port $snell_port (may cause conflicts)"
                    break
                fi
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
ExecStart=/usr/local/bin/shadow-tls --v3 ${strict_option} server ${wildcard_option} --listen ${listen_addr} --server ${server_addr} --tls ${shadow_tls_tls_domain}:443 --password ${shadow_tls_password}
Restart=always
RestartSec=3s
# Harden and increase resource limits for high concurrency
LimitNOFILE=1048576
NoNewPrivileges=true
TasksMax=infinity
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
    # Get Shadow-TLS port with enhanced validation
    printf "\n${BOLD}Shadow-TLS Port Configuration${PLAIN}\n"
    while true; do
        read -rp "Choose port for Shadow-TLS [1-65535] (default: 443): " shadow_tls_port
        if [[ -z ${shadow_tls_port} ]]; then
            shadow_tls_port="443"
            msg info "Using default port: 443"
            # Check if default port is available
            if ss -tuln | grep -q ":443 "; then
                msg warn "Port 443 is already in use"
                read -rp "Use anyway? [y/N]: " force_443
                [[ ! $force_443 =~ ^[Yy]$ ]] && continue
            fi
            break
        elif validate_port "$shadow_tls_port" true; then
            local result=$?
            if [ $result -eq 2 ]; then
                read -rp "Use this port anyway? [y/N]: " force_port
                if [[ $force_port =~ ^[Yy]$ ]]; then
                    msg warn "Using port $shadow_tls_port (may cause conflicts)"
                    break
                fi
                continue
            fi
            break
        fi
    done
    
    printf "\n${BOLD}TLS Domain Selection${PLAIN}\n"
    echo -e "${CYAN}Recommended domains (TLS 1.3 compatible):${PLAIN}"
    echo -e "  1) gateway.icloud.com (Apple services)"
    echo -e "  2) p11.douyinpic.com (Douyin related, recommended for free flow)"
    echo -e "  3) mp.weixin.qq.com (WeChat related)"
    echo -e "  4) sns-img-qc.xhscdn.com (Xiaohongshu related)"
    echo -e "  5) p9-dy.byteimg.com (Byte related)"
    echo -e "  6) weather-data.apple.com (Apple weather service)"
    echo -e "  7) Custom domain"
    echo ""
    read -rp "Select TLS domain [1-7] (default: 1): " domain_choice
    
    case ${domain_choice:-1} in
        1) shadow_tls_tls_domain="gateway.icloud.com" ;;
        2) shadow_tls_tls_domain="p11.douyinpic.com" ;;
        3) shadow_tls_tls_domain="mp.weixin.qq.com" ;;
        4) shadow_tls_tls_domain="sns-img-qc.xhscdn.com" ;;
        5) shadow_tls_tls_domain="p9-dy.byteimg.com" ;;
        6) shadow_tls_tls_domain="weather-data.apple.com" ;;
        7) 
            while true; do
                echo ""
                read -rp "Enter custom TLS domain: " shadow_tls_tls_domain
                if [[ -z ${shadow_tls_tls_domain} ]]; then
                    shadow_tls_tls_domain="gateway.icloud.com"
                    msg info "Using default domain: $shadow_tls_tls_domain"
                    break
                elif validate_domain "$shadow_tls_tls_domain" true; then
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
    msg ok "Selected TLS domain: $shadow_tls_tls_domain"
    
    read -rp "Input Shadow-TLS password (leave blank to generate a random one): " shadow_tls_password
    [[ -z ${shadow_tls_password} ]] && shadow_tls_password=$(generate_random_password) && echo "[INFO] Generated a random password for Shadow-TLS: $shadow_tls_password"

    # Determine Snell PSK for client configuration
    local client_snell_psk="${snell_psk}" # Prioritize PSK set during script execution
    if [[ -z "${client_snell_psk}" && -f "${snell_workspace}/snell-server.conf" ]]; then
        # If no PSK is set and configuration file exists, read from file
        client_snell_psk=$(grep -oP 'psk = \K.*' "${snell_workspace}/snell-server.conf")
    fi

    # Snell v5 only (fixed version)
    local snell_version_num="5"

    # Use country code as node name (or fallback to colo/Server)
    local node_name="${country_code:-${colo:-Server}}"
    
    echo -e "${node_name} = snell, ${server_ip}, ${shadow_tls_port}, psk=${client_snell_psk}, version=${snell_version_num}, shadow-tls-password=${shadow_tls_password}, shadow-tls-sni=${shadow_tls_tls_domain}, shadow-tls-version=3"
    msg ok "Shadow-TLS configuration completed."
}

# Install Snell without IP detection (core installation function)
install_snell_without_ip() {
    install_pkg
    
    # Install Snell v5 directly (no version selection)
    msg info "Installing Snell v5 (Latest Protocol)"
    log_operation "INFO" "INSTALL" "Installing Snell v5"
    
    local snell_version="5.0.0b1"
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
        local installed_version
        installed_version=$("${snell_workspace}/snell-server" --version 2>&1 | grep -oP 'v\K[0-9]+\.[0-9]+(\.[0-9]+)?')
        msg ok "Snell server binary installed successfully (version: ${installed_version})"
        log_success "INSTALL" "Snell v${installed_version} binary installed successfully"
    else
        msg err "Failed to install Snell server binary"
        handle_error "E001" "Failed to install Snell server binary" "Check network connection or try a different version"
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
        log_success "INSTALL" "Snell service started successfully on port ${snell_port}"
    else
        msg err "Failed to start Snell service, please check logs with: journalctl -u snell"
        handle_error "E002" "Failed to start Snell service" "Check logs: journalctl -u snell"
    fi

    # 安装结束后输出 Surge 标准配置（仅 Snell-only 场景）
    if [[ "${install_with_shadow_tls:-false}" != "true" ]]; then
        echo ""
        print_surge_proxy_config "snell"
        echo ""
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

    # 安装结束后输出 Surge 标准配置（Shadow-TLS / Snell+Shadow-TLS）
    echo ""
    print_surge_proxy_config "shadow-tls"
    echo ""
}

# Install Shadow-TLS only
install_shadow_tls() {
    # Detect IP
    get_ip
    
    # Install Shadow-TLS
    install_shadow_tls_without_ip
}

# Install menu with improved formatting
install() {
    while true; do
        clear
        set_breadcrumb "主菜单 > 安装"
        show_breadcrumb

        printf "\n${BOLD}安装选项${PLAIN}\n\n"
        printf "  ${GREEN}1${PLAIN}) 仅安装 Snell\n"
        printf "  ${GREEN}2${PLAIN}) 安装 Snell + Shadow-TLS\n"
        printf "  ${GREEN}3${PLAIN}) 仅安装 Shadow-TLS ${CYAN}(需要已安装 Snell)${PLAIN}\n"
        printf "  ${YELLOW}0${PLAIN}) 返回\n\n"

        printf "选择 [0-3]: "
        read -r option
        
        case $option in
            1) 
                set_breadcrumb "主菜单 > 安装 > Snell"
                log_operation "INFO" "INSTALL" "Starting Snell installation"
                install_snell
                break 
                ;;
            2) 
                set_breadcrumb "主菜单 > 安装 > Snell + Shadow-TLS"
                log_operation "INFO" "INSTALL" "Starting Snell + Shadow-TLS installation"
                install_snell_and_shadow_tls
                break 
                ;;
            3) 
                set_breadcrumb "主菜单 > 安装 > Shadow-TLS"
                log_operation "INFO" "INSTALL" "Starting Shadow-TLS installation"
                install_shadow_tls
                break 
                ;;
            0) break ;;
            *) msg warn "Invalid option"; sleep 1 ;;
        esac
    done
}

# Uninstall Snell and Shadow-TLS (极简风格)
uninstall() {
    while true; do
        clear
        set_breadcrumb "主菜单 > 卸载"
        show_breadcrumb

        printf "\n${BOLD}卸载选项${PLAIN}\n\n"
        printf "  1) 卸载 Snell + Shadow-TLS\n"
        printf "  2) 仅卸载 Snell\n"
        printf "  3) 仅卸载 Shadow-TLS\n"
        printf "  0) 返回\n\n"

        printf "选择 [0-3]: "
        read -r option

        case $option in
            1) set_breadcrumb "主菜单 > 卸载 > 全部"; uninstall_all; break ;;
            2) set_breadcrumb "主菜单 > 卸载 > Snell"; uninstall_snell; break ;;
            3) set_breadcrumb "主菜单 > 卸载 > Shadow-TLS"; uninstall_shadow_tls; break ;;
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
        log_success "MANAGE" "All services started successfully"
    else
        msg err "Failed to start Snell or Shadow-TLS, please check logs."
        log_operation "ERROR" "MANAGE" "Failed to start one or more services"
    fi
}

# Stop Snell and Shadow-TLS
stop() {  
    systemctl stop snell
    systemctl stop shadow-tls
    msg ok "Snell and Shadow-TLS have been stopped."
    log_success "MANAGE" "All services stopped"
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
    set_breadcrumb "主菜单 > 管理 > 日志"
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
        set_breadcrumb "主菜单 > 配置"
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

# Manage Snell and Shadow-TLS services with improved formatting
manage() {
    while true; do
        clear
        set_breadcrumb "主菜单 > 管理"
        show_breadcrumb

        # Display service status
        check_snell_status

        printf "${BOLD}Service Management${PLAIN}\n\n"
        printf "  ${GREEN}1${PLAIN}) Start Services\n"
        printf "  ${GREEN}2${PLAIN}) Stop Services\n"
        printf "  ${GREEN}3${PLAIN}) Restart Services\n"
        printf "  ${BLUE}4${PLAIN}) View Detailed Status\n"
        printf "  ${BLUE}5${PLAIN}) View Service Logs\n"
        printf "  ${CYAN}6${PLAIN}) Modify Configuration\n"
        printf "  ${YELLOW}0${PLAIN}) Back\n\n"

        printf "Choice [0-6]: "
        read -r operation
        
        case $operation in
            1) 
                set_breadcrumb "主菜单 > 管理 > 启动"
                log_operation "INFO" "MANAGE" "Starting services"
                run
                sleep 2 
                ;;  
            2) 
                set_breadcrumb "主菜单 > 管理 > 停止"
                log_operation "INFO" "MANAGE" "Stopping services"
                stop
                sleep 2 
                ;;
            3) 
                set_breadcrumb "主菜单 > 管理 > 重启"
                log_operation "INFO" "MANAGE" "Restarting services"
                restart_services 
                ;;
            4) set_breadcrumb "主菜单 > 管理 > 状态"; check_service ;; 
            5) set_breadcrumb "主菜单 > 管理 > 日志"; show_logs ;;
            6) set_breadcrumb "主菜单 > 管理 > 配置"; modify ;; 
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
TasksMax=infinity
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

# Display beautified main menu with improved spacing
menu() {
    while true; do
        clear
        set_breadcrumb "主菜单"
        show_breadcrumb

        printf "\n${BOLD}${BLUE}Snell + Shadow-TLS 管理${PLAIN} ${CYAN}v%s${PLAIN}\n" "${current_version}"

        # Display service status
        check_snell_status

        printf "${BOLD}主菜单${PLAIN}\n\n"
        printf "  ${GREEN}1${PLAIN}) 安装\n"
        printf "  ${GREEN}2${PLAIN}) 卸载\n"
        printf "  ${GREEN}3${PLAIN}) 服务管理\n"
        printf "  ${GREEN}4${PLAIN}) 配置编辑\n"
        printf "  ${GREEN}5${PLAIN}) 显示配置\n"
        printf "  ${GREEN}6${PLAIN}) 更新 Snell\n"
        printf "  ${YELLOW}0${PLAIN}) 退出\n\n"

        printf "选择 [0-6]: "
        read -r operation

        case $operation in  
            1) log_operation "INFO" "MENU" "User selected: Install Services"; install ;;
            2) log_operation "INFO" "MENU" "User selected: Uninstall Services"; uninstall ;;
            3) log_operation "INFO" "MENU" "User selected: Manage Services"; manage ;;
            4) log_operation "INFO" "MENU" "User selected: Modify Configuration"; modify ;;
            5) log_operation "INFO" "MENU" "User selected: Display Configuration"; display_config ;;
            6) log_operation "INFO" "MENU" "User selected: Update Snell"; update_snell ;;
            0) 
                log_operation "INFO" "SYSTEM" "Script exited by user"
                printf "\n${SUCCESS_SYMBOL} 已退出。\n\n"
                exit 0 
                ;;
            *) msg warn "无效选择"; sleep 1 ;;
        esac
    done
}

# New function to display configuration information (极简风格)
display_config() {
    clear
    set_breadcrumb "主菜单 > 显示配置"
    show_breadcrumb

    printf "\n${BOLD}配置信息${PLAIN}\n\n"
    
    if [[ ! -f "${snell_workspace}/snell-server.conf" ]]; then
        msg err "未找到 Snell 配置文件（可能未安装）。"
        read -p "Press any key to return..." _
        return
    fi
    
    # Display Snell configuration
    printf "${BOLD}Snell 配置${PLAIN}\n"
    
    local snell_config
    local snell_listen
    local snell_psk
    local snell_ipv6
    snell_config=$(cat "${snell_workspace}/snell-server.conf")
    snell_listen=$(echo "$snell_config" | grep -oP 'listen = \K.*')
    snell_psk=$(echo "$snell_config" | grep -oP 'psk = \K.*')
    snell_ipv6=$(echo "$snell_config" | grep -oP 'ipv6 = \K.*')
    
    echo -e "${GREEN}监听地址:${PLAIN} $snell_listen"
    echo -e "${GREEN}PSK:${PLAIN} $snell_psk"
    echo -e "${GREEN}IPv6:${PLAIN} $snell_ipv6"
    
    # Get Snell version (v5 only)
    local snell_version_num="5"
    if [[ -f "${snell_workspace}/snell-server" ]]; then
        local installed_version
        installed_version=$("${snell_workspace}/snell-server" --version 2>&1 | grep -oP 'v\K[0-9]+\.[0-9]+(\.[0-9]+[a-zA-Z0-9]*)?')
        echo -e "${GREEN}Version:${PLAIN} Snell v${installed_version}"
    fi
    
    # Display ShadowTLS configuration (if exists)
    if systemctl is-active --quiet shadow-tls; then
        printf "\n${BOLD}Shadow-TLS 配置${PLAIN}\n"
        
        local shadow_tls_config
        local shadow_listen
        local shadow_server
        local shadow_tls
        local shadow_password
        shadow_tls_config=$(systemctl cat shadow-tls | grep ExecStart)
        shadow_listen=$(echo "$shadow_tls_config" | grep -oP '\--listen \K[^ ]+')
        shadow_server=$(echo "$shadow_tls_config" | grep -oP '\--server \K[^ ]+')
        shadow_tls=$(echo "$shadow_tls_config" | grep -oP '\--tls \K[^ ]+')
        shadow_password=$(echo "$shadow_tls_config" | grep -oP '\--password \K[^ ]+')
        
        echo -e "${GREEN}监听地址:${PLAIN} $shadow_listen"
        echo -e "${GREEN}转发地址:${PLAIN} $shadow_server"
        echo -e "${GREEN}TLS 域名:${PLAIN} $shadow_tls"
        echo -e "${GREEN}密码:${PLAIN} $shadow_password"
        
        # Check if wildcard-sni is enabled
        if echo "$shadow_tls_config" | grep -q "wildcard-sni"; then
            echo -e "${GREEN}Wildcard SNI:${PLAIN} 已启用（客户端可自定义 SNI）"
        else
            echo -e "${GREEN}Wildcard SNI:${PLAIN} 未启用"
        fi
        
        # Check if strict mode is enabled
        if echo "$shadow_tls_config" | grep -q "\--strict"; then
            echo -e "${GREEN}严格模式:${PLAIN} 已启用"
        else
            echo -e "${GREEN}严格模式:${PLAIN} 未启用"
        fi
    fi
    
    # Display client configuration
    printf "\n${BOLD}客户端配置示例（Surge）${PLAIN}\n"
    
    # Get server IP
    local server_ip
    server_ip=$(curl -s4 --connect-timeout 5 https://api.ipify.org)
    if [[ -z "$server_ip" ]]; then
        server_ip=$(curl -s6 --connect-timeout 5 https://api6.ipify.org)
    fi
    
    # Detect server location if not already done
    if [[ -z "$country" || -z "$country_code" ]]; then
        get_server_location "$server_ip"
    fi
    
    local port
    port=$(echo "$snell_listen" | grep -oP ':\K\d+$')
    
    # Use country code as node name (or fallback)
    local node_name="${country_code:-${colo:-Server}}"
    
    # Snell v5 only
    local snell_version_num="5"
    
    if systemctl is-active --quiet shadow-tls; then
        local shadow_port
        shadow_port=$(echo "$shadow_listen" | grep -oP ':\K\d+$')
        echo -e "${CYAN}Surge Configuration:${PLAIN}"
        echo -e "[Proxy]"
        echo -e "${node_name} = snell, ${server_ip}, ${shadow_port}, psk=${snell_psk}, version=${snell_version_num}, shadow-tls-password=${shadow_password}, shadow-tls-sni=${shadow_tls%%:*}, shadow-tls-version=3"
    else
        echo -e "${CYAN}Surge Configuration:${PLAIN}"
        echo -e "[Proxy]"
        echo -e "${node_name} = snell, ${server_ip}, ${port}, psk=${snell_psk}, version=${snell_version_num}"
    fi
    
    echo ""
    msg warn "如有需要，请将 server 地址替换为你的实际可用入口。"
    
    echo ""
    read -p "Press any key to return..." _
}

# 统一输出 Surge Proxy 配置（安装完成/显示配置复用）
print_surge_proxy_config() {
    local mode="${1:-auto}" # auto|snell|shadow-tls

    # server_ip 优先使用已检测到的全局变量，否则临时探测
    local cfg_server_ip="${server_ip:-}"
    if [[ -z "$cfg_server_ip" ]]; then
        cfg_server_ip=$(curl -s4 --connect-timeout 5 https://api.ipify.org)
        [[ -z "$cfg_server_ip" ]] && cfg_server_ip=$(curl -s6 --connect-timeout 5 https://api6.ipify.org)
    fi

    # 尝试补齐 country_code（用于节点名）
    if [[ -n "$cfg_server_ip" && ( -z "${country:-}" || -z "${country_code:-}" ) ]]; then
        get_server_location "$cfg_server_ip" >/dev/null 2>&1 || true
    fi

    local node_name="${country_code:-${colo:-Server}}"

    # 读取 snell 配置（优先全局变量，其次从文件读）
    local cfg_snell_psk="${snell_psk:-}"
    local cfg_snell_listen=""
    if [[ -f "${snell_workspace}/snell-server.conf" ]]; then
        cfg_snell_listen=$(grep -oP 'listen = \K.*' "${snell_workspace}/snell-server.conf" 2>/dev/null || echo "")
        [[ -z "$cfg_snell_psk" ]] && cfg_snell_psk=$(grep -oP 'psk = \K.*' "${snell_workspace}/snell-server.conf" 2>/dev/null || echo "")
    fi

    local cfg_snell_port=""
    [[ -n "$cfg_snell_listen" ]] && cfg_snell_port=$(echo "$cfg_snell_listen" | grep -oP ':\K\d+$' 2>/dev/null || echo "")

    # Shadow-TLS 参数（可能来自运行中的服务，或来自安装时变量）
    local cfg_shadow_listen=""
    local cfg_shadow_port=""
    local cfg_shadow_password="${shadow_tls_password:-}"
    local cfg_shadow_sni="${shadow_tls_tls_domain:-}"
    if systemctl is-active --quiet shadow-tls 2>/dev/null; then
        local shadow_exec
        shadow_exec=$(systemctl cat shadow-tls 2>/dev/null | grep ExecStart || true)
        cfg_shadow_listen=$(echo "$shadow_exec" | grep -oP '\--listen \K[^ ]+' 2>/dev/null || echo "")
        cfg_shadow_port=$(echo "$cfg_shadow_listen" | grep -oP ':\K\d+$' 2>/dev/null || echo "")
        [[ -z "$cfg_shadow_password" ]] && cfg_shadow_password=$(echo "$shadow_exec" | grep -oP '\--password \K[^ ]+' 2>/dev/null || echo "")
        if [[ -z "$cfg_shadow_sni" ]]; then
            # --tls domain:443
            local tls_arg
            tls_arg=$(echo "$shadow_exec" | grep -oP '\--tls \K[^ ]+' 2>/dev/null || echo "")
            cfg_shadow_sni=${tls_arg%%:*}
        fi
    fi

    # auto 模式：shadow-tls 运行则输出 shadow-tls 组合，否则输出 snell
    if [[ "$mode" == "auto" ]]; then
        if systemctl is-active --quiet shadow-tls 2>/dev/null; then
            mode="shadow-tls"
        else
            mode="snell"
        fi
    fi

    echo -e "${CYAN}Surge Configuration:${PLAIN}"
    echo -e "[Proxy]"

    if [[ "$mode" == "shadow-tls" ]]; then
        local out_port="${cfg_shadow_port:-${shadow_tls_port:-}}"
        echo -e "${node_name} = snell, ${cfg_server_ip}, ${out_port}, psk=${cfg_snell_psk}, version=5, shadow-tls-password=${cfg_shadow_password}, shadow-tls-sni=${cfg_shadow_sni}, shadow-tls-version=3"
    else
        local out_port="${cfg_snell_port:-${snell_port:-}}"
        echo -e "${node_name} = snell, ${cfg_server_ip}, ${out_port}, psk=${cfg_snell_psk}, version=5"
    fi
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
    local snell_pid
    local shadow_pid
    snell_pid=$(pgrep -f "snell-server" 2>/dev/null || true)
    shadow_pid=$(pgrep -f "shadow-tls" 2>/dev/null || true)

    local pids=()
    [[ -n "$snell_pid" ]] && pids+=("$snell_pid")
    [[ -n "$shadow_pid" ]] && pids+=("$shadow_pid")

    if ((${#pids[@]} > 0)); then
        ps -o pid,ppid,%cpu,%mem,cmd -p "${pids[@]}" 2>/dev/null || msg info "No active processes found"
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
    local snell_current_version
    snell_current_version=$("${snell_workspace}/snell-server" --version 2>&1 | grep -oP 'v\K[0-9]+\.[0-9]+(\.[0-9]+[a-zA-Z0-9]*)?')
    if [ -z "$snell_current_version" ]; then
        msg err "Failed to get current Snell version."
        sleep 2
        return
    fi
    msg info "Current Snell version: v${snell_current_version}"
    echo ""

    # Update to Snell v5 (only option)
    printf "${BOLD}Update to Snell v5${PLAIN}\n\n"
    printf "  ${GREEN}1${PLAIN}) Update to Snell v5.0.0b1 (Latest)\n"
    printf "  ${YELLOW}0${PLAIN}) Cancel\n\n"
    printf "Choice [0-1]: "
    read -rp "" update_choice

    local target_version=""
    case $update_choice in
        0)
            msg info "Update cancelled"
            sleep 1
            return
            ;;
        1)
            target_version="5.0.0b1"
            msg info "Target Snell v5 version: v${target_version}"
            log_operation "INFO" "UPDATE" "Updating to Snell v${target_version}"
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
