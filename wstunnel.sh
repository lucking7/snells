#!/bin/bash

# wstunnel管理脚本 - 简洁版
# 功能：新建、删除、管理wstunnel转发规则

# 颜色定义 - 只使用三种颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
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

# 获取本机IP信息 - 使用单一API
get_ip_info() {
    local ip_data=$(curl -s "http://ip-api.com/json/?fields=status,country,regionName,city,isp,org,as,query" 2>/dev/null)
    
    if [ -n "$ip_data" ] && echo "$ip_data" | grep -q '"status":"success"'; then
        local ipv4=$(echo "$ip_data" | grep -oP '"query":\s*"[^"]*"' | cut -d'"' -f4)
        local country=$(echo "$ip_data" | grep -oP '"country":\s*"[^"]*"' | cut -d'"' -f4)
        local city=$(echo "$ip_data" | grep -oP '"city":\s*"[^"]*"' | cut -d'"' -f4)
        local isp=$(echo "$ip_data" | grep -oP '"isp":\s*"[^"]*"' | cut -d'"' -f4)
        local as=$(echo "$ip_data" | grep -oP '"as":\s*"[^"]*"' | cut -d'"' -f4)
        
        # 获取IPv6
        local ipv6=$(curl -s -6 http://ip.sb 2>/dev/null || echo "")
        
        echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
        echo -e " IPv4: ${YELLOW}$ipv4${NC}"
        [ -n "$ipv6" ] && echo -e " IPv6: ${YELLOW}$ipv6${NC}"
        echo -e " 位置: ${YELLOW}$country, $city${NC}"
        echo -e " ISP : ${YELLOW}$isp${NC}"
        echo -e " ASN : ${YELLOW}$as${NC}"
        echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
    else
        echo -e "${YELLOW}IP信息获取中...${NC}"
    fi
}

# 获取随机可用端口
get_random_port() {
    local port
    while true; do
        port=$((RANDOM % 16383 + 49152))  # 49152-65535 动态端口范围
        if ! ss -tuln | grep -q ":$port "; then
            echo "$port"
            return
        fi
    done
}

# 检查是否支持IPv4/IPv6
check_ip_support() {
    local has_ipv4=false
    local has_ipv6=false
    
    ip -4 addr show | grep -q "inet " && has_ipv4=true
    ip -6 addr show | grep -q "inet6 " && has_ipv6=true
    
    echo "$has_ipv4:$has_ipv6"
}

# 安装wstunnel
install_wstunnel() {
    if [ -f "$WSTUNNEL_BIN" ]; then
        echo -e "${GREEN}✓ wstunnel已安装${NC}"
        return
    fi
    
    echo -e "${YELLOW}正在安装wstunnel...${NC}"
    
    # 检测系统架构
    ARCH=$(uname -m)
    case $ARCH in
        x86_64) ARCH_NAME="x86_64" ;;
        aarch64) ARCH_NAME="aarch64" ;;
        armv7l) ARCH_NAME="armv7" ;;
        *) echo -e "${RED}不支持的架构: $ARCH${NC}"; exit 1 ;;
    esac
    
    # 获取最新版本
    LATEST_VERSION=$(curl -s https://api.github.com/repos/erebe/wstunnel/releases/latest | grep -oP '"tag_name": "\K[^"]+')
    
    if [ -z "$LATEST_VERSION" ]; then
        echo -e "${RED}无法获取版本信息${NC}"
        exit 1
    fi
    
    # 下载二进制文件
    DOWNLOAD_URL="https://github.com/erebe/wstunnel/releases/download/${LATEST_VERSION}/wstunnel_${LATEST_VERSION}_linux_${ARCH_NAME}.tar.gz"
    
    cd /tmp
    wget -q --show-progress "$DOWNLOAD_URL" -O wstunnel.tar.gz || { echo -e "${RED}下载失败${NC}"; exit 1; }
    
    # 解压并安装
    tar -xzf wstunnel.tar.gz
    chmod +x wstunnel
    mv wstunnel "$WSTUNNEL_BIN"
    rm -f wstunnel.tar.gz
    
    echo -e "${GREEN}✓ wstunnel安装成功！${NC}"
}

# 配置服务器信息
configure_server() {
    echo -e "\n${GREEN}配置服务器信息${NC}"
    echo -e "${GREEN}─────────────────${NC}"
    
    # 读取当前配置
    local current_url=$(cat "$CONFIG_FILE" | jq -r '.server.url' 2>/dev/null)
    local current_secret=$(cat "$CONFIG_FILE" | jq -r '.server.secret' 2>/dev/null)
    
    [ -n "$current_url" ] && [ "$current_url" != "null" ] && echo -e "当前: $current_url"
    read -p "服务器URL [wss://example.com]: " server_url
    server_url=${server_url:-$current_url}
    
    [ -n "$current_secret" ] && [ "$current_secret" != "null" ] && echo -e "当前密钥: ***"
    read -p "密钥前缀 [留空跳过]: " secret
    secret=${secret:-$current_secret}
    
    # 更新配置
    jq ".server.url = \"$server_url\" | .server.secret = \"$secret\"" "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    
    echo -e "${GREEN}✓ 配置已保存${NC}"
}

# 添加转发规则
add_tunnel() {
    echo -e "\n${GREEN}添加转发规则${NC}"
    echo -e "${GREEN}─────────────${NC}"
    
    # 选择协议 - 默认TCP
    echo -e "协议: [1]TCP [2]UDP [3]TCP+UDP [4]SOCKS5"
    read -p "选择 [默认3]: " protocol_choice
    protocol_choice=${protocol_choice:-3}
    
    case $protocol_choice in
        1) protocol="tcp" ;;
        2) protocol="udp" ;;
        3) protocol="tcp+udp" ;;
        4) protocol="socks5" ;;
        *) protocol="tcp+udp" ;;
    esac
    
    # 选择监听地址 - 自动检测
    local ip_support=$(check_ip_support)
    local has_ipv4=$(echo "$ip_support" | cut -d':' -f1)
    local has_ipv6=$(echo "$ip_support" | cut -d':' -f2)
    
    if [ "$has_ipv4" = "true" ] && [ "$has_ipv6" = "true" ]; then
        echo -e "监听: [1]IPv4 [2]IPv6 [3]本地"
        read -p "选择 [默认1]: " addr_choice
        addr_choice=${addr_choice:-1}
    elif [ "$has_ipv4" = "true" ]; then
        addr_choice=1
    elif [ "$has_ipv6" = "true" ]; then
        addr_choice=2
    else
        addr_choice=3
    fi
    
    case $addr_choice in
        1) listen_addr="0.0.0.0" ;;
        2) listen_addr="[::]" ;;
        3) listen_addr="127.0.0.1" ;;
        *) listen_addr="0.0.0.0" ;;
    esac
    
    # 端口 - 支持随机
    read -p "本地端口 [回车随机]: " local_port
    if [ -z "$local_port" ]; then
        local_port=$(get_random_port)
        echo -e "已分配端口: ${YELLOW}$local_port${NC}"
    fi
    
    # SOCKS5不需要远程地址
    if [ "$protocol" != "socks5" ]; then
        read -p "目标地址 [必填]: " remote_host
        if [ -z "$remote_host" ]; then
            echo -e "${RED}目标地址不能为空${NC}"
            return
        fi
        
        read -p "目标端口 [默认同本地]: " remote_port
        remote_port=${remote_port:-$local_port}
        
        # UDP超时设置
        if [[ "$protocol" == *"udp"* ]]; then
            read -p "UDP超时(秒) [默认0-不超时]: " timeout
            timeout=${timeout:-0}
        fi
    fi
    
    # 备注 - 支持自动生成
    read -p "备注 [回车自动]: " comment
    if [ -z "$comment" ]; then
        if [ "$protocol" = "socks5" ]; then
            comment="SOCKS5-$local_port"
        else
            comment="${protocol^^}-${local_port}→${remote_host}:${remote_port}"
        fi
    fi
    
    # 生成唯一ID
    local tunnel_id=$(date +%s%N | md5sum | cut -c1-8)
    
    # 处理TCP+UDP
    if [ "$protocol" = "tcp+udp" ]; then
        # 添加TCP规则
        add_single_tunnel "$tunnel_id-tcp" "tcp" "$listen_addr" "$local_port" "$remote_host" "$remote_port" "" "$comment (TCP)"
        # 添加UDP规则
        add_single_tunnel "$tunnel_id-udp" "udp" "$listen_addr" "$local_port" "$remote_host" "$remote_port" "$timeout" "$comment (UDP)"
    else
        add_single_tunnel "$tunnel_id" "$protocol" "$listen_addr" "$local_port" "$remote_host" "$remote_port" "$timeout" "$comment"
    fi
    
    echo -e "\n${GREEN}✓ 转发规则添加成功！${NC}"
    
    # 重启服务
    restart_service
}

# 添加单个转发规则
add_single_tunnel() {
    local id=$1
    local proto=$2
    local listen=$3
    local lport=$4
    local rhost=$5
    local rport=$6
    local timeout=$7
    local comment=$8
    
    # 构建配置
    local tunnel_config=""
    if [ "$proto" = "socks5" ]; then
        tunnel_config="$proto://${listen}:${lport}"
    else
        tunnel_config="$proto://${listen}:${lport}:${rhost}:${rport}"
        [ "$proto" = "udp" ] && [ "$timeout" = "0" ] && tunnel_config="${tunnel_config}?timeout_sec=0"
    fi
    
    # 构建JSON对象
    local new_tunnel="{\"id\": \"$id\", \"protocol\": \"$proto\", \"listen_addr\": \"$listen\", \"local_port\": \"$lport\""
    [ "$proto" != "socks5" ] && new_tunnel="$new_tunnel, \"remote_host\": \"$rhost\", \"remote_port\": \"$rport\""
    [ "$proto" = "udp" ] && new_tunnel="$new_tunnel, \"timeout\": \"$timeout\""
    new_tunnel="$new_tunnel, \"config\": \"$tunnel_config\", \"comment\": \"$comment\", \"enabled\": true}"
    
    # 添加到配置
    local tmp_file="$CONFIG_FILE.tmp"
    jq ".tunnels += [$new_tunnel]" "$CONFIG_FILE" > "$tmp_file" && mv "$tmp_file" "$CONFIG_FILE"
}

# 列出所有转发规则
list_tunnels() {
    echo -e "\n${GREEN}转发规则列表${NC}"
    echo -e "${GREEN}═════════════════════════════════════════════════════════════${NC}"
    
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
        local remote_host=$(echo "$tunnel" | jq -r '.remote_host // ""')
        local remote_port=$(echo "$tunnel" | jq -r '.remote_port // ""')
        local comment=$(echo "$tunnel" | jq -r '.comment')
        local enabled=$(echo "$tunnel" | jq -r '.enabled')
        
        # 状态标记
        local status_mark=""
        if [ "$enabled" = "true" ]; then
            status_mark="${GREEN}●${NC}"
        else
            status_mark="${RED}○${NC}"
        fi
        
        # 显示规则
        echo -e "$status_mark [$index] $comment"
        echo -e "      ${protocol^^} ${listen_addr}:${local_port}"
        
        if [ -n "$remote_host" ]; then
            echo -e "      → ${remote_host}:${remote_port}"
        fi
        
        echo -e "${GREEN}─────────────────────────────────────────────────────────────${NC}"
        
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
    read -p "删除规则序号 [0取消]: " index
    
    if [ "$index" = "0" ] || [ -z "$index" ]; then
        return
    fi
    
    # 验证输入
    if ! [[ "$index" =~ ^[0-9]+$ ]] || [ "$index" -lt 1 ] || [ "$index" -gt "$tunnel_count" ]; then
        echo -e "${RED}无效的序号${NC}"
        return
    fi
    
    # 删除规则
    jq "del(.tunnels[$((index-1))])" "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    
    echo -e "${GREEN}✓ 已删除${NC}"
    restart_service
}

# 启用/禁用转发规则
toggle_tunnel() {
    list_tunnels
    
    local tunnel_count=$(cat "$CONFIG_FILE" | jq '.tunnels | length')
    if [ "$tunnel_count" -eq 0 ]; then
        return
    fi
    
    echo ""
    read -p "切换规则序号 [0取消]: " index
    
    if [ "$index" = "0" ] || [ -z "$index" ]; then
        return
    fi
    
    # 验证输入
    if ! [[ "$index" =~ ^[0-9]+$ ]] || [ "$index" -lt 1 ] || [ "$index" -gt "$tunnel_count" ]; then
        echo -e "${RED}无效的序号${NC}"
        return
    fi
    
    # 切换状态
    local current_status=$(cat "$CONFIG_FILE" | jq -r ".tunnels[$((index-1))].enabled")
    local new_status="true"
    [ "$current_status" = "true" ] && new_status="false"
    
    jq ".tunnels[$((index-1))].enabled = $new_status" "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    
    echo -e "${GREEN}✓ 已更新${NC}"
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

if [ -z "$SERVER_URL" ] || [ "$SERVER_URL" = "null" ]; then
    echo "错误：未配置服务器URL"
    exit 1
fi

# 构建wstunnel命令
CMD="/usr/local/bin/wstunnel client"

# 添加HTTP升级路径前缀（如果有）
if [ -n "$SECRET" ] && [ "$SECRET" != "null" ] && [ "$SECRET" != "" ]; then
    CMD="$CMD --http-upgrade-path-prefix $SECRET"
fi

# 添加所有启用的转发规则
TUNNELS=$(cat "$CONFIG_FILE" | jq -r '.tunnels[] | select(.enabled == true) | .config')

for tunnel in $TUNNELS; do
    CMD="$CMD -L $tunnel"
done

# 添加服务器URL
CMD="$CMD $SERVER_URL"

# 执行命令
echo "执行: $CMD"
eval "$CMD"
EOF

    chmod +x "/usr/local/bin/wstunnel-start.sh"
    systemctl daemon-reload
    
    echo -e "${GREEN}✓ 服务创建成功${NC}"
}

# 启动服务
start_service() {
    if ! systemctl is-active --quiet wstunnel-client; then
        systemctl start wstunnel-client
        echo -e "${GREEN}✓ 服务已启动${NC}"
    else
        echo -e "${YELLOW}服务已在运行${NC}"
    fi
}

# 停止服务
stop_service() {
    if systemctl is-active --quiet wstunnel-client; then
        systemctl stop wstunnel-client
        echo -e "${GREEN}✓ 服务已停止${NC}"
    else
        echo -e "${YELLOW}服务未运行${NC}"
    fi
}

# 重启服务
restart_service() {
    systemctl restart wstunnel-client
    sleep 1
    
    if systemctl is-active --quiet wstunnel-client; then
        echo -e "${GREEN}✓ 服务重启成功${NC}"
    else
        echo -e "${RED}✗ 服务重启失败${NC}"
    fi
}

# 查看日志
view_logs() {
    echo -e "\n${GREEN}最近日志${NC}"
    echo -e "${GREEN}═════════════════════════════════════════════════════════════${NC}"
    journalctl -u wstunnel-client -n 30 --no-pager
}

# 服务状态
service_status() {
    if systemctl is-active --quiet wstunnel-client 2>/dev/null; then
        echo -e "服务: ${GREEN}● 运行中${NC}"
        
        # 显示进程信息
        local pid=$(systemctl show -p MainPID wstunnel-client | cut -d= -f2)
        if [ "$pid" != "0" ]; then
            local mem=$(ps -p $pid -o rss= 2>/dev/null | awk '{printf "%.1f", $1/1024}')
            [ -n "$mem" ] && echo -e "内存: ${YELLOW}${mem}MB${NC}"
        fi
    else
        echo -e "服务: ${RED}○ 已停止${NC}"
    fi
    
    # 显示服务器
    local server_url=$(cat "$CONFIG_FILE" 2>/dev/null | jq -r '.server.url' 2>/dev/null || echo "")
    if [ -n "$server_url" ] && [ "$server_url" != "null" ] && [ "$server_url" != "" ]; then
        echo -e "服务器: ${YELLOW}$server_url${NC}"
    else
        echo -e "服务器: ${RED}未配置${NC}"
    fi
    
    # 显示活跃规则数
    local active_count=$(cat "$CONFIG_FILE" 2>/dev/null | jq '[.tunnels[] | select(.enabled == true)] | length' 2>/dev/null || echo "0")
    local total_count=$(cat "$CONFIG_FILE" 2>/dev/null | jq '.tunnels | length' 2>/dev/null || echo "0")
    echo -e "规则: ${YELLOW}$active_count/$total_count${NC}"
}

# 主菜单
main_menu() {
    while true; do
        clear
        echo -e "${GREEN}wstunnel 管理工具${NC}"
        echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
        
        # 显示服务状态
        service_status
        echo ""
        
        # 显示IP信息
        get_ip_info
        echo ""
        
        # 菜单选项
        echo -e "${GREEN}转发管理${NC}"
        echo -e " 1) 添加规则    2) 查看规则"
        echo -e " 3) 删除规则    4) 启用/禁用"
        echo ""
        echo -e "${GREEN}服务管理${NC}"
        echo -e " 5) 配置服务器  6) 启动服务"
        echo -e " 7) 停止服务    8) 重启服务"
        echo -e " 9) 查看日志"
        echo ""
        echo -e "${GREEN}系统管理${NC}"
        echo -e " a) 更新程序    b) 开机启动"
        echo -e " 0) 退出"
        echo ""
        read -p "请选择: " choice
        
        case $choice in
            1) add_tunnel ;;
            2) list_tunnels; echo ""; read -p "按回车继续..." ;;
            3) delete_tunnel ;;
            4) toggle_tunnel ;;
            5) configure_server ;;
            6) start_service; sleep 2 ;;
            7) stop_service; sleep 2 ;;
            8) restart_service; sleep 2 ;;
            9) view_logs; echo ""; read -p "按回车继续..." ;;
            a|A) install_wstunnel; echo ""; read -p "按回车继续..." ;;
            b|B) 
                if systemctl is-enabled --quiet wstunnel-client 2>/dev/null; then
                    systemctl disable wstunnel-client
                    echo -e "${GREEN}✓ 已取消开机启动${NC}"
                else
                    systemctl enable wstunnel-client
                    echo -e "${GREEN}✓ 已设置开机启动${NC}"
                fi
                sleep 2
                ;;
            0) echo -e "\n${GREEN}再见！${NC}"; exit 0 ;;
            *) echo -e "${RED}无效选择${NC}"; sleep 1 ;;
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
        echo -e "${YELLOW}安装依赖...${NC}"
        if command -v apt-get &> /dev/null; then
            apt-get update -qq
            apt-get install -y "${missing[@]}" >/dev/null 2>&1
        elif command -v yum &> /dev/null; then
            yum install -y "${missing[@]}" >/dev/null 2>&1
        else
            echo -e "${RED}请手动安装: ${missing[*]}${NC}"
            exit 1
        fi
    fi
}

# 主程序入口
main() {
    check_dependencies
    init_config
    
    # 检查wstunnel
    if [ ! -f "$WSTUNNEL_BIN" ]; then
        echo -e "${YELLOW}首次运行，正在初始化...${NC}"
        install_wstunnel
    fi
    
    # 创建服务
    if [ ! -f "$SERVICE_DIR/wstunnel-client.service" ]; then
        create_service
    fi
    
    # 显示主菜单
    main_menu
}

# 运行主程序
main