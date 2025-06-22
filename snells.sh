#!/bin/bash

# 脚本版本
current_version="1.3.0"

# Define color codes
red='\e[31m'
green='\e[92m' 
yellow='\e[33m'  
reset='\e[0m'
underline='\e[4m'
blink='\e[5m'  
cyan='\e[96m'
purple='\e[35m'
BOLD='\e[1m'
BG_BLUE='\e[44m'

# Color print functions
_red() { echo -e "${red}$@${reset}"; }
_green() { echo -e "${green}$@${reset}"; }
_yellow() { echo -e "${yellow}$@${reset}"; }  
_cyan() { echo -e "${cyan}$@${reset}"; }
_magenta() { echo -e "${purple}$@${reset}"; }  
_red_bg() { echo -e "\e[41m$@${reset}"; }
_blue_bg() { echo -e "${BG_BLUE}$@${reset}"; }
_bold() { echo -e "${BOLD}$@${reset}"; }

is_err=$(_red_bg "ERROR!")
is_warn=$(_red_bg "WARNING!")

err() {  
    echo -e "\n$is_err $@\n" && return 1
}

warn() {
    echo -e "\n$is_warn $@\n"  
}

# Function to display log messages
msg() {
    case $1 in
        err) echo -e "${red}[ERROR] $2${reset}" ;;
        warn) echo -e "${yellow}[WARN] $2${reset}" ;;
        ok) echo -e "${green}[OK] $2${reset}" ;;
        info) echo -e "[INFO] $2" ;;
        *) echo -e "[LOG] $2" ;;
    esac
}

# Check Snell service status
check_snell_status() {
    echo -e "${cyan}═════════════════════════════════════${reset}"
    echo -e "${cyan}            Service Status Check      ${reset}"
    echo -e "${cyan}═════════════════════════════════════${reset}"
    
    if systemctl is-active --quiet snell; then
        echo -e "Snell Service: ${green}Running${reset}"
    else
        echo -e "Snell Service: ${red}Stopped${reset}"
    fi
    
    if systemctl is-active --quiet shadow-tls; then
        echo -e "Shadow-TLS Service: ${green}Running${reset}"
    else
        echo -e "Shadow-TLS Service: ${red}Stopped${reset} or ${yellow}Not installed${reset}"
    fi
    
    # Check port usage
    if [[ -f "${snell_workspace}/snell-server.conf" ]]; then
        local snell_port=$(grep -oP 'listen = .*?:(\d+)' "${snell_workspace}/snell-server.conf" | grep -oP '\d+$')
        if [[ -n "$snell_port" ]]; then
            if ss -tuln | grep -q ":${snell_port} "; then
                echo -e "Snell Port ${snell_port}: ${green}Open${reset}"
            else
                echo -e "Snell Port ${snell_port}: ${red}Closed${reset}"
            fi
        fi
    fi
    
    echo
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
    # Get port
    read -rp "Assign a port for Snell (Leave it blank for a random one): " snell_port
    [[ -z ${snell_port} ]] && snell_port=$(find_unused_port) && echo "[INFO] Assigned a random port for Snell: $snell_port"
    
    # Get PSK
    read -rp "Enter PSK for Snell (Leave it blank to generate a random one): " snell_psk
    [[ -z ${snell_psk} ]] && snell_psk=$(generate_random_psk) && echo "[INFO] Generated a random PSK for Snell: $snell_psk"
    
    # Get DNS settings
    system_dns=$(grep -oP '(?<=nameserver\s)\S+' /etc/resolv.conf | sort -u | tr '\n' ',' | sed 's/,$//')
    prompt_dns="Enter custom DNS servers (leave blank for default): "
    if [[ -n "$system_dns" ]]; then
        prompt_dns="Enter custom DNS servers (comma-separated, leave blank for system DNS [${system_dns}]): "
    fi
    read -rp "$prompt_dns" custom_dns

    local final_dns=""
    if [[ -n "$custom_dns" ]]; then
        final_dns="$custom_dns"
        msg info "Using custom DNS: $final_dns"
    elif [[ -n "$system_dns" ]]; then
        final_dns="$system_dns"
        msg info "Using system DNS: $final_dns"
    else
        msg warn "Unable to get system DNS from /etc/resolv.conf. Using default DNS."
        if [[ $ip_type == "both" || $ip_type == "ipv6" ]]; then
            final_dns="1.1.1.1,2606:4700:4700::1111" # Cloudflare only for IPv6
            msg info "Using default DNS (Cloudflare, includes IPv6)"
        else
            final_dns="1.1.1.1,8.8.8.8" # Cloudflare + Google for IPv4
            msg info "Using default DNS (Cloudflare + Google, IPv4 only)"
        fi
    fi
    dns_config="dns = $final_dns"

    # Ask if listening on localhost only
    read -rp "Listen on localhost only? (y/n, recommended when using Shadow-TLS): " local_only
    if [[ $local_only =~ ^[Yy]$ ]]; then
        if [[ $ip_type == "ipv6" ]]; then
            listen_addr="[::1]:$snell_port"
        else
            listen_addr="127.0.0.1:$snell_port"
        fi
        msg info "Configuring Snell to listen on localhost: $listen_addr"
    else
        # Configure IPv6 settings
        if [[ $ip_type == "both" ]]; then
            read -rp "Enable IPv6 support? (y/n): " enable_ipv6
            if [[ $enable_ipv6 =~ ^[Yy]$ ]]; then
                listen_addr="::0:$snell_port"
                ipv6_enabled="true"
            else
                listen_addr="0.0.0.0:$snell_port"
                ipv6_enabled="false"
            fi
        elif [[ $ip_type == "ipv6" ]]; then
            listen_addr="::0:$snell_port"
            ipv6_enabled="true"
        else
            listen_addr="0.0.0.0:$snell_port"
            ipv6_enabled="false"
        fi
    fi

    # Write the configuration file
    cat > "${snell_workspace}/snell-server.conf" << EOF
[snell-server]
listen = ${listen_addr}
psk = ${snell_psk}
ipv6 = ${ipv6_enabled:-true}
${dns_config}
EOF

    msg ok "Snell configuration file created: ${snell_workspace}/snell-server.conf"
    systemctl start snell
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
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity
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
    read -rp "Choose port for Shadow-TLS (default: 443): " shadow_tls_port
    if [[ -z ${shadow_tls_port} ]]; then
        shadow_tls_port="443"
        echo "[INFO] Using default port 443 for Shadow-TLS"
    fi
    
    echo -e "${yellow}Recommended TLS domain list (supports TLS 1.3):${reset}"
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
            read -rp "Enter custom TLS domain: " shadow_tls_tls_domain
            [[ -z ${shadow_tls_tls_domain} ]] && shadow_tls_tls_domain="gateway.icloud.com"
            ;;
        *) shadow_tls_tls_domain="gateway.icloud.com" ;;
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

    echo -e "${colo} = snell, ${server_ip}, ${shadow_tls_port}, psk=${client_snell_psk}, version=4, reuse=${client_reuse_value}, tfo=${client_tfo_value}, shadow-tls-password=${shadow_tls_password}, shadow-tls-sni=${shadow_tls_tls_domain}, shadow-tls-version=3"
    msg ok "Shadow-TLS configuration completed."
}

# Install Snell and Shadow-TLS
install() {
    clear
    _blue_bg "┌─────────────────────────────────────────┐"
    _blue_bg "│  $(printf '%-39s' "Installation Options")│"
    _blue_bg "└─────────────────────────────────────────┘"
    echo ""
    
    _green "1) Install Snell and Shadow-TLS"
    _yellow "2) Install Snell Only"
    _cyan "3) Install Shadow-TLS Only"
    _red "0) Back to Main Menu"
    echo ""
    
    read -p "Please select an option [0-3]: " option

    case $option in
        1) install_all ;;
        2) install_snell ;;
        3) install_shadow_tls ;;
        0) menu ;;
        *) err "Invalid option" && sleep 2 && install ;;
    esac
}

# Install both Snell and Shadow-TLS
install_all() {
    if [[ -e "${snell_workspace}/snell-server" ]] || [[ -e "/usr/local/bin/shadow-tls" ]]; then
        read -rp "Snell or Shadow-TLS is already installed. Reinstall? (y/n): " input
        case "$input" in
            y|Y) uninstall_all ;;
            *) return 0 ;;
        esac
    fi

    # Detect IP only once
    get_ip
    
    # Install Snell (no longer detect IP in install_snell)
    install_snell_without_ip
    
    # Install Shadow-TLS (no longer detect IP in install_shadow_tls)
    install_shadow_tls_without_ip
    
    # Start services
    run
    msg ok "Snell and Shadow-TLS ${latest_version} deployment successful."
}

# Install Snell only without IP detection
install_snell_without_ip() {
    install_pkg

    msg info "Downloading Snell..."
    mkdir -p "${snell_workspace}"
    cd "${snell_workspace}" || exit 1
    
    # Get latest Snell version
    latest_version=$(curl -s https://manual.nssurge.com/others/snell.html | grep -oP 'snell-server-v\K[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
    if [ -z "$latest_version" ]; then
        latest_version="4.1.1"  # Fallback version
        msg warn "Failed to get latest version, using fallback version ${latest_version}"
    fi
    
    arch=$(uname -m)
    case $arch in
    x86_64) snell_url="https://dl.nssurge.com/snell/snell-server-v${latest_version}-linux-amd64.zip" ;;
    aarch64) snell_url="https://dl.nssurge.com/snell/snell-server-v${latest_version}-linux-aarch64.zip" ;;
    armv7l) snell_url="https://dl.nssurge.com/snell/snell-server-v${latest_version}-linux-armv7l.zip" ;;
    i386) snell_url="https://dl.nssurge.com/snell/snell-server-v${latest_version}-linux-i386.zip" ;;
    *) msg err "Unsupported architecture: $arch" && exit 1 ;;
    esac

    msg info "Downloading Snell version ${latest_version}..."
    wget -O snell-server.zip "${snell_url}"
    unzip -o snell-server.zip
    rm snell-server.zip
    chmod +x snell-server
    
    # Ensure snell user can execute the binary
    chown snell:snell snell-server

    create_snell_systemd
    create_snell_conf
    
    # Check if service started successfully
    if systemctl is-active --quiet snell; then
        _green "Snell service started successfully!"
        echo -e "${cyan}Configuration information: ${reset}"
        echo -e "Server: ${server_ip}"
        echo -e "Port: ${snell_port}"
        echo -e "PSK: ${snell_psk}"
        echo -e "Version: 4"
        echo ""

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

        echo -e "${cyan}Surge configuration example: ${reset}"
        echo -e "${colo} = snell, ${server_ip}, ${snell_port}, psk=${snell_psk}, version=4, reuse=${client_reuse_value}, tfo=${client_tfo_value}"
    else
        _red "Snell service failed to start, please check configuration or run the following commands to view logs:"
        echo -e "${yellow}systemctl status snell${reset}"
        echo -e "${yellow}journalctl -u snell -n 50${reset}"
    fi
    
    msg ok "Snell installation complete!"
}

# Install Snell only
install_snell() {
    # Detect IP
    get_ip
    
    # Install Snell
    install_snell_without_ip
    
    # Ask if installing ShadowTLS
    read -rp "Do you want to install ShadowTLS for enhanced security? (y/n): " install_shadow
    if [[ "$install_shadow" =~ ^[Yy]$ ]]; then
        install_shadow_tls_without_ip
    else
        echo -e "${yellow}You can install ShadowTLS later through the main menu${reset}"
    fi
    
    # Return to menu
    read -p "Press any key to return to the main menu..." _
    menu
}

# Install Shadow-TLS only without IP detection
install_shadow_tls_without_ip() {
    install_pkg

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

# Uninstall Snell and Shadow-TLS
uninstall() {
    clear
    _blue_bg "┌─────────────────────────────────────────┐"
    _blue_bg "│  $(printf '%-39s' "Uninstall Options")│"
    _blue_bg "└─────────────────────────────────────────┘"
    echo ""
    
    _red "1) Uninstall Snell and Shadow-TLS"
    _yellow "2) Uninstall Snell Only"
    _cyan "3) Uninstall Shadow-TLS Only"
    _green "0) Back to Main Menu"
    echo ""
    
    read -p "Please select an option [0-3]: " option

    case $option in
        1) uninstall_all ;;
        2) uninstall_snell ;;
        3) uninstall_shadow_tls ;;
        0) menu ;;
        *) err "Invalid option" && sleep 2 && uninstall ;;
    esac
}

# Uninstall both Snell and Shadow-TLS
uninstall_all() {
    uninstall_snell
    uninstall_shadow_tls
    msg ok "Snell and Shadow-TLS uninstalled."
}

# Uninstall Snell only
uninstall_snell() {
    systemctl stop snell
    systemctl disable snell
    rm -f "${snell_service}"
    rm -rf "${snell_workspace}"
    systemctl daemon-reload
    msg ok "Snell uninstalled."
}

# Uninstall Shadow-TLS only
uninstall_shadow_tls() {
    systemctl stop shadow-tls
    systemctl disable shadow-tls
    rm -f "${shadow_tls_service}"
    rm -rf "${shadow_tls_workspace}"
    rm -f "/usr/local/bin/shadow-tls"
    systemctl daemon-reload
    msg ok "Shadow-TLS uninstalled."
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
    _blue_bg "┌─────────────────────────────────────────┐"
    _blue_bg "│  $(printf '%-39s' "Service Logs")│"
    _blue_bg "└─────────────────────────────────────────┘"
    echo ""
    
    echo -e "${cyan}Recent Snell Logs:${reset}"
    journalctl -u snell --no-pager -n 20
    echo ""
    
    echo -e "${cyan}Recent Shadow-TLS Logs:${reset}"
    journalctl -u shadow-tls --no-pager -n 20
    echo ""
    
    read -p "Press any key to return..." _
}

# Modify Snell and Shadow-TLS configuration  
modify() {
    clear
    _blue_bg "┌─────────────────────────────────────────┐"
    _blue_bg "│  $(printf '%-39s' "Configuration Editor")│"
    _blue_bg "└─────────────────────────────────────────┘"
    echo ""
    
    _green "1) Modify Snell Configuration"
    _yellow "2) Modify Shadow-TLS Configuration"
    _red "0) Back to Main Menu"
    echo ""
    
    read -p "Please select an option [0-2]: " operation
    
    case $operation in  
        1) nano "${snell_workspace}/snell-server.conf" ;;
        2) nano "${shadow_tls_service}" ;;
        0) menu ;;  
        *) err "Invalid operation" && sleep 2 && modify ;;
    esac

    msg info "Don't forget to restart services to apply changes!"
    read -p "Press any key to continue..." _
}

# Manage Snell and Shadow-TLS services  
manage() {
    clear
    _blue_bg "┌─────────────────────────────────────────┐"
    _blue_bg "│  $(printf '%-39s' "Service Management")│"
    _blue_bg "└─────────────────────────────────────────┘"
    echo ""
    
    # Display service status
    check_snell_status
    
    _cyan "═════════════════════════════════════"
    _bold "$(_yellow "Management Options")"
    _cyan "═════════════════════════════════════"
    
    _green "1) Start Services" 
    _red "2) Stop Services"
    _yellow "3) Restart Services"
    _cyan "4) View Detailed Service Status"
    _magenta "5) View Service Logs"
    _blue_bg "6) Modify Configuration"
    _red "0) Back to Main Menu"
    echo ""
    
    read -p "Please select an option [0-6]: " operation
    
    case $operation in
        1) run && sleep 2 && manage ;;  
        2) stop && sleep 2 && manage ;;
        3) restart_services ;;
        4) check_service ;; 
        5) show_logs && manage ;;
        6) modify && manage ;; 
        0) menu ;;
        *) err "Invalid selection" && sleep 2 && manage ;;
    esac  
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
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity
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

# Display beautified main menu
menu() {  
    clear
    _blue_bg "┌─────────────────────────────────────────┐"
    _blue_bg "│  $(printf '%-39s' "ShadowTLS + Snell Management v${current_version}")│"
    _blue_bg "└─────────────────────────────────────────┘"
    echo ""
    
    # Display service status
    check_snell_status
    
    _cyan "═════════════════════════════════════"
    _bold "$(_yellow "MAIN MENU")"
    _cyan "═════════════════════════════════════"
    
    _green "1) Install Services"
    _red "2) Uninstall Services"
    _yellow "3) Manage Services"
    _cyan "4) Modify Configuration"
    _magenta "5) Display Configuration"
    _blue_bg "6) Update Snell"
    _red "0) Exit"
    echo ""
    
    echo -e "───────────────────────────────────────"
    
    read -p "Please select an option [0-6]: " operation

    case $operation in  
        1) install ;;
        2) uninstall ;;
        3) manage ;;
        4) modify ;;
        5) display_config ;;
        6) update_snell && menu ;;
        0) echo -e "${green}Thank you for using this script! Goodbye!${reset}" && exit 0 ;;
        *) err "Invalid selection" && sleep 2 && menu ;;
    esac
}

# New function to display configuration information
display_config() {
    clear
    _blue_bg "┌─────────────────────────────────────────┐"
    _blue_bg "│  $(printf '%-39s' "Configuration Display")│"
    _blue_bg "└─────────────────────────────────────────┘"
    echo ""
    
    if [[ ! -f "${snell_workspace}/snell-server.conf" ]]; then
        msg err "Snell not installed or configuration file not found"
        read -p "Press any key to return to the main menu..." _
        menu
        return
    fi
    
    # Display Snell configuration
    _cyan "═════════════════════════════════════"
    _bold "$(_yellow "Snell Configuration")"
    _cyan "═════════════════════════════════════"
    
    local snell_config=$(cat "${snell_workspace}/snell-server.conf")
    local snell_listen=$(echo "$snell_config" | grep -oP 'listen = \K.*')
    local snell_psk=$(echo "$snell_config" | grep -oP 'psk = \K.*')
    local snell_ipv6=$(echo "$snell_config" | grep -oP 'ipv6 = \K.*')
    
    echo -e "${green}Listen Address:${reset} $snell_listen"
    echo -e "${green}PSK:${reset} $snell_psk"
    echo -e "${green}IPv6 Support:${reset} $snell_ipv6"
    
    # Display ShadowTLS configuration (if exists)
    if systemctl is-active --quiet shadow-tls; then
        _cyan "═════════════════════════════════════"
        _bold "$(_yellow "ShadowTLS Configuration")"
        _cyan "═════════════════════════════════════"
        
        local shadow_tls_config=$(systemctl cat shadow-tls | grep ExecStart)
        local shadow_listen=$(echo "$shadow_tls_config" | grep -oP '\--listen \K[^ ]+')
        local shadow_server=$(echo "$shadow_tls_config" | grep -oP '\--server \K[^ ]+')
        local shadow_tls=$(echo "$shadow_tls_config" | grep -oP '\--tls \K[^ ]+')
        local shadow_password=$(echo "$shadow_tls_config" | grep -oP '\--password \K[^ ]+')
        
        echo -e "${green}Listen Address:${reset} $shadow_listen"
        echo -e "${green}Server Address:${reset} $shadow_server"
        echo -e "${green}TLS Domain:${reset} $shadow_tls"
        echo -e "${green}Password:${reset} $shadow_password"
        
        # Check if wildcard-sni is enabled
        if echo "$shadow_tls_config" | grep -q "wildcard-sni"; then
            echo -e "${green}Wildcard SNI:${reset} Enabled (Client can customize SNI)"
        else
            echo -e "${green}Wildcard SNI:${reset} Disabled"
        fi
        
        # Check if strict mode is enabled
        if echo "$shadow_tls_config" | grep -q "\--strict"; then
            echo -e "${green}Strict Mode:${reset} Enabled"
        else
            echo -e "${green}Strict Mode:${reset} Disabled"
        fi
    fi
    
    # Display client configuration
    _cyan "═════════════════════════════════════"
    _bold "$(_yellow "Client Configuration Example")"
    _cyan "═════════════════════════════════════"
    
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
        echo -e "${cyan}Surge Configuration:${reset}"
        echo -e "[Proxy]"
        echo -e "Snell = snell, ${server_ip}, ${shadow_port}, psk=${snell_psk}, version=4, reuse=${client_reuse_value}, tfo=${client_tfo_value}, shadow-tls-password=${shadow_password}, shadow-tls-sni=${shadow_tls%%:*}, shadow-tls-version=3"
    else
        echo -e "${cyan}Surge Configuration:${reset}"
        echo -e "[Proxy]"
        echo -e "Snell = snell, ${server_ip}, ${port}, psk=${snell_psk}, version=4, reuse=${client_reuse_value}, tfo=${client_tfo_value}"
    fi
    
    echo ""
    _yellow "Note: Please replace the server address in the configuration with the actual available address"
    
    echo ""
    read -p "Press any key to return to the main menu..." _
    menu
}

# Check Snell and ShadowTLS service status command
check_service() {
    clear
    _blue_bg "┌─────────────────────────────────────────┐"
    _blue_bg "│  $(printf '%-39s' "Detailed Service Status")│"
    _blue_bg "└─────────────────────────────────────────┘"
    echo ""
    
    echo -e "${yellow}Snell Service Status:${reset}"
    systemctl status snell
    
    echo -e "\n${yellow}ShadowTLS Service Status:${reset}"
    if systemctl is-active --quiet shadow-tls; then
        systemctl status shadow-tls
    else
        echo -e "${red}ShadowTLS is not installed or not running${reset}"
    fi
    
    echo -e "\n${yellow}Port Listening Status:${reset}"
    ss -tuln | grep -E ':(10000|2000|8388|443)'
    
    echo -e "\n${yellow}System Resource Usage:${reset}"
    echo -e "${green}CPU and Memory Usage:${reset}"
    ps -o pid,ppid,%cpu,%mem,cmd -p $(pgrep -f "snell-server") $(pgrep -f "shadow-tls")
    
    echo -e "\n${yellow}Recent Logs:${reset}"
    if [[ -f "/var/log/snell.log" ]]; then
        echo -e "${green}Snell Server Log (Last 10 lines):${reset}"
        tail -n 10 /var/log/snell.log
    fi
    
    echo -e "\n${green}Check completed!${reset}"
    
    read -p "Press any key to return..." _
    manage
}

# Restart services
restart_services() {
    clear
    _blue_bg "┌─────────────────────────────────────────┐"
    _blue_bg "│  $(printf '%-39s' "Restart Services")│"
    _blue_bg "└─────────────────────────────────────────┘"
    echo ""
    
    echo -e "${yellow}Restarting services...${reset}"
    
    # Restart Snell
    if systemctl is-active --quiet snell; then
        systemctl restart snell
        if systemctl is-active --quiet snell; then
            echo -e "${green}Snell service restarted successfully${reset}"
        else
            echo -e "${red}Snell service restart failed${reset}"
        fi
    else
        echo -e "${red}Snell service is not running${reset}"
    fi
    
    # Restart ShadowTLS
    if systemctl is-active --quiet shadow-tls; then
        systemctl restart shadow-tls
        if systemctl is-active --quiet shadow-tls; then
            echo -e "${green}ShadowTLS service restarted successfully${reset}"
        else
            echo -e "${red}ShadowTLS service restart failed${reset}"
        fi
    else
        echo -e "${yellow}ShadowTLS service is not installed or not running${reset}"
    fi
    
    echo -e "${cyan}═════════════════════════════════════${reset}"
    check_snell_status
    
    read -p "Press any key to return..." _
    manage
}

# Update Snell
update_snell() {
    if [[ ! -f "${snell_workspace}/snell-server" ]]; then
        msg err "Snell is not installed, cannot update."
        return
    fi

    # Get current version
    current_version=$("${snell_workspace}/snell-server" --version 2>&1 | grep -oP 'v\K[0-9]+\.[0-9]+\.[0-9]+')
    if [ -z "$current_version" ]; then
        msg err "Failed to get current Snell version."
        return
    fi
    msg info "Current Snell version: $current_version"

    # Get latest version
    latest_version=$(curl -s https://manual.nssurge.com/others/snell.html | grep -oP 'snell-server-v\K[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
    if [ -z "$latest_version" ]; then
        msg err "Failed to get latest Snell version."
        return
    fi
    msg info "Latest Snell version: $latest_version"

    if [[ "$current_version" == "$latest_version" ]]; then
        msg ok "Snell is already up-to-date."
        return
    fi

    msg info "New version of Snell found ($latest_version)."
    read -rp "Update now? (y/n): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        msg info "Update cancelled."
        return
    fi

    msg info "Updating Snell..."
    systemctl stop snell

    cd "${snell_workspace}" || exit 1
    
    arch=$(uname -m)
    case $arch in
    x86_64) snell_url="https://dl.nssurge.com/snell/snell-server-v${latest_version}-linux-amd64.zip" ;;
    aarch64) snell_url="https://dl.nssurge.com/snell/snell-server-v${latest_version}-linux-aarch64.zip" ;;
    armv7l) snell_url="https://dl.nssurge.com/snell/snell-server-v${latest_version}-linux-armv7l.zip" ;;
    i386) snell_url="https://dl.nssurge.com/snell/snell-server-v${latest_version}-linux-i386.zip" ;;
    *) msg err "Unsupported architecture: $arch" && exit 1 ;;
    esac

    msg info "Downloading Snell version ${latest_version}..."
    wget -O snell-server.zip "${snell_url}"
    if [ $? -ne 0 ]; then
        msg err "Failed to download Snell. Restarting old version."
        systemctl start snell
        return
    fi

    unzip -o snell-server.zip
    rm snell-server.zip
    chmod +x snell-server
    
    # Ensure snell user can execute the binary
    chown snell:snell snell-server

    systemctl start snell
    sleep 2
    if systemctl is-active --quiet snell; then
        new_version=$("${snell_workspace}/snell-server" --version 2>&1 | grep -oP 'v\K[0-9]+\.[0-9]+\.[0-9]+')
        msg ok "Snell updated successfully, current version: $new_version"
    else
        msg err "Failed to start Snell after update, please check logs."
    fi
}

# Script starts here  
menu 
