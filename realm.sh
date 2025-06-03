#!/bin/bash

# 启用严格模式 - 脚本最佳实践
set -o errexit  # 任何命令失败即退出
set -o nounset  # 引用未设置的变量即退出
set -o pipefail # 管道中任何命令失败即视为失败

# 颜色定义
GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[0;33m"
BLUE="\033[0;34m"
BOLD="\033[1m" 
NC="\033[0m" # 无颜色

# 配置路径变量
CONFIG_PATH="/root/.realm/config.toml"
REALM_DIR="/root/realm"
REALM_CONFIG_DIR="/root/.realm"

# 检查依赖函数
require_command() {
    if ! command -v "$1" &> /dev/null; then
        echo -e "${RED}Error: '$1' command not found. Please install it and rerun the script.${NC}"
        exit 1
    fi
}

# 必要依赖检查
require_command curl
require_command lsof
require_command systemctl
require_command tar
require_command wget

# 检查jq可用性
use_jq=false
if command -v jq &> /dev/null; then
    use_jq=true
fi

# 验证端口号函数
validate_port() {
    local port=$1
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        return 1
    fi
    return 0
}

# 验证IP地址函数
validate_ip() {
    local ip=$1
    # 简单的IPv4验证
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        return 0
    fi
    # 简单的IPv6验证
    if [[ $ip =~ : ]]; then
        return 0
    fi
    # 域名验证
    if [[ $ip =~ ^[a-zA-Z0-9.-]+$ ]]; then
        return 0
    fi
    return 1
}

# 检查端口是否被占用
is_port_in_use() {
    local port=$1
    if lsof -i :"$port" > /dev/null 2>&1; then
        return 0  # 端口被占用
    fi
    return 1  # 端口未被占用
}

# 部署 Realm
deploy_realm() {
    echo -e "${YELLOW}Starting Realm deployment...${NC}"
    mkdir -p "$REALM_DIR" && cd "$REALM_DIR" || { echo -e "${RED}Failed to access directory $REALM_DIR${NC}"; exit 1; }
    
    # 从GitHub API获取最新版本
    local api_response
    echo -e "${YELLOW}Fetching latest version information...${NC}"
    api_response=$(curl -s https://api.github.com/repos/zhboner/realm/releases/latest)

    if $use_jq && command -v jq &> /dev/null; then
        _version=$(echo "$api_response" | jq -r '.tag_name // ""')
    else
        _version=$(echo "$api_response" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    fi
    
    if [ -z "$_version" ]; then
        echo -e "${RED}Failed to get version number. Please check if you can connect to GitHub API.${NC}"
        echo -e "${YELLOW}Falling back to default version v2.6.2${NC}"
        _version="v2.6.2" # 回退版本
    else
        echo -e "${GREEN}Latest version: ${_version}${NC}"
    fi
    
    # 检测系统架构和操作系统
    arch=$(uname -m)
    os_type=$(uname -s | tr '[:upper:]' '[:lower:]')
    
    # 根据架构选择下载URL
    download_url=""
    case "$arch-$os_type" in
        x86_64-linux)
            download_url="https://github.com/zhboner/realm/releases/download/${_version}/realm-x86_64-unknown-linux-gnu.tar.gz"
            ;;
        aarch64-linux)
            download_url="https://github.com/zhboner/realm/releases/download/${_version}/realm-aarch64-unknown-linux-gnu.tar.gz"
            ;;
        armv7l-linux | arm-linux)
            download_url="https://github.com/zhboner/realm/releases/download/${_version}/realm-arm-unknown-linux-gnueabi.tar.gz"
            ;;
        *)
            echo -e "${YELLOW}Unsupported architecture or OS: $arch-$os_type. Attempting x86_64-linux-gnu as default.${NC}"
            download_url="https://github.com/zhboner/realm/releases/download/${_version}/realm-x86_64-unknown-linux-gnu.tar.gz"
            ;;
    esac
    
    echo -e "${YELLOW}Downloading Realm from: $download_url ${NC}"
    if ! wget -qO realm.tar.gz "$download_url"; then
        echo -e "${RED}Download failed. Please check your network connection.${NC}"
        rm -f realm.tar.gz
        cd .. && rm -rf "$REALM_DIR"
        exit 1
    fi
    
    if [ ! -f realm.tar.gz ] || [ ! -s realm.tar.gz ]; then
        echo -e "${RED}Downloaded file is invalid.${NC}"
        rm -f realm.tar.gz
        cd .. && rm -rf "$REALM_DIR"
        exit 1
    fi
    
    echo -e "${YELLOW}Extracting files...${NC}"
    tar -xzf realm.tar.gz && chmod +x realm
    rm -f realm.tar.gz

    # 创建配置目录
    mkdir -p "$REALM_CONFIG_DIR"
    
    # 创建服务文件
    echo -e "${YELLOW}Creating system service...${NC}"
    cat <<EOF >/etc/systemd/system/realm.service
[Unit]
Description=Realm Service
After=network-online.target
Wants=network-online.target systemd-networkd-wait-online.service

[Service]
Type=simple
User=root
Restart=on-failure
RestartSec=5s
WorkingDirectory=${REALM_DIR}
ExecStart=${REALM_DIR}/realm -c ${CONFIG_PATH}

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    
    # 初始化配置文件（如果不存在）
    if [ ! -f "$CONFIG_PATH" ]; then
        cat <<EONET >"$CONFIG_PATH"
# Global network settings
[network]
# no_tcp = true means globally disable TCP unless explicitly enabled by endpoints
# use_udp = true means globally enable UDP unless explicitly disabled by endpoints
no_tcp = false 
use_udp = true
ipv6_only = false 
EONET
        echo -e "${GREEN}Configuration file created: ${CONFIG_PATH}${NC}"
    fi
    realm_status="Installed"
    realm_status_color="$GREEN"
    echo -e "${GREEN}Deployment completed${NC}"
}

# 卸载 Realm
uninstall_realm() {
    echo -e "${YELLOW}Uninstalling Realm...${NC}"
    systemctl stop realm &>/dev/null || true
    systemctl disable realm &>/dev/null || true
    rm -f /etc/systemd/system/realm.service
    systemctl daemon-reload
    echo -e "${YELLOW}Removing Realm directories...${NC}"
    rm -rf "$REALM_DIR"
    rm -rf "$REALM_CONFIG_DIR" 
    
    # 清理定时任务
    if [ -f "/etc/crontab" ]; then
        if [ -w "/etc/crontab" ] && command -v sed &> /dev/null; then
            sed -i '/realm/d' /etc/crontab
            echo -e "${YELLOW}Cleaned up realm cron jobs from /etc/crontab${NC}"
        else
            echo -e "${YELLOW}Warning: Cannot write to /etc/crontab or sed command unavailable${NC}"
        fi
    fi
    
    realm_status="Not Installed"
    realm_status_color="$RED"
    echo -e "${GREEN}Realm has been completely uninstalled${NC}"
}

# 检查 Realm 安装状态
check_realm_installation() {
    echo -e "${YELLOW}Checking Realm installation status...${NC}"
    if [ -f "${REALM_DIR}/realm" ]; then
        realm_status="Installed"
        realm_status_color="$GREEN"
        echo -e "${GREEN}Realm is installed${NC}"
    else
        realm_status="Not Installed"
        realm_status_color="$RED"
        echo -e "${RED}Realm is not installed. Installing automatically...${NC}"
        # 临时禁用严格模式，以防安装失败时退出脚本
        set +e
        deploy_realm
        local install_result=$?
        set -e
        if [ $install_result -eq 0 ]; then
            echo -e "${GREEN}Realm installation completed successfully.${NC}"
        else
            echo -e "${RED}Realm installation failed. Some features may not work properly.${NC}"
            echo -e "${YELLOW}You can try option 1 from the menu to manually install Realm later.${NC}"
            realm_status="Installation Failed"
            realm_status_color="$RED"
        fi
    fi
}

# 检查并修复 Realm 服务状态
check_realm_service_status() {
    if systemctl is-active --quiet realm; then
        echo -e "${GREEN}Active${NC}"
        return 0 
    fi

    # 服务未活动，检查配置是否存在
    if [ ! -f "$CONFIG_PATH" ]; then
        echo -e "${RED}Inactive${NC}"
        echo -e "${YELLOW}Configuration file (${CONFIG_PATH}) not found. Cannot start service.${NC}"
        return 1
    fi
    
    # 检查是否有任何端点配置
    if ! grep -q '^\[\[endpoints\]\]' "$CONFIG_PATH"; then
        echo -e "${RED}Inactive${NC}"
        echo -e "${YELLOW}No forwarding rules configured. Please add rules first.${NC}"
        return 0
    fi

    echo -e "${RED}Inactive${NC}"
    echo -e "${YELLOW}Attempting to fix Realm service...${NC}"

    # 清理配置文件中的重复行
    awk '!seen[$0]++' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
    echo -e "${YELLOW}Cleaned up duplicate lines in configuration${NC}"

    # 确保 [network] 部分存在
    if ! grep -q '^\[network\]' "$CONFIG_PATH"; then
        cat <<EOF >>"$CONFIG_PATH"
[network]
no_tcp = false
use_udp = true
ipv6_only = false
EOF
        echo -e "${YELLOW}Added missing [network] section${NC}"
    fi

    # 检查 realm 可执行文件
    if [ ! -x "${REALM_DIR}/realm" ]; then
        echo -e "${RED}Error: realm executable not found or not executable${NC}"
        return 1
    fi

    # 尝试重启服务
    echo -e "${YELLOW}Attempting to restart Realm service...${NC}"
    systemctl restart realm
    sleep 2

    if systemctl is-active --quiet realm; then
        echo -e "${GREEN}Realm service restarted successfully${NC}"
    else
        echo -e "${RED}Realm service failed to restart${NC}"
        echo -e "${YELLOW}Error logs:${NC}"
        journalctl -u realm.service -n 20 --no-pager
        return 1
    fi
    return 0
}

# 获取服务器信息
fetch_server_info() {
    echo -e "${YELLOW}Fetching server information...${NC}"
    meta_info=$(curl -s https://speed.cloudflare.com/meta)

    # 使用 jq 解析 (如果可用)
    if $use_jq && [ -n "$meta_info" ]; then
        asOrganization=$(echo "$meta_info" | jq -r '.asOrganization // "N/A"')
        colo=$(echo "$meta_info" | jq -r '.colo // "N/A"')
        country=$(echo "$meta_info" | jq -r '.country // "N/A"')
    else
        # 使用 grep 提取
        asOrganization=$(echo "$meta_info" | grep -oP '(?<="asOrganization":")[^"]*' 2>/dev/null || echo "N/A")
        colo=$(echo "$meta_info" | grep -oP '(?<="colo":")[^"]*' 2>/dev/null || echo "N/A")
        country=$(echo "$meta_info" | grep -oP '(?<="country":")[^"]*' 2>/dev/null || echo "N/A")
        
        # 如果grep -P不可用，回退到普通grep+sed
        if [ "$asOrganization" = "N/A" ] && command -v grep &>/dev/null && command -v sed &>/dev/null; then
             asOrganization=$(echo "$meta_info" | grep '"asOrganization":"' | sed 's/.*"asOrganization":"\([^"]*\)".*/\1/' 2>/dev/null || echo "N/A")
             colo=$(echo "$meta_info" | grep '"colo":"' | sed 's/.*"colo":"\([^"]*\)".*/\1/' 2>/dev/null || echo "N/A")
             country=$(echo "$meta_info" | grep '"country":"' | sed 's/.*"country":"\([^"]*\)".*/\1/' 2>/dev/null || echo "N/A")
        fi
    fi
    
    # 处理空值
    [ -z "$asOrganization" ] && asOrganization="N/A"
    [ -z "$colo" ] && colo="N/A"
    [ -z "$country" ] && country="N/A"

    # 获取IP信息
    ipv4=$(curl -s --max-time 5 ipv4.ip.sb 2>/dev/null || echo "N/A")
    ipv6=$(curl -s --max-time 5 ipv6.ip.sb 2>/dev/null || echo "N/A")

    # 检查IPv6是否可用
    has_ipv6=false
    if [ "$ipv6" != "N/A" ] && [[ "$ipv6" =~ ":" ]]; then
        has_ipv6=true
    fi

    # 如果单独请求失败，尝试组合API
    if { [ "$ipv4" = "N/A" ] || ! [[ "$ipv4" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; } && \
       { [ "$ipv6" = "N/A" ] || ! [[ "$ipv6" =~ ":" ]]; }; then
        combined_ip=$(curl -s --max-time 5 ip.sb 2>/dev/null || echo "N/A")
        if [[ $combined_ip =~ .*:.* ]]; then 
            ipv6=$combined_ip
            has_ipv6=true
            ipv4="N/A"
        elif [[ $combined_ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            ipv4=$combined_ip
        fi
    fi
}

# 显示菜单
show_menu() {
    fetch_server_info
    clear
    echo -e "${BOLD}=== Realm Proxy Management Script ===${NC}"
    echo "1. Install/Reinstall Realm"
    echo "2. Add Forwarding Rules"
    echo "3. View All Forwarding Rules"
    echo "4. Delete Forwarding Rules"
    echo "5. Manage Realm Service"
    echo "6. Uninstall Realm"
    echo "7. Exit"
    echo "------------------------------"
    echo -e "Realm Status: ${realm_status_color}${realm_status}${NC}"
    echo -n "Realm Service: "
    check_realm_service_status
    echo "------------------------------"
    echo "Server Information:"
    echo "IPv4: $ipv4 | IPv6: $ipv6"
    echo "COLO: $colo | AS Organization: $asOrganization | Country: $country"
    echo "=================================="
}

# 查找可用端口
find_available_port() {
    local start_port=${1:-10000}
    local end_port=${2:-65535}
    local range=$((end_port - start_port + 1))
    local max_attempts=100

    # 初始化随机数生成器
    RANDOM=$$$(date +%s)

    for ((i=1; i<=max_attempts; i++)); do
        local port=$((RANDOM % range + start_port))
        if ! is_port_in_use "$port"; then
            echo "$port"
            return 0
        fi
    done

    echo "No available ports found after $max_attempts attempts in range $start_port-$end_port" >&2
    return 1
}

# 管理 Realm 服务
manage_realm_service() {
    while true; do
        clear
        echo -e "${BOLD}Manage Realm Service${NC}"
        echo "1. Start Realm Service"
        echo "2. Stop Realm Service"
        echo "3. Restart Realm Service"
        echo "4. View Realm Service Status"
        echo "5. View Realm Service Logs"
        echo "6. Return to Main Menu"
        read -rp "Select an option: " service_choice
        case $service_choice in
            1) 
                echo -e "${YELLOW}Starting Realm service...${NC}"
                if systemctl start realm; then
                    echo -e "${GREEN}Realm service started${NC}"
                else
                    echo -e "${RED}Failed to start Realm service${NC}"
                fi
                ;;
            2) 
                echo -e "${YELLOW}Stopping Realm service...${NC}"
                if systemctl stop realm; then
                    echo -e "${GREEN}Realm service stopped${NC}"
                else
                    echo -e "${RED}Failed to stop Realm service${NC}"
                fi
                ;;
            3) 
                echo -e "${YELLOW}Restarting Realm service...${NC}"
                if systemctl restart realm; then
                    echo -e "${GREEN}Realm service restarted${NC}"
                else
                    echo -e "${RED}Failed to restart Realm service${NC}"
                fi
                ;;
            4) 
                echo -e "${YELLOW}Realm service status:${NC}"
                systemctl status realm --no-pager
                ;;
            5)
                echo -e "${YELLOW}Realm service logs (last 20 lines):${NC}"
                journalctl -u realm.service -n 20 --no-pager
                ;;
            6) return ;;
            *) echo -e "${RED}Invalid option${NC}" ;;
        esac
        read -n1 -r -p "Press any key to continue..."
    done
}

# 转发规则管理菜单
forwarding_rules_menu() {
    while true; do
        clear
        echo -e "${BOLD}Forwarding Rules Management${NC}"
        echo "1. Add Standard Forwarding Rule"
        echo "2. Add TCP/UDP Split Forwarding Rule"
        echo "3. Return to Main Menu"
        read -rp "Select an option: " forward_choice
        case $forward_choice in
            1) add_standard_forward ;;
            2) add_split_forward ;;
            3) return ;;
            *) echo -e "${RED}Invalid option${NC}" ;;
        esac
        read -n1 -r -p "Press any key to continue..."
    done
}

# 添加标准转发规则
add_standard_forward() {
    echo -e "${BOLD}Add Standard Forwarding Rule${NC}"

    # 检查Realm是否已安装
    if [ ! -f "${REALM_DIR}/realm" ]; then
        echo -e "${RED}Realm is not installed. Please install Realm first (option 1).${NC}"
        return 1
    fi

    fetch_server_info

    # 选择IP版本
    local listen_addr="0.0.0.0"
    if [ "$has_ipv6" = true ]; then
        echo "Choose IP version for listening:"
        echo "1. IPv4 (0.0.0.0)"
        echo "2. IPv6 ([::])"
        read -rp "Please select [1]: " ip_version_choice
        ip_version_choice=${ip_version_choice:-1}
        
        case $ip_version_choice in
            1) listen_addr="0.0.0.0";;
            2) listen_addr="[::]";; 
            *) echo -e "${YELLOW}Invalid choice. Using default IPv4 (0.0.0.0)${NC}"; listen_addr="0.0.0.0";;
        esac
    else
        echo -e "${YELLOW}IPv6 is not available. Using IPv4 (0.0.0.0)${NC}"
        listen_addr="0.0.0.0"
    fi

    # 选择传输协议
    echo "Choose transport protocol:"
    echo "1. TCP only"
    echo "2. UDP only"
    echo "3. Both TCP and UDP (default)"
    read -rp "Please select [3]: " transport_choice
    transport_choice=${transport_choice:-3}
    case $transport_choice in
        1) use_tcp=true; use_udp=false ;;
        2) use_tcp=false; use_udp=true ;;
        3) use_tcp=true; use_udp=true ;;
        *) echo -e "${YELLOW}Invalid choice. Using default TCP and UDP${NC}"; use_tcp=true; use_udp=true ;;
    esac

    # 获取转发详情
    while true; do
        read -rp "Enter local listening port (leave blank for auto-selection): " local_port
        if [ -z "$local_port" ]; then
            local_port=$(find_available_port)
            if [ $? -ne 0 ]; then
                echo -e "${RED}Unable to find an available port. Please specify manually.${NC}"
                continue
            fi
            echo -e "${GREEN}Automatically selected available port: $local_port${NC}"
            break
        elif validate_port "$local_port"; then
            if is_port_in_use "$local_port"; then
                echo -e "${YELLOW}Warning: Port $local_port may already be in use${NC}"
                read -rp "Continue with this port? (y/N): " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    break
                fi
            else
                break
            fi
        else
            echo -e "${RED}Invalid port number. Please enter a number between 1-65535${NC}"
        fi
    done

    while true; do
        read -rp "Enter remote IP address: " remote_ip
        if [ -n "$remote_ip" ] && validate_ip "$remote_ip"; then
            break
        else
            echo -e "${RED}Invalid IP address or domain name${NC}"
        fi
    done

    while true; do
        read -rp "Enter remote port: " remote_port
        if validate_port "$remote_port"; then
            break
        else
            echo -e "${RED}Invalid port number. Please enter a number between 1-65535${NC}"
        fi
    done

    read -rp "Enter remark (optional): " remark
    remark=${remark:-"Standard forwarding rule"}

    # 检查并创建 [network] 部分（如果不存在）
    if ! grep -q '^\[network\]' "$CONFIG_PATH"; then
        cat <<EOF >> "$CONFIG_PATH"
[network]
no_tcp = false 
use_udp = true
ipv6_only = false 
EOF
        echo -e "${YELLOW}Added missing [network] section${NC}"
    fi

    # 添加新的端点配置
    cat <<EOF >> "$CONFIG_PATH"

[[endpoints]]
# Remark: $remark
listen = "${listen_addr}:$local_port"
remote = "$remote_ip:$remote_port"
use_tcp = $use_tcp 
use_udp = $use_udp
EOF

    realm_status="Installed"
    realm_status_color="$GREEN"

    # 启用并重启服务
    systemctl enable realm
    if systemctl restart realm; then
        echo -e "${GREEN}Forwarding rule added and Realm service restarted${NC}"
        echo -e "${BLUE}Forwarding: ${listen_addr}:${local_port} -> ${remote_ip}:${remote_port}${NC}"
    else
        echo -e "${RED}Forwarding rule added but Realm service failed to restart${NC}"
        echo -e "${YELLOW}Please check configuration or service logs${NC}"
    fi
}

# 添加TCP/UDP分离转发规则
add_split_forward() {
    echo -e "${BOLD}Add TCP/UDP Split Forwarding Rule${NC}"
    echo -e "${YELLOW}This feature allows TCP and UDP traffic on the same port to be forwarded to different targets${NC}"

    # 检查Realm是否已安装
    if [ ! -f "${REALM_DIR}/realm" ]; then
        echo -e "${RED}Realm is not installed. Please install Realm first (option 1).${NC}"
        return 1
    fi

    fetch_server_info

    # 选择IP版本
    local listen_addr="0.0.0.0"
    if [ "$has_ipv6" = true ]; then
        echo "Choose IP version for listening:"
        echo "1. IPv4 (0.0.0.0)"
        echo "2. IPv6 ([::])"
        read -rp "Please select [1]: " ip_version_choice
        ip_version_choice=${ip_version_choice:-1}
        
        case $ip_version_choice in
            1) listen_addr="0.0.0.0";;
            2) listen_addr="[::]";; 
            *) echo -e "${YELLOW}Invalid choice. Using default IPv4 (0.0.0.0)${NC}"; listen_addr="0.0.0.0";;
        esac
    else
        echo -e "${YELLOW}IPv6 is not available. Using IPv4 (0.0.0.0)${NC}"
        listen_addr="0.0.0.0"
    fi

    # 获取本地监听端口
    while true; do
        read -rp "Enter local listening port (leave blank for auto-selection): " local_port
        if [ -z "$local_port" ]; then
            local_port=$(find_available_port)
            if [ $? -ne 0 ]; then
                echo -e "${RED}Unable to find an available port. Please specify manually.${NC}"
                continue
            fi
            echo -e "${GREEN}Automatically selected available port: $local_port${NC}"
            break
        elif validate_port "$local_port"; then
            if is_port_in_use "$local_port"; then
                echo -e "${YELLOW}Warning: Port $local_port may already be in use${NC}"
                read -rp "Continue with this port? (y/N): " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    break
                fi
            else
                break
            fi
        else
            echo -e "${RED}Invalid port number. Please enter a number between 1-65535${NC}"
        fi
    done

    # 获取TCP转发目标
    echo -e "${BLUE}Configure TCP forwarding target:${NC}"
    while true; do
        read -rp "Enter TCP target IP address: " tcp_ip
        if [ -n "$tcp_ip" ] && validate_ip "$tcp_ip"; then
            break
        else
            echo -e "${RED}Invalid IP address or domain name${NC}"
        fi
    done

    while true; do
        read -rp "Enter TCP target port: " tcp_port
        if validate_port "$tcp_port"; then
            break
        else
            echo -e "${RED}Invalid port number. Please enter a number between 1-65535${NC}"
        fi
    done

    # 获取UDP转发目标
    echo -e "${BLUE}Configure UDP forwarding target:${NC}"
    while true; do
        read -rp "Enter UDP target IP address: " udp_ip
        if [ -n "$udp_ip" ] && validate_ip "$udp_ip"; then
            break
        else
            echo -e "${RED}Invalid IP address or domain name${NC}"
        fi
    done

    while true; do
        read -rp "Enter UDP target port: " udp_port
        if validate_port "$udp_port"; then
            break
        else
            echo -e "${RED}Invalid port number. Please enter a number between 1-65535${NC}"
        fi
    done

    read -rp "Enter remark (optional): " remark
    remark=${remark:-"TCP/UDP split forwarding"}

    # 检查并创建 [network] 部分（如果不存在）
    if ! grep -q '^\[network\]' "$CONFIG_PATH"; then
        cat <<EOF >> "$CONFIG_PATH"
[network]
no_tcp = false 
use_udp = true
ipv6_only = false 
EOF
        echo -e "${YELLOW}Added missing [network] section${NC}"
    fi

    # 添加TCP转发规则
    cat <<EOF >> "$CONFIG_PATH"

[[endpoints]]
# Remark: $remark - TCP
listen = "${listen_addr}:$local_port"
remote = "$tcp_ip:$tcp_port"
use_tcp = true
use_udp = false
EOF

    # 添加UDP转发规则
    cat <<EOF >> "$CONFIG_PATH"

[[endpoints]]
# Remark: $remark - UDP
listen = "${listen_addr}:$local_port"
remote = "$udp_ip:$udp_port"
use_tcp = false
use_udp = true
EOF

    realm_status="Installed"
    realm_status_color="$GREEN"

    # 启用并重启服务
    systemctl enable realm
    if systemctl restart realm; then
        echo -e "${GREEN}TCP/UDP split forwarding rules added and Realm service restarted${NC}"
        echo -e "${BLUE}TCP forwarding: ${listen_addr}:${local_port} -> ${tcp_ip}:${tcp_port}${NC}"
        echo -e "${BLUE}UDP forwarding: ${listen_addr}:${local_port} -> ${udp_ip}:${udp_port}${NC}"
    else
        echo -e "${RED}Forwarding rules added but Realm service failed to restart${NC}"
        echo -e "${YELLOW}Please check configuration or service logs${NC}"
    fi
}

# 显示所有转发规则
show_all_conf() {
    echo -e "${BOLD}Current Forwarding Rules:${NC}"
    if [ ! -f "$CONFIG_PATH" ]; then
        echo -e "${RED}Configuration file ${CONFIG_PATH} not found.${NC}"
        return
    fi
    
    # 使用awk解析配置文件中的端点
    awk '
    BEGIN { 
        endpoint_idx = 0; 
        in_endpoint = 0; 
        remark="None"; 
        listen="N/A"; 
        remote="N/A"; 
        use_tcp="N/A"; 
        use_udp="N/A"; 
    }
    /^# Remark: / { 
        if (in_endpoint) {
            remark = substr($0, index($0, ":") + 2); 
            gsub(/^[ \t]+|[ \t]+$/, "", remark);
        }
    }
    /^listen = / { 
        if (in_endpoint) {
            listen = substr($0, index($0, "=") + 2); 
            gsub(/^[ \t"]+|[ \t"]+$/, "", listen);
        }
    }
    /^remote = / { 
        if (in_endpoint) {
            remote = substr($0, index($0, "=") + 2); 
            gsub(/^[ \t"]+|[ \t"]+$/, "", remote);
        }
    }
    /^use_tcp =/ { 
        if (in_endpoint) {
            use_tcp = substr($0, index($0, "=") + 2); 
            gsub(/^[ \t]+|[ \t]+$/, "", use_tcp);
        }
    }
    /^use_udp =/ { 
        if (in_endpoint) {
            use_udp = substr($0, index($0, "=") + 2);
            gsub(/^[ \t]+|[ \t]+$/, "", use_udp);
            endpoint_idx++;
            printf "%d. Remark: %s\n", endpoint_idx, remark;
            printf "   Listen: %s -> Remote: %s\n", listen, remote;
            printf "   TCP: %s, UDP: %s\n\n", use_tcp, use_udp;
            # 重置变量
            remark="None"; listen="N/A"; remote="N/A"; use_tcp="N/A"; use_udp="N/A";
        }
    }
    /^\[\[endpoints\]\]/ { 
        in_endpoint = 1; 
        remark="None"; 
        listen="N/A"; 
        remote="N/A"; 
        use_tcp="N/A"; 
        use_udp="N/A"; 
    }
    /^\[/ && !/^\[\[endpoints\]\]/ {
        in_endpoint = 0;
    }
    END { 
        if (endpoint_idx == 0) 
            print "No forwarding rules found."; 
    }
    ' "$CONFIG_PATH"
}

# 删除转发规则
delete_forward() {
    echo -e "${BOLD}Delete Forwarding Rules${NC}"
    if [ ! -f "$CONFIG_PATH" ]; then
        echo -e "${RED}Configuration file ${CONFIG_PATH} not found.${NC}"
        return
    fi

    # 首先显示所有规则
    show_all_conf

    # 使用更可靠的方法解析和删除规则
    declare -a rule_details_list=()
    local rule_idx=0
    local current_block_start_line=0
    local line_num=0
    local in_block=0
    local remark_val listen_val remote_val

    # 读取整个文件内容进行处理
    mapfile -t config_lines < "$CONFIG_PATH"
    local total_lines=${#config_lines[@]}

    for (( i=0; i<total_lines; i++ )); do
        line_num=$((i + 1))
        current_line_content=${config_lines[$i]}
        current_line_content=${current_line_content%$'\r'} # 移除CR

        if [[ "$current_line_content" == *'[[endpoints]]'* ]]; then
            if [ "$in_block" -eq 1 ]; then # 意味着上一个块结束了
                # 如果上一个块有内容，则记录其结束行
                if [ "$current_block_start_line" -ne 0 ]; then
                    # 存储上一个块的结束行号和详情
                    rule_details_list+=("${current_block_start_line}|${i}|${remark_val}|${listen_val}|${remote_val}")
                fi
            fi
            # 新块开始
            in_block=1
            ((rule_idx++))
            current_block_start_line=$line_num
            remark_val="None" # 重置当前块的详情
            listen_val="N/A"
            remote_val="N/A"
        elif [ "$in_block" -eq 1 ]; then
            # 在块内部查找remark, listen, remote
            if [[ "$current_line_content" =~ ^#.*Remark:.*(.*)$ ]]; then
                remark_val=$(echo "$current_line_content" | sed 's/^#.*Remark: *//')
            elif [[ "$current_line_content" =~ ^listen.*=.*\"(.*)\" ]]; then
                listen_val=$(echo "$current_line_content" | sed 's/^listen.*= *"\([^"]*\)".*/\1/')
            elif [[ "$current_line_content" =~ ^remote.*=.*\"(.*)\" ]]; then
                remote_val=$(echo "$current_line_content" | sed 's/^remote.*= *"\([^"]*\)".*/\1/')
            elif [[ "$current_line_content" =~ ^\[[a-zA-Z_]+\]$ ]] && [ "$current_block_start_line" -ne 0 ]; then
                 # 新的非endpoint节开始，表示当前endpoints块结束
                rule_details_list+=("${current_block_start_line}|${i}|${remark_val}|${listen_val}|${remote_val}")
                in_block=0
                current_block_start_line=0 # 为下一个可能的[[endpoints]]块做准备
            fi
        fi
    done

    # 处理文件末尾的最后一个块（如果存在且未被新节结束）
    if [ "$in_block" -eq 1 ] && [ "$current_block_start_line" -ne 0 ]; then
        rule_details_list+=("${current_block_start_line}|${total_lines}|${remark_val}|${listen_val}|${remote_val}")
    fi

    if [ ${#rule_details_list[@]} -eq 0 ]; then
        echo -e "${YELLOW}No forwarding rules found to delete.${NC}"
        return
    fi

    echo -e "${YELLOW}Available forwarding rules to delete:${NC}"
    for i in "${!rule_details_list[@]}"; do
        IFS='|' read -r start_line end_line r l rem <<< "${rule_details_list[$i]}"
        printf "%d. Remark: %s (Listen: %s -> Remote: %s)\n" "$((i + 1))" "$r" "$l" "$rem"
    done

    read -rp "Enter the number of the rule to delete (or press Enter to cancel): " choice

    if [ -z "$choice" ]; then
        echo -e "${YELLOW}Deletion cancelled.${NC}"
        return
    fi

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#rule_details_list[@]} ]; then
        echo -e "${RED}Invalid choice.${NC}"
        return
    fi

    IFS='|' read -r chosen_start_line chosen_end_line chosen_remark _ _ <<< "${rule_details_list[$((choice - 1))]}"

    # 创建备份
    cp "$CONFIG_PATH" "${CONFIG_PATH}.bak.$(date +%Y%m%d_%H%M%S)"
    echo -e "${YELLOW}Configuration file backed up.${NC}"

    # 使用sed删除选定的规则块
    sed -i "${chosen_start_line},${chosen_end_line}d" "$CONFIG_PATH"
    
    echo -e "${GREEN}Forwarding rule '$chosen_remark' deleted.${NC}"

    # 规则删除后管理服务
    if ! grep -q '^\[\[endpoints\]\]' "$CONFIG_PATH"; then
        systemctl stop realm &>/dev/null || true
        systemctl disable realm &>/dev/null || true
        realm_status="Installed (No Rules)"
        realm_status_color="$YELLOW"
        echo -e "${YELLOW}No forwarding rules left. Realm service stopped and disabled.${NC}"
    else
        echo -e "${YELLOW}Restarting Realm service...${NC}"
        if systemctl restart realm; then
            echo -e "${GREEN}Realm service restarted successfully.${NC}"
        else
            echo -e "${RED}Realm service failed to restart. Please check logs.${NC}"
            journalctl -u realm.service -n 10 --no-pager
        fi
    fi
}

# 启动时检查Realm安装
check_realm_installation

# 主循环
while true; do
    show_menu
    read -rp "Select an option (1-7): " choice
    case $choice in
        1) 
            echo -e "${YELLOW}Installing/Reinstalling Realm...${NC}"
            set +e
            deploy_realm
            local install_result=$?
            set -e
            if [ $install_result -eq 0 ]; then
                echo -e "${GREEN}Realm installation completed successfully.${NC}"
                realm_status="Installed"
                realm_status_color="$GREEN"
            else
                echo -e "${RED}Realm installation failed.${NC}"
                realm_status="Installation Failed"
                realm_status_color="$RED"
            fi
            ;;
        2) forwarding_rules_menu ;;
        3) show_all_conf ;;
        4) delete_forward ;;
        5) manage_realm_service ;;
        6) uninstall_realm ;;
        7) echo -e "${GREEN}Exiting script.${NC}"; exit 0 ;;
        *) echo -e "${RED}Invalid option: $choice${NC}" ;;
    esac
    read -n1 -r -p "Press any key to continue..."
done

