#!/bin/bash

# Forward Manager v1.0.0
# Unified management for GOST, NFTables, Realm forwarding tools
# Features: Auto-install, Rule management, Service control, Performance monitoring

set -euo pipefail

# ==================== Configuration ====================

VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="/etc/fwrd"
CONFIG_FILE="$CONFIG_DIR/config.json"
TOOLS_DIR="/opt/fwrd"

# Colors (use ANSI C quoting to emit real ESC)
declare -A COLORS=(
    [RED]=$'\033[0;31m'
    [GREEN]=$'\033[0;32m'
    [YELLOW]=$'\033[1;33m'
    [BLUE]=$'\033[0;34m'
    [PURPLE]=$'\033[0;35m'
    [CYAN]=$'\033[0;36m'
    [WHITE]=$'\033[1;37m'
    [BOLD]=$'\033[1m'
    [NC]=$'\033[0m'
)

# Symbols
SUCCESS="${COLORS[BOLD]}${COLORS[GREEN]}[✓]${COLORS[NC]}"
ERROR="${COLORS[BOLD]}${COLORS[RED]}[✗]${COLORS[NC]}"
INFO="${COLORS[BOLD]}${COLORS[BLUE]}[i]${COLORS[NC]}"
WARN="${COLORS[BOLD]}${COLORS[YELLOW]}[!]${COLORS[NC]}"

# Forward tools
declare -A FORWARD_TOOLS=(
    [gost]="GOST - Feature-rich tunnel"
    [nftables]="NFTables - Kernel-level forwarding" 
    [realm]="Realm - High-performance Rust proxy"
)

# Tool status tracking
declare -A TOOL_STATUS=()
declare -A TOOL_VERSION=()
declare -A TOOL_SERVICE_STATUS=()

# ==================== Core Functions ====================

log_info() { echo -e "${INFO} $*"; }
log_success() { echo -e "${SUCCESS} $*"; }
log_error() { echo -e "${ERROR} $*"; }
log_warn() { echo -e "${WARN} $*"; }

# Input sanitization and validation
sanitize_input() {
    local input="$1"
    # Remove leading/trailing whitespace and normalize
    echo "$input" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -s ' '
}

validate_ip() {
    local ip=$(sanitize_input "$1")
    # IPv4 validation
    if [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        IFS='.' read -r -a octets <<<"$ip"
        for octet in "${octets[@]}"; do
            [[ "$octet" -le 255 ]] || return 1
        done
        echo "$ip"
        return 0
    fi
    # IPv6 basic validation
    if [[ "$ip" =~ ^[0-9a-fA-F:]+$ ]] && [[ "$ip" == *":"* ]]; then
        echo "$ip"
        return 0
    fi
    # Domain name validation
    if [[ "$ip" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\.-]{0,61}[a-zA-Z0-9])?$ ]]; then
        echo "$ip"
        return 0
    fi
    return 1
}

validate_port() {
    local port=$(sanitize_input "$1")
    if [[ "$port" =~ ^[0-9]+$ ]] && [[ "$port" -ge 1 && "$port" -le 65535 ]]; then
        echo "$port"
        return 0
    fi
    return 1
}

# Resolve hostname to IPv4 (for nftables DNAT)
resolve_ipv4() {
    local host="$1"
    # If already IPv4, return directly
    if [[ "$host" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
        echo "$host"
        return 0
    fi
    # Try getent, then dig
    local ip
    ip=$(getent ahostsv4 "$host" 2>/dev/null | awk '/STREAM/ {print $1; exit}')
    if [[ -z "$ip" ]]; then
        ip=$(command -v dig >/dev/null 2>&1 && dig +short A "$host" | head -n1 || true)
    fi
    if [[ -n "$ip" ]]; then
        echo "$ip"
        return 0
    fi
    return 1
}

# Enhanced input validation with better user guidance
show_ip_help() {
    echo -e "${COLORS[YELLOW]}💡 IP地址格式帮助：${COLORS[NC]}"
    echo -e "   • IPv4: ${COLORS[CYAN]}192.168.1.1, 1.1.1.1${COLORS[NC]}"
    echo -e "   • IPv6: ${COLORS[CYAN]}2001:db8::1, ::1${COLORS[NC]}"
    echo -e "   • 域名: ${COLORS[CYAN]}google.com, example.org${COLORS[NC]}"
    echo -e "   • 输入 ${COLORS[CYAN]}?${COLORS[NC]} 显示此帮助"
}

get_valid_ip() {
    local prompt="$1"
    local default="${2:-}"
    local ip
    
    while true; do
        if [[ -n "$default" ]]; then
            read -p "$prompt [$default] (? 帮助): " ip
            ip=${ip:-$default}
        else
            read -p "$prompt (? 帮助): " ip
        fi
        
        # Show help if requested
        if [[ "$ip" == "?" ]]; then
            show_ip_help
            continue
        fi
        
        if [[ -z "$ip" && -n "$default" ]]; then
            echo "$default"
            return 0
        fi
        
        if [[ -z "$ip" ]]; then
            echo -e "${COLORS[RED]}❌ IP地址不能为空${COLORS[NC]}"
            show_ip_help
            continue
        fi
        
        if validated_ip=$(validate_ip "$ip"); then
            echo "$validated_ip"
            return 0
        else
            echo -e "${COLORS[RED]}❌ 无效的IP地址格式${COLORS[NC]}"
            show_ip_help
        fi
    done
}

show_port_help() {
    echo -e "${COLORS[YELLOW]}💡 端口号帮助：${COLORS[NC]}"
    echo -e "   • 范围: ${COLORS[CYAN]}1-65535${COLORS[NC]}"
    echo -e "   • 常用: ${COLORS[CYAN]}80(HTTP), 443(HTTPS), 8080(代理), 3000(开发)${COLORS[NC]}"
    echo -e "   • 避免: ${COLORS[RED]}22(SSH), 53(DNS), 25(SMTP)${COLORS[NC]} (系统保留)"
    echo -e "   • 推荐: ${COLORS[GREEN]}10000-65000${COLORS[NC]} (用户端口)"
    echo -e "   • 输入 ${COLORS[CYAN]}?${COLORS[NC]} 显示此帮助"
}

get_valid_port() {
    local prompt="$1"
    local default="${2:-}"
    local port
    
    while true; do
        if [[ -n "$default" ]]; then
            read -p "$prompt [$default] (? 帮助): " port
            port=${port:-$default}
        else
            read -p "$prompt (? 帮助): " port
        fi
        
        # Show help if requested
        if [[ "$port" == "?" ]]; then
            show_port_help
            continue
        fi
        
        if [[ -z "$port" && -n "$default" ]]; then
            echo "$default"
            return 0
        fi
        
        if [[ -z "$port" ]]; then
            echo -e "${COLORS[RED]}❌ 端口号不能为空${COLORS[NC]}"
            show_port_help
            continue
        fi
        
        if validated_port=$(validate_port "$port"); then
            # Check if port is in use
            if lsof -i :"$validated_port" >/dev/null 2>&1; then
                echo -e "${COLORS[YELLOW]}⚠️  警告：端口 $validated_port 可能正在使用${COLORS[NC]}"
                read -p "是否继续使用此端口? [y/N]: " confirm
                [[ "$confirm" =~ ^[Yy]$ ]] || continue
            fi
            echo "$validated_port"
            return 0
        else
            echo -e "${COLORS[RED]}❌ 无效端口号，必须在 1-65535 范围内${COLORS[NC]}"
            show_port_help
        fi
    done
}



# System check with better error handling
check_system() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${COLORS[RED]}❌ 需要管理员权限${COLORS[NC]}"
        echo -e "${COLORS[YELLOW]}💡 请使用 sudo 运行此脚本：${COLORS[NC]}"
        echo -e "${COLORS[CYAN]}   sudo bash $0${COLORS[NC]}"
        exit 1
    fi
    
    # Check and install missing commands
    local required_cmds=("curl" "jq" "systemctl" "lsof")
    local missing_commands=()
    
    for cmd in "${required_cmds[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_commands+=("$cmd")
        fi
    done
    
    if [[ ${#missing_commands[@]} -gt 0 ]]; then
        echo -e "${COLORS[YELLOW]}⚠️  正在安装缺少的依赖: ${missing_commands[*]}${COLORS[NC]}"
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -qq && apt-get install -y "${missing_commands[@]}" 2>/dev/null
        elif command -v yum >/dev/null 2>&1; then
            yum install -y "${missing_commands[@]}" 2>/dev/null
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y "${missing_commands[@]}" 2>/dev/null
        else
            log_error "无法自动安装依赖，请手动安装: ${missing_commands[*]}"
            exit 1
        fi
        
        # Verify installation
        for cmd in "${missing_commands[@]}"; do
            if ! command -v "$cmd" >/dev/null 2>&1; then
                log_error "安装 $cmd 失败，请手动安装"
                exit 1
            fi
        done
        log_success "依赖安装完成"
    fi
}

# Setup configuration
setup_config() {
    log_info "Setting up configuration..."
    
    mkdir -p "$CONFIG_DIR"/{rules,backups,logs}
    mkdir -p "$TOOLS_DIR"
    
    if [[ ! -f "$CONFIG_FILE" ]]; then
        cat > "$CONFIG_FILE" << 'EOF'
{
  "version": "1.0.0",
  "default_tool": "auto",
  "auto_start": true,
  "tools": {
    "gost": {"enabled": false, "config_path": "/etc/gost", "service_name": "gost"},
    "nftables": {"enabled": false, "config_path": "/etc/nftables.conf", "service_name": "nftables"},
    "realm": {"enabled": false, "config_path": "/root/.realm", "service_name": "realm"}
  },
  "rules": [],
  "global_settings": {
    "ip_forward": true,
    "log_level": "info",
    "max_rules": 100
  }
}
EOF
        log_success "Configuration created"
    fi
}

# Detect installed tools
detect_tools() {
    log_info "Detecting tools..."
    
    # GOST detection
    if command -v gost &> /dev/null; then
        TOOL_STATUS[gost]="installed"
        TOOL_VERSION[gost]=$(gost --version 2>/dev/null | head -1 || echo "unknown")
    else
        TOOL_STATUS[gost]="not_installed"
    fi
    
    # NFTables detection
    if command -v nft &> /dev/null; then
        TOOL_STATUS[nftables]="installed"
        TOOL_VERSION[nftables]=$(nft --version | head -1)
    else
        TOOL_STATUS[nftables]="not_installed"
    fi
    
    # Realm detection
    if [[ -f "/opt/fwrd/realm" ]] || command -v realm &> /dev/null; then
        TOOL_STATUS[realm]="installed"
        TOOL_VERSION[realm]=$(/opt/fwrd/realm --version 2>/dev/null || echo "unknown")
    else
        TOOL_STATUS[realm]="not_installed"
    fi
    
    # Service status with better error handling
    for tool in "${!FORWARD_TOOLS[@]}"; do
        if systemctl is-active --quiet "$tool" 2>/dev/null; then
            TOOL_SERVICE_STATUS[$tool]="active"
        elif systemctl is-enabled --quiet "$tool" 2>/dev/null; then
            TOOL_SERVICE_STATUS[$tool]="inactive"
        elif systemctl list-unit-files "$tool.service" 2>/dev/null | grep -q "$tool.service"; then
            TOOL_SERVICE_STATUS[$tool]="disabled"
        else
            TOOL_SERVICE_STATUS[$tool]="not_found"
        fi
    done
}

# Tool installation
install_gost() {
    log_info "Installing GOST..."
    
    # Check network connectivity first
    if ! curl -s --connect-timeout 10 --max-time 30 -I https://github.com >/dev/null 2>&1; then
        log_error "Network connectivity issue. Please check internet connection."
        return 1
    fi
    
    if timeout 300 curl -fsSL https://github.com/go-gost/gost/raw/master/install.sh | bash; then
        log_success "GOST installed"
        TOOL_STATUS[gost]="installed"
        return 0
    else
        log_error "GOST installation failed or timed out"
        return 1
    fi
}

install_nftables() {
    log_info "Installing NFTables..."
    if apt-get update && apt-get install -y nftables; then
        systemctl enable nftables
        log_success "NFTables installed"
        TOOL_STATUS[nftables]="installed"
        return 0
    else
        log_error "NFTables installation failed"
        return 1
    fi
}

install_realm() {
    log_info "Installing Realm..."
    
    local arch=$(uname -m)
    local realm_arch
    
    case "$arch" in
        x86_64) realm_arch="x86_64-unknown-linux-gnu" ;;
        aarch64) realm_arch="aarch64-unknown-linux-gnu" ;;
        armv7l) realm_arch="arm-unknown-linux-gnueabi" ;;
        *) log_error "Unsupported architecture: $arch"; return 1 ;;
    esac
    
    # Check network and get version with timeout
    local version
    if ! version=$(timeout 30 curl -s --connect-timeout 10 https://api.github.com/repos/zhboner/realm/releases/latest | jq -r '.tag_name // ""'); then
        log_warn "Failed to fetch latest version, using fallback"
        version="v2.6.2"
    fi
    [[ -z "$version" ]] && version="v2.6.2"
    
    local download_url="https://github.com/zhboner/realm/releases/download/${version}/realm-${realm_arch}.tar.gz"
    
    if timeout 300 curl -L --connect-timeout 10 --max-time 180 -o /tmp/realm.tar.gz "$download_url"; then
        tar -xzf /tmp/realm.tar.gz -C /tmp
        mv /tmp/realm "$TOOLS_DIR/realm"
        chmod +x "$TOOLS_DIR/realm"
        ln -sf "$TOOLS_DIR/realm" /usr/local/bin/realm
        rm -f /tmp/realm.tar.gz
        log_success "Realm installed"
        TOOL_STATUS[realm]="installed"
        return 0
    else
        log_error "Realm installation failed"
        return 1
    fi
}

# Recommend best tool
recommend_tool() {
    local protocol="$1"
    local performance_priority="${2:-normal}"
    
    case "$protocol-$performance_priority" in
        *-high)
            if [[ "${TOOL_STATUS[nftables]}" == "installed" ]]; then
                echo "nftables"
            elif [[ "${TOOL_STATUS[realm]}" == "installed" ]]; then
                echo "realm"
            else
                echo "gost"
            fi
            ;;
        *)
            if [[ "${TOOL_STATUS[gost]}" == "installed" ]]; then
                echo "gost"
            elif [[ "${TOOL_STATUS[nftables]}" == "installed" ]]; then
                echo "nftables"
            else
                echo "realm"
            fi
            ;;
    esac
}

# Add GOST rule
add_rule_gost() {
    local rule_id="$1"
    local listen_port="$2"
    local target_ip="$3"
    local target_port="$4"
    local protocol="$5"
    local listen_ip="${6:-0.0.0.0}"
    
    log_info "Adding GOST rule..."
    
    local config_file="/etc/gost/config.json"
    mkdir -p "$(dirname "$config_file")"
    
    if [[ ! -f "$config_file" ]]; then
        echo '{"services":[]}' > "$config_file"
    fi
    
    local service_name="fwrd-${rule_id}"
    local listen_addr="${listen_ip}:${listen_port}"
    local target_addr="${target_ip}:${target_port}"
    
    if [[ "$protocol" == "both" ]]; then
        jq --arg name "${service_name}-tcp" \
           --arg addr "$listen_addr" \
           --arg target "$target_addr" \
           '.services += [{name: $name, addr: $addr, handler: {type: "tcp"}, listener: {type: "tcp"}, forwarder: {nodes: [{name: "target-0", addr: $target}]}}]' \
           "$config_file" > "${config_file}.tmp"
        
        jq --arg name "${service_name}-udp" \
           --arg addr "$listen_addr" \
           --arg target "$target_addr" \
           '.services += [{name: $name, addr: $addr, handler: {type: "udp"}, listener: {type: "udp"}, forwarder: {nodes: [{name: "target-0", addr: $target}]}}]' \
           "${config_file}.tmp" > "$config_file"
        rm -f "${config_file}.tmp"
    else
        jq --arg name "$service_name" \
           --arg addr "$listen_addr" \
           --arg proto "$protocol" \
           --arg target "$target_addr" \
           '.services += [{name: $name, addr: $addr, handler: {type: $proto}, listener: {type: $proto}, forwarder: {nodes: [{name: "target-0", addr: $target}]}}]' \
           "$config_file" > "${config_file}.tmp" && mv "${config_file}.tmp" "$config_file"
    fi
    
    create_gost_service
    systemctl restart gost
    
    if systemctl is-active --quiet gost; then
        log_success "GOST rule added"
        return 0
    else
        log_error "GOST service failed"
        return 1
    fi
}

create_gost_service() {
    if ! id "gost" &>/dev/null; then
        useradd --system --no-create-home --shell /bin/false gost
    fi
    
    cat > "/etc/systemd/system/gost.service" << EOF
[Unit]
Description=GOST Proxy Service
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/gost -C /etc/gost/config.json
Restart=always
RestartSec=5
User=gost
Group=gost
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable gost
}

setup_nftables_chain() {
    # Create our custom table and chain if they don't exist
    if ! nft list tables 2>/dev/null | grep -q "fwrd_nat"; then
        if ! nft add table inet fwrd_nat 2>/dev/null; then
            log_error "Failed to create nftables table. Check permissions and nftables service."
            return 1
        fi
    fi
    if ! nft list chains inet fwrd_nat 2>/dev/null | grep -q "fwrd_prerouting"; then
        if ! nft add chain inet fwrd_nat fwrd_prerouting { type nat hook prerouting priority 0\; } 2>/dev/null; then
            log_error "Failed to create nftables chain. Check nftables configuration."
            return 1
        fi
    fi
    
    # Ensure the main nftables config includes our rules
    local nft_conf="/etc/nftables.conf"
    local fwrd_nft_conf="/etc/fwrd/nftables.conf"
    touch "$fwrd_nft_conf"
    if ! grep -q "include \"$fwrd_nft_conf\"" "$nft_conf" 2>/dev/null; then
        # If firewalld is active, add to its include file, otherwise main config
        local firewalld_include="/etc/firewalld/nftables/main.nft"
        local target_conf="$nft_conf"
        if systemctl is-active --quiet firewalld && [ -f "$firewalld_include" ]; then
            target_conf="$firewalld_include"
        fi
        
        if ! grep -q "include \"$fwrd_nft_conf\"" "$target_conf" 2>/dev/null; then
             echo "include \"$fwrd_nft_conf\"" >> "$target_conf"
        fi
    fi
    # Save current fwrd ruleset
    nft list table inet fwrd_nat > "$fwrd_nft_conf"
}

# Add NFTables rule
add_rule_nftables() {
    local rule_id="$1"
    local listen_port="$2"
    local target_ip="$3"
    local target_port="$4"
    local protocol="$5"
    local listen_ip="${6:-0.0.0.0}"
    
    log_info "Adding NFTables rule..."
    
    # Ensure our custom chain is set up
    setup_nftables_chain
    
    # Resolve domain to IPv4 for DNAT
    local dnat_ip
    if ! dnat_ip=$(resolve_ipv4 "$target_ip"); then
        log_error "Failed to resolve target IP for nftables: $target_ip"
        return 1
    fi
    
    local rule_comment="fwrd-${rule_id}"
    
    if [[ "$protocol" == "tcp" || "$protocol" == "both" ]]; then
        if ! nft add rule inet fwrd_nat fwrd_prerouting tcp dport "$listen_port" dnat to "${dnat_ip}:${target_port}" comment "\"$rule_comment\"" 2>/dev/null; then
            log_error "Failed to add TCP rule to nftables"
            return 1
        fi
    fi
    
    if [[ "$protocol" == "udp" || "$protocol" == "both" ]]; then
        if ! nft add rule inet fwrd_nat fwrd_prerouting udp dport "$listen_port" dnat to "${dnat_ip}:${target_port}" comment "\"$rule_comment\"" 2>/dev/null; then
            log_error "Failed to add UDP rule to nftables"
            # If TCP was added, try to clean it up
            if [[ "$protocol" == "both" ]]; then
                local tcp_handle=$(nft list chain inet fwrd_nat fwrd_prerouting -a 2>/dev/null | grep "fwrd-${rule_id}" | grep "tcp" | grep -o 'handle [0-9]*' | awk '{print $2}')
                [[ -n "$tcp_handle" ]] && nft delete rule inet fwrd_nat fwrd_prerouting handle "$tcp_handle" 2>/dev/null
            fi
            return 1
        fi
    fi
    
    # Persist the rules to our dedicated file
    nft list table inet fwrd_nat > /etc/fwrd/nftables.conf
    
    log_success "NFTables rule added"
    echo "${rule_id}|${protocol}|${listen_port}|${target_ip}|${target_port}|$(date)" >> "$CONFIG_DIR/nftables_rules.txt"
}

# Add Realm rule
add_rule_realm() {
    local rule_id="$1"
    local listen_port="$2"
    local target_ip="$3"
    local target_port="$4"
    local protocol="$5"
    local listen_ip="${6:-0.0.0.0}"
    
    log_info "Adding Realm rule..."
    
    local config_dir="/etc/realm"
    local config_file="$config_dir/config.toml"
    mkdir -p "$config_dir"
    chown -R realm:realm "$config_dir" 2>/dev/null || true
    
    if [[ ! -f "$config_file" ]]; then
        cat > "$config_file" << 'EOF'
[network]
no_tcp = false
use_udp = true
ipv6_only = false
EOF
        chown realm:realm "$config_file" 2>/dev/null || true
    fi
    
    local remark="Forward Rule ${rule_id}"
    cat >> "$config_file" << EOF

[[endpoints]]
# Remark: $remark
listen = "${listen_ip}:$listen_port"
remote = "$target_ip:$target_port"
use_tcp = $([[ "$protocol" == "tcp" || "$protocol" == "both" ]] && echo "true" || echo "false")
use_udp = $([[ "$protocol" == "udp" || "$protocol" == "both" ]] && echo "true" || echo "false")
EOF
    
    create_realm_service
    systemctl restart realm
    
    if systemctl is-active --quiet realm; then
        log_success "Realm rule added"
        return 0
    else
        log_error "Realm service failed"
        return 1
    fi
}

# Add Realm split rule (separate TCP/UDP targets) - 参考realm.sh实现
add_rule_realm_split() {
    local rule_id="$1"
    local listen_port="$2"
    local tcp_target_ip="$3"
    local tcp_target_port="$4"
    local udp_target_ip="$5"
    local udp_target_port="$6"
    local listen_ip="${7:-0.0.0.0}"
    
    log_info "Adding Realm split rule (TCP/UDP separation)..."
    
    local config_dir="/etc/realm"
    local config_file="$config_dir/config.toml"
    mkdir -p "$config_dir"
    chown -R realm:realm "$config_dir" 2>/dev/null || true
    
    if [[ ! -f "$config_file" ]]; then
        cat > "$config_file" << 'EOF'
[network]
no_tcp = false
use_udp = true
ipv6_only = false
EOF
        chown realm:realm "$config_file" 2>/dev/null || true
    fi
    
    local remark="Split Forward Rule ${rule_id}"
    
    # 添加TCP转发规则 - 参考realm.sh的方法
    cat >> "$config_file" << EOF

[[endpoints]]
# Remark: $remark - TCP
listen = "${listen_ip}:$listen_port"
remote = "$tcp_target_ip:$tcp_target_port"
use_tcp = true
use_udp = false
EOF

    # 添加UDP转发规则 - 参考realm.sh的方法
    cat >> "$config_file" << EOF

[[endpoints]]
# Remark: $remark - UDP
listen = "${listen_ip}:$listen_port"
remote = "$udp_target_ip:$udp_target_port"
use_tcp = false
use_udp = true
EOF
    
    create_realm_service
    systemctl restart realm
    
    if systemctl is-active --quiet realm; then
        log_success "Realm split rule added"
        log_info "TCP: ${listen_ip}:${listen_port} -> ${tcp_target_ip}:${tcp_target_port}"
        log_info "UDP: ${listen_ip}:${listen_port} -> ${udp_target_ip}:${udp_target_port}"
        return 0
    else
        log_error "Realm service failed"
        return 1
    fi
}

create_realm_service() {
    if ! id "realm" &>/dev/null; then
        useradd --system --no-create-home --shell /bin/false realm
    fi
    
    cat > "/etc/systemd/system/realm.service" << EOF
[Unit]
Description=Realm Service
After=network.target

[Service]
Type=simple
User=realm
Group=realm
Restart=on-failure
RestartSec=5s
ExecStart=$TOOLS_DIR/realm -c /etc/realm/config.toml
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable realm
}

# Unified add rule interface
add_forward_rule() {
    local listen_port="$1"
    local target_ip="$2"
    local target_port="$3"
    local protocol="$4"
    local tool="${5:-auto}"
    local listen_ip="${6:-0.0.0.0}"
    
    if [[ "$tool" == "auto" ]]; then
        tool=$(recommend_tool "$protocol" "normal")
        log_info "Auto-selected tool: $tool"
    fi
    
    if [[ "${TOOL_STATUS[$tool]}" != "installed" ]]; then
        log_error "Tool $tool not installed"
        return 1
    fi
    
    local rule_id=$(date +%s)_$(shuf -i 1000-9999 -n 1)
    
    case "$tool" in
        gost) add_rule_gost "$rule_id" "$listen_port" "$target_ip" "$target_port" "$protocol" "$listen_ip" ;;
        nftables) add_rule_nftables "$rule_id" "$listen_port" "$target_ip" "$target_port" "$protocol" "$listen_ip" ;;
        realm) add_rule_realm "$rule_id" "$listen_port" "$target_ip" "$target_port" "$protocol" "$listen_ip" ;;
        *) log_error "Unsupported tool: $tool"; return 1 ;;
    esac
    
    update_config_rule "$rule_id" "$listen_port" "$target_ip" "$target_port" "$protocol" "$tool" "$listen_ip"
}

# Validate and backup config file
validate_config() {
    local config_file="$1"
    if [[ ! -f "$config_file" ]]; then
        log_error "Config file not found: $config_file"
        return 1
    fi
    
    if ! jq '.' "$config_file" >/dev/null 2>&1; then
        log_error "Invalid JSON in config file: $config_file"
        # Try to restore from backup
        local backup_file="${config_file}.backup.$(date +%Y%m%d)"
        if [[ -f "$backup_file" ]]; then
            log_info "Attempting to restore from backup..."
            cp "$backup_file" "$config_file"
            if jq '.' "$config_file" >/dev/null 2>&1; then
                log_success "Config restored from backup"
                return 0
            fi
        fi
        return 1
    fi
    return 0
}

backup_config() {
    local config_file="$1"
    local backup_file="${config_file}.backup.$(date +%Y%m%d)"
    if [[ -f "$config_file" ]] && jq '.' "$config_file" >/dev/null 2>&1; then
        cp "$config_file" "$backup_file"
        # Keep only last 5 backups
        find "$(dirname "$config_file")" -name "$(basename "$config_file").backup.*" -type f | sort -r | tail -n +6 | xargs rm -f 2>/dev/null || true
    fi
}

# Update config file with rule
update_config_rule() {
    local rule_id="$1"
    local listen_port="$2"
    local target_ip="$3"
    local target_port="$4"
    local protocol="$5"
    local tool="$6"
    local listen_ip="$7"
    
    # Validate and backup existing config
    validate_config "$CONFIG_FILE" || return 1
    backup_config "$CONFIG_FILE"
    
    local temp_file=$(mktemp)
    if ! jq --arg id "$rule_id" \
       --arg listen_port "$listen_port" \
       --arg target_ip "$target_ip" \
       --arg target_port "$target_port" \
       --arg protocol "$protocol" \
       --arg tool "$tool" \
       --arg listen_ip "$listen_ip" \
       --arg created "$(date -Iseconds)" \
       '.rules += [{
           id: $id,
           listen_port: ($listen_port | tonumber),
           target_ip: $target_ip,
           target_port: ($target_port | tonumber),
           protocol: $protocol,
           tool: $tool,
           listen_ip: $listen_ip,
           created: $created,
           enabled: true
       }]' "$CONFIG_FILE" > "$temp_file" 2>/dev/null; then
        log_error "Failed to update config file"
        rm -f "$temp_file"
        return 1
    fi
    
    # Validate the new config before moving
    if jq '.' "$temp_file" >/dev/null 2>&1; then
        mv "$temp_file" "$CONFIG_FILE"
    else
        log_error "Generated invalid config, keeping original"
        rm -f "$temp_file"
        return 1
    fi
}

# List forward rules
list_forward_rules() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "${COLORS[YELLOW]}⚠️  配置文件不存在，正在初始化...${COLORS[NC]}"
        setup_config
        if [[ ! -f "$CONFIG_FILE" ]]; then
            log_error "无法创建配置文件 $CONFIG_FILE"
            log_error "请检查权限或手动运行: sudo mkdir -p $CONFIG_DIR"
        return 1
        fi
    fi
    
    # Check if jq is available
    if ! command -v jq >/dev/null 2>&1; then
        log_error "缺少 jq 命令，正在尝试安装..."
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update && apt-get install -y jq
        elif command -v yum >/dev/null 2>&1; then
            yum install -y jq
        else
            log_error "请手动安装 jq: apt-get install jq 或 yum install jq"
            return 1
        fi
    fi
    
    # Validate config file
    if ! jq '.' "$CONFIG_FILE" >/dev/null 2>&1; then
        log_error "配置文件损坏，正在重新创建..."
        backup_config "$CONFIG_FILE"
        setup_config
    fi
    
    local rules_count
    if ! rules_count=$(jq '.rules | length' "$CONFIG_FILE" 2>/dev/null); then
        # 在严格模式下避免退出：给予安全默认值并提示
        log_warn "无法读取配置文件，使用空规则列表"
        rules_count=0
    fi
    
    if [[ "$rules_count" -eq 0 ]]; then
        echo
        echo -e "${COLORS[CYAN]}📋 转发规则列表${COLORS[NC]}"
        echo "────────────────────────────────────────────────────────────────────────────────"
        echo -e "${COLORS[YELLOW]}暂无配置规则${COLORS[NC]}"
        echo
        echo -e "${COLORS[BLUE]}💡 提示：${COLORS[NC]}"
        echo "  • 选择选项 3 添加标准规则"
        echo "  • 选择选项 4 添加高级分离规则"
        echo -e "  • 选择选项 5 使用快速模板 ${COLORS[GREEN]}🚀${COLORS[NC]}"
        return 0
    fi
    
    echo
    printf "${COLORS[BOLD]}%-3s %-8s %-15s %-5s %-15s %-5s %-8s %-8s %-10s${COLORS[NC]}\n" \
           "#" "TOOL" "LISTEN_IP" "PORT" "TARGET_IP" "PORT" "PROTOCOL" "STATUS" "CREATED"
    echo "────────────────────────────────────────────────────────────────────────────────"
    
    local index=0
    while read -r rule; do
        ((index++))
        # 使用 // 提供字段默认值，避免 set -e 因 null 退出
        local id=$(echo "$rule" | jq -r '.id // "-"')
        local tool=$(echo "$rule" | jq -r '.tool // "-"')
        local listen_ip=$(echo "$rule" | jq -r '.listen_ip // "0.0.0.0"')
        local listen_port=$(echo "$rule" | jq -r '.listen_port // 0')
        local target_ip=$(echo "$rule" | jq -r '.target_ip // "-"')
        local target_port=$(echo "$rule" | jq -r '.target_port // 0')
        local protocol=$(echo "$rule" | jq -r '.protocol // "both"')
        local created=$(echo "$rule" | jq -r '.created // "-"' | cut -d'T' -f1)
        
        # Check service status
        local status="unknown"
        case "$tool" in
            gost|realm)
                if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet "$tool"; then
                    status="${COLORS[GREEN]}running${COLORS[NC]}"
                else
                    status="${COLORS[RED]}stopped${COLORS[NC]}"
                fi
                ;;
            nftables)
                if command -v nft >/dev/null 2>&1 && nft list ruleset 2>/dev/null | grep -q "fwrd-${id}"; then
                    status="${COLORS[GREEN]}active${COLORS[NC]}"
                else
                    status="${COLORS[RED]}inactive${COLORS[NC]}"
                fi
                ;;
        esac
        
        printf "%-3s %-8s %-15s %-5s %-15s %-5s %-8s %-16s %-10s\n" \
               "$index" "$tool" "$listen_ip" "$listen_port" "$target_ip" "$target_port" \
               "$protocol" "$status" "$created"
    # 若 .rules 不存在或为空，避免 jq 非零退出导致 set -e 触发
    done < <(jq -c '.rules // [] | .[]' "$CONFIG_FILE" 2>/dev/null || echo)
    
    echo
    log_info "Total: $rules_count rules"
}

# Delete forward rule
delete_forward_rule() {
    local rule_index="$1"
    
    if [[ ! "$rule_index" =~ ^[0-9]+$ ]]; then
        log_error "Invalid rule number"
        return 1
    fi
    
    local rules_count=$(jq '.rules | length' "$CONFIG_FILE")
    if [[ "$rule_index" -lt 1 || "$rule_index" -gt "$rules_count" ]]; then
        log_error "Rule number out of range (1-$rules_count)"
        return 1
    fi
    
    local rule=$(jq ".rules[$((rule_index-1))]" "$CONFIG_FILE")
    local id=$(echo "$rule" | jq -r '.id')
    local tool=$(echo "$rule" | jq -r '.tool')
    local listen_port=$(echo "$rule" | jq -r '.listen_port')
    local target_ip=$(echo "$rule" | jq -r '.target_ip')
    local target_port=$(echo "$rule" | jq -r '.target_port')
    local protocol=$(echo "$rule" | jq -r '.protocol')
    
    log_info "Deleting: $tool $listen_port -> $target_ip:$target_port ($protocol)"
    
    case "$tool" in
        gost)
            local config_file="/etc/gost/config.json"
            if [[ -f "$config_file" ]]; then
                jq --arg name "fwrd-${id}" \
                   '.services = [.services[] | select(.name != $name and .name != ($name + "-tcp") and .name != ($name + "-udp"))]' \
                   "$config_file" > "${config_file}.tmp" && mv "${config_file}.tmp" "$config_file"
                systemctl restart gost 2>/dev/null || true
            fi
            ;;
        nftables)
            # Find the rule handle by comment and delete it
            local handle=$(nft list chain inet fwrd_nat fwrd_prerouting -a | grep "fwrd-${id}" | grep -o 'handle [0-9]*' | awk '{print $2}')
            if [[ -n "$handle" ]]; then
                nft delete rule inet fwrd_nat fwrd_prerouting handle "$handle"
            else
                log_warn "Could not find NFTables rule handle for $id to delete."
            fi
            # Repersist rules
            nft list table inet fwrd_nat > /etc/fwrd/nftables.conf
            sed -i "/^${id}|/d" "$CONFIG_DIR/nftables_rules.txt" 2>/dev/null || true
            ;;
        realm)
            local config_file="/etc/realm/config.toml"
            if [[ -f "$config_file" ]]; then
                # Use a more robust method to remove the TOML block
                awk -v id="$id" '
                BEGIN { in_block=0; print_line=1 }
                /# Remark: Forward Rule / { if ($0 ~ id) in_block=1; }
                { if (!in_block) print $0; }
                /^$/ { if (in_block) { in_block=0; next; } }
                ' "$config_file" > "${config_file}.tmp" && mv "${config_file}.tmp" "$config_file"
                systemctl restart realm 2>/dev/null || true
            fi
            ;;
    esac
    
    # Remove from config
    local temp_file=$(mktemp)
    jq "del(.rules[$((rule_index-1))])" "$CONFIG_FILE" > "$temp_file" && mv "$temp_file" "$CONFIG_FILE"
    
    log_success "Rule deleted"
}

# Modify forward rule
modify_forward_rule() {
    local rule_index="$1"
    
    if [[ ! "$rule_index" =~ ^[0-9]+$ ]]; then
        log_error "Invalid rule number"
        return 1
    fi
    
    local rules_count=$(jq '.rules | length' "$CONFIG_FILE")
    if [[ "$rule_index" -lt 1 || "$rule_index" -gt "$rules_count" ]]; then
        log_error "Rule number out of range (1-$rules_count)"
        return 1
    fi
    
    local rule=$(jq ".rules[$((rule_index-1))]" "$CONFIG_FILE")
    local old_listen_port=$(echo "$rule" | jq -r '.listen_port')
    local old_target_ip=$(echo "$rule" | jq -r '.target_ip')
    local old_target_port=$(echo "$rule" | jq -r '.target_port')
    local old_protocol=$(echo "$rule" | jq -r '.protocol')
    
    echo "Current rule:"
    echo "  Listen port: $old_listen_port"
    echo "  Target: $old_target_ip:$old_target_port"
    echo "  Protocol: $old_protocol"
    echo
    
    # Get new values
    echo "Enter new values (press Enter to keep current):"
    local new_listen_port=$(get_valid_port "Listen port" "$old_listen_port")
    local new_target_ip=$(get_valid_ip "Target IP" "$old_target_ip")
    local new_target_port=$(get_valid_port "Target port" "$old_target_port")
    
    echo "Protocol options:"
    echo "  1) TCP"
    echo "  2) UDP"
    echo "  3) TCP + UDP"
    local current_proto_num
    case "$old_protocol" in
        tcp) current_proto_num=1 ;;
        udp) current_proto_num=2 ;;
        both) current_proto_num=3 ;;
    esac
    
    read -p "Select protocol [$current_proto_num]: " proto_choice
    proto_choice=${proto_choice:-$current_proto_num}
    
    local new_protocol
    case "$proto_choice" in
        1) new_protocol="tcp" ;;
        2) new_protocol="udp" ;;
        3) new_protocol="both" ;;
        *) new_protocol="$old_protocol" ;;
    esac
    
    # Check if anything changed
    if [[ "$new_listen_port" == "$old_listen_port" && \
          "$new_target_ip" == "$old_target_ip" && \
          "$new_target_port" == "$old_target_port" && \
          "$new_protocol" == "$old_protocol" ]]; then
        log_info "No changes made"
        return 0
    fi
    
    echo
    echo "Changes:"
    echo "  Listen port: $old_listen_port -> $new_listen_port"
    echo "  Target: $old_target_ip:$old_target_port -> $new_target_ip:$new_target_port"
    echo "  Protocol: $old_protocol -> $new_protocol"
    
    read -p "Apply changes? [y/N]: " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { log_info "Cancelled"; return 0; }
    
    # Delete old rule and add new one
    delete_forward_rule "$rule_index"
    add_forward_rule "$new_listen_port" "$new_target_ip" "$new_target_port" "$new_protocol"
    
    log_success "Rule modified"
}

# System status
show_system_status() {
    log_info "System Status"
    echo
    
    # IP forwarding
    local ip_forward=$(sysctl -n net.ipv4.ip_forward)
    echo "IP Forwarding: $([[ "$ip_forward" == "1" ]] && echo -e "${COLORS[GREEN]}enabled${COLORS[NC]}" || echo -e "${COLORS[RED]}disabled${COLORS[NC]}")"
    
    echo
    echo "Tool Status:"
    printf "%-12s %-12s %-15s %-12s\n" "TOOL" "INSTALLED" "VERSION" "SERVICE"
    echo "───────────────────────────────────────────────────────"
    
    for tool in "${!FORWARD_TOOLS[@]}"; do
        local install_status="${TOOL_STATUS[$tool]}"
        local version="${TOOL_VERSION[$tool]:-unknown}"
        local service_status="${TOOL_SERVICE_STATUS[$tool]:-disabled}"
        
        case "$install_status" in
            installed) install_status="${COLORS[GREEN]}yes${COLORS[NC]}" ;;
            *) install_status="${COLORS[RED]}no${COLORS[NC]}" ;;
        esac
        
        case "$service_status" in
            active) service_status="${COLORS[GREEN]}running${COLORS[NC]}" ;;
            inactive) service_status="${COLORS[YELLOW]}stopped${COLORS[NC]}" ;;
            *) service_status="${COLORS[RED]}disabled${COLORS[NC]}" ;;
        esac
        
        printf "%-20s %-20s %-15s %-20s\n" "$tool" "$install_status" "${version:0:12}" "$service_status"
    done
    
    echo
    local rules_count=$(jq '.rules | length' "$CONFIG_FILE" 2>/dev/null || echo 0)
    echo "Active rules: $rules_count"
    local connections
    if command -v ss >/dev/null 2>&1; then
        connections=$(ss -ant state established | tail -n +2 | wc -l)
    else
        connections=$(netstat -ant 2>/dev/null | grep ESTABLISHED | wc -l || echo 0)
    fi
    echo "Active connections: $connections"
}

# Generate available port
find_available_port() {
    local start_port=${1:-10000}
    local end_port=${2:-65000}
    
    for ((i=0; i<100; i++)); do
        local port=$((RANDOM % (end_port - start_port) + start_port))
        if ! lsof -i :"$port" >/dev/null 2>&1; then
            echo "$port"
            return 0
        fi
    done
    
    log_error "No available port found"
    return 1
}

# ==================== Interactive Menus ====================

show_main_menu() {
    clear
    echo -e "${COLORS[BOLD]}${COLORS[BLUE]}======================================${COLORS[NC]}"
    echo -e "${COLORS[BOLD]}${COLORS[BLUE]}    Forward Manager v${VERSION}${COLORS[NC]}"
    echo -e "${COLORS[BOLD]}${COLORS[BLUE]}======================================${COLORS[NC]}"
    echo
    echo "Tools:"
    echo "  1. Install tools"
    echo "  2. System status"
    echo
    echo "Rules:"
    echo "  3. Add rule (standard)"
    echo "  4. Add rule (advanced - separate TCP/UDP)"
    echo "  5. Add rule (templates) 🚀"
    echo "  6. List rules"
    echo "  7. Modify rule"
    echo "  8. Delete rule"
    echo
    echo "System:"
    echo "  9. Service control"
    echo "  10. Performance test"
    echo "  11. Health check"
    echo "  12. System diagnosis 🔍"
    echo
    echo "  0. Exit"
    echo
}

show_install_menu() {
    clear
    printf "${COLORS[BOLD]}Tool Installation${COLORS[NC]}\n"
    printf "\n"
    
    # Fixed, deterministic order
    local tools_order=(gost realm nftables)
    local index=1
    for tool in "${tools_order[@]}"; do
        local status="${TOOL_STATUS[$tool]}"
        local status_color
        case "$status" in
            installed) status_color="${COLORS[GREEN]}installed${COLORS[NC]}" ;;
            *) status_color="${COLORS[RED]}not installed${COLORS[NC]}" ;;
        esac
        printf "  %d. %s - %s (%s)\n" "$index" "$tool" "${FORWARD_TOOLS[$tool]}" "$status_color"
        ((index++))
    done
    
    printf "\n"
    printf "  0. Back\n"
    printf "\n"
}

# New simplified interactive add rule
interactive_add_rule() {
    clear
    echo -e "${COLORS[BOLD]}🚀 Add Forward Rule - Quick Setup${COLORS[NC]}"
    echo -e "${COLORS[CYAN]}Press Enter for defaults or enter custom values${COLORS[NC]}"
    echo
    
    # Step 1: Listen Port
    echo -e "${COLORS[BOLD]}Step 1: Listen Port${COLORS[NC]}"
    local listen_port
    while true; do
        read -p "Listen port (Enter for random): " listen_port
        if [[ -z "$listen_port" ]]; then
            listen_port=$(find_available_port) || return 1
            echo -e "  ${COLORS[GREEN]}✓ Auto-selected port: $listen_port${COLORS[NC]}"
            break
        elif validated_port=$(validate_port "$listen_port"); then
            listen_port="$validated_port"
            echo -e "  ${COLORS[GREEN]}✓ Using port: $listen_port${COLORS[NC]}"
            break
        else
            echo -e "  ${COLORS[RED]}✗ Invalid port. Enter 1-65535${COLORS[NC]}"
        fi
    done
    echo
    
    # Step 2: Target IP
    echo -e "${COLORS[BOLD]}Step 2: Target IP${COLORS[NC]}"
    local target_ip=$(get_valid_ip "Target IP")
    echo -e "  ${COLORS[GREEN]}✓ Target IP: $target_ip${COLORS[NC]}"
    echo
    
    # Step 3: Target Port
    echo -e "${COLORS[BOLD]}Step 3: Target Port${COLORS[NC]}"
    local target_port=$(get_valid_port "Target port")
    echo -e "  ${COLORS[GREEN]}✓ Target port: $target_port${COLORS[NC]}"
    echo
    
    # Step 4: Protocol (Simplified)
    echo -e "${COLORS[BOLD]}Step 4: Protocol${COLORS[NC]}"
    local protocol="both"
    echo "1) TCP only  2) UDP only  3) TCP+UDP"
    read -p "Protocol (Enter for TCP+UDP): " proto_input
    case "${proto_input,,}" in
        "1"|"tcp") protocol="tcp"; echo -e "  ${COLORS[GREEN]}✓ Protocol: TCP only${COLORS[NC]}" ;;
        "2"|"udp") protocol="udp"; echo -e "  ${COLORS[GREEN]}✓ Protocol: UDP only${COLORS[NC]}" ;;
        *) protocol="both"; echo -e "  ${COLORS[GREEN]}✓ Protocol: TCP + UDP (default)${COLORS[NC]}" ;;
    esac
    echo
    
    # Step 5: Tool Selection (Simplified)
    echo -e "${COLORS[BOLD]}Step 5: Tool Selection${COLORS[NC]}"
    local tool="auto"
    local available_tools=()
    local tool_display=""
    
    # Check available tools
    for t in gost realm nftables; do
        if [[ "${TOOL_STATUS[$t]}" == "installed" ]]; then
            available_tools+=("$t")
        fi
    done
    
    if [[ ${#available_tools[@]} -gt 0 ]]; then
        echo "Available: ${available_tools[*]} | auto-select"
        read -p "Tool (Enter for auto-select): " tool_input
        
        # Check if input matches available tool
        for available in "${available_tools[@]}"; do
            if [[ "${tool_input,,}" == "${available,,}" ]]; then
                tool="$available"
                tool_display="$available"
                break
            fi
        done
        
        if [[ "$tool" == "auto" ]]; then
            tool_display="auto-select"
        fi
    else
        echo "No tools installed - will use auto-select"
        tool_display="auto-select"
    fi
    
    echo -e "  ${COLORS[GREEN]}✓ Tool: $tool_display${COLORS[NC]}"
    echo
    
    # Step 6: Listen IP (Simplified)
    echo -e "${COLORS[BOLD]}Step 6: Listen IP${COLORS[NC]}"
    local listen_ip="0.0.0.0"
    read -p "Listen IP (Enter for 0.0.0.0): " ip_input
    if [[ -n "$ip_input" ]] && validated_ip=$(validate_ip "$ip_input"); then
        listen_ip="$validated_ip"
    fi
    echo -e "  ${COLORS[GREEN]}✓ Listen IP: $listen_ip${COLORS[NC]}"
    echo
    
    # Summary and Confirmation
    echo -e "${COLORS[YELLOW]}══════════════════════════════════════${COLORS[NC]}"
    echo -e "${COLORS[BOLD]}📋 RULE SUMMARY${COLORS[NC]}"
    echo -e "${COLORS[YELLOW]}══════════════════════════════════════${COLORS[NC]}"
    echo -e "  🎯 Forward: ${COLORS[CYAN]}$listen_ip:$listen_port${COLORS[NC]} → ${COLORS[CYAN]}$target_ip:$target_port${COLORS[NC]}"
    echo -e "  🔗 Protocol: ${COLORS[CYAN]}$protocol${COLORS[NC]}"
    echo -e "  🛠️  Tool: ${COLORS[CYAN]}$tool_display${COLORS[NC]}"
    echo -e "${COLORS[YELLOW]}══════════════════════════════════════${COLORS[NC]}"
    echo
    
    # Simple confirmation
    echo -e "${COLORS[BOLD]}Press Enter to CREATE this rule, or type 'n' to cancel:${COLORS[NC]}"
    read -p "> " final_confirm
    
    case "${final_confirm,,}" in
        ""|"y"|"yes")
            echo
            echo -e "${COLORS[BLUE]}🔄 Creating forwarding rule...${COLORS[NC]}"
        if add_forward_rule "$listen_port" "$target_ip" "$target_port" "$protocol" "$tool" "$listen_ip"; then
                echo
                echo -e "${COLORS[GREEN]}${COLORS[BOLD]}✅ SUCCESS!${COLORS[NC]}"
                echo -e "${COLORS[GREEN]}🎉 Rule created: $listen_ip:$listen_port → $target_ip:$target_port${COLORS[NC]}"
                echo -e "${COLORS[GREEN]}🔧 Using $tool_display with $protocol protocol${COLORS[NC]}"
            else
                echo
                echo -e "${COLORS[RED]}${COLORS[BOLD]}❌ FAILED!${COLORS[NC]}"
                echo -e "${COLORS[RED]}Unable to create forwarding rule${COLORS[NC]}"
            fi
            ;;
        *)
            echo -e "${COLORS[YELLOW]}❌ Operation cancelled${COLORS[NC]}"
            ;;
    esac
    
    echo
    read -p "Press Enter to continue..."
}

# Advanced rule with separate TCP/UDP targets
interactive_add_advanced_rule() {
    clear
    echo -e "${COLORS[BOLD]}🔧 Advanced Rule - Separate TCP/UDP Targets${COLORS[NC]}"
    echo -e "${COLORS[CYAN]}Configure different targets for TCP and UDP traffic${COLORS[NC]}"
    echo
    
    # Step 1: Listen Port (shared for both TCP and UDP)
    echo -e "${COLORS[BOLD]}Step 1: Listen Port (shared for TCP & UDP)${COLORS[NC]}"
    local listen_port
    while true; do
        read -p "Listen port (Enter for random): " listen_port
        if [[ -z "$listen_port" ]]; then
            listen_port=$(find_available_port) || return 1
            echo -e "  ${COLORS[GREEN]}✓ Auto-selected port: $listen_port${COLORS[NC]}"
            break
        elif validated_port=$(validate_port "$listen_port"); then
            listen_port="$validated_port"
            echo -e "  ${COLORS[GREEN]}✓ Using port: $listen_port${COLORS[NC]}"
            break
        else
            echo -e "  ${COLORS[RED]}✗ Invalid port. Enter 1-65535${COLORS[NC]}"
        fi
    done
    echo
    
    # Step 2: TCP Target
    echo -e "${COLORS[BOLD]}Step 2: TCP Target Configuration${COLORS[NC]}"
    local tcp_enabled="yes"
    read -p "Enable TCP forwarding? [Y/n]: " tcp_input
    if [[ "${tcp_input,,}" =~ ^n ]]; then
        tcp_enabled="no"
        echo -e "  ${COLORS[YELLOW]}⚠ TCP forwarding disabled${COLORS[NC]}"
        local tcp_target_ip=""
        local tcp_target_port=""
    else
        local tcp_target_ip=$(get_valid_ip "TCP target IP")
        echo -e "  ${COLORS[GREEN]}✓ TCP target IP: $tcp_target_ip${COLORS[NC]}"
        local tcp_target_port=$(get_valid_port "TCP target port")
        echo -e "  ${COLORS[GREEN]}✓ TCP target port: $tcp_target_port${COLORS[NC]}"
    fi
    echo
    
    # Step 3: UDP Target
    echo -e "${COLORS[BOLD]}Step 3: UDP Target Configuration${COLORS[NC]}"
    local udp_enabled="yes"
    read -p "Enable UDP forwarding? [Y/n]: " udp_input
    if [[ "${udp_input,,}" =~ ^n ]]; then
        udp_enabled="no"
        echo -e "  ${COLORS[YELLOW]}⚠ UDP forwarding disabled${COLORS[NC]}"
        local udp_target_ip=""
        local udp_target_port=""
    else
        local udp_target_ip=$(get_valid_ip "UDP target IP")
        echo -e "  ${COLORS[GREEN]}✓ UDP target IP: $udp_target_ip${COLORS[NC]}"
        local udp_target_port=$(get_valid_port "UDP target port")
        echo -e "  ${COLORS[GREEN]}✓ UDP target port: $udp_target_port${COLORS[NC]}"
    fi
    echo
    
    # Validation
    if [[ "$tcp_enabled" == "no" && "$udp_enabled" == "no" ]]; then
        log_error "At least one protocol (TCP or UDP) must be enabled"
        read -p "Press Enter to continue..."
        return 1
    fi
    
    # Step 4: Tool Selection
    echo -e "${COLORS[BOLD]}Step 4: Tool Selection${COLORS[NC]}"
    local tool="auto"
    local available_tools=()
    
    # GOST, NFTables, and Realm all support separate TCP/UDP targets
    for t in gost realm nftables; do
        if [[ "${TOOL_STATUS[$t]}" == "installed" ]]; then
            available_tools+=("$t")
        fi
    done
    
    if [[ ${#available_tools[@]} -gt 0 ]]; then
        echo "Available for advanced rules: ${available_tools[*]} | auto-select"
        echo -e "${COLORS[GREEN]}All tools support separate TCP/UDP targets${COLORS[NC]}"
        read -p "Tool (Enter for auto-select): " tool_input
        
        for available in "${available_tools[@]}"; do
            if [[ "${tool_input,,}" == "${available,,}" ]]; then
                tool="$available"
                break
            fi
        done
    else
        echo -e "${COLORS[RED]}No suitable tools installed for advanced rules${COLORS[NC]}"
        echo "Please install GOST or NFTables first"
        read -p "Press Enter to continue..."
        return 1
    fi
    
    echo -e "  ${COLORS[GREEN]}✓ Tool: ${tool:-auto-select}${COLORS[NC]}"
    echo
    
    # Step 5: Listen IP
    echo -e "${COLORS[BOLD]}Step 5: Listen IP${COLORS[NC]}"
    local listen_ip="0.0.0.0"
    read -p "Listen IP (Enter for 0.0.0.0): " ip_input
    if [[ -n "$ip_input" ]] && validated_ip=$(validate_ip "$ip_input"); then
        listen_ip="$validated_ip"
    fi
    echo -e "  ${COLORS[GREEN]}✓ Listen IP: $listen_ip${COLORS[NC]}"
    echo
    
    # Summary
    echo -e "${COLORS[YELLOW]}══════════════════════════════════════${COLORS[NC]}"
    echo -e "${COLORS[BOLD]}📋 ADVANCED RULE SUMMARY${COLORS[NC]}"
    echo -e "${COLORS[YELLOW]}══════════════════════════════════════${COLORS[NC]}"
    echo -e "  🎯 Listen: ${COLORS[CYAN]}$listen_ip:$listen_port${COLORS[NC]}"
    if [[ "$tcp_enabled" == "yes" ]]; then
        echo -e "  📡 TCP → ${COLORS[CYAN]}$tcp_target_ip:$tcp_target_port${COLORS[NC]}"
    else
        echo -e "  📡 TCP → ${COLORS[RED]}disabled${COLORS[NC]}"
    fi
    if [[ "$udp_enabled" == "yes" ]]; then
        echo -e "  📡 UDP → ${COLORS[CYAN]}$udp_target_ip:$udp_target_port${COLORS[NC]}"
    else
        echo -e "  📡 UDP → ${COLORS[RED]}disabled${COLORS[NC]}"
    fi
    echo -e "  🛠️  Tool: ${COLORS[CYAN]}${tool:-auto-select}${COLORS[NC]}"
    echo -e "${COLORS[YELLOW]}══════════════════════════════════════${COLORS[NC]}"
    echo
    
    # Confirmation
    echo -e "${COLORS[BOLD]}Press Enter to CREATE these advanced rules, or type 'n' to cancel:${COLORS[NC]}"
    read -p "> " final_confirm
    
    case "${final_confirm,,}" in
        ""|"y"|"yes")
            echo
            echo -e "${COLORS[BLUE]}🔄 Creating advanced forwarding rules...${COLORS[NC]}"
            
            local success=0
            
            # Special handling for Realm split rules (参考realm.sh的优化方法)
            if [[ "$tool" == "realm" ]] && [[ "$tcp_enabled" == "yes" ]] && [[ "$udp_enabled" == "yes" ]]; then
                # Use the new Realm split function for optimal configuration
                local rule_id=$(date +%s)_$(shuf -i 1000-9999 -n 1)
                if add_rule_realm_split "$rule_id" "$listen_port" "$tcp_target_ip" "$tcp_target_port" "$udp_target_ip" "$udp_target_port" "$listen_ip"; then
                    echo -e "${COLORS[GREEN]}✅ Realm split rules created successfully${COLORS[NC]}"
                    success=2  # Count as both TCP and UDP success
                else
                    echo -e "${COLORS[RED]}❌ Failed to create Realm split rules${COLORS[NC]}"
                fi
            else
                # Standard separate rule creation for other tools or single protocol
                
                # Create TCP rule if enabled
                if [[ "$tcp_enabled" == "yes" ]]; then
                    if add_forward_rule "$listen_port" "$tcp_target_ip" "$tcp_target_port" "tcp" "$tool" "$listen_ip"; then
                        echo -e "${COLORS[GREEN]}✅ TCP rule created successfully${COLORS[NC]}"
                        ((success++))
                    else
                        echo -e "${COLORS[RED]}❌ Failed to create TCP rule${COLORS[NC]}"
                    fi
                fi
                
                # Create UDP rule if enabled
                if [[ "$udp_enabled" == "yes" ]]; then
                    if add_forward_rule "$listen_port" "$udp_target_ip" "$udp_target_port" "udp" "$tool" "$listen_ip"; then
                        echo -e "${COLORS[GREEN]}✅ UDP rule created successfully${COLORS[NC]}"
                        ((success++))
                    else
                        echo -e "${COLORS[RED]}❌ Failed to create UDP rule${COLORS[NC]}"
                    fi
                fi
            fi
            
            echo
            if [[ $success -gt 0 ]]; then
                echo -e "${COLORS[GREEN]}${COLORS[BOLD]}🎉 Advanced rules created!${COLORS[NC]}"
                if [[ "$tcp_enabled" == "yes" ]]; then
                    echo -e "${COLORS[GREEN]}📡 TCP: $listen_ip:$listen_port → $tcp_target_ip:$tcp_target_port${COLORS[NC]}"
                fi
                if [[ "$udp_enabled" == "yes" ]]; then
                    echo -e "${COLORS[GREEN]}📡 UDP: $listen_ip:$listen_port → $udp_target_ip:$udp_target_port${COLORS[NC]}"
                fi
            else
                echo -e "${COLORS[RED]}${COLORS[BOLD]}❌ Failed to create rules${COLORS[NC]}"
            fi
            ;;
        *)
            echo -e "${COLORS[YELLOW]}❌ Operation cancelled${COLORS[NC]}"
            ;;
    esac
    
    echo
    read -p "Press Enter to continue..."
}

# Quick templates for common forwarding scenarios
quick_templates() {
    clear
    echo -e "${COLORS[BOLD]}🚀 快速模板 - 常用转发场景${COLORS[NC]}"
    echo -e "${COLORS[CYAN]}选择预设模板快速创建转发规则${COLORS[NC]}"
    echo
    
    echo "📋 可用模板："
    echo -e "  1. ${COLORS[GREEN]}HTTP 代理${COLORS[NC]} (80 → 目标服务器)"
    echo -e "  2. ${COLORS[GREEN]}HTTPS 代理${COLORS[NC]} (443 → 目标服务器)"
    echo -e "  3. ${COLORS[BLUE]}SSH 转发${COLORS[NC]} (2222 → 22)"
    echo -e "  4. ${COLORS[PURPLE]}DNS 转发${COLORS[NC]} (5353 → 53, TCP+UDP分离)"
    echo -e "  5. ${COLORS[YELLOW]}开发服务器${COLORS[NC]} (3000/8080 → 目标)"
    echo -e "  6. ${COLORS[CYAN]}游戏服务器${COLORS[NC]} (自定义端口 → UDP)"
    echo -e "  7. ${COLORS[RED]}数据库代理${COLORS[NC]} (33306 → MySQL 3306)"
    echo -e "  8. ${COLORS[GREEN]}返回主菜单${COLORS[NC]}"
    echo
    
    read -p "选择模板 [1-8]: " template_choice
    
    case "$template_choice" in
        1) template_http_proxy ;;
        2) template_https_proxy ;;
        3) template_ssh_forward ;;
        4) template_dns_split ;;
        5) template_dev_server ;;
        6) template_game_server ;;
        7) template_database_proxy ;;
        8) return ;;
        *) 
            echo -e "${COLORS[RED]}❌ 无效选择${COLORS[NC]}"
            read -p "Press Enter to continue..."
            quick_templates
            ;;
    esac
}

# Template: HTTP Proxy
template_http_proxy() {
    echo -e "${COLORS[BOLD]}🌐 HTTP 代理模板${COLORS[NC]}"
    echo -e "${COLORS[YELLOW]}监听端口 80，转发到目标 HTTP 服务器${COLORS[NC]}"
    echo
    
    local target_ip=$(get_valid_ip "目标服务器IP")
    local target_port=$(get_valid_port "目标服务器端口" "80")
    local listen_port=$(get_valid_port "本地监听端口" "8080")
    
    echo
    echo -e "${COLORS[BLUE]}🔄 创建 HTTP 代理转发规则...${COLORS[NC]}"
    
    if add_forward_rule "$listen_port" "$target_ip" "$target_port" "tcp" "auto" "0.0.0.0"; then
        echo -e "${COLORS[GREEN]}✅ HTTP 代理创建成功！${COLORS[NC]}"
        echo -e "${COLORS[CYAN]}🔗 访问地址: http://localhost:$listen_port${COLORS[NC]}"
        echo -e "${COLORS[CYAN]}📍 转发至: http://$target_ip:$target_port${COLORS[NC]}"
    else
        echo -e "${COLORS[RED]}❌ 创建失败${COLORS[NC]}"
    fi
    
    echo
    read -p "Press Enter to continue..."
}

# Template: DNS Split Forward
template_dns_split() {
    echo -e "${COLORS[BOLD]}🔍 DNS 分离转发模板${COLORS[NC]}"
    echo -e "${COLORS[YELLOW]}TCP 和 UDP 转发到不同的 DNS 服务器${COLORS[NC]}"
    echo
    
    local listen_port=$(get_valid_port "本地监听端口" "5353")
    local tcp_dns=$(get_valid_ip "TCP DNS服务器" "1.1.1.1")
    local udp_dns=$(get_valid_ip "UDP DNS服务器" "8.8.8.8")
    local tcp_port=$(get_valid_port "TCP DNS端口" "53")
    local udp_port=$(get_valid_port "UDP DNS端口" "53")
    
    echo
    echo -e "${COLORS[BLUE]}🔄 创建 DNS 分离转发规则...${COLORS[NC]}"
    
    local rule_id=$(date +%s)_$(shuf -i 1000-9999 -n 1)
    local success=0
    
    if add_forward_rule "$listen_port" "$tcp_dns" "$tcp_port" "tcp" "auto" "0.0.0.0"; then
        ((success++))
    fi
    
    if add_forward_rule "$listen_port" "$udp_dns" "$udp_port" "udp" "auto" "0.0.0.0"; then
        ((success++))
    fi
    
    if [[ $success -eq 2 ]]; then
        echo -e "${COLORS[GREEN]}✅ DNS 分离转发创建成功！${COLORS[NC]}"
        echo -e "${COLORS[CYAN]}📡 TCP: localhost:$listen_port → $tcp_dns:$tcp_port${COLORS[NC]}"
        echo -e "${COLORS[CYAN]}📡 UDP: localhost:$listen_port → $udp_dns:$udp_port${COLORS[NC]}"
    else
        echo -e "${COLORS[YELLOW]}⚠️  部分创建成功 ($success/2)${COLORS[NC]}"
    fi
    
    echo
    read -p "Press Enter to continue..."
}

# Template: SSH Forward
template_ssh_forward() {
    echo -e "${COLORS[BOLD]}🔐 SSH 转发模板${COLORS[NC]}"
    echo -e "${COLORS[YELLOW]}安全的 SSH 端口转发${COLORS[NC]}"
    echo
    
    local target_ip=$(get_valid_ip "目标服务器IP")
    local listen_port=$(get_valid_port "本地监听端口" "2222")
    local target_port="22"
    
    echo
    echo -e "${COLORS[BLUE]}🔄 创建 SSH 转发规则...${COLORS[NC]}"
    
    if add_forward_rule "$listen_port" "$target_ip" "$target_port" "tcp" "auto" "0.0.0.0"; then
        echo -e "${COLORS[GREEN]}✅ SSH 转发创建成功！${COLORS[NC]}"
        echo -e "${COLORS[CYAN]}🔗 连接命令: ssh -p $listen_port user@localhost${COLORS[NC]}"
        echo -e "${COLORS[CYAN]}📍 实际连接: $target_ip:$target_port${COLORS[NC]}"
    else
        echo -e "${COLORS[RED]}❌ 创建失败${COLORS[NC]}"
    fi
    
    echo
    read -p "Press Enter to continue..."
}

# Template: Database Proxy
template_database_proxy() {
    echo -e "${COLORS[BOLD]}🗃️  数据库代理模板${COLORS[NC]}"
    echo -e "${COLORS[YELLOW]}MySQL/MariaDB 数据库连接代理${COLORS[NC]}"
    echo
    
    local target_ip=$(get_valid_ip "数据库服务器IP")
    local listen_port=$(get_valid_port "本地监听端口" "33306")
    local target_port=$(get_valid_port "数据库端口" "3306")
    
    echo
    echo -e "${COLORS[BLUE]}🔄 创建数据库代理规则...${COLORS[NC]}"
    
    if add_forward_rule "$listen_port" "$target_ip" "$target_port" "tcp" "auto" "0.0.0.0"; then
        echo -e "${COLORS[GREEN]}✅ 数据库代理创建成功！${COLORS[NC]}"
        echo -e "${COLORS[CYAN]}🔗 连接地址: localhost:$listen_port${COLORS[NC]}"
        echo -e "${COLORS[CYAN]}📍 数据库: $target_ip:$target_port${COLORS[NC]}"
        echo -e "${COLORS[YELLOW]}💡 示例: mysql -h localhost -P $listen_port -u username${COLORS[NC]}"
    else
        echo -e "${COLORS[RED]}❌ 创建失败${COLORS[NC]}"
    fi
    
    echo
    read -p "Press Enter to continue..."
}

# Template stubs for remaining templates
template_https_proxy() {
    echo -e "${COLORS[BOLD]}🔒 HTTPS 代理模板${COLORS[NC]}"
    local target_ip=$(get_valid_ip "目标HTTPS服务器IP")
    local target_port=$(get_valid_port "目标端口" "443")
    local listen_port=$(get_valid_port "本地监听端口" "8443")
    
    if add_forward_rule "$listen_port" "$target_ip" "$target_port" "tcp" "auto" "0.0.0.0"; then
        echo -e "${COLORS[GREEN]}✅ HTTPS 代理创建成功！${COLORS[NC]}"
    fi
    read -p "Press Enter to continue..."
}

template_dev_server() {
    echo -e "${COLORS[BOLD]}💻 开发服务器模板${COLORS[NC]}"
    local target_ip=$(get_valid_ip "开发服务器IP")
    local target_port=$(get_valid_port "目标端口" "3000")
    local listen_port=$(get_valid_port "本地监听端口" "8000")
    
    if add_forward_rule "$listen_port" "$target_ip" "$target_port" "tcp" "auto" "0.0.0.0"; then
        echo -e "${COLORS[GREEN]}✅ 开发服务器转发创建成功！${COLORS[NC]}"
    fi
    read -p "Press Enter to continue..."
}

template_game_server() {
    echo -e "${COLORS[BOLD]}🎮 游戏服务器模板${COLORS[NC]}"
    local target_ip=$(get_valid_ip "游戏服务器IP")
    local target_port=$(get_valid_port "游戏端口")
    local listen_port=$(get_valid_port "本地监听端口" "$target_port")
    
    if add_forward_rule "$listen_port" "$target_ip" "$target_port" "both" "auto" "0.0.0.0"; then
        echo -e "${COLORS[GREEN]}✅ 游戏服务器转发创建成功！${COLORS[NC]}"
    fi
    read -p "Press Enter to continue..."
}

# Service control
service_control_menu() {
    while true; do
        clear
        echo -e "${COLORS[BOLD]}Service Control${COLORS[NC]}"
        echo
        
        echo "Services:"
        for tool in "${!FORWARD_TOOLS[@]}"; do
            if [[ "${TOOL_STATUS[$tool]}" == "installed" ]]; then
                local status="${TOOL_SERVICE_STATUS[$tool]}"
                local status_color
                case "$status" in
                    active) status_color="${COLORS[GREEN]}running${COLORS[NC]}" ;;
                    inactive) status_color="${COLORS[YELLOW]}stopped${COLORS[NC]}" ;;
                    *) status_color="${COLORS[RED]}disabled${COLORS[NC]}" ;;
                esac
                echo "  $tool: $status_color"
            fi
        done
        
        echo
        echo "Actions:"
        echo "  1. Start all"
        echo "  2. Stop all" 
        echo "  3. Restart all"
        echo "  4. View logs"
        echo "  5. Enable IP forwarding"
        echo "  0. Back"
        echo
        
        read -p "Select: " choice
        case "$choice" in
            1)
                log_info "Starting services..."
                for tool in "${!FORWARD_TOOLS[@]}"; do
                    if [[ "${TOOL_STATUS[$tool]}" == "installed" ]]; then
                        systemctl start "$tool" 2>/dev/null && log_success "$tool started" || log_warn "$tool start failed"
                    fi
                done
                ;;
            2)
                log_info "Stopping services..."
                for tool in "${!FORWARD_TOOLS[@]}"; do
                    systemctl stop "$tool" 2>/dev/null && log_success "$tool stopped" || log_warn "$tool stop failed"
                done
                ;;
            3)
                log_info "Restarting services..."
                for tool in "${!FORWARD_TOOLS[@]}"; do
                    if [[ "${TOOL_STATUS[$tool]}" == "installed" ]]; then
                        systemctl restart "$tool" 2>/dev/null && log_success "$tool restarted" || log_warn "$tool restart failed"
                    fi
                done
                ;;
            4)
                echo "Service logs:"
                for tool in "${!FORWARD_TOOLS[@]}"; do
                    if [[ "${TOOL_STATUS[$tool]}" == "installed" ]]; then
                        echo "=== $tool ==="
                        journalctl -u "$tool" --no-pager -n 5 2>/dev/null || echo "No logs"
                    fi
                done
                ;;
            5)
                sysctl -w net.ipv4.ip_forward=1
                echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf 2>/dev/null || true
                log_success "IP forwarding enabled"
                ;;
            0) return ;;
            *) log_error "Invalid choice" ;;
        esac
        
        [[ "$choice" != "0" ]] && { echo; read -p "Press Enter to continue..."; }
    done
}

# Performance test
performance_test() {
    local target_ip
    local target_port
    local duration
    
    target_ip=$(get_valid_ip "Test target IP")
    target_port=$(get_valid_port "Test target port")
    read -p "Test duration (seconds) [10]: " duration
    duration=${duration:-10}
    
    log_info "Testing $target_ip:$target_port for ${duration}s..."
    
    local start_time=$(date +%s)
    local success_count=0
    local total_count=0
    
    while [[ $(($(date +%s) - start_time)) -lt $duration ]]; do
        ((total_count++))
        if timeout 1 bash -c "echo >/dev/tcp/$target_ip/$target_port" 2>/dev/null; then
            ((success_count++))
        fi
        sleep 0.1
    done
    
    local success_rate=$((success_count * 100 / total_count))
    
    echo "Results:"
    echo "  Total attempts: $total_count"
    echo "  Successful: $success_count"
    echo "  Success rate: ${success_rate}%"
    
    if [[ $success_rate -ge 90 ]]; then
        log_success "Excellent performance"
    elif [[ $success_rate -ge 70 ]]; then
        log_warn "Moderate performance"
    else
        log_error "Poor performance"
    fi
}

# Health check system
health_check() {
    clear
    echo -e "${COLORS[BOLD]}System Health Check${COLORS[NC]}"
    echo
    
    local issues_found=0
    
    # Check config file integrity
    echo "Checking configuration..."
    if validate_config "$CONFIG_FILE"; then
        log_success "Configuration file is valid"
    else
        log_error "Configuration file has issues"
        ((issues_found++))
    fi
    
    # Check tool installations and services
    echo
    echo "Checking tool installations and services..."
    detect_tools
    for tool in "${!FORWARD_TOOLS[@]}"; do
        if [[ "${TOOL_STATUS[$tool]}" == "installed" ]]; then
            log_success "$tool is properly installed"
            
            # Check service status
            case "${TOOL_SERVICE_STATUS[$tool]}" in
                active) log_success "$tool service is running" ;;
                inactive) log_warn "$tool service is stopped but enabled" ;;
                disabled) log_warn "$tool service is disabled" ;;
                not_found) log_error "$tool service not found"; ((issues_found++)) ;;
            esac
        else
            log_warn "$tool is not installed"
        fi
    done
    
    # Check network connectivity
    echo
    echo "Checking network connectivity..."
    if curl -s --connect-timeout 5 --max-time 10 -I https://github.com >/dev/null 2>&1; then
        log_success "Internet connectivity is working"
    else
        log_warn "Internet connectivity issues detected"
    fi
    
    # Check system resources
    echo
    echo "Checking system resources..."
    local load=$(uptime | awk '{print $(NF-2)}' | tr -d ',')
    local memory_free=$(free -m | awk 'NR==2{printf "%.0f", $7*100/$2}')
    local disk_free=$(df / | awk 'NR==2{print $5}' | tr -d '%')
    
    echo "  System load: $load"
    echo "  Free memory: $memory_free%"
    echo "  Disk usage: $disk_free%"
    
    if (( $(echo "$load > 5.0" | bc -l 2>/dev/null || echo 0) )); then
        log_warn "High system load detected"
    fi
    
    if [[ $memory_free -lt 10 ]]; then
        log_warn "Low memory available"
    fi
    
    if [[ $disk_free -gt 90 ]]; then
        log_warn "Disk space is running low"
    fi
    
    # Check active rules
    echo
    echo "Checking active rules..."
    local rules_count=$(jq '.rules | length' "$CONFIG_FILE" 2>/dev/null || echo 0)
    if [[ $rules_count -gt 0 ]]; then
        log_success "$rules_count forwarding rules configured"
        
        # Test rule functionality (basic check)
        echo "Testing rule functionality..."
        local working_rules=0
        while read -r rule; do
            local tool=$(echo "$rule" | jq -r '.tool')
            local listen_port=$(echo "$rule" | jq -r '.listen_port')
            
            case "$tool" in
                gost|realm)
                    if systemctl is-active --quiet "$tool"; then
                        ((working_rules++))
                    fi
                    ;;
                nftables)
                    local id=$(echo "$rule" | jq -r '.id')
                    if nft list chain inet fwrd_nat fwrd_prerouting 2>/dev/null | grep -q "fwrd-${id}"; then
                        ((working_rules++))
                    fi
                    ;;
            esac
        done < <(jq -c '.rules[]' "$CONFIG_FILE" 2>/dev/null)
        
        if [[ $working_rules -eq $rules_count ]]; then
            log_success "All $rules_count rules appear to be working"
        else
            log_warn "Only $working_rules of $rules_count rules appear to be working"
            ((issues_found++))
        fi
    else
        log_info "No forwarding rules configured"
    fi
    
    echo
    echo "════════════════════════════════════════"
    if [[ $issues_found -eq 0 ]]; then
        log_success "Health check completed - no issues found!"
    else
        log_warn "Health check completed - $issues_found issue(s) found"
        echo "Run individual diagnostic commands to investigate further."
    fi
    echo "════════════════════════════════════════"
    echo
    read -p "Press Enter to continue..."
}

# Main loop
main() {
    check_system
    setup_config
    detect_tools
    
    while true; do
        show_main_menu
        read -p "Select: " choice
        
        case "$choice" in
            1) 
                show_install_menu
                read -p "Install tool: " install_choice
                case "$install_choice" in
                    1) [[ "${TOOL_STATUS[gost]}" == "installed" ]] && log_info "GOST already installed" || install_gost ;;
                    2) [[ "${TOOL_STATUS[realm]}" == "installed" ]] && log_info "Realm already installed" || install_realm ;;
                    3) [[ "${TOOL_STATUS[nftables]}" == "installed" ]] && log_info "NFTables already installed" || install_nftables ;;

                    0) continue ;;
                    *) log_error "Invalid choice" ;;
                esac
                detect_tools
                ;;
            2) show_system_status ;;
            3) interactive_add_rule ;;
            4) interactive_add_advanced_rule ;;
            5) quick_templates ;;
            6) list_forward_rules ;;
            7)
                list_forward_rules
                echo
                read -p "Rule number to modify: " rule_num
                [[ "$rule_num" =~ ^[0-9]+$ ]] && modify_forward_rule "$rule_num" || log_error "Invalid input"
                ;;
            8)
                list_forward_rules
                echo
                read -p "Rule number to delete: " rule_num
                [[ "$rule_num" =~ ^[0-9]+$ ]] && delete_forward_rule "$rule_num" || log_error "Invalid input"
                ;;
            9) service_control_menu ;;
            10) performance_test ;;
            11) health_check ;;
            12) diagnose_system ;;
            0) 
                log_info "Goodbye!"
                exit 0
                ;;
            *) log_error "Invalid choice" ;;
        esac
        
        [[ "$choice" != "0" ]] && { echo; read -p "Press Enter to continue..."; }
    done
}

# Diagnostic function to help troubleshoot issues
diagnose_system() {
    clear
    echo -e "${COLORS[BOLD]}🔍 系统诊断${COLORS[NC]}"
    echo "════════════════════════════════════════════"
    
    # Check basic requirements
    echo -e "${COLORS[CYAN]}📋 基础检查：${COLORS[NC]}"
    
    # Root privileges
    if [[ $EUID -eq 0 ]]; then
        echo -e "  ✅ Root权限: 正常"
    else
        echo -e "  ❌ Root权限: 需要sudo权限"
    fi
    
    # Required commands
    local required_cmds=("curl" "jq" "systemctl" "lsof")
    for cmd in "${required_cmds[@]}"; do
        if command -v "$cmd" >/dev/null 2>&1; then
            echo -e "  ✅ $cmd: 已安装"
        else
            echo -e "  ❌ $cmd: 未安装"
        fi
    done
    
    echo
    echo -e "${COLORS[CYAN]}📁 配置文件检查：${COLORS[NC]}"
    
    # Config directory
    if [[ -d "$CONFIG_DIR" ]]; then
        echo -e "  ✅ 配置目录: $CONFIG_DIR"
        ls -la "$CONFIG_DIR" 2>/dev/null | head -5
    else
        echo -e "  ❌ 配置目录: $CONFIG_DIR 不存在"
    fi
    
    # Config file
    if [[ -f "$CONFIG_FILE" ]]; then
        echo -e "  ✅ 配置文件: $CONFIG_FILE"
        if jq '.' "$CONFIG_FILE" >/dev/null 2>&1; then
            echo -e "  ✅ 配置文件格式: 有效的JSON"
            local rules_count=$(jq '.rules | length' "$CONFIG_FILE" 2>/dev/null || echo "0")
            echo -e "  📊 规则数量: $rules_count"
        else
            echo -e "  ❌ 配置文件格式: 无效的JSON"
        fi
    else
        echo -e "  ❌ 配置文件: $CONFIG_FILE 不存在"
    fi
    
    echo
    echo -e "${COLORS[CYAN]}🔧 工具状态：${COLORS[NC]}"
    detect_tools > /dev/null 2>&1
    for tool in "${!TOOL_STATUS[@]}"; do
        local status="${TOOL_STATUS[$tool]}"
        case "$status" in
            "installed") echo -e "  ✅ $tool: 已安装" ;;
            "not_installed") echo -e "  ❌ $tool: 未安装" ;;
            *) echo -e "  ⚠️  $tool: $status" ;;
        esac
    done
    
    echo
    echo -e "${COLORS[CYAN]}🌐 网络检查：${COLORS[NC]}"
    if curl -s --connect-timeout 5 --max-time 10 -I https://github.com >/dev/null 2>&1; then
        echo -e "  ✅ 网络连接: 正常"
    else
        echo -e "  ❌ 网络连接: 无法访问外网"
    fi
    
    echo
    echo -e "${COLORS[BLUE]}💡 建议修复步骤：${COLORS[NC]}"
    if [[ $EUID -ne 0 ]]; then
        echo "  1. 使用 sudo 权限运行脚本"
    fi
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "  2. 运行脚本将自动创建配置文件"
    fi
    if ! command -v jq >/dev/null 2>&1; then
        echo "  3. 安装 jq: apt-get install jq"
    fi
    
    echo
    read -p "Press Enter to continue..."
}

# Signal handlers for clean exit
cleanup() {
    local exit_code=$?
    echo
    log_info "Cleaning up..."
    
    # Clean up any temporary files
    find /tmp -name "realm.tar.gz" -user root -mtime -1 -delete 2>/dev/null || true
    find /tmp -name "*.fwrd.tmp.*" -user root -mtime -1 -delete 2>/dev/null || true
    
    # If we were in the middle of an operation, mention state might be inconsistent
    if [[ $exit_code -ne 0 ]]; then
        log_warn "Script interrupted. System state might be inconsistent."
        log_warn "Run the script again to verify configuration."
    fi
    
    exit $exit_code
}

# Set up signal handlers
trap cleanup EXIT
trap 'log_warn "Interrupted by user"; exit 130' INT TERM

# Script entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
