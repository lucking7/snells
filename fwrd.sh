#!/bin/bash

# Forward Manager v4.0.0
# Unified management for Realm, GOST, and Brook forwarding tools

set -o errexit
set -o nounset
set -o pipefail

# ==================== CONFIGURATION ====================

VERSION="4.0.0"
CONFIG_DIR="/etc/fwrd"
CONFIG_FILE="$CONFIG_DIR/config.json"
BACKUP_DIR="$CONFIG_DIR/backups"

REALM_DIR="/opt/realm"
REALM_CONFIG="$CONFIG_DIR/realm/config.toml"
GOST_CONFIG="$CONFIG_DIR/gost/config.json"
BROOK_CONFIG="$CONFIG_DIR/brook/forwards.conf"

# ==================== COLOR SYSTEM ====================

PLAIN='\033[0m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'

SUCCESS_SYMBOL="${BOLD}${GREEN}[+]${PLAIN}"
ERROR_SYMBOL="${BOLD}${RED}[x]${PLAIN}"
INFO_SYMBOL="${BOLD}${BLUE}[i]${PLAIN}"
WARN_SYMBOL="${BOLD}${YELLOW}[!]${PLAIN}"

# ==================== GLOBAL VARIABLES ====================

declare -A TOOL_STATUS=()
declare -A TOOL_SERVICE_STATUS=()

SUDO=""
if [ "$EUID" -ne 0 ]; then
    SUDO="sudo"
    if ! command -v sudo &>/dev/null; then
        printf "${ERROR_SYMBOL} 需要 root 权限或 sudo${PLAIN}\n"
        exit 1
    fi
fi

# ==================== UTILITY FUNCTIONS ====================

log_info()    { printf "${INFO_SYMBOL} %s${PLAIN}\n" "$*"; }
log_success() { printf "${SUCCESS_SYMBOL} %s${PLAIN}\n" "$*"; }
log_warn()    { printf "${WARN_SYMBOL} %s${PLAIN}\n" "$*"; }
log_error()   { printf "${ERROR_SYMBOL} %s${PLAIN}\n" "$*"; }

show_loading() {
    local pid=$1
    local spinstr=$'|/-\\'
    printf " "
    while ps -p "$pid" &>/dev/null; do
        local temp=${spinstr#?}
        printf "[%c]  " "$spinstr"
        spinstr=$temp${spinstr%"$temp"}
        sleep 0.2
        printf "\\b\\b\\b\\b\\b"
    done
    printf "\\b    \\b\\b\\b\\b"
    printf "${BOLD}${GREEN}[OK]${PLAIN}\n"
}

validate_port() {
    local port=$1
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

validate_ip() {
    local ip=$1
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        IFS='.' read -r -a octets <<<"$ip"
        for octet in "${octets[@]}"; do [ "$octet" -le 255 ] || return 1; done
        return 0
    fi
    [[ "$ip" =~ ^([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}$ ]] && return 0
    [[ "$ip" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.\-]{0,61}[a-zA-Z0-9])?$ ]] && return 0
    return 1
}

is_port_in_use() {
    local port=$1
    lsof -i:"$port" >/dev/null 2>&1 && return 0
    ss -tuln 2>/dev/null | grep -q ":${port} " && return 0
    return 1
}

find_available_port() {
    for ((i=0; i<100; i++)); do
        local port
        port=$(shuf -i 10000-65000 -n 1 2>/dev/null || echo $((RANDOM % 55000 + 10000)))
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
        local dev
        dev=$(ip route | grep '^default' | head -1 | awk '{print $5}')
        [ -n "$dev" ] && ip=$(ip -4 addr show "$dev" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
    fi
    echo "${ip:-N/A}"
}

press_enter() {
    printf "\n按回车键继续..."
    read -r
}

# ==================== DEPENDENCY MANAGEMENT ====================

install_dependencies() {
    local deps=("curl" "jq" "lsof")
    local missing=()
    for d in "${deps[@]}"; do
        command -v "$d" &>/dev/null || missing+=("$d")
    done
    [ ${#missing[@]} -eq 0 ] && return 0

    local pm=""
    if command -v apt-get &>/dev/null; then pm="apt-get"
    elif command -v yum &>/dev/null; then pm="yum"
    elif command -v dnf &>/dev/null; then pm="dnf"
    else log_error "未找到包管理器 (apt-get/yum/dnf)"; return 1; fi

    log_info "安装缺失依赖: ${missing[*]}"
    [ "$pm" = "apt-get" ] && $SUDO apt-get update -qq 2>/dev/null
    if $SUDO "$pm" install -y "${missing[@]}" 2>/dev/null; then
        log_success "依赖安装完成"
    else
        log_error "依赖安装失败，请手动安装: ${missing[*]}"
        return 1
    fi
}

# ==================== SYSTEM SETUP ====================

setup_config_dirs() {
    $SUDO mkdir -p "$CONFIG_DIR" "$BACKUP_DIR"
    $SUDO mkdir -p "$CONFIG_DIR/realm" "$CONFIG_DIR/gost" "$CONFIG_DIR/brook"

    if [ ! -f "$CONFIG_FILE" ]; then
        cat > /tmp/fwrd_config.json << 'EOF'
{
  "version": "4.0.0",
  "rules": [],
  "global_settings": {
    "auto_tool_selection": true,
    "default_tool": "realm"
  }
}
EOF
        $SUDO mv /tmp/fwrd_config.json "$CONFIG_FILE"
        $SUDO chmod 640 "$CONFIG_FILE"
    fi
    log_success "配置目录就绪"
}

optimize_system() {
    log_info "优化系统内核参数..."

    if ! lsmod 2>/dev/null | grep -q nf_conntrack; then
        $SUDO modprobe nf_conntrack 2>/dev/null || true
    fi

    $SUDO sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
    $SUDO sysctl -w net.core.somaxconn=65535 >/dev/null 2>&1
    $SUDO sysctl -w net.ipv4.tcp_max_syn_backlog=8192 >/dev/null 2>&1
    $SUDO sysctl -w net.ipv4.ip_local_port_range="1024 65535" >/dev/null 2>&1
    $SUDO sysctl -w net.ipv4.tcp_tw_reuse=1 >/dev/null 2>&1
    $SUDO sysctl -w fs.file-max=1048576 >/dev/null 2>&1
    $SUDO sysctl -w net.netfilter.nf_conntrack_max=1048576 >/dev/null 2>&1 || true

    cat > /tmp/99-fwrd.conf << 'EOF'
net.ipv4.ip_forward = 1
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_tw_reuse = 1
fs.file-max = 1048576
EOF
    $SUDO mv /tmp/99-fwrd.conf /etc/sysctl.d/99-fwrd.conf
    log_success "系统优化完成"
}

# ==================== TOOL DETECTION ====================

detect_realm() {
    if command -v realm &>/dev/null || [ -f "$REALM_DIR/realm" ]; then
        TOOL_STATUS[realm]="installed"
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
        local cnt
        cnt=$(systemctl list-units --full -all 2>/dev/null | grep -c 'brook-forward.*\.service' || echo 0)
        if [ "$cnt" -gt 0 ]; then
            TOOL_SERVICE_STATUS[brook]="active($cnt)"
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
    log_info "安装 Realm..."
    $SUDO mkdir -p "$REALM_DIR"

    local arch realm_arch
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64)   realm_arch="x86_64-unknown-linux-gnu" ;;
        aarch64|arm64)   realm_arch="aarch64-unknown-linux-gnu" ;;
        armv7l)          realm_arch="arm-unknown-linux-gnueabi" ;;
        *) log_error "不支持的架构: $arch"; return 1 ;;
    esac

    local version
    version=$(curl -s https://api.github.com/repos/zhboner/realm/releases/latest | grep -o '"tag_name": "v[^"]*' | sed 's/"tag_name": "v//' | head -1)
    version=${version:-"2.6.2"}

    log_info "下载 Realm v${version}..."
    if ! curl -L -o /tmp/realm.tar.gz "https://github.com/zhboner/realm/releases/download/v${version}/realm-${realm_arch}.tar.gz"; then
        log_error "Realm 下载失败"; return 1
    fi

    tar -xzf /tmp/realm.tar.gz -C /tmp
    $SUDO mv /tmp/realm "$REALM_DIR/"
    $SUDO chmod +x "$REALM_DIR/realm"
    $SUDO ln -sf "$REALM_DIR/realm" /usr/local/bin/realm 2>/dev/null || true
    rm -f /tmp/realm.tar.gz

    if ! id "realm" &>/dev/null; then
        $SUDO useradd --system --no-create-home --shell /bin/false realm 2>/dev/null || true
    fi

    $SUDO mkdir -p "$(dirname "$REALM_CONFIG")"
    if [ ! -f "$REALM_CONFIG" ]; then
        cat > /tmp/realm_cfg.toml << 'EOF'
[network]
no_tcp = false
use_udp = true
ipv6_only = false
EOF
        $SUDO mv /tmp/realm_cfg.toml "$REALM_CONFIG"
        $SUDO chown realm:realm "$REALM_CONFIG" 2>/dev/null || true
        $SUDO chmod 640 "$REALM_CONFIG"
    fi

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
NoNewPrivileges=true
LimitNOFILE=infinity
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
OOMScoreAdjust=-900

[Install]
WantedBy=multi-user.target
EOF
    $SUDO mv /tmp/realm.service /etc/systemd/system/realm.service
    $SUDO systemctl daemon-reload
    $SUDO systemctl enable realm >/dev/null 2>&1
    TOOL_STATUS[realm]="installed"
    log_success "Realm v${version} 安装成功"
}

install_gost() {
    log_info "安装 GOST..."
    (bash <(curl -fsSL https://github.com/go-gost/gost/raw/master/install.sh) --install) &
    show_loading $!

    if ! command -v gost &>/dev/null; then
        log_error "GOST 安装失败"; return 1
    fi

    if ! id "gost" &>/dev/null; then
        $SUDO useradd --system --no-create-home --shell /bin/false gost 2>/dev/null || true
    fi

    $SUDO mkdir -p "$(dirname "$GOST_CONFIG")"
    if [ ! -f "$GOST_CONFIG" ]; then
        echo '{"services":[]}' | $SUDO tee "$GOST_CONFIG" > /dev/null
        $SUDO chmod 640 "$GOST_CONFIG"
    fi

    cat > /tmp/gost.service << EOF
[Unit]
Description=GOST Proxy Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=gost
Group=gost
ExecStart=/usr/local/bin/gost -C $GOST_CONFIG
Restart=always
RestartSec=5
NoNewPrivileges=true
LimitNOFILE=infinity
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
OOMScoreAdjust=-900

[Install]
WantedBy=multi-user.target
EOF
    $SUDO mv /tmp/gost.service /etc/systemd/system/gost.service
    $SUDO systemctl daemon-reload
    $SUDO systemctl enable gost >/dev/null 2>&1
    TOOL_STATUS[gost]="installed"
    log_success "GOST 安装成功"
}

install_brook() {
    log_info "安装 Brook..."
    local arch os_name brook_arch
    arch=$(uname -m)
    os_name=$(uname -s | tr '[:upper:]' '[:lower:]')

    case "$arch" in
        x86_64|amd64)   brook_arch="amd64" ;;
        aarch64|arm64)   brook_arch="arm64" ;;
        i386|i686)       brook_arch="386" ;;
        *) log_error "不支持的架构: $arch"; return 1 ;;
    esac

    local version
    version=$(curl -s https://api.github.com/repos/txthinking/brook/releases/latest | grep -o '"tag_name": "v[^"]*' | sed 's/"tag_name": "v//' | head -1)
    version=${version:-"20250202"}

    log_info "下载 Brook v${version}..."
    if ! curl -L -o /tmp/brook "https://github.com/txthinking/brook/releases/download/v${version}/brook_${os_name}_${brook_arch}"; then
        log_error "Brook 下载失败"; return 1
    fi

    $SUDO mv /tmp/brook /usr/local/bin/brook
    $SUDO chmod +x /usr/local/bin/brook

    if ! id "brook" &>/dev/null; then
        $SUDO useradd --system --no-create-home --shell /bin/false brook 2>/dev/null || true
    fi

    $SUDO mkdir -p "$CONFIG_DIR/brook"
    [ ! -f "$BROOK_CONFIG" ] && $SUDO touch "$BROOK_CONFIG"

    TOOL_STATUS[brook]="installed"
    log_success "Brook v${version} 安装成功"
}

# ==================== TOOL UNINSTALL ====================

uninstall_realm() {
    log_info "卸载 Realm..."
    $SUDO systemctl stop realm 2>/dev/null || true
    $SUDO systemctl disable realm 2>/dev/null || true
    $SUDO rm -f /etc/systemd/system/realm.service
    $SUDO rm -rf "$REALM_DIR"
    $SUDO rm -rf "$CONFIG_DIR/realm"
    $SUDO rm -f /usr/local/bin/realm
    $SUDO systemctl daemon-reload
    TOOL_STATUS[realm]="not_installed"
    TOOL_SERVICE_STATUS[realm]="disabled"
    log_success "Realm 已卸载"
}

uninstall_gost() {
    log_info "卸载 GOST..."
    $SUDO systemctl stop gost 2>/dev/null || true
    $SUDO systemctl disable gost 2>/dev/null || true
    $SUDO rm -f /etc/systemd/system/gost.service
    $SUDO rm -f /usr/local/bin/gost
    $SUDO rm -rf "$CONFIG_DIR/gost"
    $SUDO systemctl daemon-reload
    TOOL_STATUS[gost]="not_installed"
    TOOL_SERVICE_STATUS[gost]="disabled"
    log_success "GOST 已卸载"
}

uninstall_brook() {
    log_info "卸载 Brook..."
    local svc
    for svc in $(systemctl list-units --full -all 2>/dev/null | grep 'brook-forward.*\.service' | awk '{print $1}'); do
        $SUDO systemctl stop "$svc" 2>/dev/null || true
        $SUDO systemctl disable "$svc" 2>/dev/null || true
        $SUDO rm -f "/etc/systemd/system/$svc"
    done
    $SUDO rm -f /usr/local/bin/brook
    $SUDO rm -rf "$CONFIG_DIR/brook"
    $SUDO systemctl daemon-reload
    TOOL_STATUS[brook]="not_installed"
    TOOL_SERVICE_STATUS[brook]="disabled"
    log_success "Brook 已卸载"
}

# ==================== FORWARD RULE MANAGEMENT ====================

add_rule_realm() {
    local listen_port=$1 target_ip=$2 target_port=$3 protocol=$4
    local listen_addr=${5:-"0.0.0.0"}
    local use_tcp="false" use_udp="false"

    case "$protocol" in
        tcp)  use_tcp="true" ;;
        udp)  use_udp="true" ;;
        both) use_tcp="true"; use_udp="true" ;;
    esac

    cat >> "$REALM_CONFIG" << EOF

[[endpoints]]
listen = "${listen_addr}:${listen_port}"
remote = "${target_ip}:${target_port}"
use_tcp = ${use_tcp}
use_udp = ${use_udp}
EOF

    $SUDO systemctl restart realm 2>/dev/null
}

add_rule_gost() {
    local listen_port=$1 target_ip=$2 target_port=$3 protocol=$4
    local svc_name="fwrd-${listen_port}-${protocol}"
    local addr="0.0.0.0:${listen_port}"
    local target="${target_ip}:${target_port}"

    if [ "$protocol" = "both" ]; then
        jq --arg tcp_name "${svc_name}-tcp" --arg udp_name "${svc_name}-udp" \
           --arg addr "$addr" --arg target "$target" \
           '.services += [
             {name:$tcp_name, addr:$addr, handler:{type:"tcp"}, listener:{type:"tcp"}, forwarder:{nodes:[{name:"target-0",addr:$target}]}},
             {name:$udp_name, addr:$addr, handler:{type:"udp"}, listener:{type:"udp"}, forwarder:{nodes:[{name:"target-0",addr:$target}]}}
           ]' "$GOST_CONFIG" > /tmp/gost_cfg.json
    else
        jq --arg name "$svc_name" --arg addr "$addr" --arg proto "$protocol" --arg target "$target" \
           '.services += [{name:$name, addr:$addr, handler:{type:$proto}, listener:{type:$proto}, forwarder:{nodes:[{name:"target-0",addr:$target}]}}]' \
           "$GOST_CONFIG" > /tmp/gost_cfg.json
    fi
    $SUDO mv /tmp/gost_cfg.json "$GOST_CONFIG"
    $SUDO systemctl restart gost 2>/dev/null
}

add_rule_brook() {
    local listen_port=$1 target_ip=$2 target_port=$3 protocol=$4
    local svc_name="brook-forward-${listen_port}-${protocol}"
    local listen_addr=":${listen_port}"
    local target="${target_ip}:${target_port}"

    local relay_cmd="/usr/local/bin/brook relay -f ${listen_addr} -t ${target}"
    case "$protocol" in
        tcp) relay_cmd+=" --udpTimeout 0" ;;
        udp) relay_cmd+=" --tcpTimeout 0" ;;
    esac

    cat > "/tmp/${svc_name}.service" << EOF
[Unit]
Description=Brook Forward ${listen_addr} -> ${target} (${protocol})
After=network.target

[Service]
Type=simple
User=brook
Group=brook
ExecStart=${relay_cmd}
Restart=always
RestartSec=5
NoNewPrivileges=true
LimitNOFILE=infinity
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
OOMScoreAdjust=-900

[Install]
WantedBy=multi-user.target
EOF
    $SUDO mv "/tmp/${svc_name}.service" "/etc/systemd/system/${svc_name}.service"
    $SUDO systemctl daemon-reload
    $SUDO systemctl enable "${svc_name}" >/dev/null 2>&1
    $SUDO systemctl start "${svc_name}"

    echo "${svc_name}|${listen_addr}|${target}|${protocol}" | $SUDO tee -a "$BROOK_CONFIG" > /dev/null
}

update_master_config() {
    local rule_id=$1 tool=$2 listen_port=$3 target_ip=$4 target_port=$5 protocol=$6
    local remark=${7:-""}

    local tmp
    tmp=$(mktemp)
    jq --arg id "$rule_id" --arg tool "$tool" \
       --arg lp "$listen_port" --arg tip "$target_ip" --arg tp "$target_port" \
       --arg proto "$protocol" --arg ts "$(date -Iseconds)" --arg remark "$remark" \
       '.rules += [{id:$id, tool:$tool, listen_port:($lp|tonumber), target_ip:$tip, target_port:($tp|tonumber), protocol:$proto, remark:$remark, created:$ts, enabled:true}]' \
       "$CONFIG_FILE" > "$tmp"
    $SUDO mv "$tmp" "$CONFIG_FILE"
}

add_forward_rule() {
    local listen_port=$1 target_ip=$2 target_port=$3 protocol=$4
    local tool=${5:-auto} remark=${6:-""}

    if [ "$tool" = "auto" ]; then
        tool=$(recommend_tool)
        [ "$tool" = "none" ] && { log_error "没有已安装的转发工具"; return 1; }
        log_info "自动选择: $tool"
    fi
    [ "${TOOL_STATUS[$tool]}" != "installed" ] && { log_error "$tool 未安装"; return 1; }

    local rule_id
    rule_id="rule_$(date +%s)_$(shuf -i 1000-9999 -n 1 2>/dev/null || echo $((RANDOM % 9000 + 1000)))"

    case "$tool" in
        realm) add_rule_realm "$listen_port" "$target_ip" "$target_port" "$protocol" ;;
        gost)  add_rule_gost  "$listen_port" "$target_ip" "$target_port" "$protocol" ;;
        brook) add_rule_brook "$listen_port" "$target_ip" "$target_port" "$protocol" ;;
        *) log_error "未知工具: $tool"; return 1 ;;
    esac

    if [ $? -eq 0 ]; then
        update_master_config "$rule_id" "$tool" "$listen_port" "$target_ip" "$target_port" "$protocol" "$remark"
        log_success "$tool 规则添加成功"
        return 0
    fi
    log_error "规则添加失败"
    return 1
}

recommend_tool() {
    for t in realm gost brook; do
        [ "${TOOL_STATUS[$t]}" = "installed" ] && { echo "$t"; return; }
    done
    echo "none"
}

list_all_rules() {
    printf "\n${BOLD}${BLUE}--- 当前转发规则 ---${PLAIN}\n"
    printf "${BOLD}%-4s %-6s %-6s %-22s %-6s %-6s %-10s %-s${PLAIN}\n" \
           "#" "工具" "端口" "目标" "端口" "协议" "状态" "备注"
    printf "${BLUE}%s${PLAIN}\n" "──────────────────────────────────────────────────────────────────────────────────"

    local count=0
    if [ -f "$CONFIG_FILE" ]; then
        while read -r rule; do
            ((count++))
            local tool listen_port target_ip target_port protocol remark status
            tool=$(echo "$rule" | jq -r '.tool')
            listen_port=$(echo "$rule" | jq -r '.listen_port')
            target_ip=$(echo "$rule" | jq -r '.target_ip')
            target_port=$(echo "$rule" | jq -r '.target_port')
            protocol=$(echo "$rule" | jq -r '.protocol')
            remark=$(echo "$rule" | jq -r '.remark // ""')

            status="${RED}未知${PLAIN}"
            case "$tool" in
                realm|gost)
                    if systemctl is-active --quiet "$tool" 2>/dev/null; then
                        status="${GREEN}运行中${PLAIN}"
                    else
                        status="${RED}已停止${PLAIN}"
                    fi ;;
                brook)
                    local sn="brook-forward-${listen_port}-${protocol}"
                    if systemctl is-active --quiet "$sn" 2>/dev/null; then
                        status="${GREEN}运行中${PLAIN}"
                    else
                        status="${RED}已停止${PLAIN}"
                    fi ;;
            esac

            printf "%-4s %-6s %-6s %-22s %-6s %-6s %b  %s\n" \
                   "$count" "$tool" "$listen_port" "$target_ip" "$target_port" "$protocol" "$status" "$remark"
        done < <(jq -c '.rules[]' "$CONFIG_FILE" 2>/dev/null)
    fi

    if [ "$count" -eq 0 ]; then
        log_warn "没有转发规则"
    else
        printf "\n${INFO_SYMBOL} 共 %d 条规则\n" "$count"
    fi
}

delete_forward_rule() {
    local idx=$1
    local rules_count
    rules_count=$(jq '.rules | length' "$CONFIG_FILE" 2>/dev/null || echo 0)

    if [ "$idx" -lt 1 ] || [ "$idx" -gt "$rules_count" ]; then
        log_error "无效的规则编号"; return 1
    fi

    local rule tool listen_port protocol
    rule=$(jq ".rules[$((idx-1))]" "$CONFIG_FILE")
    tool=$(echo "$rule" | jq -r '.tool')
    listen_port=$(echo "$rule" | jq -r '.listen_port')
    protocol=$(echo "$rule" | jq -r '.protocol')

    log_info "删除规则: $tool 端口 $listen_port..."

    case "$tool" in
        realm)
            $SUDO sed -i "/listen = \"0.0.0.0:${listen_port}\"/,/^$/d" "$REALM_CONFIG"
            $SUDO systemctl restart realm 2>/dev/null || true
            ;;
        gost)
            local sn="fwrd-${listen_port}-${protocol}"
            jq --arg name "$sn" \
               '.services = [.services[] | select(.name != $name and .name != ($name+"-tcp") and .name != ($name+"-udp"))]' \
               "$GOST_CONFIG" > /tmp/gost_cfg.json
            $SUDO mv /tmp/gost_cfg.json "$GOST_CONFIG"
            $SUDO systemctl restart gost 2>/dev/null || true
            ;;
        brook)
            local sn="brook-forward-${listen_port}-${protocol}"
            $SUDO systemctl stop "$sn" 2>/dev/null || true
            $SUDO systemctl disable "$sn" 2>/dev/null || true
            $SUDO rm -f "/etc/systemd/system/${sn}.service"
            $SUDO systemctl daemon-reload
            $SUDO sed -i "/^${sn}|/d" "$BROOK_CONFIG" 2>/dev/null || true
            ;;
    esac

    local tmp
    tmp=$(mktemp)
    jq "del(.rules[$((idx-1))])" "$CONFIG_FILE" > "$tmp"
    $SUDO mv "$tmp" "$CONFIG_FILE"
    log_success "规则删除成功"
}

modify_forward_rule() {
    local idx=$1
    local rules_count
    rules_count=$(jq '.rules | length' "$CONFIG_FILE" 2>/dev/null || echo 0)

    if [ "$idx" -lt 1 ] || [ "$idx" -gt "$rules_count" ]; then
        log_error "无效的规则编号"; return 1
    fi

    local rule old_tool old_lp old_tip old_tp old_proto old_remark
    rule=$(jq ".rules[$((idx-1))]" "$CONFIG_FILE")
    old_tool=$(echo "$rule" | jq -r '.tool')
    old_lp=$(echo "$rule" | jq -r '.listen_port')
    old_tip=$(echo "$rule" | jq -r '.target_ip')
    old_tp=$(echo "$rule" | jq -r '.target_port')
    old_proto=$(echo "$rule" | jq -r '.protocol')
    old_remark=$(echo "$rule" | jq -r '.remark // ""')

    printf "\n${BOLD}修改规则 #%s${PLAIN}\n" "$idx"
    printf "  工具: %s | 监听: %s | 目标: %s:%s | 协议: %s\n" "$old_tool" "$old_lp" "$old_tip" "$old_tp" "$old_proto"
    printf "  ${YELLOW}回车保留原值${PLAIN}\n\n"

    local new_tip new_tp new_remark
    printf "新目标IP/域名 [%s]: " "$old_tip"; read -r new_tip
    new_tip=${new_tip:-$old_tip}
    if ! validate_ip "$new_tip"; then log_error "无效地址"; return 1; fi

    printf "新目标端口 [%s]: " "$old_tp"; read -r new_tp
    new_tp=${new_tp:-$old_tp}
    if ! validate_port "$new_tp"; then log_error "无效端口"; return 1; fi

    printf "新备注 [%s]: " "$old_remark"; read -r new_remark
    new_remark=${new_remark:-$old_remark}

    if [ "$new_tip" = "$old_tip" ] && [ "$new_tp" = "$old_tp" ] && [ "$new_remark" = "$old_remark" ]; then
        log_warn "未更改"; return 0
    fi

    log_info "应用更改..."
    delete_forward_rule "$idx"
    add_forward_rule "$old_lp" "$new_tip" "$new_tp" "$old_proto" "$old_tool" "$new_remark"
}

# ==================== SERVICE OPERATIONS ====================

view_service_logs() {
    clear
    printf "\n${BOLD}${BLUE}--- 服务日志 ---${PLAIN}\n"

    for tool in realm gost; do
        if [ "${TOOL_STATUS[$tool]}" = "installed" ]; then
            printf "\n${BOLD}=== %s ===\n${PLAIN}" "$tool"
            journalctl -u "$tool" --no-pager -n 15 2>/dev/null || log_warn "无法获取 $tool 日志"
        fi
    done

    if [ "${TOOL_STATUS[brook]}" = "installed" ]; then
        local svc
        for svc in $(systemctl list-units --full -all 2>/dev/null | grep 'brook-forward.*\.service' | awk '{print $1}'); do
            printf "\n${BOLD}=== %s ===\n${PLAIN}" "$svc"
            journalctl -u "$svc" --no-pager -n 10 2>/dev/null || true
        done
    fi
    press_enter
}

test_forward() {
    list_all_rules
    local rules_count
    rules_count=$(jq '.rules | length' "$CONFIG_FILE" 2>/dev/null || echo 0)
    [ "$rules_count" -eq 0 ] && { press_enter; return; }

    printf "\n请输入要测试的规则编号 (0取消): "
    read -r num
    [[ ! "$num" =~ ^[0-9]+$ ]] || [ "$num" -eq 0 ] && return

    local rule lp
    rule=$(jq ".rules[$((num-1))]" "$CONFIG_FILE" 2>/dev/null)
    [ -z "$rule" ] || [ "$rule" = "null" ] && { log_error "无效编号"; press_enter; return; }

    lp=$(echo "$rule" | jq -r '.listen_port')
    log_info "测试端口 $lp 连通性..."

    if timeout 3 bash -c "true &>/dev/null </dev/tcp/127.0.0.1/${lp}" 2>/dev/null; then
        log_success "TCP 端口 $lp 可达"
    else
        log_warn "TCP 端口 $lp 不可达或目标无响应"
    fi
    press_enter
}

# ==================== INTERACTIVE MENUS ====================

interactive_add_rule() {
    clear
    printf "\n${BOLD}${BLUE}========== 添加转发规则 ==========${PLAIN}\n\n"

    # --- 选择工具 ---
    printf "${BLUE}选择转发工具:${PLAIN}\n"
    printf "  ${GREEN}1.${PLAIN} 自动选择 (推荐)\n"
    printf "  ${GREEN}2.${PLAIN} Realm\n"
    printf "  ${GREEN}3.${PLAIN} GOST\n"
    printf "  ${GREEN}4.${PLAIN} Brook\n\n"
    read -rp "请选择 [1-4, 默认1]: " tc
    local tool="auto"
    case "${tc:-1}" in
        2) tool="realm" ;; 3) tool="gost" ;; 4) tool="brook" ;; *) tool="auto" ;;
    esac

    # --- 选择协议 ---
    printf "\n${BLUE}选择转发协议:${PLAIN}\n"
    printf "  ${GREEN}1.${PLAIN} 仅TCP\n"
    printf "  ${GREEN}2.${PLAIN} 仅UDP\n"
    printf "  ${GREEN}3.${PLAIN} TCP+UDP (默认)\n"
    printf "  ${GREEN}4.${PLAIN} TCP/UDP 分别转发到不同目标\n\n"
    read -rp "请选择 [1-4, 默认3]: " pc
    local protocol="both"
    case "${pc:-3}" in
        1) protocol="tcp" ;; 2) protocol="udp" ;; 4) protocol="split" ;; *) protocol="both" ;;
    esac

    # --- 监听端口 ---
    local listen_port
    printf "\n${BLUE}本地监听端口 (留空自动选择): ${PLAIN}"
    read -r listen_port
    if [ -z "$listen_port" ]; then
        listen_port=$(find_available_port) || { log_error "无法找到可用端口"; return 1; }
        log_success "自动选择端口: $listen_port"
    else
        if ! validate_port "$listen_port"; then log_error "无效端口"; return 1; fi
        if is_port_in_use "$listen_port"; then
            log_warn "端口 $listen_port 可能被占用"
            read -rp "继续? [y/N]: " c
            [[ ! "$c" =~ ^[Yy]$ ]] && return 1
        fi
    fi

    # --- 备注 ---
    printf "${BLUE}备注 (可选): ${PLAIN}"
    read -r remark

    # --- Split 模式 ---
    if [ "$protocol" = "split" ]; then
        printf "\n${BOLD}${YELLOW}--- TCP 转发目标 ---${PLAIN}\n"
        local tcp_ip tcp_port
        while true; do
            printf "${BLUE}TCP 目标IP/域名: ${PLAIN}"; read -r tcp_ip
            [ -n "$tcp_ip" ] && validate_ip "$tcp_ip" && break
            log_error "无效地址"
        done
        while true; do
            printf "${BLUE}TCP 目标端口: ${PLAIN}"; read -r tcp_port
            validate_port "$tcp_port" && break
            log_error "无效端口"
        done

        printf "\n${BOLD}${YELLOW}--- UDP 转发目标 ---${PLAIN}\n"
        local udp_ip udp_port
        while true; do
            printf "${BLUE}UDP 目标IP/域名: ${PLAIN}"; read -r udp_ip
            [ -n "$udp_ip" ] && validate_ip "$udp_ip" && break
            log_error "无效地址"
        done
        while true; do
            printf "${BLUE}UDP 目标端口: ${PLAIN}"; read -r udp_port
            validate_port "$udp_port" && break
            log_error "无效端口"
        done

        printf "\n${BOLD}${YELLOW}=== 规则摘要 ===${PLAIN}\n"
        printf "  工具: %s | 监听: :%s\n" "$tool" "$listen_port"
        printf "  TCP -> %s:%s\n" "$tcp_ip" "$tcp_port"
        printf "  UDP -> %s:%s\n" "$udp_ip" "$udp_port"
        read -rp "确认? [Y/n]: " confirm
        [[ "$confirm" =~ ^[Nn]$ ]] && return 0

        add_forward_rule "$listen_port" "$tcp_ip" "$tcp_port" "tcp" "$tool" "${remark:+${remark} }TCP"
        add_forward_rule "$listen_port" "$udp_ip" "$udp_port" "udp" "$tool" "${remark:+${remark} }UDP"
        press_enter
        return
    fi

    # --- 普通模式 ---
    local target_ip target_port
    while true; do
        printf "${BLUE}目标IP/域名: ${PLAIN}"; read -r target_ip
        [ -n "$target_ip" ] && validate_ip "$target_ip" && break
        log_error "无效地址"
    done
    while true; do
        printf "${BLUE}目标端口: ${PLAIN}"; read -r target_port
        validate_port "$target_port" && break
        log_error "无效端口"
    done

    printf "\n${BOLD}${YELLOW}=== 规则摘要 ===${PLAIN}\n"
    printf "  工具: %s | 监听: :%s | 目标: %s:%s | 协议: %s\n" "$tool" "$listen_port" "$target_ip" "$target_port" "$protocol"
    read -rp "确认? [Y/n]: " confirm
    [[ "$confirm" =~ ^[Nn]$ ]] && return 0

    add_forward_rule "$listen_port" "$target_ip" "$target_port" "$protocol" "$tool" "$remark"
    press_enter
}

interactive_modify_rule() {
    clear
    list_all_rules
    local rules_count
    rules_count=$(jq '.rules | length' "$CONFIG_FILE" 2>/dev/null || echo 0)
    [ "$rules_count" -eq 0 ] && { press_enter; return; }

    printf "\n请输入要修改的规则编号 (0取消): "
    read -r num
    [[ ! "$num" =~ ^[0-9]+$ ]] || [ "$num" -eq 0 ] && return
    modify_forward_rule "$num"
    press_enter
}

interactive_delete_rule() {
    clear
    list_all_rules
    local rules_count
    rules_count=$(jq '.rules | length' "$CONFIG_FILE" 2>/dev/null || echo 0)
    [ "$rules_count" -eq 0 ] && { press_enter; return; }

    printf "\n请输入要删除的规则编号 (0取消): "
    read -r num
    [[ ! "$num" =~ ^[0-9]+$ ]] || [ "$num" -eq 0 ] && return

    printf "${BOLD}${YELLOW}确认删除规则 #%s?${PLAIN} 此操作无法撤销。\n" "$num"
    read -rp "继续? [y/N]: " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] && delete_forward_rule "$num"
    press_enter
}

install_tools_menu() {
    while true; do
        clear
        printf "\n${BOLD}${BLUE}========== 工具管理 ==========${PLAIN}\n\n"
        printf "${BLUE}安装:${PLAIN}\n"
        for i_tool in realm gost brook; do
            local label=""
            case "$i_tool" in realm) label="Realm - 高性能Rust代理";; gost) label="GOST - 功能丰富的隧道";; brook) label="Brook - 简洁高效";; esac
            local idx; case "$i_tool" in realm) idx=1;; gost) idx=2;; brook) idx=3;; esac
            printf "  ${GREEN}%s.${PLAIN} %s " "$idx" "$label"
            [ "${TOOL_STATUS[$i_tool]}" = "installed" ] && printf "${GREEN}[已安装]${PLAIN}\n" || printf "${RED}[未安装]${PLAIN}\n"
        done
        printf "\n${BLUE}卸载:${PLAIN}\n"
        printf "  ${YELLOW}4.${PLAIN} 卸载 Realm\n"
        printf "  ${YELLOW}5.${PLAIN} 卸载 GOST\n"
        printf "  ${YELLOW}6.${PLAIN} 卸载 Brook\n"
        printf "\n  ${GREEN}0.${PLAIN} 返回\n\n"

        read -rp "选择: " choice
        case "$choice" in
            1) if [ "${TOOL_STATUS[realm]}" = "installed" ]; then log_info "已安装"; else install_realm; fi; detect_realm; press_enter ;;
            2) if [ "${TOOL_STATUS[gost]}" = "installed" ]; then log_info "已安装"; else install_gost; fi; detect_gost; press_enter ;;
            3) if [ "${TOOL_STATUS[brook]}" = "installed" ]; then log_info "已安装"; else install_brook; fi; detect_brook; press_enter ;;
            4)
                if [ "${TOOL_STATUS[realm]}" = "installed" ]; then
                    read -rp "确认卸载 Realm? [y/N]: " c; [[ "$c" =~ ^[Yy]$ ]] && uninstall_realm
                else log_warn "Realm 未安装"; fi
                press_enter ;;
            5)
                if [ "${TOOL_STATUS[gost]}" = "installed" ]; then
                    read -rp "确认卸载 GOST? [y/N]: " c; [[ "$c" =~ ^[Yy]$ ]] && uninstall_gost
                else log_warn "GOST 未安装"; fi
                press_enter ;;
            6)
                if [ "${TOOL_STATUS[brook]}" = "installed" ]; then
                    read -rp "确认卸载 Brook? [y/N]: " c; [[ "$c" =~ ^[Yy]$ ]] && uninstall_brook
                else log_warn "Brook 未安装"; fi
                press_enter ;;
            0) return ;;
            *) log_error "无效选择"; sleep 1 ;;
        esac
    done
}

service_control_menu() {
    while true; do
        clear
        printf "\n${BOLD}${BLUE}========== 服务管理 ==========${PLAIN}\n\n"

        printf "${BOLD}状态:${PLAIN}\n"
        for tool in realm gost brook; do
            [ "${TOOL_STATUS[$tool]}" != "installed" ] && continue
            printf "  %s: " "$tool"
            case "${TOOL_SERVICE_STATUS[$tool]}" in
                active*) printf "${GREEN}%s${PLAIN}\n" "${TOOL_SERVICE_STATUS[$tool]}" ;;
                inactive) printf "${YELLOW}%s${PLAIN}\n" "${TOOL_SERVICE_STATUS[$tool]}" ;;
                *) printf "${RED}%s${PLAIN}\n" "${TOOL_SERVICE_STATUS[$tool]}" ;;
            esac
        done

        printf "\n${BOLD}操作:${PLAIN}\n"
        printf "  ${GREEN}1.${PLAIN} 启动所有  ${GREEN}2.${PLAIN} 停止所有  ${GREEN}3.${PLAIN} 重启所有\n"
        printf "  ${GREEN}4.${PLAIN} 查看详细状态  ${GREEN}5.${PLAIN} 查看日志  ${GREEN}6.${PLAIN} 测试转发\n"
        printf "  ${GREEN}0.${PLAIN} 返回\n\n"

        read -rp "选择: " choice
        case "$choice" in
            1)
                for tool in realm gost; do
                    [ "${TOOL_STATUS[$tool]}" = "installed" ] && $SUDO systemctl start "$tool" 2>/dev/null && log_success "$tool 已启动"
                done
                if [ "${TOOL_STATUS[brook]}" = "installed" ]; then
                    local svc
                    for svc in $(systemctl list-units --full -all 2>/dev/null | grep 'brook-forward.*\.service' | awk '{print $1}'); do
                        $SUDO systemctl start "$svc" 2>/dev/null
                    done
                    log_success "Brook 服务已启动"
                fi
                detect_all_tools; press_enter ;;
            2)
                for tool in realm gost; do
                    $SUDO systemctl stop "$tool" 2>/dev/null && log_success "$tool 已停止"
                done
                if [ "${TOOL_STATUS[brook]}" = "installed" ]; then
                    local svc
                    for svc in $(systemctl list-units --full -all 2>/dev/null | grep 'brook-forward.*\.service' | awk '{print $1}'); do
                        $SUDO systemctl stop "$svc" 2>/dev/null
                    done
                    log_success "Brook 服务已停止"
                fi
                detect_all_tools; press_enter ;;
            3)
                for tool in realm gost; do
                    [ "${TOOL_STATUS[$tool]}" = "installed" ] && $SUDO systemctl restart "$tool" 2>/dev/null && log_success "$tool 已重启"
                done
                if [ "${TOOL_STATUS[brook]}" = "installed" ]; then
                    local svc
                    for svc in $(systemctl list-units --full -all 2>/dev/null | grep 'brook-forward.*\.service' | awk '{print $1}'); do
                        $SUDO systemctl restart "$svc" 2>/dev/null
                    done
                    log_success "Brook 服务已重启"
                fi
                detect_all_tools; press_enter ;;
            4)
                for tool in realm gost; do
                    [ "${TOOL_STATUS[$tool]}" = "installed" ] || continue
                    printf "\n${BOLD}=== %s ===${PLAIN}\n" "$tool"
                    systemctl status "$tool" --no-pager -l 2>/dev/null || true
                done
                press_enter ;;
            5) view_service_logs ;;
            6) test_forward ;;
            0) return ;;
            *) log_error "无效选择"; sleep 1 ;;
        esac
    done
}

backup_configs() {
    log_info "创建配置备份..."
    local ts backup_file
    ts=$(date +%Y%m%d_%H%M%S)
    backup_file="$BACKUP_DIR/backup_${ts}.tar.gz"
    $SUDO mkdir -p "$BACKUP_DIR"

    $SUDO tar -czf "$backup_file" -C / \
        etc/fwrd/config.json etc/fwrd/realm etc/fwrd/gost etc/fwrd/brook 2>/dev/null || true

    find "$BACKUP_DIR" -maxdepth 1 -name 'backup_*.tar.gz' -printf '%T@ %p\n' 2>/dev/null | sort -rn | awk 'NR>10{print $2}' | xargs $SUDO rm -f 2>/dev/null || true
    log_success "备份: $backup_file"
    press_enter
}

# ==================== MAIN MENU ====================

show_main_menu() {
    while true; do
        clear
        local ip_info
        ip_info=$(get_ip_info)

        printf "\n${BOLD}${BLUE}========== 转发管理器 v%s ==========${PLAIN}\n" "$VERSION"
        printf "${INFO_SYMBOL} 本机IP: ${GREEN}%s${PLAIN}\n" "$ip_info"

        printf "\n${BOLD}工具:${PLAIN} "
        for tool in realm gost brook; do
            if [ "${TOOL_STATUS[$tool]}" = "installed" ]; then
                case "${TOOL_SERVICE_STATUS[$tool]}" in
                    active*) printf "${GREEN}%s✓${PLAIN} " "$tool" ;;
                    *)       printf "${YELLOW}%s○${PLAIN} " "$tool" ;;
                esac
            else
                printf "${RED}%s✗${PLAIN} " "$tool"
            fi
        done

        local rules_count
        rules_count=$(jq '.rules | length' "$CONFIG_FILE" 2>/dev/null || echo 0)
        printf "  ${BOLD}规则:${PLAIN} %d\n" "$rules_count"

        printf "\n${BOLD}${BLUE}==== 功能菜单 ====${PLAIN}\n"
        printf "  ${GREEN}1.${PLAIN} 安装/卸载工具\n"
        printf "  ${GREEN}2.${PLAIN} 添加转发规则\n"
        printf "  ${GREEN}3.${PLAIN} 查看所有规则\n"
        printf "  ${GREEN}4.${PLAIN} 修改规则\n"
        printf "  ${GREEN}5.${PLAIN} 删除规则\n"
        printf "  ${GREEN}6.${PLAIN} 服务管理\n"
        printf "  ${GREEN}7.${PLAIN} 备份配置\n"
        printf "  ${GREEN}8.${PLAIN} 系统优化\n"
        printf "  ${GREEN}0.${PLAIN} 退出\n"
        printf "${BOLD}${BLUE}====================================${PLAIN}\n\n"

        read -rp "请选择: " choice
        case "$choice" in
            1) install_tools_menu ;;
            2) interactive_add_rule ;;
            3) list_all_rules; press_enter ;;
            4) interactive_modify_rule ;;
            5) interactive_delete_rule ;;
            6) service_control_menu ;;
            7) backup_configs ;;
            8) optimize_system; press_enter ;;
            0) printf "\n${SUCCESS_SYMBOL} 再见！${PLAIN}\n"; exit 0 ;;
            *) log_error "无效选择"; sleep 1 ;;
        esac
    done
}

# ==================== MAIN ====================

main() {
    install_dependencies
    setup_config_dirs
    detect_all_tools
    show_main_menu
}

main "$@"
