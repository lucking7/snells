#!/bin/bash

# 启用严格模式 - 脚本最佳实践
set -o errexit  # 任何命令失败即退出
set -o nounset  # 引用未设置的变量即退出
set -o pipefail # 管道中任何命令失败即视为失败

# 颜色定义
GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[0;33m"
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

# 部署 Realm
deploy_realm() {
    mkdir -p "$REALM_DIR" && cd "$REALM_DIR" || { echo -e "${RED}Failed to access $REALM_DIR directory.${NC}"; exit 1; }
    
    # 从GitHub API获取最新版本
    local api_response
    api_response=$(curl -s https://api.github.com/repos/zhboner/realm/releases/latest)

    if $use_jq && command -v jq &> /dev/null; then
        _version=$(echo "$api_response" | jq -r '.tag_name // ""')
    else
        _version=$(echo "$api_response" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    fi
    
    if [ -z "$_version" ]; then
        echo -e "${RED}Failed to get version number. Please check if you can connect to GitHub API.${NC}"
        echo -e "${YELLOW}Falling back to a default known version v2.6.2 for download.${NC}"
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
            echo -e "${RED}Unsupported architecture or OS: $arch-$os_type. Attempting x86_64-linux-gnu as a default.${NC}"
            download_url="https://github.com/zhboner/realm/releases/download/${_version}/realm-x86_64-unknown-linux-gnu.tar.gz"
            ;;
    esac
    
    echo -e "${YELLOW}Downloading Realm from: $download_url ${NC}"
    wget -qO realm.tar.gz "$download_url"
    if [ ! -f realm.tar.gz ] || [ ! -s realm.tar.gz ]; then
        echo -e "${RED}Download realm.tar.gz failed. Please check network or URL: $download_url ${NC}"
        # 失败时清理
        rm -f realm.tar.gz
        cd .. && rm -rf "$REALM_DIR"
        exit 1
    fi
    tar -xzf realm.tar.gz && chmod +x realm
    rm -f realm.tar.gz

    # 创建配置目录
    mkdir -p "$REALM_CONFIG_DIR"
    
    # 创建服务文件
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
# 全局网络设置
[network]
# no_tcp = true 表示全局禁用TCP，除非端点明确启用
# use_udp = true 表示全局启用UDP，除非端点明确禁用
no_tcp = false 
use_udp = true
ipv6_only = false 
EONET
        echo -e "${GREEN}[network] configuration added to ${CONFIG_PATH}.${NC}"
    fi
    realm_status="Installed"
    realm_status_color="$GREEN"
    echo -e "${GREEN}Deployment completed.${NC}"
}

# 卸载 Realm
uninstall_realm() {
    systemctl stop realm &>/dev/null
    systemctl disable realm &>/dev/null
    rm -f /etc/systemd/system/realm.service
    systemctl daemon-reload
    echo -e "${YELLOW}Removing Realm directories...${NC}"
    rm -rf "$REALM_DIR"
    rm -rf "$REALM_CONFIG_DIR" 
    
    # 清理定时任务
    if [ -f "/etc/crontab" ]; then
        if [ -w "/etc/crontab" ] && command -v sed &> /dev/null; then
            sed -i '/realm/d' /etc/crontab
            echo -e "${YELLOW}Realm cron jobs removed from /etc/crontab.${NC}"
        else
            echo -e "${YELLOW}Warning: /etc/crontab not writable or sed not found. Skipping crontab cleanup.${NC}"
        fi
    fi
    
    realm_status="Not Installed"
    realm_status_color="$RED"
    echo -e "${RED}Realm has been uninstalled.${NC}"
}

# 检查 Realm 安装状态
check_realm_installation() {
    if [ -f "${REALM_DIR}/realm" ]; then
        realm_status="Installed"
        realm_status_color="$GREEN"
    else
        realm_status="Not Installed"
        realm_status_color="$RED"
        echo -e "${RED}Realm is not installed. Installing now...${NC}"
        deploy_realm
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
        echo -e "${YELLOW}Realm configuration file (${CONFIG_PATH}) not found. Cannot start service.${NC}"
        return 1
    fi
    
    # 检查是否有任何端点配置
    if ! grep -q '^\[\[endpoints\]\]' "$CONFIG_PATH"; then
        echo -e "${RED}Inactive${NC}"
        echo -e "${YELLOW}No forwarding rules configured in ${CONFIG_PATH}. Add rules before starting the service.${NC}"
        return 0
    fi

    echo -e "${RED}Inactive${NC}"
    echo "Attempting to fix Realm service..."

    # 清理配置文件中的重复行
    awk '!seen[$0]++' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
    echo "Cleaned up duplicate lines in ${CONFIG_PATH}"

    # 确保 [network] 部分存在
    if ! grep -q '^\[network\]' "$CONFIG_PATH"; then
        cat <<EOF >>"$CONFIG_PATH"
[network]
no_tcp = false
use_udp = true
ipv6_only = false
EOF
        echo "Added missing [network] section to ${CONFIG_PATH}"
    fi

    # 检查 realm 可执行文件
    if [ ! -x "${REALM_DIR}/realm" ]; then
        echo -e "${RED}Error: realm executable not found or not executable at ${REALM_DIR}/realm${NC}"
        return 1
    fi

    # 尝试重启服务
    echo "Attempting to restart Realm service..."
    systemctl restart realm
    sleep 2

    if systemctl is-active --quiet realm; then
        echo -e "${GREEN}Realm service successfully restarted${NC}"
    else
        echo -e "${RED}Failed to restart Realm service${NC}"
        echo "Checking logs for errors:"
        journalctl -u realm.service -n 20 --no-pager
        return 1
    fi
    return 0
}

# 获取服务器信息
fetch_server_info() {
    meta_info=$(curl -s https://speed.cloudflare.com/meta)

    # 使用 jq 解析 (如果可用)
    if $use_jq && [ -n "$meta_info" ]; then
        asOrganization=$(echo "$meta_info" | jq -r '.asOrganization // "N/A"')
        colo=$(echo "$meta_info" | jq -r '.colo // "N/A"')
        country=$(echo "$meta_info" | jq -r '.country // "N/A"')
    else
        # 使用 grep 提取
        asOrganization=$(echo "$meta_info" | grep -oP '(?<="asOrganization":")[^"]*' || echo "N/A")
        colo=$(echo "$meta_info" | grep -oP '(?<="colo":")[^"]*' || echo "N/A")
        country=$(echo "$meta_info" | grep -oP '(?<="country":")[^"]*' || echo "N/A")
        
        # 如果grep -P不可用，回退到普通grep+sed
        if [ "$asOrganization" = "N/A" ] && command -v grep &>/dev/null && command -v sed &>/dev/null; then
             asOrganization=$(echo "$meta_info" | grep '"asOrganization":"' | sed 's/.*"asOrganization":"\([^"]*\)".*/\1/' || echo "N/A")
             colo=$(echo "$meta_info" | grep '"colo":"' | sed 's/.*"colo":"\([^"]*\)".*/\1/' || echo "N/A")
             country=$(echo "$meta_info" | grep '"country":"' | sed 's/.*"country":"\([^"]*\)".*/\1/' || echo "N/A")
        fi
    fi
    
    # 处理空值
    [ -z "$asOrganization" ] && asOrganization="N/A"
    [ -z "$colo" ] && colo="N/A"
    [ -z "$country" ] && country="N/A"

    # 获取IP信息
    ipv4=$(curl -s ipv4.ip.sb || echo "N/A")
    ipv6=$(curl -s ipv6.ip.sb || echo "N/A")

    # 检查IPv6是否可用
    has_ipv6=false
    if [ "$ipv6" != "N/A" ] && [[ "$ipv6" =~ ":" ]]; then
        has_ipv6=true
    fi

    # 如果单独请求失败，尝试组合API
    if { [ "$ipv4" = "N/A" ] || ! [[ "$ipv4" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; } && \
       { [ "$ipv6" = "N/A" ] || ! [[ "$ipv6" =~ ":" ]]; }; then
        combined_ip=$(curl -s ip.sb || echo "N/A")
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
    echo -e "${BOLD}=== Realm Relay Management ===${NC}"
    echo "1. Add Realm Forward"
    echo "2. View Realm Forwards"
    echo "3. Delete Realm Forward"
    echo "4. Manage Realm Service"
    echo "5. Uninstall Realm"
    echo "6. Exit"
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
        if ! lsof -i :"$port" > /dev/null 2>&1; then
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
        echo "5. Return to Main Menu"
        read -rp "Select an option: " service_choice
        case $service_choice in
            1) systemctl start realm; echo "Realm service started." ;;
            2) systemctl stop realm; echo "Realm service stopped." ;;
            3) systemctl restart realm; echo "Realm service restarted." ;;
            4) systemctl status realm ;;
            5) return ;;
            *) echo -e "${RED}Invalid option${NC}" ;;
        esac
        read -n1 -r -p "Press any key to continue..."
    done
}

# 添加转发规则
add_forward() {
    echo -e "${BOLD}Add New Forwarding Rule${NC}"

    fetch_server_info

    # 选择IP版本
    local listen_ipv6_only_for_endpoint=false
    if [ "$has_ipv6" = true ]; then
        echo "Choose IP version for this listening endpoint:"
        echo "1. IPv4 (0.0.0.0)"
        echo "2. IPv6 ([::])"
        echo "3. Both IPv4 and IPv6 (Not directly supported by realm listen)"
        echo "   If you need separate IPv4 and IPv6 listeners, create two rules."
        read -rp "Choice for listening [1 for IPv4, 2 for IPv6]: " ip_version_choice
        
        case $ip_version_choice in
            1) listen_addr="0.0.0.0";;
            2) listen_addr="[::]"; listen_ipv6_only_for_endpoint=true;; 
            *) echo "Invalid choice. Defaulting to IPv4 (0.0.0.0)."; listen_addr="0.0.0.0";;
        esac
    else
        echo "IPv6 is not available on this server. Using IPv4 (0.0.0.0)."
        listen_addr="0.0.0.0"
    fi

    # 选择传输协议
    echo "Choose Transport Protocol:"
    echo "1. TCP"
    echo "2. UDP"
    echo "3. Both TCP and UDP (Default)"
    read -rp "Choice [3]: " transport_choice
    transport_choice=${transport_choice:-3}
    case $transport_choice in
        1) use_tcp=true; use_udp=false ;;
        2) use_tcp=false; use_udp=true ;;
        3) use_tcp=true; use_udp=true ;;
        *) echo "Invalid choice. Defaulting to Both."; use_tcp=true; use_udp=true ;;
    esac

    # 获取转发详情
    read -rp "Enter local listening port (leave blank for auto-selection): " local_port
    if [ -z "$local_port" ]; then
        local_port=$(find_available_port)
        if [ $? -ne 0 ]; then
            echo -e "${RED}Failed to find an available port. Please specify one manually.${NC}"
            return 1
        fi
        echo -e "${GREEN}Automatically selected available port: $local_port${NC}"
    fi
    read -rp "Enter remote IP: " ip
    read -rp "Enter remote port: " port
    read -rp "Enter remark: " remark

    # 验证输入
    if ! [[ "$local_port" =~ ^[0-9]+$ ]] || [ "$local_port" -lt 1 ] || [ "$local_port" -gt 65535 ]; then
        echo -e "${RED}Invalid local port number.${NC}"
        return 1
    fi
    
    # 检查远程IP是否为空
    if [[ -z "$ip" ]]; then
        echo -e "${RED}Remote IP cannot be empty.${NC}"
        return 1
    fi

    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        echo -e "${RED}Invalid remote port number.${NC}"
        return 1
    fi

    # 检查并创建 [network] 部分（如果不存在）
    if ! grep -q '^\[network\]' "$CONFIG_PATH"; then
        cat <<EOF >> "$CONFIG_PATH"
[network]
no_tcp = false 
use_udp = true
ipv6_only = false 
EOF
        echo -e "${YELLOW}Warning: [network] section was missing and has been added to ${CONFIG_PATH}.${NC}"
    fi

    # 添加新的端点配置
    cat <<EOF >> "$CONFIG_PATH"

[[endpoints]]
# Remark: $remark
listen = "${listen_addr}:$local_port"
remote = "$ip:$port"
use_tcp = $use_tcp 
use_udp = $use_udp
EOF

    realm_status="Installed"
    realm_status_color="$GREEN"

    # 启用并重启服务
    systemctl enable realm
    systemctl restart realm
    echo -e "${GREEN}Forwarding rule added and Realm service restarted.${NC}"
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
    BEGIN { endpoint_idx = 0; in_endpoint = 0; }
    /^# Remark: / { if (in_endpoint) remark = substr($0, index($0, ":") + 2); }
    /listen = "/ { if (in_endpoint) listen = substr($0, index($0, "=") + 2); }
    /remote = "/ { if (in_endpoint) remote = substr($0, index($0, "=") + 2); }
    /use_tcp =/ { if (in_endpoint) use_tcp = substr($0, index($0, "=") + 2); }
    /use_udp =/ { 
        if (in_endpoint) {
            use_udp = substr($0, index($0, "=") + 2);
            endpoint_idx++;
            printf "%d. Remark: %s\n", endpoint_idx, remark;
            printf "   Listen: %s, Remote: %s\n", listen, remote;
            printf "   TCP: %s, UDP: %s\n", use_tcp, use_udp;
            # 重置变量
            remark="None"; listen="N/A"; remote="N/A"; use_tcp="N/A"; use_udp="N/A";
        }
    }
    /^\[\[endpoints\]\]/ { in_endpoint = 1; remark="None"; listen="N/A"; remote="N/A"; use_tcp="N/A"; use_udp="N/A"; }
    END { if (endpoint_idx == 0) print "No forwarding rules found."; }
    ' "$CONFIG_PATH"
}

# 删除转发规则
delete_forward() {
    echo -e "${BOLD}Delete Forwarding Rule${NC}"
    if [ ! -f "$CONFIG_PATH" ]; then
        echo -e "${RED}Configuration file ${CONFIG_PATH} not found.${NC}"
        return
    fi

    # 使用awk解析配置文件并显示规则供用户选择
    # rule_details 数组存储每个规则的起始行号、结束行号和描述
    declare -a rule_details_list=()
    local rule_idx=0
    local current_block_start_line=0
    local line_num=0
    local in_block=0
    local remark listen remote

    # 读取整个文件内容进行处理，以正确识别多行块
    # 先用awk提取每个endpoint块，然后逐个处理
    # 这种方法比逐行sed更健壮

    # 将整个文件读入一个变量，然后用awk处理
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
            if [[ "$current_line_content" =~ ^#\s*Remark:\s*(.*) ]]; then
                remark_val="${BASH_REMATCH[1]}"
            elif [[ "$current_line_content" =~ ^listen\s*=\s*\"(.*)\" ]]; then
                listen_val="${BASH_REMATCH[1]}"
            elif [[ "$current_line_content" =~ ^remote\s*=\s*\"(.*)\" ]]; then
                remote_val="${BASH_REMATCH[1]}"
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
        echo "No forwarding rules found to delete."
        return
    fi

    echo "Available forwarding rules:"
    for i in "${!rule_details_list[@]}"; do
        IFS='|' read -r start_line end_line r l rem <<< "${rule_details_list[$i]}"
        printf "%d. Remark: %s (Listen: %s, Remote: %s)\n" "$((i + 1))" "$r" "$l" "$rem"
    done

    read -rp "Enter the number of the rule to delete (or press Enter to cancel): " choice

    if [ -z "$choice" ]; then
        echo "Deletion cancelled."
        return
    fi

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#rule_details_list[@]} ]; then
        echo "Invalid choice."
        return
    fi

    IFS='|' read -r chosen_start_line chosen_end_line _ _ _ <<< "${rule_details_list[$((choice - 1))]}"

    # 创建备份
    cp "$CONFIG_PATH" "${CONFIG_PATH}.bak"
    echo "Original config backed up to ${CONFIG_PATH}.bak"

    # 使用sed删除选定的规则块
    sed -i "${chosen_start_line},${chosen_end_line}d" "$CONFIG_PATH"
    
    # 清理配置文件中可能的多余空行（可选，但保持整洁）
    # 这个awk命令会移除所有完全是空行的行
    awk 'NF > 0 || /^$/ { if (NF > 0) prev_nf=1; else if (prev_nf == 1) { print; prev_nf=0; } else prev_nf=0; } NF>0 {print}' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp_clean" && mv "${CONFIG_PATH}.tmp_clean" "$CONFIG_PATH"
    # 更简单的清理：移除所有连续的空行，只保留最多一个空行
    # awk '{ if (NF > 0) { print } else if (prev_blank == 0) { print; prev_blank=1 } } NF>0 {prev_blank=0}' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp_clean" && mv "${CONFIG_PATH}.tmp_clean" "$CONFIG_PATH"
    # 最简单的清理：删除所有空行（如果这是期望的）
    # awk 'NF' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp_clean" && mv "${CONFIG_PATH}.tmp_clean" "$CONFIG_PATH"
    # 鉴于TOML的结构，保留一些空行可能更好，我们用sed删除规则后，后续的cat EOF追加新规则时会自行处理空行。
    # 暂时只执行规则删除，避免过度处理空行。

    echo "Forwarding rule $choice deleted."

    # 规则删除后管理服务
    if ! grep -q '^\[\[endpoints\]\]' "$CONFIG_PATH"; then
        systemctl stop realm &>/dev/null
        systemctl disable realm &>/dev/null
        realm_status="Installed (No Forwards)"
        realm_status_color="$YELLOW"
        echo -e "${YELLOW}No forwarding rules left. Realm service has been stopped and disabled.${NC}"
    else
        echo "Restarting Realm service due to configuration change..."
        systemctl restart realm
        sleep 1
        if systemctl is-active --quiet realm; then
            echo -e "${GREEN}Realm service restarted successfully.${NC}"
        else
            echo -e "${RED}Realm service failed to restart after rule deletion. Check logs.${NC}"
            journalctl -u realm.service -n 10 --no-pager
        fi
    fi
}

# 启动时检查Realm安装
check_realm_installation

# 主循环
while true; do
    show_menu
    read -rp "Select an option (1-6): " choice
    case $choice in
        1) add_forward ;;
        2) show_all_conf ;;
        3) delete_forward ;;
        4) manage_realm_service ;;
        5) uninstall_realm ;;
        6) echo "Exiting script."; exit 0 ;;
        *) echo -e "${RED}Invalid option: $choice${NC}" ;;
    esac
    read -n1 -r -p "Press any key to continue..."
done
