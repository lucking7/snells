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

# Progressive input with error correction
get_valid_ip() {
    local prompt="$1"
    local default="${2:-}"
    local ip
    
    while true; do
        if [[ -n "$default" ]]; then
            read -p "$prompt [$default]: " ip
            ip=${ip:-$default}
        else
            read -p "$prompt: " ip
        fi
        
        if [[ -z "$ip" && -n "$default" ]]; then
            echo "$default"
            return 0
        fi
        
        if [[ -z "$ip" ]]; then
            log_error "IP address cannot be empty"
            continue
        fi
        
        if validated_ip=$(validate_ip "$ip"); then
            echo "$validated_ip"
            return 0
        else
            log_error "Invalid IP format. Examples: 192.168.1.1, example.com, 2001:db8::1"
        fi
    done
}

get_valid_port() {
    local prompt="$1"
    local default="${2:-}"
    local port
    
    while true; do
        if [[ -n "$default" ]]; then
            read -p "$prompt [$default]: " port
            port=${port:-$default}
        else
            read -p "$prompt: " port
        fi
        
        if [[ -z "$port" && -n "$default" ]]; then
            echo "$default"
            return 0
        fi
        
        if [[ -z "$port" ]]; then
            log_error "Port cannot be empty"
            continue
        fi
        
        if validated_port=$(validate_port "$port"); then
            # Check if port is in use
            if lsof -i :"$validated_port" >/dev/null 2>&1; then
                log_warn "Port $validated_port appears to be in use"
                read -p "Continue anyway? [y/N]: " confirm
                [[ "$confirm" =~ ^[Yy]$ ]] || continue
            fi
            echo "$validated_port"
            return 0
        else
            log_error "Invalid port. Must be 1-65535"
        fi
    done
}

get_protocol() {
    local protocol
    while true; do
        echo "Protocol options:"
        echo "  1) TCP only"
        echo "  2) UDP only" 
        echo "  3) TCP + UDP (recommended)"
        echo
        read -p "Select protocol [3] (press Enter for default): " protocol
        protocol=${protocol:-3}
        
        case "$protocol" in
            1) echo "tcp"; return 0 ;;
            2) echo "udp"; return 0 ;;
            3|"") echo "both"; return 0 ;;
            *) 
                log_error "Invalid choice. Please enter 1, 2, or 3, or press Enter for default"
                echo
                ;;
        esac
    done
}

# System check
check_system() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Root privileges required"
        exit 1
    fi
    
    local required_cmds=("curl" "jq" "systemctl" "lsof")
    for cmd in "${required_cmds[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            log_warn "Missing command: $cmd, attempting install..."
            case "$cmd" in
                jq|lsof) apt-get update && apt-get install -y "$cmd" ;;
                *) log_error "Please install: $cmd" && exit 1 ;;
            esac
        fi
    done
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
        log_warn "No configuration found"
        return 1
    fi
    
    local rules_count=$(jq '.rules | length' "$CONFIG_FILE")
    if [[ "$rules_count" -eq 0 ]]; then
        log_warn "No rules found"
        return 0
    fi
    
    echo
    printf "${COLORS[BOLD]}%-3s %-8s %-15s %-5s %-15s %-5s %-8s %-8s %-10s${COLORS[NC]}\n" \
           "#" "TOOL" "LISTEN_IP" "PORT" "TARGET_IP" "PORT" "PROTOCOL" "STATUS" "CREATED"
    echo "────────────────────────────────────────────────────────────────────────────────"
    
    local index=0
    while read -r rule; do
        ((index++))
        local id=$(echo "$rule" | jq -r '.id')
        local tool=$(echo "$rule" | jq -r '.tool')
        local listen_ip=$(echo "$rule" | jq -r '.listen_ip')
        local listen_port=$(echo "$rule" | jq -r '.listen_port')
        local target_ip=$(echo "$rule" | jq -r '.target_ip')
        local target_port=$(echo "$rule" | jq -r '.target_port')
        local protocol=$(echo "$rule" | jq -r '.protocol')
        local created=$(echo "$rule" | jq -r '.created' | cut -d'T' -f1)
        
        # Check service status
        local status="unknown"
        case "$tool" in
            gost|realm)
                if systemctl is-active --quiet "$tool"; then
                    status="${COLORS[GREEN]}running${COLORS[NC]}"
                else
                    status="${COLORS[RED]}stopped${COLORS[NC]}"
                fi
                ;;
            nftables)
                if nft list ruleset | grep -q "fwrd-${id}"; then
                    status="${COLORS[GREEN]}active${COLORS[NC]}"
                else
                    status="${COLORS[RED]}inactive${COLORS[NC]}"
                fi
                ;;
        esac
        
        printf "%-3s %-8s %-15s %-5s %-15s %-5s %-8s %-16s %-10s\n" \
               "$index" "$tool" "$listen_ip" "$listen_port" "$target_ip" "$target_port" \
               "$protocol" "$status" "$created"
    done < <(jq -c '.rules[]' "$CONFIG_FILE")
    
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
    echo "  3. Add rule"
    echo "  4. List rules"
    echo "  5. Modify rule"
    echo "  6. Delete rule"
    echo
    echo "System:"
    echo "  7. Service control"
    echo "  8. Performance test"
    echo "  9. Health check"
    echo
    echo "  0. Exit"
    echo
}

show_install_menu() {
    clear
    echo -e "${COLORS[BOLD]}Tool Installation${COLORS[NC]}"
    echo
    
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
        echo "  $index. $tool - ${FORWARD_TOOLS[$tool]} ($status_color)"
        ((index++))
    done
    
    echo
    echo "  0. Back"
    echo
}

# Interactive add rule
interactive_add_rule() {
    clear
    echo -e "${COLORS[BOLD]}Add Forward Rule${COLORS[NC]}"
    echo
    
    # Progressive input with improved flow
    local listen_port
    while true; do
        read -p "Listen port (leave empty for auto): " listen_port
        if [[ -z "$listen_port" ]]; then
            listen_port=$(find_available_port) || return 1 # Exit if no port found
            log_info "Auto-selected port: $listen_port"
            break
        elif validated_port=$(validate_port "$listen_port"); then
            listen_port="$validated_port"
            break
        else
            log_error "Invalid port. Must be 1-65535"
        fi
    done
    
    echo
    local target_ip=$(get_valid_ip "Target IP")
    
    echo
    local target_port=$(get_valid_port "Target port")
    
    echo
    local protocol=$(get_protocol)
    
    echo
    echo "Tool selection:"
    echo "  1. Auto-select (recommended)"
    # Use deterministic order matching install menu
    local tools_order=(gost realm nftables)
    local printed_tools=()
    local index=2
    for tool in "${tools_order[@]}"; do
        if [[ "${TOOL_STATUS[$tool]}" == "installed" ]]; then
            echo "  $index. $tool"
            printed_tools+=("$tool")
            ((index++))
        fi
    done
    echo
    read -p "Select tool [1] (press Enter for auto-select): " tool_choice
    tool_choice=${tool_choice:-1}
    
    local tool="auto"
    if [[ "$tool_choice" != "1" ]]; then
        local sel_index=$((tool_choice-2))
        if [[ $sel_index -ge 0 && $sel_index -lt ${#printed_tools[@]} ]]; then
            tool="${printed_tools[$sel_index]}"
        else
            log_warn "Invalid selection, fallback to auto"
            tool="auto"
        fi
    fi
    
    echo
    local listen_ip="0.0.0.0"
    read -p "Listen IP [0.0.0.0] (press Enter for all interfaces): " input_listen_ip
    [[ -n "$input_listen_ip" ]] && listen_ip=$(get_valid_ip "Listen IP" "$input_listen_ip")
    
    echo
    echo -e "${COLORS[YELLOW]}═══ Rule Summary ═══${COLORS[NC]}"
    echo "  Listen: $listen_ip:$listen_port"
    echo "  Target: $target_ip:$target_port"
    echo "  Protocol: $protocol"
    echo "  Tool: $tool"
    echo "════════════════════"
    echo
    
    read -p "Create this forwarding rule? [Y/n] (press Enter to confirm): " confirm
    confirm=${confirm:-Y}
    
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        if add_forward_rule "$listen_port" "$target_ip" "$target_port" "$protocol" "$tool" "$listen_ip"; then
            log_success "Rule created successfully!"
            echo "Access: $listen_ip:$listen_port -> $target_ip:$target_port"
        else
            log_error "Failed to create rule"
        fi
    else
        log_info "Cancelled"
    fi
    
    echo
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
            4) list_forward_rules ;;
            5)
                list_forward_rules
                echo
                read -p "Rule number to modify: " rule_num
                [[ "$rule_num" =~ ^[0-9]+$ ]] && modify_forward_rule "$rule_num" || log_error "Invalid input"
                ;;
            6)
                list_forward_rules
                echo
                read -p "Rule number to delete: " rule_num
                [[ "$rule_num" =~ ^[0-9]+$ ]] && delete_forward_rule "$rule_num" || log_error "Invalid input"
                ;;
            7) service_control_menu ;;
            8) performance_test ;;
            9) health_check ;;
            0) 
                log_info "Goodbye!"
                exit 0
                ;;
            *) log_error "Invalid choice" ;;
        esac
        
        [[ "$choice" != "0" ]] && { echo; read -p "Press Enter to continue..."; }
    done
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
