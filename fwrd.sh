#!/bin/bash

# Forward Manager v3.0.0
# Unified management for Realm, GOST, and Brook forwarding tools
# Author: Forward Management Team
# Purpose: Professional multi-tool forwarding solution

set -o errexit
set -o nounset
set -o pipefail

# ==================== CONFIGURATION ====================

VERSION="3.0.0"
CONFIG_DIR="/etc/fwrd"
CONFIG_FILE="$CONFIG_DIR/config.json"
BACKUP_DIR="$CONFIG_DIR/backups"

# Tool-specific directories
REALM_DIR="/opt/realm"
REALM_CONFIG="$CONFIG_DIR/realm/config.toml"
GOST_CONFIG="$CONFIG_DIR/gost/config.json"
BROOK_CONFIG="$CONFIG_DIR/brook/forwards.conf"

# ==================== COLOR SYSTEM (Simplified 4-color) ====================

PLAIN='\033[0m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'

# Semantic color aliases
COLOR_INFO_TEXT="${BLUE}"
COLOR_SUCCESS="${GREEN}"
COLOR_ERROR="${RED}"
COLOR_WARNING="${YELLOW}"
COLOR_MENU_BORDER="${BLUE}"
COLOR_MENU_ITEM="${GREEN}"
COLOR_IP_INFO="${GREEN}"

# Unified symbols
SUCCESS_SYMBOL="${BOLD}${COLOR_SUCCESS}[+]${PLAIN}"
ERROR_SYMBOL="${BOLD}${COLOR_ERROR}[x]${PLAIN}"
INFO_SYMBOL="${BOLD}${COLOR_INFO_TEXT}[i]${PLAIN}"
WARN_SYMBOL="${BOLD}${COLOR_WARNING}[!]${PLAIN}"
OK_SYMBOL="${BOLD}${COLOR_SUCCESS}[OK]${PLAIN}"

# ==================== GLOBAL VARIABLES ====================

declare -A TOOL_STATUS=()
declare -A TOOL_VERSION=()
declare -A TOOL_SERVICE_STATUS=()

# Check for root/sudo
SUDO=""
if [ "$EUID" -ne 0 ]; then
    SUDO="sudo"
    if ! command -v sudo &>/dev/null; then
        printf "${ERROR_SYMBOL} This script requires sudo privileges${PLAIN}\n"
        exit 1
    fi
fi

# ==================== UTILITY FUNCTIONS ====================

show_loading() {
    local pid=$1
    local delay=0.2
    local spinstr='|/-\\'
    local temp
    printf " "
    while ps -p "$pid" &>/dev/null; do
        temp=${spinstr#?}
        printf "[%c]  " "$spinstr"
        spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\\b\\b\\b\\b\\b"
    done
    printf "\\b\\b\\b\\b\\b"
    printf "${OK_SYMBOL}\n"
}

log_info() {
    printf "${INFO_SYMBOL} %s${PLAIN}\n" "$*"
}

log_success() {
    printf "${SUCCESS_SYMBOL} %s${PLAIN}\n" "$*"
}

log_warn() {
    printf "${WARN_SYMBOL} %s${PLAIN}\n" "$*"
}

log_error() {
    printf "${ERROR_SYMBOL} %s${PLAIN}\n" "$*"
}

validate_port() {
    local port=$1
    if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
        return 0
    fi
    return 1
}

validate_ip() {
    local ip=$1
    # IPv4 validation
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        IFS='.' read -r -a octets <<<"$ip"
        for octet in "${octets[@]}"; do
            [ "$octet" -le 255 ] || return 1
        done
        return 0
    fi
    # IPv6 validation (basic)
    if [[ "$ip" =~ ^([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}$ ]]; then
        return 0
    fi
    # Domain name validation
    if [[ "$ip" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\.-]{0,61}[a-zA-Z0-9])?$ ]]; then
        return 0
    fi
    return 1
}

is_port_in_use() {
    local port=$1
    if lsof -i:"$port" >/dev/null 2>&1; then
        return 0
    fi
    if ss -tuln 2>/dev/null | grep -q ":${port} "; then
        return 0
    fi
    return 1
}

find_available_port() {
    local max_attempts=100
    for ((i=0; i<max_attempts; i++)); do
        local port=$(shuf -i 10000-65000 -n 1 2>/dev/null || echo $((RANDOM % 55000 + 10000)))
        if ! is_port_in_use "$port"; then
            echo "$port"
            return 0
        fi
    done
    log_error "无法找到可用端口"
    return 1
}

get_ip_info() {
    local ip=""
    if command -v ip &>/dev/null; then
        local default_if=$(ip route | grep '^default' | head -1 | awk '{print $5}')
        if [ -n "$default_if" ]; then
            ip=$(ip -4 addr show "$default_if" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
        fi
    fi
    if [ -z "$ip" ] && command -v ifconfig &>/dev/null; then
        ip=$(ifconfig 2>/dev/null | grep -Eo 'inet (addr:)?([0-9]*\.){3}[0-9]*' | grep -Eo '([0-9]*\.){3}[0-9]*' | grep -v '127.0.0.1' | head -1)
    fi
    echo "${ip:-无法获取IP}"
}

# ==================== SYSTEM SETUP ====================

setup_config_dirs() {
    log_info "初始化配置目录..."
    
    $SUDO mkdir -p "$CONFIG_DIR" "$BACKUP_DIR"
    $SUDO mkdir -p "$CONFIG_DIR/realm" "$CONFIG_DIR/gost" "$CONFIG_DIR/brook"
    
    if [ ! -f "$CONFIG_FILE" ]; then
        cat > /tmp/config.json << 'EOF'
{
  "version": "3.0.0",
  "rules": [],
  "global_settings": {
    "auto_tool_selection": true,
    "default_tool": "realm",
    "kernel_optimized": false,
    "protection_level": "balanced"
  }
}
EOF
        $SUDO mv /tmp/config.json "$CONFIG_FILE"
        $SUDO chmod 640 "$CONFIG_FILE"
    fi
    
    log_success "配置目录初始化完成"
}

optimize_system() {
    log_info "优化系统内核参数..."
    
    # 确保 conntrack 模块加载
    if ! lsmod | grep -q nf_conntrack; then
        $SUDO modprobe nf_conntrack 2>/dev/null || log_warn "无法加载 nf_conntrack 模块"
    fi
    
    # 连接跟踪优化
    $SUDO sysctl -w net.netfilter.nf_conntrack_max=1048576 >/dev/null 2>&1 || true
    $SUDO sysctl -w net.nf_conntrack_max=1048576 >/dev/null 2>&1 || true
    
    # TCP优化
    $SUDO sysctl -w net.core.somaxconn=65535 >/dev/null 2>&1
    $SUDO sysctl -w net.ipv4.tcp_max_syn_backlog=8192 >/dev/null 2>&1
    $SUDO sysctl -w net.ipv4.ip_local_port_range="1024 65535" >/dev/null 2>&1
    $SUDO sysctl -w net.ipv4.tcp_tw_reuse=1 >/dev/null 2>&1
    
    # 文件描述符优化
    $SUDO sysctl -w fs.file-max=1048576 >/dev/null 2>&1
    
    # 持久化配置
    local sysctl_conf="/etc/sysctl.d/99-fwrd.conf"
    cat > /tmp/99-fwrd.conf << 'EOF'
# FWRD forwarding optimizations
net.netfilter.nf_conntrack_max = 1048576
net.nf_conntrack_max = 1048576
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_tw_reuse = 1
fs.file-max = 1048576
net.ipv4.ip_forward = 1
EOF
    $SUDO mv /tmp/99-fwrd.conf "$sysctl_conf"
    
    # 启用IP转发
    $SUDO sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
    
    log_success "系统优化完成"
}

# ==================== TOOL DETECTION ====================

detect_realm() {
    if command -v realm &>/dev/null || [ -f "$REALM_DIR/realm" ]; then
        TOOL_STATUS[realm]="installed"
        if [ -x "$REALM_DIR/realm" ]; then
            TOOL_VERSION[realm]=$("$REALM_DIR/realm" --version 2>/dev/null | head -1 || echo "unknown")
        else
            TOOL_VERSION[realm]="unknown"
        fi
        
        if systemctl is-active --quiet realm 2>/dev/null; then
            TOOL_SERVICE_STATUS[realm]="active"
        else
            TOOL_SERVICE_STATUS[realm]="inactive"
        fi
    else
        TOOL_STATUS[realm]="not_installed"
        TOOL_SERVICE_STATUS[realm]="disabled"
    fi
}

detect_gost() {
    if command -v gost &>/dev/null; then
        TOOL_STATUS[gost]="installed"
        TOOL_VERSION[gost]=$(gost --version 2>/dev/null | head -1 || echo "unknown")
        
        if systemctl is-active --quiet gost 2>/dev/null; then
            TOOL_SERVICE_STATUS[gost]="active"
        else
            TOOL_SERVICE_STATUS[gost]="inactive"
        fi
    else
        TOOL_STATUS[gost]="not_installed"
        TOOL_SERVICE_STATUS[gost]="disabled"
    fi
}

detect_brook() {
    if command -v brook &>/dev/null; then
        TOOL_STATUS[brook]="installed"
        TOOL_VERSION[brook]=$(brook --version 2>/dev/null | head -1 || echo "unknown")
        
        # Brook可能有多个服务
        local brook_services=$(systemctl list-units --full -all | grep -c 'brook-forward.*\.service' || echo 0)
        if [ "$brook_services" -gt 0 ]; then
            TOOL_SERVICE_STATUS[brook]="active($brook_services)"
        else
            TOOL_SERVICE_STATUS[brook]="inactive"
        fi
    else
        TOOL_STATUS[brook]="not_installed"
        TOOL_SERVICE_STATUS[brook]="disabled"
    fi
}

detect_all_tools() {
    detect_realm
    detect_gost
    detect_brook
}

# ==================== TOOL INSTALLATION ====================

install_realm() {
    log_info "开始安装 Realm..."
    
    if ! command -v curl &>/dev/null; then
        log_error "需要 curl 命令"
        return 1
    fi
    
    $SUDO mkdir -p "$REALM_DIR"
    
    # 检测架构
    local arch=$(uname -m)
    local realm_arch
    case "$arch" in
        x86_64|amd64) realm_arch="x86_64-unknown-linux-gnu" ;;
        aarch64|arm64) realm_arch="aarch64-unknown-linux-gnu" ;;
        armv7l) realm_arch="arm-unknown-linux-gnueabi" ;;
        *) log_error "不支持的架构: $arch"; return 1 ;;
    esac
    
    # 获取最新版本
    local version=$(curl -s https://api.github.com/repos/zhboner/realm/releases/latest | grep -o '"tag_name": "v[^"]*' | sed 's/"tag_name": "v//' | head -1)
    if [ -z "$version" ]; then
        version="2.6.2"
        log_warn "无法获取最新版本，使用默认版本: $version"
    fi
    
    local download_url="https://github.com/zhboner/realm/releases/download/v${version}/realm-${realm_arch}.tar.gz"
    
    log_info "下载 Realm v${version}..."
    if curl -L -o /tmp/realm.tar.gz "$download_url"; then
        cd /tmp
        tar -xzf realm.tar.gz
        $SUDO mv realm "$REALM_DIR/"
        $SUDO chmod +x "$REALM_DIR/realm"
        $SUDO ln -sf "$REALM_DIR/realm" /usr/local/bin/realm 2>/dev/null || true
        rm -f /tmp/realm.tar.gz
        
        # 创建realm用户
        if ! id "realm" &>/dev/null; then
            $SUDO useradd --system --no-create-home --shell /bin/false realm 2>/dev/null || true
        fi
        
        # 初始化配置
        $SUDO mkdir -p "$(dirname "$REALM_CONFIG")"
        if [ ! -f "$REALM_CONFIG" ]; then
            cat > /tmp/realm_config.toml << 'EOF'
[network]
no_tcp = false
use_udp = true
ipv6_only = false
EOF
            $SUDO mv /tmp/realm_config.toml "$REALM_CONFIG"
            $SUDO chown realm:realm "$REALM_CONFIG"
            $SUDO chmod 640 "$REALM_CONFIG"
        fi
        
        create_realm_service
        log_success "Realm 安装成功"
        TOOL_STATUS[realm]="installed"
        return 0
    else
        log_error "Realm 下载失败"
        return 1
    fi
}

create_realm_service() {
    cat > /tmp/realm.service << EOF
[Unit]
Description=Realm Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=realm
Group=realm
Restart=on-failure
RestartSec=5s
ExecStart=$REALM_DIR/realm -c $REALM_CONFIG

# Security
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
LimitNOFILE=infinity
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE

# OOM Protection
OOMScoreAdjust=-900
OOMPolicy=continue

[Install]
WantedBy=multi-user.target
EOF
    $SUDO mv /tmp/realm.service /etc/systemd/system/realm.service
    $SUDO systemctl daemon-reload
    $SUDO systemctl enable realm >/dev/null 2>&1
}

install_gost() {
    log_info "开始安装 GOST..."
    
    if ! command -v curl &>/dev/null; then
        log_error "需要 curl 命令"
        return 1
    fi
    
    # 使用官方安装脚本
    (bash <(curl -fsSL https://github.com/go-gost/gost/raw/master/install.sh) --install) &
    show_loading $!
    
    if command -v gost &>/dev/null; then
        # 初始化GOST配置
        $SUDO mkdir -p "$(dirname "$GOST_CONFIG")"
        if [ ! -f "$GOST_CONFIG" ]; then
            echo '{"services":[]}' | $SUDO tee "$GOST_CONFIG" > /dev/null
            $SUDO chmod 640 "$GOST_CONFIG"
        fi
        
        # 创建gost用户
        if ! id "gost" &>/dev/null; then
            $SUDO useradd --system --no-create-home --shell /bin/false gost 2>/dev/null || true
        fi
        
        create_gost_service
        log_success "GOST 安装成功"
        TOOL_STATUS[gost]="installed"
        return 0
    else
        log_error "GOST 安装失败"
        return 1
    fi
}

create_gost_service() {
    cat > /tmp/gost.service << EOF
[Unit]
Description=GOST Proxy Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/gost -C $GOST_CONFIG
Restart=always
RestartSec=5
User=gost
Group=gost

# Security
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
LimitNOFILE=infinity
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE

# OOM Protection
OOMScoreAdjust=-900
OOMPolicy=continue

[Install]
WantedBy=multi-user.target
EOF
    $SUDO mv /tmp/gost.service /etc/systemd/system/gost.service
    $SUDO systemctl daemon-reload
    $SUDO systemctl enable gost >/dev/null 2>&1
}

install_brook() {
    log_info "开始安装 Brook..."
    
    if ! command -v curl &>/dev/null; then
        log_error "需要 curl 命令"
        return 1
    fi
    
    # 检测架构
    local arch=$(uname -m)
    local os=$(uname -s | tr '[:upper:]' '[:lower:]')
    local brook_arch
    
    case "$arch" in
        x86_64|amd64) brook_arch="amd64" ;;
        aarch64|arm64) brook_arch="arm64" ;;
        i386|i686) brook_arch="386" ;;
        *) log_error "不支持的架构: $arch"; return 1 ;;
    esac
    
    case "$os" in
        linux) brook_os="linux" ;;
        darwin) brook_os="darwin" ;;
        *) log_error "不支持的系统: $os"; return 1 ;;
    esac
    
    # 获取最新版本
    local version=$(curl -s https://api.github.com/repos/txthinking/brook/releases/latest | grep -o '"tag_name": "v[^"]*' | sed 's/"tag_name": "v//' | head -1)
    if [ -z "$version" ]; then
        version="20250202"
        log_warn "无法获取最新版本，使用默认版本: $version"
    fi
    
    local download_url="https://github.com/txthinking/brook/releases/download/v${version}/brook_${brook_os}_${brook_arch}"
    
    log_info "下载 Brook v${version}..."
    if curl -L -o /tmp/brook "$download_url"; then
        $SUDO mv /tmp/brook /usr/local/bin/brook
        $SUDO chmod +x /usr/local/bin/brook
        
        # 创建brook用户
        if ! id "brook" &>/dev/null; then
            $SUDO useradd --system --no-create-home --shell /bin/false brook 2>/dev/null || true
        fi
        
        # 初始化Brook配置目录
        $SUDO mkdir -p "$CONFIG_DIR/brook"
        if [ ! -f "$BROOK_CONFIG" ]; then
            $SUDO touch "$BROOK_CONFIG"
            $SUDO chmod 640 "$BROOK_CONFIG"
        fi
        
        log_success "Brook 安装成功"
        TOOL_STATUS[brook]="installed"
        return 0
    else
        log_error "Brook 下载失败"
        return 1
    fi
}

# ==================== TOOL RECOMMENDATION ====================

recommend_tool() {
    # 优先级: realm > gost > brook
    if [ "${TOOL_STATUS[realm]}" = "installed" ]; then
        echo "realm"
    elif [ "${TOOL_STATUS[gost]}" = "installed" ]; then
        echo "gost"
    elif [ "${TOOL_STATUS[brook]}" = "installed" ]; then
        echo "brook"
    else
        echo "none"
    fi
}

# ==================== FORWARD RULE MANAGEMENT ====================

add_rule_realm() {
    local listen_port=$1
    local target_ip=$2
    local target_port=$3
    local protocol=$4
    
    local use_tcp="false"
    local use_udp="false"
    
    case "$protocol" in
        tcp) use_tcp="true" ;;
        udp) use_udp="true" ;;
        both) use_tcp="true"; use_udp="true" ;;
    esac
    
    # 添加到Realm配置
    cat >> "$REALM_CONFIG" << EOF

[[endpoints]]
listen = "0.0.0.0:${listen_port}"
remote = "${target_ip}:${target_port}"
use_tcp = ${use_tcp}
use_udp = ${use_udp}
EOF
    
    $SUDO systemctl restart realm
    return $?
}

add_rule_gost() {
    local listen_port=$1
    local target_ip=$2
    local target_port=$3
    local protocol=$4
    
    local service_name="fwrd-${listen_port}-${protocol}"
    local listen_addr="0.0.0.0:${listen_port}"
    local target_addr="${target_ip}:${target_port}"
    
    if [ "$protocol" = "both" ]; then
        # 添加TCP服务
        jq --arg name "${service_name}-tcp" \
           --arg addr "$listen_addr" \
           --arg target "$target_addr" \
           '.services += [{
               name: $name,
               addr: $addr,
               handler: {type: "tcp"},
               listener: {type: "tcp"},
               forwarder: {nodes: [{name: "target-0", addr: $target}]}
           }]' "$GOST_CONFIG" > /tmp/gost_config.json
        $SUDO mv /tmp/gost_config.json "$GOST_CONFIG"
        
        # 添加UDP服务
        jq --arg name "${service_name}-udp" \
           --arg addr "$listen_addr" \
           --arg target "$target_addr" \
           '.services += [{
               name: $name,
               addr: $addr,
               handler: {type: "udp"},
               listener: {type: "udp"},
               forwarder: {nodes: [{name: "target-0", addr: $target}]}
           }]' "$GOST_CONFIG" > /tmp/gost_config.json
        $SUDO mv /tmp/gost_config.json "$GOST_CONFIG"
    else
        jq --arg name "$service_name" \
           --arg addr "$listen_addr" \
           --arg proto "$protocol" \
           --arg target "$target_addr" \
           '.services += [{
               name: $name,
               addr: $addr,
               handler: {type: $proto},
               listener: {type: $proto},
               forwarder: {nodes: [{name: "target-0", addr: $target}]}
           }]' "$GOST_CONFIG" > /tmp/gost_config.json
        $SUDO mv /tmp/gost_config.json "$GOST_CONFIG"
    fi
    
    $SUDO systemctl restart gost
    return $?
}

add_rule_brook() {
    local listen_port=$1
    local target_ip=$2
    local target_port=$3
    local protocol=$4
    
    local service_name="brook-forward-${listen_port}-${protocol}"
    local listen_addr=":${listen_port}"
    local target_addr="${target_ip}:${target_port}"
    
    # 创建Brook systemd服务
    cat > /tmp/${service_name}.service << EOF
[Unit]
Description=Brook Forward ${listen_addr} to ${target_addr} (${protocol})
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/brook relay -f ${listen_addr} -t ${target_addr}
Restart=always
RestartSec=5
User=brook
Group=brook
NoNewPrivileges=true
LimitNOFILE=infinity
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
OOMScoreAdjust=-900

[Install]
WantedBy=multi-user.target
EOF
    
    $SUDO mv /tmp/${service_name}.service /etc/systemd/system/${service_name}.service
    $SUDO systemctl daemon-reload
    $SUDO systemctl enable ${service_name} >/dev/null 2>&1
    $SUDO systemctl start ${service_name}
    
    # 记录到配置文件
    echo "${service_name}|${listen_addr}|${target_addr}|${protocol}" | $SUDO tee -a "$BROOK_CONFIG" > /dev/null
    
    return $?
}

update_master_config() {
    local rule_id=$1
    local tool=$2
    local listen_port=$3
    local target_ip=$4
    local target_port=$5
    local protocol=$6
    
    local temp_file=$(mktemp)
    jq --arg id "$rule_id" \
       --arg tool "$tool" \
       --arg listen_port "$listen_port" \
       --arg target_ip "$target_ip" \
       --arg target_port "$target_port" \
       --arg protocol "$protocol" \
       --arg created "$(date -Iseconds)" \
       '.rules += [{
           id: $id,
           tool: $tool,
           listen_port: ($listen_port | tonumber),
           target_ip: $target_ip,
           target_port: ($target_port | tonumber),
           protocol: $protocol,
           created: $created,
           enabled: true
       }]' "$CONFIG_FILE" > "$temp_file"
    
    $SUDO mv "$temp_file" "$CONFIG_FILE"
}

add_forward_rule() {
    local listen_port=$1
    local target_ip=$2
    local target_port=$3
    local protocol=$4
    local tool=${5:-auto}
    
    # 自动选择工具
    if [ "$tool" = "auto" ]; then
        tool=$(recommend_tool)
        if [ "$tool" = "none" ]; then
            log_error "没有已安装的转发工具"
            return 1
        fi
        log_info "自动选择工具: $tool"
    fi
    
    # 检查工具是否已安装
    if [ "${TOOL_STATUS[$tool]}" != "installed" ]; then
        log_error "工具 $tool 未安装"
        return 1
    fi
    
    # 生成规则ID
    local rule_id="rule_$(date +%s)_$(shuf -i 1000-9999 -n 1 2>/dev/null || echo $((RANDOM % 9000 + 1000)))"
    
    # 调用对应工具的添加函数
    case "$tool" in
        realm)
            if add_rule_realm "$listen_port" "$target_ip" "$target_port" "$protocol"; then
                update_master_config "$rule_id" "$tool" "$listen_port" "$target_ip" "$target_port" "$protocol"
                log_success "Realm 规则添加成功"
                return 0
            fi
            ;;
        gost)
            if add_rule_gost "$listen_port" "$target_ip" "$target_port" "$protocol"; then
                update_master_config "$rule_id" "$tool" "$listen_port" "$target_ip" "$target_port" "$protocol"
                log_success "GOST 规则添加成功"
                return 0
            fi
            ;;
        brook)
            if add_rule_brook "$listen_port" "$target_ip" "$target_port" "$protocol"; then
                update_master_config "$rule_id" "$tool" "$listen_port" "$target_ip" "$target_port" "$protocol"
                log_success "Brook 规则添加成功"
                return 0
            fi
            ;;
    esac
    
    log_error "规则添加失败"
    return 1
}

list_all_rules() {
    printf "\n${BOLD}${COLOR_MENU_BORDER}--- 当前转发规则 ---${PLAIN}\n"
    printf "${BOLD}%-5s %-8s %-6s %-20s %-6s %-10s %-10s${PLAIN}\n" \
           "#" "工具" "端口" "目标" "端口" "协议" "状态"
    printf "${COLOR_MENU_BORDER}%s${PLAIN}\n" "--------------------------------------------------------------------------------"
    
    local count=0
    if [ -f "$CONFIG_FILE" ]; then
        while read -r rule; do
            ((count++))
            local id=$(echo "$rule" | jq -r '.id')
            local tool=$(echo "$rule" | jq -r '.tool')
            local listen_port=$(echo "$rule" | jq -r '.listen_port')
            local target_ip=$(echo "$rule" | jq -r '.target_ip')
            local target_port=$(echo "$rule" | jq -r '.target_port')
            local protocol=$(echo "$rule" | jq -r '.protocol')
            
            # 检查状态
            local status="${COLOR_ERROR}未知${PLAIN}"
            case "$tool" in
                realm|gost)
                    if systemctl is-active --quiet "$tool" 2>/dev/null; then
                        status="${COLOR_SUCCESS}运行中${PLAIN}"
                    else
                        status="${COLOR_ERROR}已停止${PLAIN}"
                    fi
                    ;;
                brook)
                    local service_name="brook-forward-${listen_port}-${protocol}"
                    if systemctl is-active --quiet "$service_name" 2>/dev/null; then
                        status="${COLOR_SUCCESS}运行中${PLAIN}"
                    else
                        status="${COLOR_ERROR}已停止${PLAIN}"
                    fi
                    ;;
            esac
            
            printf "%-5s %-8s %-6s %-20s %-6s %-10s %b\n" \
                   "$count" "$tool" "$listen_port" "$target_ip" "$target_port" "$protocol" "$status"
        done < <(jq -c '.rules[]' "$CONFIG_FILE" 2>/dev/null)
    fi
    
    if [ "$count" -eq 0 ]; then
        printf "${WARN_SYMBOL} 没有找到转发规则${PLAIN}\n"
    else
        printf "\n${INFO_SYMBOL} 共 ${COLOR_INFO_ACCENT}%d${PLAIN} 条规则\n" "$count"
    fi
}

delete_forward_rule() {
    local rule_index=$1
    
    if [ ! -f "$CONFIG_FILE" ]; then
        log_error "配置文件不存在"
        return 1
    fi
    
    local rules_count=$(jq '.rules | length' "$CONFIG_FILE")
    
    if [ "$rule_index" -lt 1 ] || [ "$rule_index" -gt "$rules_count" ]; then
        log_error "无效的规则编号"
        return 1
    fi
    
    local rule=$(jq ".rules[$((rule_index-1))]" "$CONFIG_FILE")
    local id=$(echo "$rule" | jq -r '.id')
    local tool=$(echo "$rule" | jq -r '.tool')
    local listen_port=$(echo "$rule" | jq -r '.listen_port')
    local protocol=$(echo "$rule" | jq -r '.protocol')
    
    log_info "删除规则: $tool 端口 $listen_port..."
    
    # 根据工具类型删除
    case "$tool" in
        realm)
            # 从Realm配置中删除对应端点
            $SUDO sed -i "/listen = \"0.0.0.0:${listen_port}\"/,/^$/d" "$REALM_CONFIG"
            $SUDO systemctl restart realm
            ;;
        gost)
            # 从GOST配置中删除服务
            local service_name="fwrd-${listen_port}-${protocol}"
            jq --arg name "$service_name" \
               '.services = [.services[] | select(.name != $name and .name != ($name + "-tcp") and .name != ($name + "-udp"))]' \
               "$GOST_CONFIG" > /tmp/gost_config.json
            $SUDO mv /tmp/gost_config.json "$GOST_CONFIG"
            $SUDO systemctl restart gost
            ;;
        brook)
            # 停止并删除Brook服务
            local service_name="brook-forward-${listen_port}-${protocol}"
            $SUDO systemctl stop "$service_name" 2>/dev/null
            $SUDO systemctl disable "$service_name" 2>/dev/null
            $SUDO rm -f "/etc/systemd/system/${service_name}.service"
            $SUDO systemctl daemon-reload
            $SUDO sed -i "/^${service_name}|/d" "$BROOK_CONFIG"
            ;;
    esac
    
    # 从主配置删除
    local temp_file=$(mktemp)
    jq "del(.rules[$((rule_index-1))])" "$CONFIG_FILE" > "$temp_file"
    $SUDO mv "$temp_file" "$CONFIG_FILE"
    
    log_success "规则删除成功"
}

# ==================== INTERACTIVE MENU ====================

interactive_add_rule() {
    clear
    printf "\n${BOLD}${COLOR_MENU_BORDER}========== 添加转发规则 ==========${PLAIN}\n\n"
    
    # 选择工具
    printf "${COLOR_INFO_TEXT}选择转发工具:${PLAIN}\n"
    printf "  ${COLOR_MENU_ITEM}1.${PLAIN} 自动选择 (推荐)\n"
    printf "  ${COLOR_MENU_ITEM}2.${PLAIN} Realm - 高性能Rust代理\n"
    printf "  ${COLOR_MENU_ITEM}3.${PLAIN} GOST - 功能丰富的隧道\n"
    printf "  ${COLOR_MENU_ITEM}4.${PLAIN} Brook - 简洁高效\n"
    printf "\n"
    read -p "请选择 [1-4, 默认1]: " tool_choice
    tool_choice=${tool_choice:-1}
    
    local tool="auto"
    case "$tool_choice" in
        1) tool="auto" ;;
        2) tool="realm" ;;
        3) tool="gost" ;;
        4) tool="brook" ;;
        *) log_error "无效选择"; return 1 ;;
    esac
    
    # 选择协议
    printf "\n${COLOR_INFO_TEXT}选择转发协议:${PLAIN}\n"
    printf "  ${COLOR_MENU_ITEM}1.${PLAIN} 仅TCP\n"
    printf "  ${COLOR_MENU_ITEM}2.${PLAIN} 仅UDP\n"
    printf "  ${COLOR_MENU_ITEM}3.${PLAIN} TCP+UDP (默认)\n"
    printf "\n"
    read -p "请选择 [1-3, 默认3]: " proto_choice
    proto_choice=${proto_choice:-3}
    
    local protocol="both"
    case "$proto_choice" in
        1) protocol="tcp" ;;
        2) protocol="udp" ;;
        3) protocol="both" ;;
        *) log_error "无效选择"; return 1 ;;
    esac
    
    # 获取端口
    local listen_port
    printf "\n${COLOR_INFO_TEXT}本地监听端口 (留空自动选择): ${PLAIN}"
    read listen_port
    
    if [ -z "$listen_port" ]; then
        listen_port=$(find_available_port)
        if [ $? -ne 0 ]; then
            log_error "无法找到可用端口"
            return 1
        fi
        log_success "自动选择端口: $listen_port"
    else
        if ! validate_port "$listen_port"; then
            log_error "无效的端口号"
            return 1
        fi
        if is_port_in_use "$listen_port"; then
            log_warn "端口 $listen_port 可能已被占用"
            read -p "继续使用此端口? [y/N]: " confirm
            if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                return 1
            fi
        fi
    fi
    
    # 获取目标IP
    local target_ip
    while true; do
        printf "${COLOR_INFO_TEXT}目标IP或域名: ${PLAIN}"
        read target_ip
        if [ -n "$target_ip" ] && validate_ip "$target_ip"; then
            break
        else
            log_error "无效的IP地址或域名"
        fi
    done
    
    # 获取目标端口
    local target_port
    while true; do
        printf "${COLOR_INFO_TEXT}目标端口: ${PLAIN}"
        read target_port
        if validate_port "$target_port"; then
            break
        else
            log_error "无效的端口号"
        fi
    done
    
    # 显示摘要
    printf "\n${BOLD}${COLOR_WARNING}=== 规则摘要 ===${PLAIN}\n"
    printf "  工具: %s\n" "$tool"
    printf "  监听: 0.0.0.0:%s\n" "$listen_port"
    printf "  目标: %s:%s\n" "$target_ip" "$target_port"
    printf "  协议: %s\n" "$protocol"
    printf "${BOLD}${COLOR_WARNING}===================${PLAIN}\n\n"
    
    read -p "确认创建此规则? [Y/n]: " confirm
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        log_info "操作已取消"
        return 0
    fi
    
    # 添加规则
    if add_forward_rule "$listen_port" "$target_ip" "$target_port" "$protocol" "$tool"; then
        printf "\n${SUCCESS_SYMBOL} 规则创建成功！${PLAIN}\n"
        printf "访问地址: 0.0.0.0:%s -> %s:%s\n" "$listen_port" "$target_ip" "$target_port"
    else
        log_error "规则创建失败"
    fi
    
    printf "\n按回车键继续..."
    read
}

interactive_delete_rule() {
    clear
    list_all_rules
    
    local rules_count=$(jq '.rules | length' "$CONFIG_FILE" 2>/dev/null || echo 0)
    if [ "$rules_count" -eq 0 ]; then
        printf "\n按回车键继续..."
        read
        return
    fi
    
    printf "\n"
    read -p "请输入要删除的规则编号 (0取消): " rule_num
    
    if [ "$rule_num" -eq 0 ]; then
        log_info "操作已取消"
        printf "\n按回车键继续..."
        read
        return
    fi
    
    if [[ "$rule_num" =~ ^[0-9]+$ ]]; then
        printf "\n${BOLD}${COLOR_WARNING}确认删除规则 #%s?${PLAIN}\n" "$rule_num"
        printf "此操作无法撤销。\n\n"
        read -p "继续? [y/N]: " confirm
        
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            delete_forward_rule "$rule_num"
        else
            log_info "操作已取消"
        fi
    else
        log_error "无效的规则编号"
    fi
    
    printf "\n按回车键继续..."
    read
}

# ==================== MAIN MENU ====================

install_tools_menu() {
    while true; do
        clear
        printf "\n${BOLD}${COLOR_MENU_BORDER}========== 工具安装 ==========${PLAIN}\n\n"
        
        printf "${COLOR_INFO_TEXT}可用工具:${PLAIN}\n"
        printf "  ${COLOR_MENU_ITEM}1.${PLAIN} Realm - 高性能Rust代理 "
        [ "${TOOL_STATUS[realm]}" = "installed" ] && printf "${COLOR_SUCCESS}[已安装]${PLAIN}\n" || printf "${COLOR_ERROR}[未安装]${PLAIN}\n"
        
        printf "  ${COLOR_MENU_ITEM}2.${PLAIN} GOST - 功能丰富的隧道 "
        [ "${TOOL_STATUS[gost]}" = "installed" ] && printf "${COLOR_SUCCESS}[已安装]${PLAIN}\n" || printf "${COLOR_ERROR}[未安装]${PLAIN}\n"
        
        printf "  ${COLOR_MENU_ITEM}3.${PLAIN} Brook - 简洁高效 "
        [ "${TOOL_STATUS[brook]}" = "installed" ] && printf "${COLOR_SUCCESS}[已安装]${PLAIN}\n" || printf "${COLOR_ERROR}[未安装]${PLAIN}\n"
        
        printf "\n  ${COLOR_MENU_ITEM}0.${PLAIN} 返回主菜单\n\n"
        
        read -p "选择要安装的工具: " install_choice
        
        case "$install_choice" in
            1)
                if [ "${TOOL_STATUS[realm]}" = "installed" ]; then
                    log_info "Realm 已安装"
                else
                    install_realm
                fi
                detect_realm
                printf "\n按回车键继续..."
                read
                ;;
            2)
                if [ "${TOOL_STATUS[gost]}" = "installed" ]; then
                    log_info "GOST 已安装"
                else
                    install_gost
                fi
                detect_gost
                printf "\n按回车键继续..."
                read
                ;;
            3)
                if [ "${TOOL_STATUS[brook]}" = "installed" ]; then
                    log_info "Brook 已安装"
                else
                    install_brook
                fi
                detect_brook
                printf "\n按回车键继续..."
                read
                ;;
            0) return ;;
            *) log_error "无效选择"; sleep 1 ;;
        esac
    done
}

service_control_menu() {
    while true; do
        clear
        printf "\n${BOLD}${COLOR_MENU_BORDER}========== 服务管理 ==========${PLAIN}\n\n"
        
        printf "${BOLD}当前状态:${PLAIN}\n"
        for tool in realm gost brook; do
            if [ "${TOOL_STATUS[$tool]}" = "installed" ]; then
                local status="${TOOL_SERVICE_STATUS[$tool]}"
                printf "  %s: " "$tool"
                case "$status" in
                    active*) printf "${COLOR_SUCCESS}%s${PLAIN}\n" "$status" ;;
                    inactive) printf "${COLOR_WARNING}%s${PLAIN}\n" "$status" ;;
                    *) printf "${COLOR_ERROR}%s${PLAIN}\n" "$status" ;;
                esac
            fi
        done
        
        printf "\n${BOLD}操作:${PLAIN}\n"
        printf "  ${COLOR_MENU_ITEM}1.${PLAIN} 启动所有服务\n"
        printf "  ${COLOR_MENU_ITEM}2.${PLAIN} 停止所有服务\n"
        printf "  ${COLOR_MENU_ITEM}3.${PLAIN} 重启所有服务\n"
        printf "  ${COLOR_MENU_ITEM}4.${PLAIN} 查看服务状态\n"
        printf "  ${COLOR_MENU_ITEM}0.${PLAIN} 返回\n\n"
        
        read -p "选择: " choice
        case "$choice" in
            1)
                log_info "启动服务..."
                for tool in realm gost; do
                    if [ "${TOOL_STATUS[$tool]}" = "installed" ]; then
                        $SUDO systemctl start "$tool" 2>/dev/null && log_success "$tool 已启动"
                    fi
                done
                # Brook 服务需要单独处理
                if [ "${TOOL_STATUS[brook]}" = "installed" ]; then
                    for service in $(systemctl list-units --full -all | grep 'brook-forward.*\.service' | awk '{print $1}'); do
                        $SUDO systemctl start "$service" 2>/dev/null
                    done
                    log_success "Brook 服务已启动"
                fi
                detect_all_tools
                printf "\n按回车键继续..."
                read
                ;;
            2)
                log_info "停止服务..."
                for tool in realm gost; do
                    $SUDO systemctl stop "$tool" 2>/dev/null && log_success "$tool 已停止"
                done
                if [ "${TOOL_STATUS[brook]}" = "installed" ]; then
                    for service in $(systemctl list-units --full -all | grep 'brook-forward.*\.service' | awk '{print $1}'); do
                        $SUDO systemctl stop "$service" 2>/dev/null
                    done
                    log_success "Brook 服务已停止"
                fi
                detect_all_tools
                printf "\n按回车键继续..."
                read
                ;;
            3)
                log_info "重启服务..."
                for tool in realm gost; do
                    if [ "${TOOL_STATUS[$tool]}" = "installed" ]; then
                        $SUDO systemctl restart "$tool" 2>/dev/null && log_success "$tool 已重启"
                    fi
                done
                if [ "${TOOL_STATUS[brook]}" = "installed" ]; then
                    for service in $(systemctl list-units --full -all | grep 'brook-forward.*\.service' | awk '{print $1}'); do
                        $SUDO systemctl restart "$service" 2>/dev/null
                    done
                    log_success "Brook 服务已重启"
                fi
                detect_all_tools
                printf "\n按回车键继续..."
                read
                ;;
            4)
                printf "\n${BOLD}详细状态:${PLAIN}\n"
                for tool in realm gost; do
                    if [ "${TOOL_STATUS[$tool]}" = "installed" ]; then
                        printf "\n${BOLD}=== %s ===${PLAIN}\n" "$tool"
                        systemctl status "$tool" --no-pager -l
                    fi
                done
                printf "\n按回车键继续..."
                read
                ;;
            0) return ;;
            *) log_error "无效选择"; sleep 1 ;;
        esac
    done
}

backup_configs() {
    log_info "创建配置备份..."
    
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_file="$BACKUP_DIR/backup_${timestamp}.tar.gz"
    
    $SUDO mkdir -p "$BACKUP_DIR"
    
    $SUDO tar -czf "$backup_file" \
        -C / \
        etc/fwrd/config.json \
        etc/fwrd/realm \
        etc/fwrd/gost \
        etc/fwrd/brook \
        2>/dev/null || true
    
    # 只保留最近10个备份
    ls -t "$BACKUP_DIR"/backup_*.tar.gz 2>/dev/null | tail -n +11 | xargs $SUDO rm -f 2>/dev/null || true
    
    log_success "备份已创建: $backup_file"
    printf "\n按回车键继续..."
    read
}

show_main_menu() {
    while true; do
        clear
        local ip_info=$(get_ip_info)
        
        printf "\n${BOLD}${COLOR_MENU_BORDER}========== 转发管理器 (v%s) ==========${PLAIN}\n" "$VERSION"
        printf "${INFO_SYMBOL} 本机IP: ${COLOR_IP_INFO}%s${PLAIN}\n" "$ip_info"
        printf "${BOLD}${COLOR_MENU_BORDER}============================================${PLAIN}\n"
        
        # 工具状态
        printf "\n${BOLD}工具状态:${PLAIN}\n"
        for tool in realm gost brook; do
            printf "  %s: " "$tool"
            if [ "${TOOL_STATUS[$tool]}" = "installed" ]; then
                printf "${COLOR_SUCCESS}已安装${PLAIN} ("
                case "${TOOL_SERVICE_STATUS[$tool]}" in
                    active*) printf "${COLOR_SUCCESS}运行中${PLAIN}" ;;
                    inactive) printf "${COLOR_WARNING}已停止${PLAIN}" ;;
                    *) printf "${COLOR_ERROR}禁用${PLAIN}" ;;
                esac
                printf ")\n"
            else
                printf "${COLOR_ERROR}未安装${PLAIN}\n"
            fi
        done
        
        # 规则统计
        local rules_count=$(jq '.rules | length' "$CONFIG_FILE" 2>/dev/null || echo 0)
        printf "\n${BOLD}活动规则:${PLAIN} %d\n" "$rules_count"
        
        printf "\n${BOLD}${COLOR_MENU_BORDER}==== 功能菜单 ====${PLAIN}\n"
        printf "  ${COLOR_MENU_ITEM}1.${PLAIN} 安装/管理工具\n"
        printf "  ${COLOR_MENU_ITEM}2.${PLAIN} 添加转发规则\n"
        printf "  ${COLOR_MENU_ITEM}3.${PLAIN} 查看所有规则\n"
        printf "  ${COLOR_MENU_ITEM}4.${PLAIN} 删除规则\n"
        printf "  ${COLOR_MENU_ITEM}5.${PLAIN} 服务管理\n"
        printf "  ${COLOR_MENU_ITEM}6.${PLAIN} 备份配置\n"
        printf "  ${COLOR_MENU_ITEM}7.${PLAIN} 系统优化\n"
        printf "  ${COLOR_MENU_ITEM}0.${PLAIN} 退出\n"
        printf "${BOLD}${COLOR_MENU_BORDER}============================================${PLAIN}\n"
        printf "\n"
        
        read -p "请选择: " choice
        case "$choice" in
            1) install_tools_menu ;;
            2) interactive_add_rule ;;
            3) list_all_rules; printf "\n按回车键继续..."; read ;;
            4) interactive_delete_rule ;;
            5) service_control_menu ;;
            6) backup_configs ;;
            7)
                optimize_system
                printf "\n按回车键继续..."
                read
                ;;
            0)
                printf "\n${SUCCESS_SYMBOL} 感谢使用，再见！${PLAIN}\n"
                exit 0
                ;;
            *) log_error "无效选择"; sleep 1 ;;
        esac
    done
}

# ==================== MAIN EXECUTION ====================

main() {
    # 检查root权限
    if [ "$EUID" -ne 0 ] && [ -z "$SUDO" ]; then
        log_error "需要root权限或sudo"
        exit 1
    fi
    
    # 初始化
    setup_config_dirs
    detect_all_tools
    
    # 显示主菜单
    show_main_menu
}

# 运行主程序
main "$@"
