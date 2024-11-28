#!/bin/bash

# Define color codes
red='\e[31m'
green='\e[92m' 
yellow='\e[33m'  
reset='\e[0m'
underline='\e[4m'
blink='\e[5m'  
cyan='\e[96m'
purple='\e[35m'

# Color print functions
_red() { echo -e "${red}$@${reset}"; }
_green() { echo -e "${green}$@${reset}"; }
_yellow() { echo -e "${yellow}$@${reset}"; }  
_cyan() { echo -e "${cyan}$@${reset}"; }
_magenta() { echo -e "${purple}$@${reset}"; }  
_red_bg() { echo -e "\e[41m$@${reset}"; }

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
    apt-get update -y
    apt-get install -y dnsutils ${dependencies[@]}  
}

# Function to generate a random PSK
generate_random_psk() {
    tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32  
}

# Function to generate a random password  
generate_random_password() {
    tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16
}

# Function to find an unused port  
find_unused_port() {
    local port
    while :; do  
        port=$(shuf -i 10000-60000 -n 1)
        if ! ss -tuln | grep -q ":${port} " ; then
            echo $port  
            break
        fi
    done
}

# Function to check server IP (supports both IPv4 and IPv6)
get_ip() {
    trace_info_v4=$(curl -s4 https://cloudflare.com/cdn-cgi/trace)
    trace_info_v6=$(curl -s6 https://cloudflare.com/cdn-cgi/trace)
    ipv4=$(echo "$trace_info_v4" | grep -oP '(?<=ip=)[^\n]*')
    ipv6=$(echo "$trace_info_v6" | grep -oP '(?<=ip=)[^\n]*')
    colo=$(echo "$trace_info_v4" | grep -oP '(?<=colo=)[^\n]*')

    if [[ -n $ipv4 && -n $ipv6 ]]; then
        ip_type="both"
    elif [[ -n $ipv4 ]]; then
        ip_type="ipv4"
    elif [[ -n $ipv6 ]]; then
        ip_type="ipv6"
    else
        msg err "Unable to get server IP address." && exit 1
    fi

    server_ip=${ipv4:-$ipv6}

    if [[ -z $colo ]]; then
        msg err "Unable to retrieve DC location." && exit 1
    else
        msg ok "DC Location: ${colo}"
    fi
}

# Create systemd service file for Snell
create_snell_systemd() {
    cat > $snell_service << EOF
[Unit]
Description=Snell Proxy Service
After=network.target

[Service]
User=root
WorkingDirectory=${snell_workspace}
ExecStart=/bin/bash -c '${snell_workspace}/snell-server -c snell-server.conf 2>&1 | tee /var/log/snell.log'
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable snell
    msg ok "Snell systemd service created."
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
    read -rp "Enter custom DNS servers (comma-separated, leave blank for default): " custom_dns
    if [[ -n $custom_dns ]]; then
        dns_config="dns = $custom_dns"
    else
        dns_config=""
    fi

    # Configure IPv6 settings
    if [[ $ip_type == "both" ]]; then
        read -rp "Enable IPv6 support? (y/n): " enable_ipv6
        if [[ $enable_ipv6 =~ ^[Yy]$ ]]; then
            listen_addr="[::]:$snell_port"
            ipv6_enabled="true"
        else
            listen_addr="0.0.0.0:$snell_port"
            ipv6_enabled="false"
        fi
    elif [[ $ip_type == "ipv6" ]]; then
        listen_addr="[::]:$snell_port"
        ipv6_enabled="true"
    else
        listen_addr="0.0.0.0:$snell_port"
        ipv6_enabled="false"
    fi

    # Write the configuration file
    cat > "${snell_workspace}/snell-server.conf" << EOF
[snell-server]
listen = ${listen_addr}
psk = ${snell_psk}
ipv6 = ${ipv6_enabled}
${dns_config}
EOF

    msg ok "Snell configuration file created at ${snell_workspace}/snell-server.conf"
    systemctl start snell
    msg ok "Snell configuration established."
}

create_shadow_tls_systemd() {
    if [[ -z ${snell_port} ]]; then
        read -rp "Enter ShadowTLS forwarding port (Default: randomly select from unused ports): " shadow_tls_f_port
        [[ -z ${shadow_tls_f_port} ]] && shadow_tls_f_port=$(find_unused_port) && echo "[INFO] Randomly selected port for ShadowTLS forwarding: $shadow_tls_f_port"
    else
        shadow_tls_f_port=${snell_port}
        echo "[INFO] Using Snell port as ShadowTLS forwarding port: $shadow_tls_f_port"
    fi

    listen_addr=$([[ $ip_type == "ipv6" ]] && echo "[::]:${shadow_tls_port}" || echo "0.0.0.0:${shadow_tls_port}")
    server_addr=$([[ $ip_type == "ipv6" ]] && echo "[::1]:${shadow_tls_f_port}" || echo "127.0.0.1:${shadow_tls_f_port}")

    cat > $shadow_tls_service << EOF
[Unit]
Description=Shadow-TLS Proxy Service
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/shadow-tls --v3 --fastopen server --listen ${listen_addr} --server ${server_addr} --tls ${shadow_tls_tls_domain}:443 --password ${shadow_tls_password}
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
    #common_https_ports=(8443 2053 2083 2087 2096)
    #read -rp "Select a port for Shadow-TLS (Default: randomly select from common HTTPS ports): " shadow_tls_port
    read -rp "Select a port for Shadow-TLS (Default: randomly select from unused ports): " shadow_tls_port
    if [[ -z ${shadow_tls_port} ]]; then
        #shadow_tls_port=${common_https_ports[$RANDOM % ${#common_https_ports[@]}]}
        shadow_tls_port=$(find_unused_port)
        echo "[INFO] Randomly selected port for Shadow-TLS: $shadow_tls_port"
    fi
    read -rp "Enter TLS domain for Shadow-TLS (Default: gateway.icloud.com): " shadow_tls_tls_domain  
    [[ -z ${shadow_tls_tls_domain} ]] && shadow_tls_tls_domain="gateway.icloud.com"
    read -rp "Enter password for Shadow-TLS (Leave it blank to generate a random one): " shadow_tls_password
    [[ -z ${shadow_tls_password} ]] && shadow_tls_password=$(generate_random_password) && echo "[INFO] Generated a random password for Shadow-TLS: $shadow_tls_password"

    echo -e "${colo} = snell, ${server_ip}, ${shadow_tls_port}, psk=${snell_psk}, version=4, shadow-tls-password=${shadow_tls_password}, shadow-tls-sni=${shadow_tls_tls_domain}, shadow-tls-version=3"
    msg ok "Shadow-TLS configuration established."
}

# Install Snell and Shadow-TLS
install() {
    echo "1. Install Snell and Shadow-TLS"
    echo "2. Install Snell only"
    read -p "Select an option (1-2): " option

    case $option in
        1)
            install_all
            ;;
        2)
            install_snell
            ;;
        *)
            msg err "Invalid option"
            ;;
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

    install_snell
    install_shadow_tls
    get_ip
    run
    msg ok "Snell with Shadow-TLS ${latest_version} deployed successfully."
}

# Install Snell only
install_snell() {
    install_pkg

    msg info "Downloading Snell..."
    mkdir -p "${snell_workspace}"
    cd "${snell_workspace}" || exit 1
    
    # Get latest Snell version from Surge manual
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

    get_ip
    create_snell_systemd
    create_snell_conf
    echo -e "${colo} = snell, ${server_ip}, $snell_port, psk=${snell_psk}, version=4"
}

# Install Shadow-TLS only
install_shadow_tls() {
    install_pkg

    msg info "Downloading Shadow-TLS..."
    mkdir -p "${shadow_tls_workspace}"
    cd "${shadow_tls_workspace}" || exit 1

    # Get the latest release of Shadow-TLS from GitHub API
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

    get_ip
    config_shadow_tls
    create_shadow_tls_systemd
}

# Uninstall Snell and Shadow-TLS
uninstall() {
    echo "1. Uninstall Snell and Shadow-TLS"
    echo "2. Uninstall Snell only"
    read -p "Select an option (1-2): " option

    case $option in
        1)
            uninstall_all
            ;;
        2)
            uninstall_snell
            ;;
        *)
            msg err "Invalid option"
            ;;
    esac
}

# Uninstall both Snell and Shadow-TLS
uninstall_all() {
    uninstall_snell
    uninstall_shadow_tls
    msg ok "Snell and Shadow-TLS have been uninstalled."
}

# Uninstall Snell only
uninstall_snell() {
    systemctl stop snell
    systemctl disable snell
    rm -f "${snell_service}"
    rm -rf "${snell_workspace}"
    systemctl daemon-reload
    msg ok "Snell has been uninstalled."
}

# Uninstall Shadow-TLS only
uninstall_shadow_tls() {
    systemctl stop shadow-tls
    systemctl disable shadow-tls
    rm -f "${shadow_tls_service}"
    rm -rf "${shadow_tls_workspace}"
    rm -f "/usr/local/bin/shadow-tls"
    systemctl daemon-reload
    msg ok "Shadow-TLS has been uninstalled."
}

# Run Snell and Shadow-TLS  
run() {
    systemctl start snell  
    systemctl start shadow-tls
    sleep 2
    if systemctl is-active --quiet snell && systemctl is-active --quiet shadow-tls; then  
        msg ok "Snell and Shadow-TLS are running now."
    else
        msg err "Failed to start Snell or Shadow-TLS. Please check the logs."  
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
        msg err "Failed to restart Snell or Shadow-TLS. Please check the logs."
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

# Modify Snell and Shadow-TLS configuration  
modify() {
    _green "1. Modify Snell Configuration"
    _yellow "2. Modify Shadow-TLS Configuration"
    echo "3. Back to Main Menu"  
    read -p "Select operation (1-3): " operation
    
    case $operation in  
        1) nano "${snell_workspace}/snell-server.conf" ;;
        2) nano "${shadow_tls_service}" ;;
        3) menu ;;  
        *) msg err "Invalid operation." ;;
    esac

    msg ok "Don't forget to restart services to apply changes: ./snell-shadowtls.sh restart"  
}

# Manage Snell and Shadow-TLS services  
manage() {
    _green "1. Start" 
    _red "2. Stop"
    _yellow "3. Restart"
    echo "4. Modify Config"
    echo "5. Show Snell Log"
    echo "6. Back to Main Menu"  
    read -p "Select operation (1-6): " operation
    
    case $operation in
        1) run ;;  
        2) stop ;;
        3) restart ;;
        4) modify ;; 
        5) show_snell_log ;;
        6) menu ;;
        *) msg err "Invalid operation." ;;
    esac  
}


# Main menu
menu() {  
    _cyan "${cyan}${underline}${blink}Snell with Shadow-TLS, double the speed, double the fun!${reset}\n"
    _green "1. Install"
    _red "2. Uninstall"
    _yellow "3. Manage"
    echo "4. Exit"  
    read -p "Select operation (1-4): " operation

    case $operation in  
        1) install ;;
        2) uninstall ;;
        3) manage ;;
        4) exit 0 ;;  
        *) msg err "Invalid operation." ;;
    esac
}

# Script starts here  
menu 