#!/bin/bash

# wstunnel管理脚本
# 功能：新建、删除、管理wstunnel转发规则

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color

# 配置文件路径
CONFIG_DIR="/etc/wstunnel"
CONFIG_FILE="$CONFIG_DIR/config.json"
WSTUNNEL_BIN="/usr/local/bin/wstunnel"
SERVICE_DIR="/etc/systemd/system"

# 确保以root权限运行
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}请使用root权限运行此脚本${NC}"
    exit 1
fi

# 创建配置目录
mkdir -p "$CONFIG_DIR"

# 初始化配置文件
init_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo '{"tunnels": [], "server": {"url": "", "secret": ""}}' > "$CONFIG_FILE"
    fi
}

# 获取本机IP信息
get_ip_info() {
    local ipv4=""
    local ipv6=""
    local ip_info=""
    
    # 获取IPv4地址
    ipv4=$(curl -s -4 http://ip.sb 2>/dev/null || echo "")
    
    # 获取IPv6地址
    ipv6=$(curl -s -6 http://ip.sb 2>/dev/null || echo "")
    
    # 获取IP详细信息（ASN/ORG）
    if [ -n "$ipv4" ]; then
        ip_info=$(curl -s "http://ip-api.com/json/$ipv4" 2>/dev/null || echo "{}")
        local asn=$(echo "$ip_info" | grep -oP '"as":\s*"[^"]*"' | cut -d'"' -f4)
        local org=$(echo "$ip_info" | grep -oP '"org":\s*"[^"]*"' | cut -d'"' -f4)
        local country=$(echo "$ip_info" | grep -oP '"country":\s*"[^"]*"' | cut -d'"' -f4)
        
        echo -e "${CYAN}本机IP信息：${NC}"
        echo -e "  IPv4: ${GREEN}$ipv4${NC}"
        [ -n "$ipv6" ] && echo -e "  IPv6: ${GREEN}$ipv6${NC}"
        [ -n "$asn" ] && echo -e "  ASN: ${YELLOW}$asn${NC}"
        [ -n "$org" ] && echo -e "  ORG: ${YELLOW}$org${NC}"
        [ -n "$country" ] && echo -e "  位置: ${YELLOW}$country${NC}"
    else
        echo -e "${RED}无法获取IP信息${NC}"
    fi
    echo ""
}

# 检查是否支持IPv4/IPv6
check_ip_support() {
    local has_ipv4=false
    local has_ipv6=false
    
    # 检查IPv4
    if ip -4 addr show | grep -q "inet "; then
        has_ipv4=true
    fi
    
    # 检查IPv6
    if ip -6 addr show | grep -q "inet6 "; then
        has_ipv6=true
    fi
    
    echo "$has_ipv4:$has_ipv6"
}

# 安装wstunnel
install_wstunnel() {
    if [ -f "$WSTUNNEL_BIN" ]; then
        echo -e "${GREEN}wstunnel已安装${NC}"
        return
    fi
    
    echo -e "${YELLOW}正在安装wstunnel...${NC}"
    
    # 检测系统架构
    ARCH=$(uname -m)
    case $ARCH in
        x86_64)
            ARCH_NAME="x86_64"
            ;;
        aarch64)
            ARCH_NAME="aarch64"
            ;;
        armv7l)
            ARCH_NAME="armv7"
            ;;
        *)
            echo -e "${RED}不支持的架构: $ARCH${NC}"
            exit 1
            ;;
    esac
    
    # 获取最新版本
    LATEST_VERSION=$(curl -s https://api.github.com/repos/erebe/wstunnel/releases/latest | grep -oP '"tag_name": "\K[^"]+')
    
    if [ -z "$LATEST_VERSION" ]; then
        echo -e "${RED}无法获取最新版本信息${NC}"
        exit 1
    fi
    
    # 下载二进制文件
    DOWNLOAD_URL="https://github.com/erebe/wstunnel/releases/download/${LATEST_VERSION}/wstunnel_${LATEST_VERSION}_linux_${ARCH_NAME}.tar.gz"
    
    echo -e "${CYAN}下载地址: $DOWNLOAD_URL${NC}"
    
    cd /tmp
    wget -q --show-progress "$DOWNLOAD_URL" -O wstunnel.tar.gz
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}下载失败${NC}"
        exit 1
    fi
    
    # 解压并安装
    tar -xzf wstunnel.tar.gz
    chmod +x wstunnel
    mv wstunnel "$WSTUNNEL_BIN"
    
    # 清理临时文件
    rm -f wstunnel.tar.gz
    
    echo -e "${GREEN}wstunnel安装成功！${NC}"
}

# 配置服务器信息
configure_server() {
    echo -e "${CYAN}配置wstunnel服务器信息${NC}"
    
    # 读取当前配置
    local current_url=$(cat "$CONFIG_FILE" | grep -oP '"url":\s*"[^"]*"' | cut -d'"' -f4)
    local current_secret=$(cat "$CONFIG_FILE" | grep -oP '"secret":\s*"[^"]*"' | cut -d'"' -f4)
    
    echo -e "当前服务器URL: ${YELLOW}${current_url:-未设置}${NC}"
    read -p "请输入wstunnel服务器URL (例如: wss://example.com:443): " server_url
    
    echo -e "当前密钥: ${YELLOW}${current_secret:-未设置}${NC}"
    read -p "请输入HTTP升级路径前缀密钥 (留空表示不使用): " secret
    
    # 更新配置
    local config=$(cat "$CONFIG_FILE")
    config=$(echo "$config" | sed "s|\"url\":\s*\"[^\"]*\"|\"url\": \"$server_url\"|")
    config=$(echo "$config" | sed "s|\"secret\":\s*\"[^\"]*\"|\"secret\": \"$secret\"|")
    echo "$config" > "$CONFIG_FILE"
    
    echo -e "${GREEN}服务器配置已更新${NC}"
}

# 添加转发规则
add_tunnel() {
    echo -e "${CYAN}添加新的转发规则${NC}"
    
    # 选择协议
    echo "请选择转发协议:"
    echo "1) TCP"
    echo "2) UDP"
    echo "3) SOCKS5"
    read -p "请选择 [1-3]: " protocol_choice
    
    case $protocol_choice in
        1) protocol="tcp" ;;
        2) protocol="udp" ;;
        3) protocol="socks5" ;;
        *) echo -e "${RED}无效选择${NC}"; return ;;
    esac
    
    # 选择监听地址类型
    local ip_support=$(check_ip_support)
    local has_ipv4=$(echo "$ip_support" | cut -d':' -f1)
    local has_ipv6=$(echo "$ip_support" | cut -d':' -f2)
    
    echo "请选择监听地址类型:"
    local options=()
    [ "$has_ipv4" = "true" ] && options+=("1) IPv4 (0.0.0.0)")
    [ "$has_ipv6" = "true" ] && options+=("2) IPv6 ([::])")
    options+=("3) 本地回环 (127.0.0.1)")
    
    for opt in "${options[@]}"; do
        echo "$opt"
    done
    
    read -p "请选择: " addr_choice
    
    case $addr_choice in
        1) 
            if [ "$has_ipv4" = "true" ]; then
                listen_addr="0.0.0.0"
            else
                echo -e "${RED}系统不支持IPv4${NC}"
                return
            fi
            ;;
        2) 
            if [ "$has_ipv6" = "true" ]; then
                listen_addr="[::]"
            else
                echo -e "${RED}系统不支持IPv6${NC}"
                return
            fi
            ;;
        3) listen_addr="127.0.0.1" ;;
        *) echo -e "${RED}无效选择${NC}"; return ;;
    esac
    
    # 输入端口
    read -p "请输入本地监听端口: " local_port
    
    # SOCKS5不需要远程地址
    if [ "$protocol" != "socks5" ]; then
        read -p "请输入远程地址 (例如: example.com 或 192.168.1.100): " remote_host
        read -p "请输入远程端口: " remote_port
        
        # 对于UDP，询问超时设置
        if [ "$protocol" = "udp" ]; then
            read -p "UDP超时时间(秒，0表示不超时) [默认30]: " timeout
            timeout=${timeout:-30}
        fi
    fi
    
    # 输入备注
    read -p "请输入备注说明: " comment
    
    # 生成唯一ID
    local tunnel_id=$(date +%s%N | md5sum | cut -c1-8)
    
    # 构建转发规则
    local tunnel_config=""
    if [ "$protocol" = "socks5" ]; then
        tunnel_config="$protocol://${listen_addr}:${local_port}"
    else
        tunnel_config="$protocol://${listen_addr}:${local_port}:${remote_host}:${remote_port}"
        [ "$protocol" = "udp" ] && [ "$timeout" = "0" ] && tunnel_config="${tunnel_config}?timeout_sec=0"
    fi
    
    # 添加到配置文件
    local new_tunnel="{\"id\": \"$tunnel_id\", \"protocol\": \"$protocol\", \"listen_addr\": \"$listen_addr\", \"local_port\": \"$local_port\""
    [ "$protocol" != "socks5" ] && new_tunnel="$new_tunnel, \"remote_host\": \"$remote_host\", \"remote_port\": \"$remote_port\""
    [ "$protocol" = "udp" ] && new_tunnel="$new_tunnel, \"timeout\": \"$timeout\""
    new_tunnel="$new_tunnel, \"config\": \"$tunnel_config\", \"comment\": \"$comment\", \"enabled\": true}"
    
    # 更新配置文件
    local config=$(cat "$CONFIG_FILE")
    config=$(echo "$config" | sed 's/"tunnels": \[/"tunnels": ['"$new_tunnel"',/')
    
    # 如果是第一个tunnel，需要特殊处理
    if echo "$config" | grep -q '"tunnels": \[\]'; then
        config=$(echo "$config" | sed 's/"tunnels": \[\]/"tunnels": ['"$new_tunnel"']/')
    fi
    
    echo "$config" | jq . > "$CONFIG_FILE"
    
    echo -e "${GREEN}转发规则添加成功！${NC}"
    echo -e "ID: ${YELLOW}$tunnel_id${NC}"
    echo -e "规则: ${YELLOW}$tunnel_config${NC}"
    
    # 重启服务
    restart_service
}

# 列出所有转发规则
list_tunnels() {
    echo -e "${CYAN}当前转发规则列表：${NC}"
    echo -e "${WHITE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    local tunnels=$(cat "$CONFIG_FILE" | jq -r '.tunnels[] | @base64')
    local index=1
    
    if [ -z "$tunnels" ]; then
        echo -e "${YELLOW}暂无转发规则${NC}"
        return
    fi
    
    for tunnel_base64 in $tunnels; do
        local tunnel=$(echo "$tunnel_base64" | base64 -d)
        local id=$(echo "$tunnel" | jq -r '.id')
        local protocol=$(echo "$tunnel" | jq -r '.protocol')
        local listen_addr=$(echo "$tunnel" | jq -r '.listen_addr')
        local local_port=$(echo "$tunnel" | jq -r '.local_port')
        local remote_host=$(echo "$tunnel" | jq -r '.remote_host // "N/A"')
        local remote_port=$(echo "$tunnel" | jq -r '.remote_port // "N/A"')
        local comment=$(echo "$tunnel" | jq -r '.comment')
        local enabled=$(echo "$tunnel" | jq -r '.enabled')
        
        # 状态显示
        local status_color=$GREEN
        local status_text="启用"
        if [ "$enabled" = "false" ]; then
            status_color=$RED
            status_text="禁用"
        fi
        
        echo -e "${WHITE}[$index]${NC} ID: ${YELLOW}$id${NC} | 状态: ${status_color}$status_text${NC}"
        echo -e "    协议: ${CYAN}$protocol${NC} | 监听: ${PURPLE}${listen_addr}:${local_port}${NC}"
        
        if [ "$protocol" != "socks5" ]; then
            echo -e "    目标: ${BLUE}${remote_host}:${remote_port}${NC}"
        fi
        
        echo -e "    备注: ${WHITE}$comment${NC}"
        echo -e "${WHITE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        
        ((index++))
    done
}

# 删除转发规则
delete_tunnel() {
    list_tunnels
    
    local tunnel_count=$(cat "$CONFIG_FILE" | jq '.tunnels | length')
    if [ "$tunnel_count" -eq 0 ]; then
        return
    fi
    
    echo ""
    read -p "请输入要删除的规则序号: " index
    
    # 验证输入
    if ! [[ "$index" =~ ^[0-9]+$ ]] || [ "$index" -lt 1 ] || [ "$index" -gt "$tunnel_count" ]; then
        echo -e "${RED}无效的序号${NC}"
        return
    fi
    
    # 获取要删除的规则信息
    local tunnel_info=$(cat "$CONFIG_FILE" | jq ".tunnels[$((index-1))]")
    local tunnel_id=$(echo "$tunnel_info" | jq -r '.id')
    local tunnel_comment=$(echo "$tunnel_info" | jq -r '.comment')
    
    echo -e "${YELLOW}确认删除规则:${NC}"
    echo -e "ID: $tunnel_id"
    echo -e "备注: $tunnel_comment"
    read -p "确认删除？(y/N): " confirm
    
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        # 删除规则
        local new_config=$(cat "$CONFIG_FILE" | jq "del(.tunnels[$((index-1))])")
        echo "$new_config" > "$CONFIG_FILE"
        
        echo -e "${GREEN}规则删除成功！${NC}"
        
        # 重启服务
        restart_service
    else
        echo -e "${YELLOW}取消删除${NC}"
    fi
}

# 启用/禁用转发规则
toggle_tunnel() {
    list_tunnels
    
    local tunnel_count=$(cat "$CONFIG_FILE" | jq '.tunnels | length')
    if [ "$tunnel_count" -eq 0 ]; then
        return
    fi
    
    echo ""
    read -p "请输入要启用/禁用的规则序号: " index
    
    # 验证输入
    if ! [[ "$index" =~ ^[0-9]+$ ]] || [ "$index" -lt 1 ] || [ "$index" -gt "$tunnel_count" ]; then
        echo -e "${RED}无效的序号${NC}"
        return
    fi
    
    # 获取当前状态
    local current_status=$(cat "$CONFIG_FILE" | jq -r ".tunnels[$((index-1))].enabled")
    local new_status="true"
    local action="启用"
    
    if [ "$current_status" = "true" ]; then
        new_status="false"
        action="禁用"
    fi
    
    # 更新状态
    local new_config=$(cat "$CONFIG_FILE" | jq ".tunnels[$((index-1))].enabled = $new_status")
    echo "$new_config" > "$CONFIG_FILE"
    
    echo -e "${GREEN}规则已${action}！${NC}"
    
    # 重启服务
    restart_service
}

# 生成systemd服务
create_service() {
    local service_file="$SERVICE_DIR/wstunnel-client.service"
    
    cat > "$service_file" << EOF
[Unit]
Description=wstunnel Client Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/etc/wstunnel
ExecStart=/usr/local/bin/wstunnel-start.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    # 创建启动脚本
    cat > "/usr/local/bin/wstunnel-start.sh" << 'EOF'
#!/bin/bash

CONFIG_FILE="/etc/wstunnel/config.json"

# 读取服务器配置
SERVER_URL=$(cat "$CONFIG_FILE" | jq -r '.server.url')
SECRET=$(cat "$CONFIG_FILE" | jq -r '.server.secret')

if [ -z "$SERVER_URL" ]; then
    echo "错误：未配置服务器URL"
    exit 1
fi

# 构建wstunnel命令
CMD="/usr/local/bin/wstunnel client"

# 添加HTTP升级路径前缀（如果有）
if [ -n "$SECRET" ] && [ "$SECRET" != "null" ]; then
    CMD="$CMD --http-upgrade-path-prefix $SECRET"
fi

# 添加所有启用的转发规则
TUNNELS=$(cat "$CONFIG_FILE" | jq -r '.tunnels[] | select(.enabled == true) | .config')

for tunnel in $TUNNELS; do
    CMD="$CMD -L '$tunnel'"
done

# 添加服务器URL
CMD="$CMD $SERVER_URL"

# 执行命令
echo "执行命令: $CMD"
eval "$CMD"
EOF

    chmod +x "/usr/local/bin/wstunnel-start.sh"
    
    # 重新加载systemd
    systemctl daemon-reload
    
    echo -e "${GREEN}systemd服务创建成功！${NC}"
}

# 启动服务
start_service() {
    if ! systemctl is-active --quiet wstunnel-client; then
        systemctl start wstunnel-client
        echo -e "${GREEN}wstunnel服务已启动${NC}"
    else
        echo -e "${YELLOW}wstunnel服务已在运行中${NC}"
    fi
    
    # 显示服务状态
    systemctl status wstunnel-client --no-pager
}

# 停止服务
stop_service() {
    if systemctl is-active --quiet wstunnel-client; then
        systemctl stop wstunnel-client
        echo -e "${GREEN}wstunnel服务已停止${NC}"
    else
        echo -e "${YELLOW}wstunnel服务未在运行${NC}"
    fi
}

# 重启服务
restart_service() {
    echo -e "${CYAN}正在重启wstunnel服务...${NC}"
    systemctl restart wstunnel-client
    sleep 2
    
    if systemctl is-active --quiet wstunnel-client; then
        echo -e "${GREEN}wstunnel服务重启成功${NC}"
    else
        echo -e "${RED}wstunnel服务重启失败${NC}"
        systemctl status wstunnel-client --no-pager
    fi
}

# 查看日志
view_logs() {
    echo -e "${CYAN}wstunnel服务日志：${NC}"
    journalctl -u wstunnel-client -n 50 --no-pager
}

# 主菜单
main_menu() {
    while true; do
        clear
        echo -e "${PURPLE}╔═══════════════════════════════════════════════════════════╗${NC}"
        echo -e "${PURPLE}║              ${WHITE}wstunnel 客户端管理脚本${PURPLE}                      ║${NC}"
        echo -e "${PURPLE}╚═══════════════════════════════════════════════════════════╝${NC}"
        echo ""
        
        # 显示IP信息
        get_ip_info
        
        # 显示服务状态
        if systemctl is-active --quiet wstunnel-client 2>/dev/null; then
            echo -e "服务状态: ${GREEN}● 运行中${NC}"
        else
            echo -e "服务状态: ${RED}● 已停止${NC}"
        fi
        
        # 显示服务器配置
        local server_url=$(cat "$CONFIG_FILE" 2>/dev/null | jq -r '.server.url' 2>/dev/null || echo "")
        if [ -n "$server_url" ] && [ "$server_url" != "null" ]; then
            echo -e "服务器: ${CYAN}$server_url${NC}"
        else
            echo -e "服务器: ${YELLOW}未配置${NC}"
        fi
        echo ""
        
        echo -e "${CYAN}转发管理：${NC}"
        echo "  1) 添加转发规则"
        echo "  2) 查看转发规则"
        echo "  3) 删除转发规则"
        echo "  4) 启用/禁用规则"
        echo ""
        echo -e "${CYAN}服务管理：${NC}"
        echo "  5) 配置服务器"
        echo "  6) 启动服务"
        echo "  7) 停止服务"
        echo "  8) 重启服务"
        echo "  9) 查看日志"
        echo ""
        echo -e "${CYAN}系统功能：${NC}"
        echo "  10) 安装/更新 wstunnel"
        echo "  11) 设置开机启动"
        echo "  12) 取消开机启动"
        echo ""
        echo "  0) 退出"
        echo ""
        read -p "请选择操作 [0-12]: " choice
        
        case $choice in
            1) add_tunnel ;;
            2) list_tunnels; echo ""; read -p "按回车键继续..." ;;
            3) delete_tunnel ;;
            4) toggle_tunnel ;;
            5) configure_server ;;
            6) start_service; echo ""; read -p "按回车键继续..." ;;
            7) stop_service; echo ""; read -p "按回车键继续..." ;;
            8) restart_service; echo ""; read -p "按回车键继续..." ;;
            9) view_logs; echo ""; read -p "按回车键继续..." ;;
            10) install_wstunnel; echo ""; read -p "按回车键继续..." ;;
            11) 
                systemctl enable wstunnel-client
                echo -e "${GREEN}已设置开机启动${NC}"
                echo ""; read -p "按回车键继续..."
                ;;
            12) 
                systemctl disable wstunnel-client
                echo -e "${GREEN}已取消开机启动${NC}"
                echo ""; read -p "按回车键继续..."
                ;;
            0) 
                echo -e "${GREEN}感谢使用，再见！${NC}"
                exit 0
                ;;
            *) 
                echo -e "${RED}无效的选择，请重试${NC}"
                sleep 2
                ;;
        esac
    done
}

# 检查依赖
check_dependencies() {
    local deps=("jq" "curl" "wget")
    local missing=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing+=("$dep")
        fi
    done
    
    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${YELLOW}正在安装缺失的依赖...${NC}"
        if command -v apt-get &> /dev/null; then
            apt-get update -qq
            apt-get install -y "${missing[@]}"
        elif command -v yum &> /dev/null; then
            yum install -y "${missing[@]}"
        else
            echo -e "${RED}无法自动安装依赖，请手动安装: ${missing[*]}${NC}"
            exit 1
        fi
    fi
}

# 主程序入口
main() {
    check_dependencies
    init_config
    
    # 检查wstunnel是否已安装
    if [ ! -f "$WSTUNNEL_BIN" ]; then
        echo -e "${YELLOW}检测到wstunnel未安装${NC}"
        install_wstunnel
    fi
    
    # 创建systemd服务（如果不存在）
    if [ ! -f "$SERVICE_DIR/wstunnel-client.service" ]; then
        create_service
    fi
    
    # 显示主菜单
    main_menu
}

# 运行主程序
main