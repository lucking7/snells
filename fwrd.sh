#!/usr/bin/env bash

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
# Bash version check (must be >=4.0)
if [[ -z "${BASH_VERSINFO+x}" || ${BASH_VERSINFO[0]} -lt 4 ]]; then
  echo "[x] Bash 4.0+ required" >&2
  exit 2
fi

# OS detection and Linux check
OS_NAME=$(uname -s 2>/dev/null || echo "Unknown")
if [[ "$OS_NAME" != "Linux" ]]; then
    echo "[x] This script requires Linux. Detected: $OS_NAME" >&2
    echo "[x] macOS/BSD are not supported" >&2
    exit 2
fi

# ==================== CLI/LOG DEFAULTS (ADDED) ====================
# Global CLI flags and runtime defaults. Only effective when CLI mode is used.
BACKEND="auto"             # --backend gost|realm|auto
DRY_RUN=0                   # --dry-run
HEALTH_ONLY=0               # --health-check
LOG_LEVEL="info"           # --log-level (error|warn|info|debug|trace)
NO_COLOR=0                  # --no-color
USER_LOG_FILE=""           # --log-file (optional override)
CONFIG_INPUT=""            # --config (future: unified JSON / realm TOML / gost JSON)

# Endpoint storage (CLI mode). Store as JSON objects for safe merge/validate.
# Each entry shape: {"listen":"host:port","remote":"host:port","proto":"tcp|udp|both","timeout":N,"dns":"ip","bind_if":"name","pp":"send|recv|none"}
CLI_ENDPOINTS_RAW=()        # raw strings passed by --endpoint
ENDPOINTS_JSON=()           # validated objects as JSON strings

# Logging level map (requires Bash 4 associative arrays)
declare -A LEVEL_MAP=([error]=0 [warn]=1 [info]=2 [debug]=3 [trace]=4)
# Current threshold numeric value, computed from LOG_LEVEL at runtime
LOG_THRESHOLD=2

# Max log file size for rotation (bytes). 5MB default.
LOG_MAX_SIZE=$((5 * 1024 * 1024))

# Timeout constants (seconds)
readonly HEALTH_CHECK_TIMEOUT=5
readonly PORT_CHECK_TIMEOUT=2
readonly CONNECTIVITY_TIMEOUT=2
readonly BACKEND_STARTUP_TIMEOUT=5

# Process protection levels
# Format: "OOMScore:Nice:MemHigh:MemMax"
declare -A PROTECTION_LEVELS=(
    [aggressive]="-1000:-10:infinity:infinity"
    [balanced]="-900:-5:2G:4G"
    [conservative]="-500:0:1G:2G"
)
DEFAULT_PROTECTION_LEVEL="balanced"

# Runtime tmp dir and child process tracking (CLI mode)
TMP_RUNTIME_DIR=""
CHILD_PID=""

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

# Logging functions (enhanced)
# LOG_FILE default remains /var/log/fwrd.log (backward compatible). Can be overridden by --log-file.
LOG_FILE="/var/log/fwrd.log"

# rotate_log: simple size-based rotation; keep one rotated copy with timestamp
# Params: none
# Return: 0 always
rotate_log() {
    local size=0
    if [[ -f "$LOG_FILE" ]]; then
        size=$(wc -c <"$LOG_FILE" 2>/dev/null || echo 0)
        if [[ "$size" -gt "$LOG_MAX_SIZE" ]]; then
            local ts
            ts=$(date +%F_%H%M%S)
            mv "$LOG_FILE" "${LOG_FILE}.${ts}" 2>/dev/null || true
        fi
    fi
}

# apply_color: honor --no-color to strip ANSI sequences
# Params: $1: text
# Return: prints text with or without color
apply_color() {
    if [[ "$NO_COLOR" -eq 1 ]]; then
        # remove ANSI color codes
        sed -E 's/\x1B\[[0-9;]*[JKmsu]//g' <<<"$1"
    else
        printf "%b" "$1"
    fi
}

# _compute_threshold: compute LOG_THRESHOLD from LOG_LEVEL
# Params: none
# Return: set LOG_THRESHOLD
_compute_threshold() {
    local lvl=${LOG_LEVEL,,}
    LOG_THRESHOLD=${LEVEL_MAP[$lvl]:-2}
}

# _ensure_logfile: set file path and permissions
# Params: none
# Return: 0
_ensure_logfile() {
    [[ -n "$USER_LOG_FILE" ]] && LOG_FILE="$USER_LOG_FILE"
    # create if possible, with safe perms
    if touch "$LOG_FILE" 2>/dev/null; then
        chmod 640 "$LOG_FILE" 2>/dev/null || true
    fi
}

# log_to_file: append message to log file with timestamp; rotates if needed
# Params: $*: message
log_to_file() {
    _ensure_logfile
    rotate_log
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE" 2>/dev/null || true
}

# _log: core logger with level filtering and dual output
# Params: $1 level; $2.. message
_log() {
    local lvl=$1; shift || true
    _compute_threshold
    local lvln=${LEVEL_MAP[$lvl]:-2}
    if [[ "$lvln" -le "$LOG_THRESHOLD" ]]; then
        local tag
        case "$lvl" in
            error) tag="$ERROR_SYMBOL" ;;
            warn)  tag="$WARN_SYMBOL" ;;
            info)  tag="$INFO_SYMBOL" ;;
            debug|trace) tag="${BOLD}${BLUE}[d]${PLAIN}" ;;
        esac
        local msg="$*"
        # stdout (respect color flag)
        apply_color "${tag} ${msg}${PLAIN}\n"
        # file
        log_to_file "${lvl^^}: ${msg}"
    fi
}

# Public wrappers (names unchanged for backward compatibility)
log_info()    { _log info   "$@"; }
log_success() { _log info   "$@"; }
log_warn()    { _log warn   "$@"; }
log_error()   { _log error  "$@"; }

# compute masked string for sensitive values (e.g., credentials)
# Params: $1 raw
# Return: masked string
mask_sensitive() {
    local s="$1"
    [[ -z "$s" ]] && { echo ""; return; }
    local len=${#s}
    if (( len <= 3 )); then echo "***"; else echo "${s:0:1}***${s: -1}"; fi
}

# Normalize and validate host:port string.
# Params: $1 string (like ":8080" or "0.0.0.0:8080"); fills default host 0.0.0.0 when missing
# Return: echo normalized host:port, non-zero on error (3)
normalize_hostport() {
    local s="$1"
    if [[ "$s" == :* ]]; then s="0.0.0.0${s}"; fi
    if [[ "$s" != *:* ]]; then
        log_error "无效的地址：$s；需 host:port 或 :port"
        return 3
    fi
    local host="${s%:*}"; local port="${s##*:}"
    if ! validated_port=$(validate_port "$port"); then
        log_error "端口无效：$port；范围 1-65535"
        return 3
    fi
    if ! validated_ip=$(validate_ip "$host"); then
        log_error "主机无效：$host；需 IPv4 或域名"
        return 3
    fi
    echo "${validated_ip}:${validated_port}"
}

# Check port occupancy using ss/lsof
# Params: $1 port
# Return: 0 if free, 4 if occupied
check_port_free() {
    local port="$1"
    if ss -tuln 2>/dev/null | grep -q ":${port} "; then
        return 4
    fi
    if lsof -i :"$port" >/dev/null 2>&1; then
        return 4
    fi
    return 0
}

# Parse one --endpoint KV list into a JSON object and push into ENDPOINTS_JSON.
# Supports keys: listen,remote,proto,timeout,dns,bind_interface,pp
# Return: 0 on success, 3 on validation failure, 4 on port conflict
parse_endpoint_kv() {
    local kvs="$1"
    local listen="" remote="" proto="" timeout="" dns="" bind_if="" pp=""
    IFS=',' read -r -a parts <<<"$kvs"
    local p
    for p in "${parts[@]}"; do
        p=${p//[$'\t\r\n']/}
        [[ -z "$p" ]] && continue
        local k="${p%%=*}"; local v="${p#*=}"
        case "$k" in
            listen) listen="$v" ;;
            remote) remote="$v" ;;
            proto)  proto="${v,,}" ;;
            timeout) timeout="$v" ;;
            dns)    dns="$v" ;;
            bind_interface|bind-if|bind_if) bind_if="$v" ;;
            pp|proxy_protocol) pp="${v,,}" ;;
            *) log_warn "忽略未知端点键：$k" ;;
        esac
    done
    # Required fields
    if [[ -z "$listen" || -z "$remote" ]]; then
        log_error "--endpoint 缺少必要键：listen 与 remote"
        return 3
    fi
    local nlisten; nlisten=$(normalize_hostport "$listen") || return 3
    local nremote; nremote=$(normalize_hostport "$remote") || return 3
    # proto default both
    case "$proto" in ""|both|tcp|udp) : ;; *) log_error "proto 必须为 tcp|udp|both"; return 3;; esac
    [[ -z "$proto" ]] && proto="both"
    # timeout optional int
    if [[ -n "$timeout" && ! "$timeout" =~ ^[0-9]+$ ]]; then
        log_error "timeout 必须为整数秒"
        return 3
    fi
    # dns optional ip
    if [[ -n "$dns" ]]; then
        if ! validate_ip "$dns" >/dev/null; then
            log_error "dns 必须为 IPv4 或域名"
            return 3
        fi
    fi
    # proxy protocol
    case "$pp" in ""|none|send|recv) : ;; *) log_error "pp 必须为 send|recv|none"; return 3;; esac
    [[ -z "$pp" ]] && pp="none"
    # port conflict check
    local lport="${nlisten##*:}"
    if ! check_port_free "$lport"; then
        log_error "端口 $lport 已被占用；建议使用替代端口 $(find_available_port || echo 0)"
        return 4
    fi
    # build JSON
    local obj
    obj=$(jq -n --arg listen "$nlisten" --arg remote "$nremote" --arg proto "$proto" \
                --arg timeout "${timeout:-0}" --arg dns "$dns" --arg bind_if "$bind_if" --arg pp "$pp" \
                '{listen:$listen,remote:$remote,proto:$proto,timeout:($timeout|tonumber),dns:$dns,bind_if:$bind_if,pp:$pp}')
    ENDPOINTS_JSON+=("$obj")
    return 0
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

# Optimize kernel network parameters for forwarding
# Params: none
# Return: 0 on success
optimize_kernel_params() {
    log_info "优化内核网络参数..."

    # 确保 conntrack 模块加载
    if ! lsmod | grep -q nf_conntrack; then
        modprobe nf_conntrack 2>/dev/null || log_warn "无法加载 nf_conntrack 模块"
    fi

    # 连接跟踪表优化
    sysctl -w net.netfilter.nf_conntrack_max=1048576 >/dev/null 2>&1 || true
    sysctl -w net.nf_conntrack_max=1048576 >/dev/null 2>&1 || true

    # TCP 连接优化
    sysctl -w net.core.somaxconn=65535 >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_max_syn_backlog=8192 >/dev/null 2>&1
    sysctl -w net.ipv4.ip_local_port_range="1024 65535" >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_tw_reuse=1 >/dev/null 2>&1

    # 文件描述符优化
    local current_max=$(cat /proc/sys/fs/file-max)
    if [[ $current_max -lt 1048576 ]]; then
        sysctl -w fs.file-max=1048576 >/dev/null 2>&1
    fi

    # 持久化配置
    local sysctl_conf="/etc/sysctl.d/99-fwrd.conf"
    cat > "$sysctl_conf" << 'EOF'
# FWRD forwarding optimizations
net.netfilter.nf_conntrack_max = 1048576
net.nf_conntrack_max = 1048576
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_tw_reuse = 1
fs.file-max = 1048576
EOF

    log_success "内核参数优化完成"
    return 0
}

# Check connection tracking table usage
# Params: none
# Return: 0
check_conntrack_usage() {
    if [[ ! -f /proc/sys/net/netfilter/nf_conntrack_count ]]; then
        log_info "连接跟踪模块未加载"
        return 0
    fi

    local current=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo 0)
    local max=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo 65536)
    local usage=$((current * 100 / max))

    printf "连接跟踪: %d/%d (使用率 %d%%)" "$current" "$max" "$usage"

    if [[ $usage -gt 90 ]]; then
        printf " ${RED}[危险: 即将耗尽]${PLAIN}\n"
        log_error "连接跟踪表使用率 ${usage}%，即将耗尽！"
    elif [[ $usage -gt 80 ]]; then
        printf " ${YELLOW}[警告: 使用率过高]${PLAIN}\n"
        log_warn "连接跟踪表使用率 ${usage}%，建议增加 nf_conntrack_max"
    else
        printf " ${GREEN}[正常]${PLAIN}\n"
    fi
}

# Check file descriptor usage
# Params: none
# Return: 0
check_fd_usage() {
    local allocated=$(cat /proc/sys/fs/file-nr | awk '{print $1}')
    local max=$(cat /proc/sys/fs/file-max)
    local usage=$((allocated * 100 / max))

    printf "文件描述符: %d/%d (使用率 %d%%)" "$allocated" "$max" "$usage"

    if [[ $usage -gt 85 ]]; then
        printf " ${RED}[危险]${PLAIN}\n"
        log_error "文件描述符使用率 ${usage}%，即将耗尽！"
    elif [[ $usage -gt 70 ]]; then
        printf " ${YELLOW}[警告]${PLAIN}\n"
        log_warn "文件描述符使用率 ${usage}%"
    else
        printf " ${GREEN}[正常]${PLAIN}\n"
    fi
}

# Show system resource status
# Params: none
# Return: 0
show_resource_status() {
    printf "\n${BOLD}系统资源状态${PLAIN}\n"
    printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
    check_conntrack_usage
    check_fd_usage

    # 内存使用
    local mem_total=$(free -m | awk '/^Mem:/ {print $2}')
    local mem_used=$(free -m | awk '/^Mem:/ {print $3}')
    local mem_usage=$((mem_used * 100 / mem_total))
    printf "系统内存: %dMB/%dMB (使用率 %d%%)" "$mem_used" "$mem_total" "$mem_usage"
    if [[ $mem_usage -gt 80 ]]; then
        printf " ${YELLOW}[警告]${PLAIN}\n"
    else
        printf " ${GREEN}[正常]${PLAIN}\n"
    fi

    printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
}

# Create system user and group for service
# Params: $1 service name
# Return: 0 on success
create_system_user_group() {
    local name="$1"
    getent group "$name" >/dev/null 2>&1 || groupadd --system "$name"
    id -u "$name" >/dev/null 2>&1 || useradd --system --no-create-home --shell /bin/false -g "$name" "$name"
    return 0
}

check_system() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Root privileges required"
        return 1
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
    "max_rules": 100,
    "protection_level": "balanced",
    "kernel_optimized": false
  }
}
EOF
        chmod 640 "$CONFIG_FILE" 2>/dev/null || true
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

    # Ensure persistence with proper permissions and reload
    if [[ -d /etc/nftables.d ]]; then
        nft list table inet fwrd_nat > /etc/nftables.d/fwrd.nft 2>/dev/null || true
        chmod 640 /etc/nftables.d/fwrd.nft 2>/dev/null || true
        # Reload nftables service to ensure rules persist across reboots
        systemctl reload nftables 2>/dev/null || true
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
    create_system_user_group gost

    # 获取保护级别配置
    local protection_level=$(jq -r '.global_settings.protection_level // "balanced"' "$CONFIG_FILE" 2>/dev/null || echo "balanced")
    local params="${PROTECTION_LEVELS[$protection_level]}"
    local oom_score=$(echo "$params" | cut -d: -f1)
    local nice=$(echo "$params" | cut -d: -f2)
    local mem_high=$(echo "$params" | cut -d: -f3)
    local mem_max=$(echo "$params" | cut -d: -f4)

    cat > "/etc/systemd/system/gost.service" << EOF
[Unit]
Description=GOST Proxy Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/gost -C /etc/gost/config.json
Restart=always
RestartSec=5
User=gost
Group=gost

# Security hardening
NoNewPrivileges=true
LimitNOFILE=infinity
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE

# Process protection (OOM & Priority)
OOMScoreAdjust=$oom_score
OOMPolicy=continue
Nice=$nice
IOSchedulingClass=best-effort
IOSchedulingPriority=2

# Resource limits
TasksMax=infinity
LimitNPROC=infinity
LimitCORE=0
MemoryHigh=$mem_high
MemoryMax=$mem_max

# Restart policy
StartLimitIntervalSec=0

# Logging
LogRateLimitIntervalSec=30s
LogRateLimitBurst=1000

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
    create_system_user_group realm

    # 获取保护级别配置
    local protection_level=$(jq -r '.global_settings.protection_level // "balanced"' "$CONFIG_FILE" 2>/dev/null || echo "balanced")
    local params="${PROTECTION_LEVELS[$protection_level]}"
    local oom_score=$(echo "$params" | cut -d: -f1)
    local nice=$(echo "$params" | cut -d: -f2)
    local mem_high=$(echo "$params" | cut -d: -f3)
    local mem_max=$(echo "$params" | cut -d: -f4)

    cat > "/etc/systemd/system/realm.service" << EOF
[Unit]
Description=Realm Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=realm
Group=realm
Restart=always
RestartSec=5s
ExecStart=$TOOLS_DIR/realm -c /etc/realm/config.toml

# Security hardening
NoNewPrivileges=true
LimitNOFILE=infinity
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE

# Process protection (OOM & Priority)
OOMScoreAdjust=$oom_score
OOMPolicy=continue
Nice=$nice
IOSchedulingClass=best-effort
IOSchedulingPriority=2

# Resource limits
TasksMax=infinity
LimitNPROC=infinity
LimitCORE=0
MemoryHigh=$mem_high
MemoryMax=$mem_max

# Restart policy
StartLimitIntervalSec=0

# Logging
LogRateLimitIntervalSec=30s
LogRateLimitBurst=1000

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
            if [[ -f "$config_file" ]]; then
                # Use awk to precisely remove the endpoint block containing the listen port
                awk -v port="$listen_port" '
                BEGIN { in_block=0; block=""; skip=0 }
                /^\[\[endpoints\]\]/ {
                    if (block != "" && skip == 0) print block
                    in_block=1; block=$0 "\n"; skip=0; next
                }
                in_block {
                    block = block $0 "\n"
                    if ($0 ~ "listen.*:" port) skip=1
                    if ($0 ~ /^$/ || $0 ~ /^\[/) {
                        if (skip == 0) printf "%s", block
                        block=""; in_block=0; skip=0
                    }
                    if ($0 ~ /^\[/ && !($0 ~ /^\[\[endpoints\]\]/)) next
                }
                !in_block { print }
                END { if (block != "" && skip == 0) printf "%s", block }
                ' "$config_file" > "${config_file}.tmp" && mv "${config_file}.tmp" "$config_file"
                systemctl restart realm 2>/dev/null
            fi
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
        printf "  9) System optimization\n"
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
            9) system_optimization_menu ;;
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

# System optimization and monitoring menu
system_optimization_menu() {
    while true; do
        clear
        set_breadcrumb "Main > System Optimization"
        show_breadcrumb

        # Show current optimization status
        local kernel_optimized=$(jq -r '.global_settings.kernel_optimized // false' "$CONFIG_FILE" 2>/dev/null)
        local protection_level=$(jq -r '.global_settings.protection_level // "balanced"' "$CONFIG_FILE" 2>/dev/null)

        printf "\n${BOLD}当前配置${PLAIN}\n"
        printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
        printf "内核优化: "
        if [[ "$kernel_optimized" == "true" ]]; then
            printf "${GREEN}已启用${PLAIN}\n"
        else
            printf "${YELLOW}未启用${PLAIN}\n"
        fi
        printf "保护级别: "
        case "$protection_level" in
            aggressive) printf "${RED}激进保护${PLAIN} (OOMScore=-1000)\n" ;;
            balanced) printf "${GREEN}平衡保护${PLAIN} (OOMScore=-900)\n" ;;
            conservative) printf "${BLUE}保守保护${PLAIN} (OOMScore=-500)\n" ;;
            *) printf "${YELLOW}未知${PLAIN}\n" ;;
        esac
        printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"

        printf "\n${BOLD}操作菜单${PLAIN}\n"
        printf "  1) 优化内核参数\n"
        printf "  2) 查看资源使用状态\n"
        printf "  3) 设置服务保护级别\n"
        printf "  4) 重建所有服务单元（应用新保护级别）\n"
        printf "  0) 返回主菜单\n"
        printf "\n"

        read -p "选择: " opt_choice
        case "$opt_choice" in
            1)
                clear
                printf "\n${BOLD}内核参数优化${PLAIN}\n"
                printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
                printf "此操作将优化以下参数：\n"
                printf "  • 连接跟踪表: 1048576\n"
                printf "  • TCP 连接队列: 65535\n"
                printf "  • 文件描述符: 1048576\n"
                printf "  • 端口范围优化\n"
                printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
                printf "\n继续优化? [Y/n]: "
                read -r confirm
                if [[ ! "$confirm" =~ ^[Nn]$ ]]; then
                    optimize_kernel_params
                    # 更新配置标记
                    local temp_file=$(mktemp)
                    TEMP_FILES+=("$temp_file")
                    jq '.global_settings.kernel_optimized = true' "$CONFIG_FILE" > "$temp_file" && \
                        mv "$temp_file" "$CONFIG_FILE"
                fi
                printf "\nPress Enter to continue..."
                read -r
                ;;
            2)
                clear
                show_resource_status
                printf "\nPress Enter to continue..."
                read -r
                ;;
            3)
                clear
                printf "\n${BOLD}设置服务保护级别${PLAIN}\n"
                printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
                printf "\n选择保护级别:\n"
                printf "  1) ${RED}激进保护${PLAIN}\n"
                printf "     • OOMScore: -1000 (最高优先级)\n"
                printf "     • Nice: -10 (CPU 高优先级)\n"
                printf "     • 内存: 无限制\n"
                printf "     • 适用: 生产环境，关键服务\n"
                printf "\n"
                printf "  2) ${GREEN}平衡保护${PLAIN} (推荐)\n"
                printf "     • OOMScore: -900\n"
                printf "     • Nice: -5\n"
                printf "     • 内存: 2G/4G\n"
                printf "     • 适用: 一般环境\n"
                printf "\n"
                printf "  3) ${BLUE}保守保护${PLAIN}\n"
                printf "     • OOMScore: -500\n"
                printf "     • Nice: 0\n"
                printf "     • 内存: 1G/2G\n"
                printf "     • 适用: 测试环境\n"
                printf "\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
                printf "\n选择 [2]: "
                read -r level_choice
                level_choice=${level_choice:-2}

                local level_name
                case "$level_choice" in
                    1) level_name="aggressive" ;;
                    2) level_name="balanced" ;;
                    3) level_name="conservative" ;;
                    *) log_error "Invalid choice"; sleep 1; continue ;;
                esac

                # 更新配置
                local temp_file=$(mktemp)
                TEMP_FILES+=("$temp_file")
                jq --arg level "$level_name" '.global_settings.protection_level = $level' "$CONFIG_FILE" > "$temp_file" && \
                    mv "$temp_file" "$CONFIG_FILE"

                log_success "保护级别已设置为: $level_name"
                printf "\n${YELLOW}提示:${PLAIN} 需要选择菜单项 4 重建服务单元以应用新保护级别\n"
                printf "\nPress Enter to continue..."
                read -r
                ;;
            4)
                clear
                printf "\n${BOLD}重建服务单元${PLAIN}\n"
                printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
                printf "此操作将使用当前保护级别重建所有已安装工具的服务单元\n"
                printf "\n继续? [Y/n]: "
                read -r confirm
                if [[ ! "$confirm" =~ ^[Nn]$ ]]; then
                    local rebuilt=0
                    for tool in gost realm; do
                        if [[ "${TOOL_STATUS[$tool]}" == "installed" ]]; then
                            log_info "重建 $tool 服务单元..."
                            if [[ "$tool" == "gost" ]]; then
                                create_gost_service
                            elif [[ "$tool" == "realm" ]]; then
                                create_realm_service
                            fi
                            ((rebuilt++))
                        fi
                    done

                    if [[ $rebuilt -gt 0 ]]; then
                        log_success "已重建 $rebuilt 个服务单元"
                        log_info "重启服务以应用新配置..."
                        for tool in gost realm; do
                            [[ "${TOOL_STATUS[$tool]}" == "installed" ]] && systemctl restart "$tool" 2>/dev/null
                        done
                        detect_tools
                        log_success "服务已重启"
                    else
                        log_warn "未找到已安装的服务"
                    fi
                fi
                printf "\nPress Enter to continue..."
                read -r
                ;;
            0) return ;;
            *) log_error "Invalid choice"; sleep 1 ;;
        esac
    done
}

# ==================== CLI MODE (ADDED) ====================
# show_help: Print detailed CLI usage and examples
# Params: none
# Return: 0
show_help() {
  cat <<'HLP'
用法: fwrd.sh [选项]

无参数运行：进入交互式菜单（保持与旧版完全一致）

可选项（仅在显式提供时生效，不影响旧行为）:
  --backend {auto|gost|realm}   指定后端，默认 auto（自动选择已安装后端）
  --endpoint "listen=:8080,remote=127.0.0.1:80,proto=tcp[,timeout=10][,dns=8.8.8.8][,bind_interface=eth0][,pp=send|recv|none]"
                                可多次指定以添加多个端点
  --config PATH                  统一配置文件路径（阶段2：仅支持本脚本自定义JSON；阶段3将支持Realm TOML/GOST JSON）
  --dry-run                      仅显示将生成的配置与命令，不实际执行
  --health-check                 仅进行依赖与端口健康检查并以退出码返回
  --verbose                      等价于 --log-level=debug
  --log-level {error|warn|info|debug|trace}
  --log-file PATH                日志输出到文件（默认 /var/log/fwrd.log）
  --no-color                     禁用彩色输出
  --help                         显示本帮助

示例:
  单端点TCP干跑:
    ./fwrd.sh --endpoint "listen=:10080,remote=127.0.0.1:8080,proto=tcp" --dry-run

  多端点（Realm/GOST均可）：
    ./fwrd.sh --backend realm \
      --endpoint "listen=:10535,remote=1.1.1.1:53,proto=udp" \
      --endpoint "listen=:18080,remote=127.0.0.1:8080,proto=tcp" --dry-run

退出码:
  0 成功 | 1 参数/未知错误 | 2 依赖缺失 | 3 参数校验失败 | 4 端口冲突 | 5 后端启动失败 | 6 健康检查失败 | 7 权限不足
HLP
}

# parse_cli_args: parse top-level CLI options and populate globals
# Params: $@ from CLI
# Return: 0 success; 1 unknown option
parse_cli_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --backend) BACKEND="$2"; shift 2;;
      --endpoint) CLI_ENDPOINTS_RAW+=("$2"); shift 2;;
      --config) CONFIG_INPUT="$2"; shift 2;;
      --dry-run) DRY_RUN=1; shift;;
      --health-check) HEALTH_ONLY=1; shift;;
      --verbose) LOG_LEVEL="debug"; shift;;
      --log-level) LOG_LEVEL="$2"; shift 2;;
      --log-file) USER_LOG_FILE="$2"; shift 2;;
      --no-color) NO_COLOR=1; shift;;
      --help) show_help; exit 0;;
      --*) echo "未知参数: $1"; return 1;;
      *) echo "未知位置参数: $1"; return 1;;
    esac
  done
  return 0
}

# choose_backend: decide final backend respecting --backend and installed tools
# Return: echo backend or 'none'
choose_backend() {
  local b="${BACKEND,,}"
  case "$b" in
    gost|realm) echo "$b"; return;;
    auto|"")
      if command -v gost >/dev/null 2>&1; then echo gost; return; fi
      if command -v realm >/dev/null 2>&1; then echo realm; return; fi
      echo none; return;;
    *) echo none; return;;
  esac
}

# validate_and_collect_endpoints: parse CLI endpoints into ENDPOINTS_JSON
# Return: 0 or non-zero per错误码
validate_and_collect_endpoints() {
  local e
  for e in "${CLI_ENDPOINTS_RAW[@]}"; do
    parse_endpoint_kv "$e" || return $?
  done
  return 0
}

# build_endpoints_json_array: pack ENDPOINTS_JSON[*] into a JSON array string
# Return: echo JSON array
build_endpoints_json_array() {
  local arr='[]'
  local item
  for item in "${ENDPOINTS_JSON[@]}"; do
    arr=$(jq -c --argjson it "$item" '. + [ $it ]' <<<"$arr")
  done
  echo "$arr"
}

# cli_main: entry for CLI mode (when arguments present)
# Behavior (阶段1/2): 解析参数、校验端点、选择后端；支持 --dry-run 与基本 --health-check
# Return: exit with proper code
cli_main() {
  # 权限检查（仅在需要写日志或健康检查操作时提示）
  if [[ $EUID -ne 0 ]]; then
    # 保持与旧逻辑一致：菜单模式需 root；CLI模式中，若仅 dry-run 可不强制 root
    if [[ $DRY_RUN -eq 0 ]]; then
      log_error "需要 root 权限运行（或使用 sudo）"
      return 7
    fi
  fi

  # 初始化日志文件（如可写）
  _ensure_logfile

  # 解析端点
  if [[ ${#CLI_ENDPOINTS_RAW[@]} -gt 0 ]]; then
    validate_and_collect_endpoints || return $?
  fi

  # 合并配置（阶段2）：
  #  - 当前阶段仅合并 CLI 端点；--config 留待阶段3针对 realm.tml/gost.json 做真实装载
  if [[ -n "$CONFIG_INPUT" ]]; then
    case "$CONFIG_INPUT" in
      *.json)
        # 尝试读取统一JSON: {"endpoints":[...]} （可选）
        if jq -e . "$CONFIG_INPUT" >/dev/null 2>&1; then
          local conf_eps
          conf_eps=$(jq -c '.endpoints // []' "$CONFIG_INPUT" 2>/dev/null || echo '[]')
          # 将文件端点附加到 ENDPOINTS_JSON（CLI 优先，文件次之）
          local idx len
          len=$(jq 'length' <<<"$conf_eps")
          for ((idx=0; idx<len; idx++)); do
            ENDPOINTS_JSON+=("$(jq -c ".[$idx]" <<<"$conf_eps")")
          done
        else
          log_warn "--config 指向的 JSON 无法解析；将于阶段3支持 Realm TOML / GOST JSON"
        fi
        ;;
      *.toml|*.yml|*.yaml)
        log_warn "阶段3将支持 Realm TOML / GOST YAML/JSON 的装载与合并；当前仅使用 CLI 端点"
        ;;
      *) log_warn "未知的配置文件类型：$CONFIG_INPUT" ;;
    esac
  fi

  # 选择后端
  local backend
  backend=$(choose_backend)
  if [[ "$backend" == "none" ]]; then
    log_error "未发现可用后端；请安装 gost 或 realm，或使用 --backend 指定"
    return 2
  fi

  # 健康检查（阶段4增强：依赖+版本+端口占用）
  if [[ $HEALTH_ONLY -eq 1 ]]; then
    if ! command -v "$backend" >/dev/null 2>&1; then
      log_error "依赖缺失：$backend 未安装"
      return 2
    fi
    # 版本检测：根据仓库现有逻辑使用 --version
    local ver
    ver=$("$backend" --version 2>/dev/null | head -1 || true)
    [[ -n "$ver" ]] && log_info "$backend 版本: $ver" || log_warn "$backend 版本信息不可用"
    # 端口占用（仅针对 CLI 端点）
    local itm
    for itm in "${ENDPOINTS_JSON[@]}"; do
      local lport
      lport=$(jq -r '.listen|split(":")|.[1]' <<<"$itm")
      if ss -tuln 2>/dev/null | grep -q ":${lport} "; then
        log_warn "端口 ${lport} 已被占用"
        return 6
      fi
    done
    log_info "健康检查通过"
    return 0
  fi

  # 干跑输出
  if [[ $DRY_RUN -eq 1 ]]; then
    local eps_json; eps_json=$(build_endpoints_json_array)
    log_info "干跑模式：不实际执行，仅展示摘要"
# ===== Stage4 Ops helpers: mktemp/trap/cleanup =====
# safe_mktemp_dir: create secure runtime dir (700) and export TMP_RUNTIME_DIR
# Params: none; Return: 0 echo path; non-zero on fail
safe_mktemp_dir() {
  local d
  d=$(mktemp -d 2>/dev/null || printf "/tmp/fwrd.%s" "$$")
  mkdir -p "$d" 2>/dev/null || true
  chmod 700 "$d" 2>/dev/null || true
  TMP_RUNTIME_DIR="$d"
  echo "$d"
}

# cleanup_runtime: kill child, remove temp files/dir; safe to call multiple times
# Params: none; Return: 0
cleanup_runtime() {
  if [[ -n "$CHILD_PID" ]] && kill -0 "$CHILD_PID" 2>/dev/null; then
    kill "$CHILD_PID" 2>/dev/null || true
    sleep 0.2
    kill -9 "$CHILD_PID" 2>/dev/null || true
    CHILD_PID=""
  fi
  local f
  for f in "${TEMP_FILES[@]}"; do rm -f -- "$f" 2>/dev/null || true; done
  if [[ -n "$TMP_RUNTIME_DIR" && -d "$TMP_RUNTIME_DIR" ]]; then rm -rf -- "$TMP_RUNTIME_DIR" 2>/dev/null || true; fi
  return 0
}

# install_cli_traps: set traps for INT/TERM/EXIT in CLI mode
# Params: none; Return: 0
install_cli_traps() {
  trap 'log_warn "收到中断信号，正在清理..."; cleanup_runtime; exit 130' INT TERM
  trap 'cleanup_runtime' EXIT
}

    log_info "后端：$backend"
    log_info "端点数量：$(jq 'length' <<<"$eps_json")"
    printf "\n配置摘要(JSON)：\n%s\n" "$(jq . <<<"$eps_json")"
# build_realm_toml_from_endpoints: generate Realm TOML config from ENDPOINTS_JSON
# Params: $1 output file path; $2 JSON array of endpoints
# Return: 0 on success; 3 on invalid data
build_realm_toml_from_endpoints() {
  local out="$1"; local arr="$2"
  umask 077
  : >"$out" || { log_error "无法写入 $out"; return 3; }
  # Compute global flags
  local any_tcp=false any_udp=false i len
  len=$(jq 'length' <<<"$arr")
  for ((i=0; i<len; i++)); do
    local proto; proto=$(jq -r ".[$i].proto" <<<"$arr")
    [[ "$proto" == "tcp" || "$proto" == "both" ]] && any_tcp=true
    [[ "$proto" == "udp" || "$proto" == "both" ]] && any_udp=true
  done
  {
    echo "[network]"
    if $any_tcp; then echo "no_tcp = false"; else echo "no_tcp = true"; fi
    if $any_udp; then echo "use_udp = true"; else echo "use_udp = false"; fi
    echo
  } >>"$out"
  # Endpoints
  for ((i=0; i<len; i++)); do
    local listen remote proto
    listen=$(jq -r ".[$i].listen" <<<"$arr")
    remote=$(jq -r ".[$i].remote" <<<"$arr")
    proto=$(jq -r ".[$i].proto" <<<"$arr")
    local use_tcp=false use_udp=false
    [[ "$proto" == "tcp" || "$proto" == "both" ]] && use_tcp=true
    [[ "$proto" == "udp" || "$proto" == "both" ]] && use_udp=true
    {
      echo "[[endpoints]]"
      echo "listen = \"$listen\""
      echo "remote = \"$remote\""
      echo "use_tcp = ${use_tcp}"
      echo "use_udp = ${use_udp}"
      echo
    } >>"$out"
  done
  chmod 600 "$out" 2>/dev/null || true
  return 0
}

# build_gost_json_from_endpoints: generate GOST JSON config from ENDPOINTS_JSON
# Params: $1 output file path; $2 JSON array of endpoints
# Return: 0 on success; 3 on invalid data
build_gost_json_from_endpoints() {
  local out="$1"; local arr="$2"
  umask 077
  echo '{"services":[]}' >"$out" || { log_error "无法写入 $out"; return 3; }
  local i len; len=$(jq 'length' <<<"$arr")
  for ((i=0; i<len; i++)); do
    local listen remote proto name
    listen=$(jq -r ".[$i].listen" <<<"$arr")
    remote=$(jq -r ".[$i].remote" <<<"$arr")
    proto=$(jq -r ".[$i].proto" <<<"$arr")
    name="fwrd-$(date +%s)-$i"
    if [[ "$proto" == "both" ]]; then
      jq --arg name "${name}-tcp" --arg addr "$listen" --arg target "$remote" \
         '.services += [{name:$name,addr:$addr,handler:{type:"tcp"},listener:{type:"tcp"},forwarder:{nodes:[{name:"target-0",addr:$target}]}}]' \
         "$out" >"$out.tmp" && mv "$out.tmp" "$out"
      jq --arg name "${name}-udp" --arg addr "$listen" --arg target "$remote" \
         '.services += [{name:$name,addr:$addr,handler:{type:"udp"},listener:{type:"udp"},forwarder:{nodes:[{name:"target-0",addr:$target}]}}]' \
         "$out" >"$out.tmp" && mv "$out.tmp" "$out"
    else
      jq --arg name "$name" --arg addr "$listen" --arg proto "$proto" --arg target "$remote" \
         '.services += [{name:$name,addr:$addr,handler:{type:$proto},listener:{type:$proto},forwarder:{nodes:[{name:"target-0",addr:$target}]}}]' \
         "$out" >"$out.tmp" && mv "$out.tmp" "$out"
    fi
  done
  chmod 600 "$out" 2>/dev/null || true
  # Validate JSON
  jq empty "$out" >/dev/null 2>&1 || { log_error "GOST 配置 JSON 校验失败"; return 3; }
  return 0
}

# start_backend_with_config: start selected backend with given config
# Params: $1 backend (realm|gost); $2 config path; $3 endpoints JSON array (for health)
# Return: 0 on success; 5 on start failure
start_backend_with_config() {
  local be="$1" cfg="$2" eps="$3"
  local cmd=()
  case "$be" in
    realm) cmd=(realm -c "$cfg");;
    gost)  cmd=(gost -C "$cfg");;
    *) log_error "不支持的后端: $be"; return 5;;
  esac
  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "DRY-RUN 启动命令：${cmd[*]}"
    return 0
  fi
  # 前台运行以便 trap 优雅退出
  log_info "启动后端：${cmd[*]}"
  "${cmd[@]}" &
  CHILD_PID=$!
  # 简单健康探测：等待最多5秒看监听端口就绪
  local i=0 ready=true
  local ports_json; ports_json=$(jq -r '[.[].listen|split(":")|.[1]]' <<<"$eps")
  while [[ $i -lt 5 ]]; do
    ready=true
    local p; for p in $(jq -r '.[]' <<<"$ports_json"); do
      if ! ss -tuln 2>/dev/null | grep -q ":${p} "; then ready=false; break; fi
    done
    $ready && break
    sleep 1; i=$((i+1))
  done
  if ! $ready; then
    log_error "后端未在超时时间内就绪"
    kill "$CHILD_PID" 2>/dev/null || true
    return 5
  fi
  log_success "后端已启动 (PID=$CHILD_PID)"
  # 前台等待，便于 Ctrl-C 退出
  wait "$CHILD_PID"; return $?
}

    return 0
  fi

  # 阶段3：生成配置并启动后端（前台进程，macOS/Linux 通用）
  local eps_json; eps_json=$(build_endpoints_json_array)
  # Stage4: secure runtime dir + traps
  local tmpdir; tmpdir=$(safe_mktemp_dir)
  install_cli_traps
  local cfg_path
  case "$backend" in
    realm)
      cfg_path="$tmpdir/realm.toml"
      build_realm_toml_from_endpoints "$cfg_path" "$eps_json" || return 3
      ;;
    gost)
      cfg_path="$tmpdir/gost.json"
      build_gost_json_from_endpoints "$cfg_path" "$eps_json" || return 3
      ;;
  esac
  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "DRY-RUN 配置文件：$cfg_path"
    cat "$cfg_path"
    return 0
  fi
  start_backend_with_config "$backend" "$cfg_path" "$eps_json" || return 5
  return 0
}

# ==================== MAIN ENTRY POINT ====================

main() {
    check_system || exit 1
    setup_config
    detect_tools
    show_main_menu
}

# Script entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # CLI mode triggers only when arguments are present; otherwise keep legacy menu
    if [[ $# -gt 0 ]]; then
        if ! parse_cli_args "$@"; then
            log_error "参数错误；使用 --help 查看帮助"
            exit 1
        fi
        cli_main || exit $?
        exit 0
    else
        main "$@"
    fi
fi
