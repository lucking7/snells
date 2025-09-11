#!/bin/bash

# Forward Manager v2.0.0
# Professional forwarding management for GOST, NFTables, and Realm
# Author: Forward Management Team
# Purpose: Unified management of network forwarding tools

set -o errexit   # Exit on any error
set -o nounset   # Exit on undefined variable  
set -o pipefail  # Exit on pipe failure

# ==================== CONFIGURATION ====================

VERSION="2.0.0"
CONFIG_DIR="/etc/fwrd"
CONFIG_FILE="$CONFIG_DIR/config.json"
TOOLS_DIR="/opt/fwrd"

# Standard color definitions
PLAIN='\033[0m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'

# Consistent symbols for different message types
SUCCESS_SYMBOL="${BOLD}${GREEN}[+]${PLAIN}"
ERROR_SYMBOL="${BOLD}${RED}[x]${PLAIN}"
INFO_SYMBOL="${BOLD}${BLUE}[i]${PLAIN}"
WARN_SYMBOL="${BOLD}${YELLOW}[!]${PLAIN}"

# Global breadcrumb variable
BREADCRUMB_PATH="Main"

# Temporary files tracking
declare -a TEMP_FILES=()

# Supported forwarding tools
declare -A FORWARD_TOOLS=(
    [gost]="GOST - Feature-rich tunnel"
    [nftables]="NFTables - Kernel-level forwarding"
    [realm]="Realm - High-performance Rust proxy"
)

# Tool status tracking
declare -A TOOL_STATUS=()
declare -A TOOL_VERSION=()
declare -A TOOL_SERVICE_STATUS=()

# ==================== UTILITY FUNCTIONS ====================

# Cleanup function
cleanup() {
    local exit_code=$?
    
    # Remove temporary files
    for temp_file in "${TEMP_FILES[@]}"; do
        [[ -f "$temp_file" ]] && rm -f "$temp_file" 2>/dev/null
    done
    
    # Log cleanup
    [[ $exit_code -ne 0 ]] && log_warn "Script exited with code: $exit_code"
    
    exit $exit_code
}

# Signal handling
trap cleanup EXIT
trap 'log_warn "Interrupted by user"; cleanup' SIGINT SIGTERM

# Breadcrumb functions
show_breadcrumb() {
    printf "\n${BOLD}${BLUE}==== %s ====${PLAIN}\n" "$BREADCRUMB_PATH"
}

set_breadcrumb() {
    BREADCRUMB_PATH="$1"
}

# Logging functions
# Logging with file support
LOG_FILE="/var/log/fwrd.log"

log_to_file() {
    [[ -w "$LOG_FILE" ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE" 2>/dev/null || true
}

log_info() { 
    printf "${INFO_SYMBOL} %s${PLAIN}\n" "$*"
    log_to_file "INFO: $*"
}

log_success() { 
    printf "${SUCCESS_SYMBOL} %s${PLAIN}\n" "$*"
    log_to_file "SUCCESS: $*"
}

log_error() { 
    printf "${ERROR_SYMBOL} %s${PLAIN}\n" "$*"
    log_to_file "ERROR: $*"
}

log_warn() { 
    printf "${WARN_SYMBOL} %s${PLAIN}\n" "$*"
    log_to_file "WARN: $*"
}

# Input validation
sanitize_input() {
    local input="$1"
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

# Resolve hostname to IPv4 for nftables
resolve_ipv4() {
    local host="$1"
    if [[ "$host" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
        echo "$host"
        return 0
    fi
    local ip
    ip=$(getent ahostsv4 "$host" 2>/dev/null | awk '/STREAM/ {print $1; exit}')
    if [[ -n "$ip" ]]; then
        echo "$ip"
        return 0
    fi
    return 1
}

# Progressive input
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
        
        if [[ -z "$ip" ]]; then
            if [[ -n "$default" ]]; then
                echo "$default"
                return 0
            fi
            log_error "IP address cannot be empty"
            continue
        fi
        
        if validated_ip=$(validate_ip "$ip"); then
            echo "$validated_ip"
            return 0
        else
            log_error "Invalid IP format. Examples: 192.168.1.1, example.com"
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
        
        if [[ -z "$port" ]]; then
            if [[ -n "$default" ]]; then
                echo "$default"
                return 0
            fi
            log_error "Port cannot be empty"
            continue
        fi
        
        if validated_port=$(validate_port "$port"); then
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
        printf "Protocol options:\n"
        printf "  1) TCP only\n"
        printf "  2) UDP only\n"
        printf "  3) TCP + UDP (recommended)\n"
        printf "\n"
        read -p "Select protocol [3]: " protocol
        protocol=${protocol:-3}
        
        case "$protocol" in
            1) echo "tcp"; return 0 ;;
            2) echo "udp"; return 0 ;;
            3) echo "both"; return 0 ;;
            *) log_error "Invalid choice. Enter 1, 2, or 3" ;;
        esac
    done
}

# ==================== SYSTEM FUNCTIONS ====================

check_system() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Root privileges required"
        exit 1
    fi
    
    local required_cmds=("curl" "jq" "systemctl" "lsof")
    local missing_cmds=()
    
    for cmd in "${required_cmds[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_cmds+=("$cmd")
        fi
    done
    
    if [[ ${#missing_cmds[@]} -gt 0 ]]; then
        log_warn "Installing missing commands: ${missing_cmds[*]}"
        apt-get update -qq && apt-get install -y "${missing_cmds[@]}"
    fi
}

setup_config() {
    mkdir -p "$CONFIG_DIR" "$TOOLS_DIR"
    
    # Initialize log file
    touch "$LOG_FILE" 2>/dev/null && chmod 644 "$LOG_FILE" 2>/dev/null || true
    
    if [[ ! -f "$CONFIG_FILE" ]]; then
        cat > "$CONFIG_FILE" << 'EOF'
{
  "version": "2.0.0",
  "rules": [],
  "global_settings": {
    "ip_forward": true,
    "max_rules": 100
  }
}
EOF
    fi
}

detect_tools() {
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
        TOOL_VERSION[nftables]=$(nft --version | head -1 | cut -d' ' -f1-2)
    else
        TOOL_STATUS[nftables]="not_installed"
    fi
    
    # Realm detection
    if command -v realm &> /dev/null || [[ -f "$TOOLS_DIR/realm" ]]; then
        TOOL_STATUS[realm]="installed"
        TOOL_VERSION[realm]=$($TOOLS_DIR/realm --version 2>/dev/null || echo "unknown")
    else
        TOOL_STATUS[realm]="not_installed"
    fi
    
    # Service status
    for tool in "${!FORWARD_TOOLS[@]}"; do
        if systemctl is-active --quiet "$tool" 2>/dev/null; then
            TOOL_SERVICE_STATUS[$tool]="active"
        elif systemctl is-enabled --quiet "$tool" 2>/dev/null; then
            TOOL_SERVICE_STATUS[$tool]="inactive"
        else
            TOOL_SERVICE_STATUS[$tool]="disabled"
        fi
    done
}

# ==================== TOOL INSTALLATION ====================

install_gost() {
    log_info "Installing GOST..."
    if curl -fsSL https://github.com/go-gost/gost/raw/master/install.sh | bash; then
        log_success "GOST installed successfully"
        TOOL_STATUS[gost]="installed"
        return 0
    else
        log_error "GOST installation failed"
        return 1
    fi
}

install_nftables() {
    log_info "Installing NFTables..."
    if apt-get update -qq && apt-get install -y nftables; then
        systemctl enable nftables >/dev/null 2>&1
        log_success "NFTables installed successfully"
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
    
    # Get version
    local version="v2.6.2"
    if curl -s --connect-timeout 5 https://api.github.com/repos/zhboner/realm/releases/latest >/dev/null 2>&1; then
        version=$(curl -s https://api.github.com/repos/zhboner/realm/releases/latest | jq -r '.tag_name // "v2.6.2"')
    fi
    
    local download_url="https://github.com/zhboner/realm/releases/download/${version}/realm-${realm_arch}.tar.gz"
    
    if curl -L -o /tmp/realm.tar.gz "$download_url" && \
       tar -xzf /tmp/realm.tar.gz -C /tmp && \
       mv /tmp/realm "$TOOLS_DIR/realm" && \
       chmod +x "$TOOLS_DIR/realm" && \
       ln -sf "$TOOLS_DIR/realm" /usr/local/bin/realm; then
        rm -f /tmp/realm.tar.gz
        log_success "Realm installed successfully"
        TOOL_STATUS[realm]="installed"
        return 0
    else
        rm -f /tmp/realm.tar.gz /tmp/realm 2>/dev/null
        log_error "Realm installation failed"
        return 1
    fi
}

# ==================== BACKUP & RESTORE ====================

backup_config() {
    local backup_dir="$CONFIG_DIR/backups"
    mkdir -p "$backup_dir"
    
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_file="$backup_dir/backup_${timestamp}.tar.gz"
    
    log_info "Creating configuration backup..."
    
    # Create backup
    tar -czf "$backup_file" \
        "$CONFIG_FILE" \
        "/etc/gost/config.json" \
        "/etc/realm/config.toml" \
        "/etc/nftables.d/fwrd.nft" \
        2>/dev/null || true
    
    # Keep only last 10 backups
    ls -t "$backup_dir"/backup_*.tar.gz 2>/dev/null | tail -n +11 | xargs rm -f 2>/dev/null || true
    
    log_success "Backup created: $backup_file"
    return 0
}

restore_config() {
    local backup_dir="$CONFIG_DIR/backups"
    
    if [[ ! -d "$backup_dir" ]]; then
        log_error "No backups found"
        return 1
    fi
    
    # List available backups
    local backups=($(ls -t "$backup_dir"/backup_*.tar.gz 2>/dev/null))
    
    if [[ ${#backups[@]} -eq 0 ]]; then
        log_error "No backups available"
        return 1
    fi
    
    printf "\nAvailable backups:\n"
    local index=1
    for backup in "${backups[@]}"; do
        local name=$(basename "$backup")
        local date=${name#backup_}
        date=${date%.tar.gz}
        printf "  %d. %s\n" "$index" "$date"
        ((index++))
    done
    
    printf "\n"
    read -p "Select backup to restore [1]: " choice
    choice=${choice:-1}
    
    if [[ "$choice" -lt 1 || "$choice" -gt ${#backups[@]} ]]; then
        log_error "Invalid selection"
        return 1
    fi
    
    local selected_backup="${backups[$((choice-1))]}"
    
    printf "\n${YELLOW}Restore from $(basename "$selected_backup")?${PLAIN}\n"
    printf "Current configuration will be overwritten.\n"
    printf "\nContinue? [y/N]: "
    read -r confirm
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "Restore cancelled"
        return 0
    fi
    
    # Create current backup before restore
    backup_config
    
    # Restore files
    log_info "Restoring configuration..."
    tar -xzf "$selected_backup" -C / 2>/dev/null || {
        log_error "Restore failed"
        return 1
    }
    
    # Restart services
    for tool in "${!FORWARD_TOOLS[@]}"; do
        [[ "${TOOL_STATUS[$tool]}" == "installed" ]] && systemctl restart "$tool" 2>/dev/null
    done
    
    log_success "Configuration restored successfully"
    return 0
}

# ==================== HEALTH CHECK ====================

check_rule_health() {
    local listen_port="$1"
    local target_ip="$2"
    local target_port="$3"
    local protocol="$4"
    
    log_info "Checking rule health: 0.0.0.0:$listen_port -> $target_ip:$target_port ($protocol)"
    
    # Check if port is listening
    local listening=false
    if command -v ss &>/dev/null; then
        if [[ "$protocol" == "tcp" || "$protocol" == "both" ]]; then
            ss -tln | grep -q ":$listen_port " && listening=true
        fi
        if [[ "$protocol" == "udp" || "$protocol" == "both" ]]; then
            ss -uln | grep -q ":$listen_port " && listening=true
        fi
    else
        lsof -i :"$listen_port" >/dev/null 2>&1 && listening=true
    fi
    
    if [[ "$listening" == "true" ]]; then
        log_success "Port $listen_port is listening"
        
        # Test connectivity if TCP
        if [[ "$protocol" == "tcp" || "$protocol" == "both" ]]; then
            if timeout 2 bash -c "echo >/dev/tcp/$target_ip/$target_port" 2>/dev/null; then
                log_success "Target $target_ip:$target_port is reachable"
            else
                log_warn "Target $target_ip:$target_port may be unreachable"
            fi
        fi
        
        return 0
    else
        log_error "Port $listen_port is not listening"
        return 1
    fi
}

health_check_all() {
    local rules_count=$(jq '.rules | length' "$CONFIG_FILE" 2>/dev/null || echo 0)
    
    if [[ "$rules_count" -eq 0 ]]; then
        log_warn "No rules to check"
        return 0
    fi
    
    printf "\n${BOLD}Health Check Results${PLAIN}\n"
    printf "----------------------------------------------------------------------\n"
    
    local healthy=0
    local unhealthy=0
    
    while read -r rule; do
        local listen_port=$(echo "$rule" | jq -r '.listen_port')
        local target_ip=$(echo "$rule" | jq -r '.target_ip')
        local target_port=$(echo "$rule" | jq -r '.target_port')
        local protocol=$(echo "$rule" | jq -r '.protocol')
        local tool=$(echo "$rule" | jq -r '.tool')
        
        printf "\nRule: %s:%s -> %s:%s [%s/%s]\n" \
               "0.0.0.0" "$listen_port" "$target_ip" "$target_port" "$tool" "$protocol"
        
        if check_rule_health "$listen_port" "$target_ip" "$target_port" "$protocol"; then
            ((healthy++))
        else
            ((unhealthy++))
        fi
    done < <(jq -c '.rules[]' "$CONFIG_FILE")
    
    printf "\n----------------------------------------------------------------------\n"
    printf "Summary: ${GREEN}%d healthy${PLAIN}, ${RED}%d unhealthy${PLAIN}\n" "$healthy" "$unhealthy"
    
    return 0
}

# ==================== RULE MANAGEMENT ====================

recommend_tool() {
    if [[ "${TOOL_STATUS[gost]}" == "installed" ]]; then
        echo "gost"
    elif [[ "${TOOL_STATUS[nftables]}" == "installed" ]]; then
        echo "nftables"
    elif [[ "${TOOL_STATUS[realm]}" == "installed" ]]; then
        echo "realm"
    else
        echo "none"
    fi
}

find_available_port() {
    for ((i=0; i<50; i++)); do
        local port=$((RANDOM % 55000 + 10000))
        # Check with both ss and lsof for better coverage
        if command -v ss &>/dev/null; then
            if ! ss -tuln | grep -q ":$port "; then
                echo "$port"
                return 0
            fi
        elif ! lsof -i :"$port" >/dev/null 2>&1; then
            echo "$port"
            return 0
        fi
    done
    return 1
}

setup_nftables_chain() {
    if ! nft list tables 2>/dev/null | grep -q "fwrd_nat"; then
        nft add table inet fwrd_nat 2>/dev/null || return 1
    fi
    if ! nft list chains inet fwrd_nat 2>/dev/null | grep -q "fwrd_prerouting"; then
        nft add chain inet fwrd_nat fwrd_prerouting '{ type nat hook prerouting priority 0; }' 2>/dev/null || return 1
    fi
    
    # Ensure persistence
    if [[ -d /etc/nftables.d ]]; then
        nft list table inet fwrd_nat > /etc/nftables.d/fwrd.nft 2>/dev/null || true
    fi
}

# Add GOST rule
add_rule_gost() {
    local rule_id="$1" listen_port="$2" target_ip="$3" target_port="$4" protocol="$5"
    
    local config_file="/etc/gost/config.json"
    mkdir -p "$(dirname "$config_file")"
    [[ ! -f "$config_file" ]] && echo '{"services":[]}' > "$config_file"
    
    local service_name="fwrd-${rule_id}"
    local listen_addr="0.0.0.0:${listen_port}"
    local target_addr="${target_ip}:${target_port}"
    
    if [[ "$protocol" == "both" ]]; then
        jq --arg name "${service_name}-tcp" --arg addr "$listen_addr" --arg target "$target_addr" \
           '.services += [{name: $name, addr: $addr, handler: {type: "tcp"}, listener: {type: "tcp"}, forwarder: {nodes: [{name: "target-0", addr: $target}]}}]' \
           "$config_file" > "${config_file}.tmp" && mv "${config_file}.tmp" "$config_file"
        jq --arg name "${service_name}-udp" --arg addr "$listen_addr" --arg target "$target_addr" \
           '.services += [{name: $name, addr: $addr, handler: {type: "udp"}, listener: {type: "udp"}, forwarder: {nodes: [{name: "target-0", addr: $target}]}}]' \
           "$config_file" > "${config_file}.tmp" && mv "${config_file}.tmp" "$config_file"
    else
        jq --arg name "$service_name" --arg addr "$listen_addr" --arg proto "$protocol" --arg target "$target_addr" \
           '.services += [{name: $name, addr: $addr, handler: {type: $proto}, listener: {type: $proto}, forwarder: {nodes: [{name: "target-0", addr: $target}]}}]' \
           "$config_file" > "${config_file}.tmp" && mv "${config_file}.tmp" "$config_file"
    fi
    
    create_gost_service
    systemctl restart gost 2>/dev/null && systemctl is-active --quiet gost
}

create_gost_service() {
    getent group gost >/dev/null 2>&1 || groupadd --system gost
    id -u gost >/dev/null 2>&1 || useradd --system --no-create-home --shell /bin/false -g gost gost
    
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
LimitNOFILE=infinity
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable gost >/dev/null 2>&1
}

# Add NFTables rule  
add_rule_nftables() {
    local rule_id="$1" listen_port="$2" target_ip="$3" target_port="$4" protocol="$5"
    
    setup_nftables_chain || return 1
    
    local dnat_ip
    dnat_ip=$(resolve_ipv4 "$target_ip") || return 1
    
    local rule_comment="fwrd-${rule_id}"
    
    [[ "$protocol" == "tcp" || "$protocol" == "both" ]] && \
        nft add rule inet fwrd_nat fwrd_prerouting tcp dport "$listen_port" dnat to "${dnat_ip}:${target_port}" comment "\"$rule_comment\"" 2>/dev/null
    
    [[ "$protocol" == "udp" || "$protocol" == "both" ]] && \
        nft add rule inet fwrd_nat fwrd_prerouting udp dport "$listen_port" dnat to "${dnat_ip}:${target_port}" comment "\"$rule_comment\"" 2>/dev/null
    
    nft list table inet fwrd_nat > /etc/fwrd/nftables.conf 2>/dev/null
}

# Add Realm rule
add_rule_realm() {
    local rule_id="$1" listen_port="$2" target_ip="$3" target_port="$4" protocol="$5"
    
    local config_file="/etc/realm/config.toml"
    mkdir -p "$(dirname "$config_file")"
    
    getent group realm >/dev/null 2>&1 || groupadd --system realm
    id -u realm >/dev/null 2>&1 || useradd --system --no-create-home --shell /bin/false -g realm realm
    
    if [[ ! -f "$config_file" ]]; then
        cat > "$config_file" << 'EOF'
[network]
no_tcp = false
use_udp = true
EOF
        chown realm:realm "$config_file" 2>/dev/null || true
        chmod 640 "$config_file" 2>/dev/null || true
    fi
    
    cat >> "$config_file" << EOF

[[endpoints]]
listen = "0.0.0.0:$listen_port"
remote = "$target_ip:$target_port"
use_tcp = $([[ "$protocol" == "tcp" || "$protocol" == "both" ]] && echo "true" || echo "false")
use_udp = $([[ "$protocol" == "udp" || "$protocol" == "both" ]] && echo "true" || echo "false")
EOF
    
    create_realm_service
    systemctl restart realm 2>/dev/null && systemctl is-active --quiet realm
}

create_realm_service() {
    getent group realm >/dev/null 2>&1 || groupadd --system realm
    id -u realm >/dev/null 2>&1 || useradd --system --no-create-home --shell /bin/false -g realm realm
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
LimitNOFILE=infinity
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable realm >/dev/null 2>&1
}

# Main add rule function
add_forward_rule() {
    local listen_port="$1" target_ip="$2" target_port="$3" protocol="$4" tool="${5:-auto}"
    
    if [[ "$tool" == "auto" ]]; then
        tool=$(recommend_tool)
        [[ "$tool" == "none" ]] && { log_error "No tools installed"; return 1; }
        log_info "Auto-selected tool: $tool"
    fi
    
    [[ "${TOOL_STATUS[$tool]}" != "installed" ]] && { log_error "Tool $tool not installed"; return 1; }
    
    local rule_id=$(date +%s)_$(shuf -i 1000-9999 -n 1 2>/dev/null || echo $((RANDOM % 9000 + 1000)))
    
    case "$tool" in
        gost) add_rule_gost "$rule_id" "$listen_port" "$target_ip" "$target_port" "$protocol" ;;
        nftables) add_rule_nftables "$rule_id" "$listen_port" "$target_ip" "$target_port" "$protocol" ;;
        realm) add_rule_realm "$rule_id" "$listen_port" "$target_ip" "$target_port" "$protocol" ;;
        *) log_error "Unsupported tool: $tool"; return 1 ;;
    esac && update_config_rule "$rule_id" "$listen_port" "$target_ip" "$target_port" "$protocol" "$tool"
}

update_config_rule() {
    local rule_id="$1" listen_port="$2" target_ip="$3" target_port="$4" protocol="$5" tool="$6"
    
    local temp_file=$(mktemp)
    TEMP_FILES+=("$temp_file")
    jq --arg id "$rule_id" --arg listen_port "$listen_port" --arg target_ip "$target_ip" \
       --arg target_port "$target_port" --arg protocol "$protocol" --arg tool "$tool" \
       --arg created "$(date -Iseconds)" \
       '.rules += [{id: $id, listen_port: ($listen_port | tonumber), target_ip: $target_ip, target_port: ($target_port | tonumber), protocol: $protocol, tool: $tool, created: $created, enabled: true}]' \
       "$CONFIG_FILE" > "$temp_file" && mv "$temp_file" "$CONFIG_FILE"
}

# List rules
list_forward_rules() {
    local rules_count=$(jq '.rules | length' "$CONFIG_FILE" 2>/dev/null || echo 0)
    
    if [[ "$rules_count" -eq 0 ]]; then
        log_warn "No forwarding rules found"
        return 0
    fi
    
    printf "\n${BOLD}%-3s %-8s %-5s %-15s %-5s %-8s %-8s %-10s${PLAIN}\n" \
           "#" "TOOL" "PORT" "TARGET_IP" "PORT" "PROTOCOL" "STATUS" "CREATED"
    printf "----------------------------------------------------------------------\n"
    
    local index=0
    while read -r rule; do
        ((index++))
        local id=$(echo "$rule" | jq -r '.id')
        local tool=$(echo "$rule" | jq -r '.tool')
        local listen_port=$(echo "$rule" | jq -r '.listen_port')
        local target_ip=$(echo "$rule" | jq -r '.target_ip')
        local target_port=$(echo "$rule" | jq -r '.target_port')
        local protocol=$(echo "$rule" | jq -r '.protocol')
        local created=$(echo "$rule" | jq -r '.created' | cut -d'T' -f1)
        
        # Check status
        local status="unknown"
        case "$tool" in
            gost|realm)
                status=$( systemctl is-active --quiet "$tool" 2>/dev/null && echo "${GREEN}running${PLAIN}" || echo "${RED}stopped${PLAIN}" )
                ;;
            nftables)
                status=$( nft list chain inet fwrd_nat fwrd_prerouting 2>/dev/null | grep -q "fwrd-${id}" && echo "${GREEN}active${PLAIN}" || echo "${RED}inactive${PLAIN}" )
                ;;
        esac
        
        printf "%-3s %-8s %-5s %-15s %-5s %-8s %-16s %-10s\n" \
               "$index" "$tool" "$listen_port" "$target_ip" "$target_port" "$protocol" "$status" "$created"
    done < <(jq -c '.rules[]' "$CONFIG_FILE")
    
    printf "\nTotal: %d rules\n" "$rules_count"
}

# Delete rule
delete_forward_rule() {
    local rule_index="$1"
    local rules_count=$(jq '.rules | length' "$CONFIG_FILE")
    
    [[ "$rule_index" -lt 1 || "$rule_index" -gt "$rules_count" ]] && { log_error "Invalid rule number"; return 1; }
    
    local rule=$(jq ".rules[$((rule_index-1))]" "$CONFIG_FILE")
    local id=$(echo "$rule" | jq -r '.id')
    local tool=$(echo "$rule" | jq -r '.tool')
    local listen_port=$(echo "$rule" | jq -r '.listen_port')
    
    case "$tool" in
        gost)
            local config_file="/etc/gost/config.json"
            if [[ -f "$config_file" ]]; then
                jq --arg name "fwrd-${id}" '.services = [.services[] | select(.name != $name and .name != ($name + "-tcp") and .name != ($name + "-udp"))]' \
                   "$config_file" > "${config_file}.tmp" && mv "${config_file}.tmp" "$config_file"
                systemctl restart gost 2>/dev/null
            fi
            ;;
        nftables)
            local handle=$(nft list chain inet fwrd_nat fwrd_prerouting -a 2>/dev/null | grep "fwrd-${id}" | grep -o 'handle [0-9]*' | awk '{print $2}')
            [[ -n "$handle" ]] && nft delete rule inet fwrd_nat fwrd_prerouting handle "$handle" 2>/dev/null
            ;;
        realm)
            local config_file="/etc/realm/config.toml"
            [[ -f "$config_file" ]] && sed -i "/listen.*${listen_port}/,/^$/d" "$config_file" && systemctl restart realm 2>/dev/null
            ;;
    esac
    
    local temp_file=$(mktemp)
    TEMP_FILES+=("$temp_file")
    jq "del(.rules[$((rule_index-1))])" "$CONFIG_FILE" > "$temp_file" && mv "$temp_file" "$CONFIG_FILE"
    log_success "Rule deleted successfully"
}

# Show system status
show_system_status() {
    local ipv4_forward=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo "0")
    local ipv6_forward=$(sysctl -n net.ipv6.conf.all.forwarding 2>/dev/null || echo "0")
    
    printf "IP Forwarding:\n"
    printf "  IPv4: %s\n" "$([[ "$ipv4_forward" == "1" ]] && echo -e "${GREEN}enabled${PLAIN}" || echo -e "${RED}disabled${PLAIN}")"
    printf "  IPv6: %s\n" "$([[ "$ipv6_forward" == "1" ]] && echo -e "${GREEN}enabled${PLAIN}" || echo -e "${RED}disabled${PLAIN}")"
    
    printf "\nTool Status:\n"
    for tool in "${!FORWARD_TOOLS[@]}"; do
        local install_status="${TOOL_STATUS[$tool]}"
        local service_status="${TOOL_SERVICE_STATUS[$tool]:-disabled}"
        
        case "$install_status" in
            installed) install_status="${GREEN}installed${PLAIN}" ;;
            *) install_status="${RED}not installed${PLAIN}" ;;
        esac
        
        case "$service_status" in
            active) service_status="${GREEN}running${PLAIN}" ;;
            inactive) service_status="${YELLOW}stopped${PLAIN}" ;;
            *) service_status="${RED}disabled${PLAIN}" ;;
        esac
        
        printf "  %s: %s (%s)\n" "$tool" "$install_status" "$service_status"
    done
    
    local rules_count=$(jq '.rules | length' "$CONFIG_FILE" 2>/dev/null || echo 0)
    printf "\nActive rules: %d\n" "$rules_count"
}

# ==================== INTERACTIVE FUNCTIONS ====================

interactive_add_rule() {
    clear
    set_breadcrumb "Main > Add Rule"
    show_breadcrumb
    
    # Get listen port
    local listen_port
    read -p "Listen port (leave empty for auto): " listen_port
    if [[ -z "$listen_port" ]]; then
        listen_port=$(find_available_port) || { log_error "No available port found"; return 1; }
        log_info "Auto-selected port: $listen_port"
    else
        listen_port=$(get_valid_port "Listen port" "$listen_port") || return 1
    fi
    
    # Get target details
    printf "\n"
    local target_ip=$(get_valid_ip "Target IP") || return 1
    
    printf "\n"
    local target_port=$(get_valid_port "Target port") || return 1
    
    # Get protocol
    printf "\n"
    local protocol=$(get_protocol) || return 1
    
    # Tool selection
    printf "\nTool selection:\n"
    printf "  1. Auto-select (recommended)\n"
    
    local tools_order=(gost nftables realm)
    local available_tools=()
    local index=2
    
    for tool in "${tools_order[@]}"; do
        if [[ "${TOOL_STATUS[$tool]}" == "installed" ]]; then
            printf "  %d. %s\n" "$index" "$tool"
            available_tools+=("$tool")
            ((index++))
        fi
    done
    
    printf "\n"
    read -p "Select tool [1]: " tool_choice
    tool_choice=${tool_choice:-1}
    
    local tool="auto"
    if [[ "$tool_choice" != "1" ]]; then
        local sel_index=$((tool_choice-2))
        if [[ $sel_index -ge 0 && $sel_index -lt ${#available_tools[@]} ]]; then
            tool="${available_tools[$sel_index]}"
        fi
    fi
    
    # Show summary and confirm
    printf "\n${YELLOW}═══ Rule Summary ═══${PLAIN}\n"
    printf "  Listen: 0.0.0.0:%s\n" "$listen_port"
    printf "  Target: %s:%s\n" "$target_ip" "$target_port"
    printf "  Protocol: %s\n" "$protocol"
    printf "  Tool: %s\n" "$tool"
    printf "════════════════════\n"
    
    printf "\nCreate this rule? [Y/n]: "
    read -r confirm
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        log_info "Operation cancelled"
        return 0
    fi
    
    if add_forward_rule "$listen_port" "$target_ip" "$target_port" "$protocol" "$tool"; then
        log_success "Rule created successfully!"
        printf "Access: 0.0.0.0:%s -> %s:%s\n" "$listen_port" "$target_ip" "$target_port"
    else
        log_error "Failed to create rule"
    fi
    
    printf "\nPress Enter to continue..."
    read -r
}

# Main menu
show_main_menu() {
    while true; do
        clear
        set_breadcrumb "Main"
        show_breadcrumb
        show_system_status
        
        printf "\n${BOLD}${GREEN}==== Menu Options ====${PLAIN}\n"
        printf "  1) Install tools\n"
        printf "  2) Add forwarding rule\n"
        printf "  3) List rules\n"
        printf "  4) Delete rule\n"
        printf "  5) Service control\n"
        printf "  6) Health check\n"
        printf "  7) Backup configuration\n"
        printf "  8) Restore configuration\n"
        printf "  0) Exit\n"
        printf "\n"
        
        read -p "Choice: " choice
        case "$choice" in
            1) install_tools_menu ;;
            2) interactive_add_rule ;;
            3) list_forward_rules; printf "\nPress Enter to continue..."; read -r ;;
            4) delete_rule_interactive ;;
            5) service_control_menu ;;
            6) health_check_all; printf "\nPress Enter to continue..."; read -r ;;
            7) backup_config; printf "\nPress Enter to continue..."; read -r ;;
            8) restore_config; printf "\nPress Enter to continue..."; read -r ;;
            0) printf "${SUCCESS_SYMBOL} Goodbye${PLAIN}\n"; exit 0 ;;
            *) printf "${WARN_SYMBOL} Invalid choice${PLAIN}\n"; sleep 1 ;;
        esac
    done
}

install_tools_menu() {
    clear
    show_breadcrumb
    
    printf "\n${BOLD}Tool Installation${PLAIN}\n\n"
    
    local tools_order=(gost nftables realm)
    local index=1
    for tool in "${tools_order[@]}"; do
        local status="${TOOL_STATUS[$tool]}"
        local status_color=$([[ "$status" == "installed" ]] && echo "${GREEN}installed${PLAIN}" || echo "${RED}not installed${PLAIN}")
        printf "  %d. %s - %s (%s)\n" "$index" "$tool" "${FORWARD_TOOLS[$tool]}" "$status_color"
        ((index++))
    done
    
    printf "\n  0. Back\n\n"
    
    read -p "Install tool: " install_choice
    case "$install_choice" in
        1) [[ "${TOOL_STATUS[gost]}" == "installed" ]] && log_info "GOST already installed" || install_gost ;;
        2) [[ "${TOOL_STATUS[nftables]}" == "installed" ]] && log_info "NFTables already installed" || install_nftables ;;
        3) [[ "${TOOL_STATUS[realm]}" == "installed" ]] && log_info "Realm already installed" || install_realm ;;
        0) return ;;
        *) log_error "Invalid choice" ;;
    esac
    
    detect_tools
    printf "\nPress Enter to continue..."
    read -r
}

delete_rule_interactive() {
    clear
    show_breadcrumb
    list_forward_rules
    
    local rules_count=$(jq '.rules | length' "$CONFIG_FILE" 2>/dev/null || echo 0)
    [[ "$rules_count" -eq 0 ]] && { printf "\nPress Enter to continue..."; read -r; return; }
    
    printf "\n"
    read -p "Rule number to delete: " rule_num
    
    if [[ "$rule_num" =~ ^[0-9]+$ ]]; then
        printf "\n${YELLOW}Delete rule #%s?${PLAIN}\n" "$rule_num"
        printf "This action cannot be undone.\n"
        printf "\nContinue? [y/N]: "
        read -r confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            delete_forward_rule "$rule_num"
        else
            log_info "Operation cancelled"
        fi
    else
        log_error "Invalid rule number"
    fi
    
    printf "\nPress Enter to continue..."
    read -r
}

service_control_menu() {
    while true; do
        clear
        show_breadcrumb
        
        printf "\n${BOLD}Service Control${PLAIN}\n\n"
        
        printf "Current Status:\n"
        for tool in "${!FORWARD_TOOLS[@]}"; do
            if [[ "${TOOL_STATUS[$tool]}" == "installed" ]]; then
                local status="${TOOL_SERVICE_STATUS[$tool]}"
                local status_color
                case "$status" in
                    active) status_color="${GREEN}running${PLAIN}" ;;
                    inactive) status_color="${YELLOW}stopped${PLAIN}" ;;
                    *) status_color="${RED}disabled${PLAIN}" ;;
                esac
                printf "  %s: %s\n" "$tool" "$status_color"
            fi
        done
        
        printf "\n${BOLD}Actions:${PLAIN}\n"
        printf "  1. Start all services\n"
        printf "  2. Stop all services\n"
        printf "  3. Restart all services\n"
        printf "  4. Enable IP forwarding\n"
        printf "  0. Back\n"
        printf "\n"
        
        read -p "Select: " choice
        case "$choice" in
            1)
                log_info "Starting services..."
                for tool in "${!FORWARD_TOOLS[@]}"; do
                    [[ "${TOOL_STATUS[$tool]}" == "installed" ]] && systemctl start "$tool" 2>/dev/null
                done
                detect_tools
                ;;
            2)
                log_info "Stopping services..."
                for tool in "${!FORWARD_TOOLS[@]}"; do
                    systemctl stop "$tool" 2>/dev/null
                done
                detect_tools
                ;;
            3)
                log_info "Restarting services..."
                for tool in "${!FORWARD_TOOLS[@]}"; do
                    [[ "${TOOL_STATUS[$tool]}" == "installed" ]] && systemctl restart "$tool" 2>/dev/null
                done
                detect_tools
                ;;
            4)
                sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
                sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1
                
                # Ensure persistence
                if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf 2>/dev/null; then
                    echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
                fi
                if ! grep -q "net.ipv6.conf.all.forwarding=1" /etc/sysctl.conf 2>/dev/null; then
                    echo 'net.ipv6.conf.all.forwarding=1' >> /etc/sysctl.conf
                fi
                
                log_success "IPv4/IPv6 forwarding enabled"
                ;;
            0) return ;;
            *) log_error "Invalid choice"; sleep 1 ;;
        esac
        
        [[ "$choice" != "0" ]] && { printf "\nPress Enter to continue..."; read -r; }
    done
}

# ==================== MAIN ENTRY POINT ====================

main() {
    check_system
    setup_config
    detect_tools
    show_main_menu
}

# Script entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
