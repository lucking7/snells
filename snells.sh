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

# 检查Snell服务状态
check_snell_status() {
    echo -e "${cyan}═════════════════════════════════════${reset}"
    echo -e "${cyan}            服务状态检查             ${reset}"
    echo -e "${cyan}═════════════════════════════════════${reset}"
    
    if systemctl is-active --quiet snell; then
        echo -e "Snell 服务: ${green}运行中${reset}"
    else
        echo -e "Snell 服务: ${red}未运行${reset}"
    fi
    
    if systemctl is-active --quiet shadow-tls; then
        echo -e "Shadow-TLS 服务: ${green}运行中${reset}"
    else
        echo -e "Shadow-TLS 服务: ${red}未运行${reset} 或 ${yellow}未安装${reset}"
    fi
    
    # 检查端口占用情况
    if [[ -f "${snell_workspace}/snell-server.conf" ]]; then
        local snell_port=$(grep -oP 'listen = .*?:(\d+)' "${snell_workspace}/snell-server.conf" | grep -oP '\d+$')
        if [[ -n "$snell_port" ]]; then
            if ss -tuln | grep -q ":${snell_port} "; then
                echo -e "Snell 端口 ${snell_port}: ${green}已开放${reset}"
            else
                echo -e "Snell 端口 ${snell_port}: ${red}未开放${reset}"
            fi
        fi
    fi
    
    echo
}

# Function to check server IP (supports both IPv4 and IPv6)
get_ip() {
    # 为IPv4添加超时
    trace_info_v4=$(curl -s4 --connect-timeout 5 https://cloudflare.com/cdn-cgi/trace)
    # 为IPv6添加超时：--connect-timeout 5秒连接超时, --max-time 10秒总超时
    trace_info_v6=$(curl -s6 --connect-timeout 5 --max-time 10 https://cloudflare.com/cdn-cgi/trace)
    ipv4=$(echo "$trace_info_v4" | grep -oP '(?<=ip=)[^\n]*')
    ipv6=$(echo "$trace_info_v6" | grep -oP '(?<=ip=)[^\n]*')
    colo=$(echo "$trace_info_v4" | grep -oP '(?<=colo=)[^\n]*')

    if [[ -n $ipv4 && -n $ipv6 ]]; then
        ip_type="both"
    elif [[ -n $ipv4 ]]; then
        ip_type="ipv4"
        msg info "IPv6不可用或检测超时."
    elif [[ -n $ipv6 ]]; then
        ip_type="ipv6"
    else
        msg err "无法获取服务器IP地址." && exit 1
    fi

    server_ip=${ipv4:-$ipv6}

    if [[ -z $colo ]]; then
        # 尝试从IPv6信息中获取colo
        colo=$(echo "$trace_info_v6" | grep -oP '(?<=colo=)[^\n]*')
        if [[ -z $colo ]]; then
            msg warn "无法获取数据中心位置，使用默认设置."
            colo="unknown"
        else
            msg ok "数据中心位置: ${colo}"
        fi
    else
        msg ok "数据中心位置: ${colo}"
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
        # 设置默认DNS，根据是否启用IPv6来决定使用哪些DNS服务器
        if [[ $ip_type == "both" || $ip_type == "ipv6" ]]; then
            # 带IPv6的默认DNS (Cloudflare + Google)
            dns_config="dns = 1.1.1.1, 8.8.8.8, 2606:4700:4700::1111, 2001:4860:4860::8888"
            msg info "使用默认DNS (Cloudflare + Google，包含IPv6)"
        else
            # 仅IPv4的默认DNS (Cloudflare + Google)
            dns_config="dns = 1.1.1.1, 8.8.8.8"
            msg info "使用默认DNS (Cloudflare + Google，仅IPv4)"
        fi
    fi

    # 询问是否仅监听本地地址
    read -rp "是否仅监听本地地址？(y/n, 推荐使用Shadow-TLS时选择y): " local_only
    if [[ $local_only =~ ^[Yy]$ ]]; then
        if [[ $ip_type == "ipv6" ]]; then
            listen_addr="[::1]:$snell_port"
        else
            listen_addr="127.0.0.1:$snell_port"
        fi
        msg info "配置Snell仅监听本地地址: $listen_addr"
    else
        # Configure IPv6 settings
        if [[ $ip_type == "both" ]]; then
            read -rp "Enable IPv6 support? (y/n): " enable_ipv6
            if [[ $enable_ipv6 =~ ^[Yy]$ ]]; then
                listen_addr="::0:$snell_port"
                ipv6_enabled="true"
                
                # 如果启用IPv6但用户使用了自定义DNS，提醒可能需要包含IPv6 DNS
                if [[ -n $custom_dns ]] && ! [[ $custom_dns =~ ":" ]]; then
                    msg warn "您启用了IPv6但DNS中似乎没有包含IPv6地址，这可能会影响IPv6连接"
                    read -rp "是否添加IPv6 DNS？(y/n): " add_ipv6_dns
                    if [[ $add_ipv6_dns =~ ^[Yy]$ ]]; then
                        dns_config="dns = $custom_dns, 2606:4700:4700::1111, 2001:4860:4860::8888"
                        msg info "已添加Cloudflare和Google的IPv6 DNS"
                    fi
                fi
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

    # 询问是否启用TFO
    read -rp "是否启用TFO(TCP Fast Open)? (y/n): " enable_tfo
    if [[ $enable_tfo =~ ^[Yy]$ ]]; then
        tfo_config="tfo = true"
        msg info "已启用TCP Fast Open"
    else
        tfo_config="tfo = false"
    fi

    # Write the configuration file
    cat > "${snell_workspace}/snell-server.conf" << EOF
[snell-server]
listen = ${listen_addr}
psk = ${snell_psk}
ipv6 = ${ipv6_enabled:-true}
${tfo_config}
${dns_config}
EOF

    msg ok "Snell 配置文件已创建: ${snell_workspace}/snell-server.conf"
    systemctl start snell
    msg ok "Snell 配置已完成."
}

create_shadow_tls_systemd() {
    if [[ -z ${snell_port} ]]; then
        read -rp "输入ShadowTLS转发端口 (默认: 随机选择未使用端口): " shadow_tls_f_port
        [[ -z ${shadow_tls_f_port} ]] && shadow_tls_f_port=$(find_unused_port) && echo "[INFO] 为ShadowTLS转发随机选择端口: $shadow_tls_f_port"
    else
        shadow_tls_f_port=${snell_port}
        echo "[INFO] 使用Snell端口作为ShadowTLS转发端口: $shadow_tls_f_port"
    fi

    # 根据IPv6支持确定监听地址
    if [[ $ip_type == "both" ]]; then
        read -rp "是否启用IPv6监听? (y/n): " ipv6_listen
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

    # 设置转发地址
    if [[ $ip_type == "ipv6" ]]; then
        server_addr="[::1]:${shadow_tls_f_port}" 
    else
        server_addr="127.0.0.1:${shadow_tls_f_port}"
    fi

    # 询问是否启用wildcard-sni
    read -rp "是否启用wildcard-sni? (y/n, 可使客户端自定义SNI): " enable_wildcard
    if [[ $enable_wildcard =~ ^[Yy]$ ]]; then
        wildcard_option="--wildcard-sni=authed"
        msg info "已启用wildcard-sni，客户端可自定义SNI"
    else
        wildcard_option=""
    fi

    # 询问是否启用strict模式
    read -rp "是否启用TLS strict模式? (y/n, 增强安全性): " enable_strict
    if [[ $enable_strict =~ ^[Yy]$ ]]; then
        strict_option="--strict"
        msg info "已启用strict模式，增强TLS握手安全性"
    else
        strict_option=""
    fi

    cat > $shadow_tls_service << EOF
[Unit]
Description=Shadow-TLS Server Service
After=network-online.target
Wants=network-online.target systemd-networkd-wait-online.service

[Service]
LimitNOFILE=32767
Type=simple
User=root
Restart=on-failure
RestartSec=5s
ExecStartPre=/bin/sh -c ulimit -n 51200
ExecStart=/usr/local/bin/shadow-tls --fastopen --v3 ${strict_option} server ${wildcard_option} --listen ${listen_addr} --server ${server_addr} --tls ${shadow_tls_tls_domain}:443 --password ${shadow_tls_password} 

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable shadow-tls
    msg ok "Shadow-TLS 系统服务已创建."
}

# Configure Shadow-TLS  
config_shadow_tls() { 
    read -rp "为Shadow-TLS选择端口 (默认: 443): " shadow_tls_port
    if [[ -z ${shadow_tls_port} ]]; then
        shadow_tls_port="443"
        echo "[INFO] 使用默认端口443作为Shadow-TLS端口"
    fi
    
    echo -e "${yellow}推荐的TLS域名列表 (支持TLS 1.3):${reset}"
    echo -e "1) gateway.icloud.com (苹果服务)"
    echo -e "2) p11.douyinpic.com (抖音相关，推荐用于免流)"
    echo -e "3) mp.weixin.qq.com (微信相关)"
    echo -e "4) sns-img-qc.xhscdn.com (小红书相关)"
    echo -e "5) p9-dy.byteimg.com (字节相关)"
    echo -e "6) weather-data.apple.com (苹果天气服务)"
    echo -e "7) 自定义"
    read -rp "请选择TLS域名 [1-7]: " domain_choice
    
    case $domain_choice in
        1) shadow_tls_tls_domain="gateway.icloud.com" ;;
        2) shadow_tls_tls_domain="p11.douyinpic.com" ;;
        3) shadow_tls_tls_domain="mp.weixin.qq.com" ;;
        4) shadow_tls_tls_domain="sns-img-qc.xhscdn.com" ;;
        5) shadow_tls_tls_domain="p9-dy.byteimg.com" ;;
        6) shadow_tls_tls_domain="weather-data.apple.com" ;;
        7) 
            read -rp "请输入自定义TLS域名: " shadow_tls_tls_domain
            [[ -z ${shadow_tls_tls_domain} ]] && shadow_tls_tls_domain="gateway.icloud.com"
            ;;
        *) shadow_tls_tls_domain="gateway.icloud.com" ;;
    esac
    
    read -rp "输入Shadow-TLS的密码 (留空则随机生成): " shadow_tls_password
    [[ -z ${shadow_tls_password} ]] && shadow_tls_password=$(generate_random_password) && echo "[INFO] 为Shadow-TLS生成随机密码: $shadow_tls_password"

    # 为客户端配置确定Snell PSK
    local client_snell_psk="${snell_psk}" # 优先使用当前脚本运行中设置的PSK
    if [[ -z "${client_snell_psk}" && -f "${snell_workspace}/snell-server.conf" ]]; then
        # 如果当前没有PSK且配置文件存在，则从中读取
        client_snell_psk=$(grep -oP 'psk = \K.*' "${snell_workspace}/snell-server.conf")
    fi

    # 为客户端配置确定TFO设置
    local client_tfo_value="true" # 默认值，如果无法从配置文件读取
    if [[ -f "${snell_workspace}/snell-server.conf" ]]; then
        local current_tfo_setting=$(grep -oP 'tfo = \K(true|false)' "${snell_workspace}/snell-server.conf")
        if [[ -n "$current_tfo_setting" ]]; then
            client_tfo_value="$current_tfo_setting"
        fi
    fi

    echo -e "${colo} = snell, ${server_ip}, ${shadow_tls_port}, psk=${client_snell_psk}, version=4, reuse=true, tfo=${client_tfo_value}, shadow-tls-password=${shadow_tls_password}, shadow-tls-sni=${shadow_tls_tls_domain}, shadow-tls-version=3"
    msg ok "Shadow-TLS 配置已完成."
}

# Install Snell and Shadow-TLS
install() {
    echo "1. 安装 Snell 和 Shadow-TLS"
    echo "2. 仅安装 Snell"
    read -p "选择一个选项 (1-2): " option

    case $option in
        1)
            install_all
            ;;
        2)
            install_snell
            ;;
        *)
            msg err "无效选项"
            ;;
    esac
}

# Install both Snell and Shadow-TLS
install_all() {
    if [[ -e "${snell_workspace}/snell-server" ]] || [[ -e "/usr/local/bin/shadow-tls" ]]; then
        read -rp "Snell 或 Shadow-TLS 已安装。重新安装? (y/n): " input
        case "$input" in
            y|Y) uninstall_all ;;
            *) return 0 ;;
        esac
    fi

    # 先检测IP，只检测一次
    get_ip
    
    # 安装Snell (不再在install_snell中检测IP)
    install_snell_without_ip
    
    # 安装Shadow-TLS (不再在install_shadow_tls中检测IP)
    install_shadow_tls_without_ip
    
    # 启动服务
    run
    msg ok "Snell 与 Shadow-TLS ${latest_version} 部署成功."
}

# Install Snell only without IP detection
install_snell_without_ip() {
    install_pkg

    msg info "下载 Snell..."
    mkdir -p "${snell_workspace}"
    cd "${snell_workspace}" || exit 1
    
    # 获取最新Snell版本
    latest_version=$(curl -s https://manual.nssurge.com/others/snell.html | grep -oP 'snell-server-v\K[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
    if [ -z "$latest_version" ]; then
        latest_version="4.1.1"  # 兜底版本
        msg warn "无法获取最新版本，使用兜底版本 ${latest_version}"
    fi
    
    arch=$(uname -m)
    case $arch in
    x86_64) snell_url="https://dl.nssurge.com/snell/snell-server-v${latest_version}-linux-amd64.zip" ;;
    aarch64) snell_url="https://dl.nssurge.com/snell/snell-server-v${latest_version}-linux-aarch64.zip" ;;
    armv7l) snell_url="https://dl.nssurge.com/snell/snell-server-v${latest_version}-linux-armv7l.zip" ;;
    i386) snell_url="https://dl.nssurge.com/snell/snell-server-v${latest_version}-linux-i386.zip" ;;
    *) msg err "不支持的架构: $arch" && exit 1 ;;
    esac

    msg info "下载 Snell 版本 ${latest_version}..."
    wget -O snell-server.zip "${snell_url}"
    unzip -o snell-server.zip
    rm snell-server.zip
    chmod +x snell-server

    create_snell_systemd
    create_snell_conf
    
    # 判断服务是否成功启动
    if systemctl is-active --quiet snell; then
        _green "Snell 服务已成功启动!"
        echo -e "${cyan}配置信息: ${reset}"
        echo -e "服务器: ${server_ip}"
        echo -e "端口: ${snell_port}"
        echo -e "PSK: ${snell_psk}"
        echo -e "版本: 4"
        echo ""
        echo -e "${cyan}Surge配置示例: ${reset}"
        echo -e "${colo} = snell, ${server_ip}, ${snell_port}, psk=${snell_psk}, version=4"
    else
        _red "Snell 服务启动失败，请检查配置或执行以下命令查看日志:"
        echo -e "${yellow}systemctl status snell${reset}"
        echo -e "${yellow}journalctl -u snell -n 50${reset}"
    fi
    
    msg ok "Snell 安装完成!"
}

# Install Snell only
install_snell() {
    # 先检测IP
    get_ip
    
    # 安装Snell
    install_snell_without_ip
    
    # 提示是否安装ShadowTLS
    read -rp "是否同时安装ShadowTLS增强安全性？(y/n): " install_shadow
    if [[ "$install_shadow" =~ ^[Yy]$ ]]; then
        install_shadow_tls_without_ip
    else
        echo -e "${yellow}您可以稍后通过主菜单安装ShadowTLS${reset}"
    fi
    
    # 返回菜单
    read -p "按任意键返回主菜单..." _
    menu
}

# Install Shadow-TLS only without IP detection
install_shadow_tls_without_ip() {
    install_pkg

    msg info "下载 Shadow-TLS..."
    mkdir -p "${shadow_tls_workspace}"
    cd "${shadow_tls_workspace}" || exit 1

    # 获取Shadow-TLS最新版本
    latest_release=$(wget -qO- https://api.github.com/repos/ihciah/shadow-tls/releases/latest)
    latest_version=$(echo "$latest_release" | jq -r '.tag_name')
    arch=$(uname -m)
    case $arch in
        x86_64) shadow_tls_url=$(echo "$latest_release" | jq -r '.assets[] | select(.name | contains("x86_64-unknown-linux-musl")) | .browser_download_url') ;;
        aarch64) shadow_tls_url=$(echo "$latest_release" | jq -r '.assets[] | select(.name | contains("aarch64-unknown-linux-musl")) | .browser_download_url') ;;
        *) msg err "不支持的架构: $arch" && exit 1 ;;
    esac

    wget -O shadow-tls "${shadow_tls_url}"
    chmod +x shadow-tls
    mv shadow-tls /usr/local/bin/

    config_shadow_tls
    create_shadow_tls_systemd
}

# Install Shadow-TLS only
install_shadow_tls() {
    # 先检测IP
    get_ip
    
    # 安装Shadow-TLS
    install_shadow_tls_without_ip
}

# Uninstall Snell and Shadow-TLS
uninstall() {
    echo "1. 卸载 Snell 和 Shadow-TLS"
    echo "2. 仅卸载 Snell"
    read -p "选择一个选项 (1-2): " option

    case $option in
        1)
            uninstall_all
            ;;
        2)
            uninstall_snell
            ;;
        *)
            msg err "无效选项"
            ;;
    esac
}

# Uninstall both Snell and Shadow-TLS
uninstall_all() {
    uninstall_snell
    uninstall_shadow_tls
    msg ok "Snell 和 Shadow-TLS 已卸载."
}

# Uninstall Snell only
uninstall_snell() {
    systemctl stop snell
    systemctl disable snell
    rm -f "${snell_service}"
    rm -rf "${snell_workspace}"
    systemctl daemon-reload
    msg ok "Snell 已卸载."
}

# Uninstall Shadow-TLS only
uninstall_shadow_tls() {
    systemctl stop shadow-tls
    systemctl disable shadow-tls
    rm -f "${shadow_tls_service}"
    rm -rf "${shadow_tls_workspace}"
    rm -f "/usr/local/bin/shadow-tls"
    systemctl daemon-reload
    msg ok "Shadow-TLS 已卸载."
}

# Run Snell and Shadow-TLS  
run() {
    systemctl start snell  
    systemctl start shadow-tls
    sleep 2
    if systemctl is-active --quiet snell && systemctl is-active --quiet shadow-tls; then  
        msg ok "Snell 和 Shadow-TLS 现在正在运行."
    else
        msg err "启动 Snell 或 Shadow-TLS 失败，请检查日志."  
    fi
}

# Stop Snell and Shadow-TLS
stop() {  
    systemctl stop snell
    systemctl stop shadow-tls
    msg ok "Snell 和 Shadow-TLS 已停止."  
}

# Restart Snell and Shadow-TLS  
restart() {
    systemctl restart snell
    systemctl restart shadow-tls  
    sleep 2
    if systemctl is-active --quiet snell && systemctl is-active --quiet shadow-tls; then
        msg ok "Snell 和 Shadow-TLS 已重启."  
    else
        msg err "重启 Snell 或 Shadow-TLS 失败，请检查日志."
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
    clear
    _blue_bg "┌─────────────────────────────────────────┐"
    _blue_bg "│  $(printf '%-36s' "服务管理")  │"
    _blue_bg "└─────────────────────────────────────────┘"
    echo ""
    
    # 显示服务状态
    check_snell_status
    
    _cyan "═════════════════════════════════════"
    _bold "$(_yellow "管理选项")"
    _cyan "═════════════════════════════════════"
    
    _green "1) 启动服务" 
    _red "2) 停止服务"
    _yellow "3) 重启服务"
    _cyan "4) 查看详细服务状态"
    _magenta "5) 查看服务日志"
    _yellow "6) 修改配置"
    _red "0) 返回主菜单"
    echo ""
    
    read -p "请输入选择 [0-6]: " operation
    
    case $operation in
        1) run && manage ;;  
        2) stop && manage ;;
        3) restart_services ;;
        4) check_service ;; 
        5) show_snell_log && manage ;;
        6) modify && manage ;; 
        0) menu ;;
        *) err "无效选择" && sleep 2 && manage ;;
    esac  
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
    msg ok "Snell 系统服务已创建."
}

# 显示美化后的主菜单
menu() {  
    clear
    _blue_bg "┌─────────────────────────────────────────┐"
    _blue_bg "│  $(printf '%-36s' "ShadowTLS + Snell 管理脚本 v${current_version}")  │"
    _blue_bg "└─────────────────────────────────────────┘"
    echo ""
    
    # 显示服务状态
    check_snell_status
    
    _cyan "═════════════════════════════════════"
    _bold "$(_yellow "主菜单")"
    _cyan "═════════════════════════════════════"
    
    _green "1) 安装"
    _red "2) 卸载"
    _yellow "3) 管理"
    _cyan "4) 修改配置"
    _magenta "5) 显示配置信息"
    _red "0) 退出"
    echo ""
    
    echo -e "───────────────────────────────────────"
    
    read -p "请输入选择 [0-5]: " operation

    case $operation in  
        1) install ;;
        2) uninstall ;;
        3) manage ;;
        4) modify ;;
        5) display_config ;;
        0) echo -e "${green}再见!${reset}" && exit 0 ;;
        *) err "无效选择" && sleep 2 && menu ;;
    esac
}

# 新增显示配置信息函数
display_config() {
    clear
    _blue_bg "┌─────────────────────────────────────────┐"
    _blue_bg "│  $(printf '%-36s' "Snell + ShadowTLS 配置信息")  │"
    _blue_bg "└─────────────────────────────────────────┘"
    echo ""
    
    if [[ ! -f "${snell_workspace}/snell-server.conf" ]]; then
        msg err "Snell未安装或配置文件不存在"
        read -p "按任意键返回主菜单..." _
        menu
        return
    fi
    
    # 显示Snell配置
    _cyan "═════════════════════════════════════"
    _bold "$(_yellow "Snell 配置")"
    _cyan "═════════════════════════════════════"
    
    local snell_config=$(cat "${snell_workspace}/snell-server.conf")
    local snell_listen=$(echo "$snell_config" | grep -oP 'listen = \K.*')
    local snell_psk=$(echo "$snell_config" | grep -oP 'psk = \K.*')
    local snell_ipv6=$(echo "$snell_config" | grep -oP 'ipv6 = \K.*')
    local snell_tfo=$(echo "$snell_config" | grep -oP 'tfo = \K.*' || echo "false")
    
    echo -e "${green}监听地址:${reset} $snell_listen"
    echo -e "${green}PSK密钥:${reset} $snell_psk"
    echo -e "${green}IPv6支持:${reset} $snell_ipv6"
    echo -e "${green}TCP Fast Open:${reset} $snell_tfo"
    
    # 显示ShadowTLS配置（如果存在）
    if systemctl is-active --quiet shadow-tls; then
        _cyan "═════════════════════════════════════"
        _bold "$(_yellow "ShadowTLS 配置")"
        _cyan "═════════════════════════════════════"
        
        local shadow_tls_config=$(systemctl cat shadow-tls | grep ExecStart)
        local shadow_listen=$(echo "$shadow_tls_config" | grep -oP '\--listen \K[^ ]+')
        local shadow_server=$(echo "$shadow_tls_config" | grep -oP '\--server \K[^ ]+')
        local shadow_tls=$(echo "$shadow_tls_config" | grep -oP '\--tls \K[^ ]+')
        local shadow_password=$(echo "$shadow_tls_config" | grep -oP '\--password \K[^ ]+')
        
        echo -e "${green}监听地址:${reset} $shadow_listen"
        echo -e "${green}服务器地址:${reset} $shadow_server"
        echo -e "${green}TLS域名:${reset} $shadow_tls"
        echo -e "${green}密码:${reset} $shadow_password"
        
        # 检查是否启用了wildcard-sni
        if echo "$shadow_tls_config" | grep -q "wildcard-sni"; then
            echo -e "${green}通配符SNI:${reset} 已启用 (客户端可自定义SNI)"
        else
            echo -e "${green}通配符SNI:${reset} 未启用"
        fi
        
        # 检查是否启用了strict模式
        if echo "$shadow_tls_config" | grep -q "\--strict"; then
            echo -e "${green}Strict模式:${reset} 已启用"
        else
            echo -e "${green}Strict模式:${reset} 未启用"
        fi
    fi
    
    # 显示客户端配置
    _cyan "═════════════════════════════════════"
    _bold "$(_yellow "客户端配置示例")"
    _cyan "═════════════════════════════════════"
    
    # 获取服务器IP
    local server_ip=$(curl -s4 --connect-timeout 5 https://api.ipify.org)
    if [[ -z "$server_ip" ]]; then
        server_ip=$(curl -s6 --connect-timeout 5 https://api6.ipify.org)
    fi
    
    local port=$(echo "$snell_listen" | grep -oP ':\K\d+$')
    
    if systemctl is-active --quiet shadow-tls; then
        local shadow_port=$(echo "$shadow_listen" | grep -oP ':\K\d+$')
        echo -e "${cyan}Surge配置:${reset}"
        echo -e "[Proxy]"
        echo -e "Snell = snell, ${server_ip}, ${shadow_port}, psk=${snell_psk}, version=4, reuse=true, tfo=${snell_tfo}, shadow-tls-password=${shadow_password}, shadow-tls-sni=${shadow_tls%%:*}, shadow-tls-version=3"
    else
        echo -e "${cyan}Surge配置:${reset}"
        echo -e "[Proxy]"
        echo -e "Snell = snell, ${server_ip}, ${port}, psk=${snell_psk}, version=4, reuse=true, tfo=${snell_tfo}"
    fi
    
    echo ""
    _yellow "注意: 请将配置中的服务器地址替换为实际可用的地址"
    
    echo ""
    read -p "按任意键返回主菜单..." _
    menu
}

# 检查Snell和ShadowTLS服务状态命令
check_service() {
    clear
    echo -e "${cyan}═════════════════════════════════════${reset}"
    echo -e "${cyan}          服务状态详细信息           ${reset}"
    echo -e "${cyan}═════════════════════════════════════${reset}"
    
    echo -e "${yellow}Snell 服务状态:${reset}"
    systemctl status snell
    
    echo -e "\n${yellow}ShadowTLS 服务状态:${reset}"
    if systemctl is-active --quiet shadow-tls; then
        systemctl status shadow-tls
    else
        echo -e "${red}ShadowTLS 未安装或未运行${reset}"
    fi
    
    echo -e "\n${yellow}端口监听状态:${reset}"
    ss -tuln | grep -E ':(10000|2000|8388|443)'
    
    echo -e "\n${yellow}系统资源使用:${reset}"
    echo -e "${green}CPU和内存使用:${reset}"
    ps -o pid,ppid,%cpu,%mem,cmd -p $(pgrep -f "snell-server") $(pgrep -f "shadow-tls")
    
    echo -e "\n${yellow}最近日志:${reset}"
    if [[ -f "/var/log/snell.log" ]]; then
        echo -e "${green}Snell 日志 (最后10行):${reset}"
        tail -n 10 /var/log/snell.log
    fi
    
    echo -e "\n${green}检查完成!${reset}"
    
    read -p "按任意键返回..." _
    manage
}

# 重启服务
restart_services() {
    clear
    echo -e "${cyan}═════════════════════════════════════${reset}"
    echo -e "${cyan}            重启服务                 ${reset}"
    echo -e "${cyan}═════════════════════════════════════${reset}"
    
    echo -e "${yellow}正在重启服务...${reset}"
    
    # 重启Snell
    if systemctl is-active --quiet snell; then
        systemctl restart snell
        if systemctl is-active --quiet snell; then
            echo -e "${green}Snell 服务已成功重启${reset}"
        else
            echo -e "${red}Snell 服务重启失败${reset}"
        fi
    else
        echo -e "${red}Snell 服务未运行${reset}"
    fi
    
    # 重启ShadowTLS
    if systemctl is-active --quiet shadow-tls; then
        systemctl restart shadow-tls
        if systemctl is-active --quiet shadow-tls; then
            echo -e "${green}ShadowTLS 服务已成功重启${reset}"
        else
            echo -e "${red}ShadowTLS 服务重启失败${reset}"
        fi
    else
        echo -e "${yellow}ShadowTLS 服务未安装或未运行${reset}"
    fi
    
    echo -e "${cyan}═════════════════════════════════════${reset}"
    check_snell_status
    
    read -p "按任意键返回..." _
    manage
}

# Script starts here  
menu 
