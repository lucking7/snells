#!/bin/bash

# 统一入口：fwrd.sh
# 目的：为多种转发引擎（brook/gost/realm/nftables）提供统一的 CLI 契约
# 三个统一：
# 1) 统一动词/子命令：add | list | delete | restart | status | logs
# 2) 统一资源模型：--engine --proto --listen --target [--target-udp] --ipver --name [--range]
# 3) 统一输出接口：--output text|json，统一退出码（0 成功；非 0 失败）

set -euo pipefail

# 颜色与符号（与各脚本统一）
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
PLAIN='\033[0m'

SUCCESS_SYMBOL="${BOLD}${GREEN}[+]${PLAIN}"
ERROR_SYMBOL="${BOLD}${RED}[x]${PLAIN}"
INFO_SYMBOL="${BOLD}${BLUE}[i]${PLAIN}"
WARN_SYMBOL="${BOLD}${YELLOW}[!]${PLAIN}"

# sudo 检查
if [ "${EUID:-$(id -u)}" -eq 0 ]; then
  SUDO=""
else
  SUDO="sudo"
fi

# 默认路径（与各引擎脚本保持一致）
BROOK_SERVICE_DIR="/etc/systemd/system"
BROOK_CONFIG_DIR="/etc/brook"
BROOK_CONFIG_FILE="${BROOK_CONFIG_DIR}/forwards.conf"

GOST_CONFIG_DIR="/etc/gost"
GOST_CONFIG_FILE="${GOST_CONFIG_DIR}/config.json"

REALM_DIR="/root/realm"
REALM_CONFIG="/root/.realm/config.toml"

# nftables 相关
NFTABLES_CONF="/etc/nftables.conf"

usage() {
  cat <<EOF
用法: fwrd.sh <command> [选项]

命令:
  add       添加转发规则
  list      列出转发规则
  delete    删除转发规则
  restart   重启引擎服务（适用: gost/realm）
  status    查看引擎服务状态（适用: gost/realm）
  logs      查看引擎服务日志（适用: gost/realm/brook）

核心选项（统一资源模型）:
  --engine <brook|gost|realm|nftables>
  --proto <tcp|udp|both>
  --listen <addr:port>        例: :8080 / 0.0.0.0:8080 / [::]:8080
  --target <host:port>        例: 1.2.3.4:80 / example.com:443 / [2001:db8::1]:80
  --target-udp <host:port>    分离转发的 UDP 目标（仅 both/split 时可用）
  --ipver <4|6|46>            引擎支持时用于监听与目标栈选择
  --name <rule-name>          规则名/备注（用于匹配删除/显示）
  --range <start-end>         端口范围（可选，gost/nftables 支持更好）
  --output <text|json>

示例:
  fwrd.sh add --engine brook --proto tcp --listen :8080 --target 1.2.3.4:80 --name web8080
  fwrd.sh add --engine gost --proto both --listen :10053 --target 1.1.1.1:53 --name dns53
  fwrd.sh list --engine gost --output json
  fwrd.sh delete --engine brook --name brook-forward-8080-tcp
EOF
}

json_escape() { echo -n "$1" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))' 2>/dev/null || echo -n "$1"; }

is_ipv6_literal() { [[ "$1" == *":"* ]] && [[ "$1" != \[*\]* ]]; }
wrap_ipv6() { if is_ipv6_literal "$1"; then echo "[$1]"; else echo "$1"; fi }

# ----------- 运行时依赖与自动安装（按引擎） -----------
pm_detect() {
  if command -v apt-get >/dev/null 2>&1; then echo apt-get; return; fi
  if command -v yum >/dev/null 2>&1; then echo yum; return; fi
  if command -v dnf >/dev/null 2>&1; then echo dnf; return; fi
  echo ""
}

install_pkgs() {
  local pm; pm=$(pm_detect)
  [ -z "$pm" ] && { echo -e "${ERROR_SYMBOL} 未找到受支持的包管理器(apt/yum/dnf)"; return 1; }
  case "$pm" in
    apt-get)
      $SUDO apt-get update -y >/dev/null 2>&1 || true
      $SUDO apt-get install -y "$@" >/dev/null 2>&1 ;;
    yum) $SUDO yum install -y "$@" >/dev/null 2>&1 ;;
    dnf) $SUDO dnf install -y "$@" >/dev/null 2>&1 ;;
  esac
}

ensure_user() {
  local u="$1"
  id "$u" >/dev/null 2>&1 || $SUDO useradd --system --no-create-home --shell /bin/false "$u" >/dev/null 2>&1 || true
}

ensure_jq() {
  command -v jq >/dev/null 2>&1 || install_pkgs jq
}

install_brook_binary() {
  local arch os brook_arch brook_os ver url
  arch=$(uname -m)
  case "$arch" in
    x86_64|amd64) brook_arch="amd64";;
    aarch64|arm64) brook_arch="arm64";;
    i386|i686) brook_arch="386";;
    *) echo -e "${ERROR_SYMBOL} 不支持的架构: $arch"; return 1;;
  esac
  os=$(uname -s | tr '[:upper:]' '[:lower:]')
  case "$os" in
    linux) brook_os="linux";;
    darwin) brook_os="darwin";;
    *) echo -e "${ERROR_SYMBOL} 不支持的操作系统: $os"; return 1;;
  esac
  ver=$(curl -s --connect-timeout 8 https://api.github.com/repos/txthinking/brook/releases/latest | grep -o '"tag_name": "v[^"]*' | sed 's/"tag_name": "v//' | head -1 || true)
  [ -z "$ver" ] && ver="20250202"
  url="https://github.com/txthinking/brook/releases/download/v${ver}/brook_${brook_os}_${brook_arch}"
  tmpf=$(mktemp)
  if curl -L --connect-timeout 30 --max-time 300 -o "$tmpf" "$url" && [ -s "$tmpf" ]; then
    $SUDO chmod +x "$tmpf"
    $SUDO mv "$tmpf" /usr/local/bin/brook
    return 0
  fi
  rm -f "$tmpf" 2>/dev/null || true
  return 1
}

ensure_brook_installed() {
  if ! command -v brook >/dev/null 2>&1 || ! brook --help >/dev/null 2>&1; then
    echo -e "${INFO_SYMBOL} 正在安装 brook..."
    install_pkgs curl >/dev/null 2>&1 || true
    install_brook_binary || { echo -e "${ERROR_SYMBOL} 安装 brook 失败"; return 1; }
  fi
  ensure_user brook
}

install_gost_binary() {
  install_pkgs curl >/dev/null 2>&1 || true
  bash -c "bash <(curl -fsSL https://github.com/go-gost/gost/raw/master/install.sh) --install" >/dev/null 2>&1 || return 1
}

ensure_gost_service() {
  [ -d "$GOST_CONFIG_DIR" ] || $SUDO mkdir -p "$GOST_CONFIG_DIR"
  [ -f "$GOST_CONFIG_FILE" ] || echo '{"services":[]}' | $SUDO tee "$GOST_CONFIG_FILE" >/dev/null
  ensure_user gost
  local svc=/etc/systemd/system/gost.service
  if [ ! -f "$svc" ]; then
    cat <<EOF | $SUDO tee "$svc" >/dev/null
[Unit]
Description=GOST Proxy Service
After=network.target
Wants=network.target

[Service]
ExecStart=/usr/local/bin/gost -C "$GOST_CONFIG_FILE"
Restart=always
RestartSec=5
User=gost
Group=gost
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
LimitNOFILE=infinity
CapabilityBoundingSet=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
    $SUDO systemctl daemon-reload
  fi
  $SUDO systemctl enable gost >/dev/null 2>&1 || true
}

ensure_gost_installed() {
  ensure_jq
  if ! command -v gost >/dev/null 2>&1; then
    echo -e "${INFO_SYMBOL} 正在安装 gost..."
    install_gost_binary || { echo -e "${ERROR_SYMBOL} 安装 gost 失败"; return 1; }
  fi
  ensure_gost_service
}

install_realm_binary() {
  install_pkgs curl wget tar >/dev/null 2>&1 || true
  local api=$(curl -s https://api.github.com/repos/zhboner/realm/releases/latest || true)
  local ver
  ver=$(echo "$api" | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/' | head -1)
  [ -z "$ver" ] && ver="v2.6.2"
  local arch=$(uname -m)
  local os=$(uname -s | tr '[:upper:]' '[:lower:]')
  local url=""
  case "${arch}-${os}" in
    x86_64-linux) url="https://github.com/zhboner/realm/releases/download/${ver}/realm-x86_64-unknown-linux-gnu.tar.gz";;
    aarch64-linux) url="https://github.com/zhboner/realm/releases/download/${ver}/realm-aarch64-unknown-linux-gnu.tar.gz";;
    armv7l-linux|arm-linux) url="https://github.com/zhboner/realm/releases/download/${ver}/realm-arm-unknown-linux-gnueabi.tar.gz";;
    *) url="https://github.com/zhboner/realm/releases/download/${ver}/realm-x86_64-unknown-linux-gnu.tar.gz";;
  esac
  $SUDO mkdir -p "$REALM_DIR"
  ( cd "$REALM_DIR" && wget -qO realm.tar.gz "$url" && tar -xzf realm.tar.gz && $SUDO chmod +x realm && rm -f realm.tar.gz ) || return 1
}

ensure_realm_service() {
  $SUDO mkdir -p "$(dirname "$REALM_CONFIG")" >/dev/null 2>&1 || true
  [ -f "$REALM_CONFIG" ] || cat <<EOF | $SUDO tee "$REALM_CONFIG" >/dev/null
[network]
no_tcp = false
use_udp = true
ipv6_only = false
EOF
  ensure_user realm
  local svc=/etc/systemd/system/realm.service
  if [ ! -f "$svc" ]; then
    cat <<EOF | $SUDO tee "$svc" >/dev/null
[Unit]
Description=Realm Service
After=network-online.target
Wants=network-online.target systemd-networkd-wait-online.service

[Service]
Type=simple
User=realm
Group=realm
WorkingDirectory=${REALM_DIR}
ExecStart=${REALM_DIR}/realm -c ${REALM_CONFIG}
Restart=on-failure
RestartSec=5s
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
LimitNOFILE=infinity
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
    $SUDO systemctl daemon-reload
  fi
  $SUDO systemctl enable realm >/dev/null 2>&1 || true
}

ensure_realm_installed() {
  if [ ! -x "${REALM_DIR}/realm" ]; then
    echo -e "${INFO_SYMBOL} 正在安装 realm..."
    install_realm_binary || { echo -e "${ERROR_SYMBOL} 安装 realm 失败"; return 1; }
  fi
  ensure_realm_service
}

ensure_nftables_ready() {
  if ! command -v nft >/dev/null 2>&1; then
    echo -e "${INFO_SYMBOL} 正在安装 nftables..."
    install_pkgs nftables >/dev/null 2>&1 || true
  fi
  $SUDO systemctl enable nftables >/dev/null 2>&1 || true
  $SUDO systemctl start nftables >/dev/null 2>&1 || true
}

ensure_engine_ready() {
  case "$1" in
    brook) ensure_brook_installed ;;
    gost) ensure_gost_installed ;;
    realm) ensure_realm_installed ;;
    nftables) ensure_nftables_ready ;;
  esac
}

# 解析参数
CMD="${1:-}"
if [ $# -gt 0 ]; then shift || true; fi

ENGINE=""; PROTO=""; LISTEN=""; TARGET=""; TARGET_UDP=""; IPVER=""; NAME=""; RANGE=""; OUTPUT="text"
while [ $# -gt 0 ]; do
  case "$1" in
    --engine) ENGINE="$2"; shift 2 ;;
    --proto) PROTO="$2"; shift 2 ;;
    --listen) LISTEN="$2"; shift 2 ;;
    --target) TARGET="$2"; shift 2 ;;
    --target-udp) TARGET_UDP="$2"; shift 2 ;;
    --ipver) IPVER="$2"; shift 2 ;;
    --name) NAME="$2"; shift 2 ;;
    --range) RANGE="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo -e "${ERROR_SYMBOL} 未知参数: $1"; usage; exit 2 ;;
  esac
done

ensure_dirs() {
  [ -d "$BROOK_CONFIG_DIR" ] || $SUDO mkdir -p "$BROOK_CONFIG_DIR"
  [ -f "$BROOK_CONFIG_FILE" ] || $SUDO touch "$BROOK_CONFIG_FILE"
  [ -d "$GOST_CONFIG_DIR" ] || $SUDO mkdir -p "$GOST_CONFIG_DIR"
  [ -f "$GOST_CONFIG_FILE" ] || echo '{"services":[]}' | $SUDO tee "$GOST_CONFIG_FILE" >/dev/null
}

# 引擎适配：brook（系统级 systemd + forwards.conf）
engine_brook_add() {
  local proto="$1" listen="$2" target="$3" name="$4"
  local service_name
  local normalized_listen="$listen"
  # brook relay 支持 -f <listen> -t <remote>
  service_name="brook-forward-$(echo "$listen" | sed 's/[^0-9]//g')-${proto}"
  [ -n "$name" ] && service_name="$name"

  # 生成 service 文件
  ensure_brook_installed || { echo -e "${ERROR_SYMBOL} brook 未就绪"; exit 1; }
  local brook_exec
  if command -v brook &>/dev/null; then brook_exec=$(command -v brook); else brook_exec="/usr/local/bin/brook"; fi

  local unit="${BROOK_SERVICE_DIR}/${service_name}.service"
  local cmd="${brook_exec} relay -f ${normalized_listen} -t ${target}"
  cat <<EOF | $SUDO tee "$unit" >/dev/null
[Unit]
Description=Brook Forward ${listen} -> ${target} (${proto})
After=network.target

[Service]
Type=simple
ExecStart=$cmd
Restart=always
RestartSec=5
User=brook
Group=brook
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
LimitNOFILE=infinity
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
  $SUDO systemctl daemon-reload
  $SUDO systemctl enable "$service_name" >/dev/null 2>&1 || true
  $SUDO systemctl restart "$service_name"
  echo "${service_name}|${listen}|${target}|${proto}" | $SUDO tee -a "$BROOK_CONFIG_FILE" >/dev/null
  echo -e "${SUCCESS_SYMBOL} brook 添加成功: $service_name"
}

engine_brook_list() {
  if [ "$OUTPUT" = "json" ]; then
    echo -n '['
    local first=1
    while IFS='|' read -r s l r p; do
      [ -z "$s" ] && continue
      [ $first -eq 0 ] && echo -n ','
      first=0
      local active
      active=$(systemctl is-active "$s" 2>/dev/null || echo "unknown")
      echo -n "{\"engine\":\"brook\",\"service\":$(json_escape "$s"),\"listen\":$(json_escape "$l"),\"target\":$(json_escape "$r"),\"proto\":\"$p\",\"active\":\"$active\"}"
    done < "$BROOK_CONFIG_FILE"
    echo ']'
  else
    printf "%-28s %-20s %-24s %-6s %-8s\n" "SERVICE" "LISTEN" "TARGET" "PROTO" "ACTIVE"
    if [ -f "$BROOK_CONFIG_FILE" ]; then
      while IFS='|' read -r s l r p; do
        [ -z "$s" ] && continue
        active=$(systemctl is-active "$s" 2>/dev/null || echo "unknown")
        printf "%-28s %-20s %-24s %-6s %-8s\n" "$s" "$l" "$r" "$p" "$active"
      done < "$BROOK_CONFIG_FILE"
    fi
  fi
}

engine_brook_delete() {
  local name="$1"
  [ -z "$name" ] && { echo -e "${ERROR_SYMBOL} 请提供 --name"; exit 2; }
  $SUDO systemctl stop "$name" 2>/dev/null || true
  $SUDO systemctl disable "$name" 2>/dev/null || true
  $SUDO rm -f "${BROOK_SERVICE_DIR}/${name}.service"
  $SUDO systemctl daemon-reload
  $SUDO sed -i "/^${name}|/d" "$BROOK_CONFIG_FILE" 2>/dev/null || true
  echo -e "${SUCCESS_SYMBOL} 已删除: $name"
}

# 引擎适配：gost（配置文件 JSON）
engine_gost_add() {
  local proto="$1" listen="$2" target="$3" name="$4"
  command -v jq >/dev/null 2>&1 || { echo -e "${ERROR_SYMBOL} 缺少 jq"; exit 1; }
  [ -f "$GOST_CONFIG_FILE" ] || echo '{"services":[]}' | $SUDO tee "$GOST_CONFIG_FILE" >/dev/null
  local tmp=$(mktemp)
  local svc_name
  if [ -n "$name" ]; then svc_name="$name"; else svc_name="forward-$(echo "$listen"|sed 's/[^0-9]//g')-$proto"; fi
  jq --arg n "$svc_name" --arg a "$listen" --arg t "$target" --arg p "$proto" \
     '.services += [{name:$n, addr:$a, handler:{type:$p}, listener:{type:$p}, forwarder:{nodes:[{name:"target-0", addr:$t}]}}]' \
     "$GOST_CONFIG_FILE" > "$tmp"
  $SUDO mv "$tmp" "$GOST_CONFIG_FILE"
  $SUDO chown root:root "$GOST_CONFIG_FILE"; $SUDO chmod 644 "$GOST_CONFIG_FILE"
  $SUDO systemctl restart gost || $SUDO systemctl start gost || true
  echo -e "${SUCCESS_SYMBOL} gost 添加成功: $svc_name"
}

engine_gost_list() {
  command -v jq >/dev/null 2>&1 || { echo -e "${ERROR_SYMBOL} 缺少 jq"; exit 1; }
  if [ "$OUTPUT" = "json" ]; then
    jq -r '.services[] | {engine:"gost", name:.name, listen:.addr, proto:(.handler.type), target:(.forwarder.nodes[0].addr // "") }' "$GOST_CONFIG_FILE" 2>/dev/null | \
    python3 -c 'import sys,json; print(json.dumps([json.loads(l) for l in sys.stdin if l.strip()], ensure_ascii=False))' 2>/dev/null || echo '[]'
  else
    printf "%-28s %-20s %-6s %-24s\n" "NAME" "LISTEN" "PROTO" "TARGET"
    jq -r '.services[] | [.name, .addr, .handler.type, (.forwarder.nodes[0].addr // "")] | @tsv' "$GOST_CONFIG_FILE" 2>/dev/null | \
    awk -F'\t' '{printf "%-28s %-20s %-6s %-24s\n", $1,$2,$3,$4}' || true
  fi
}

engine_gost_delete() {
  local name="$1" tmp=$(mktemp)
  command -v jq >/dev/null 2>&1 || { echo -e "${ERROR_SYMBOL} 缺少 jq"; exit 1; }
  [ -z "$name" ] && { echo -e "${ERROR_SYMBOL} 请提供 --name"; exit 2; }
  jq --arg n "$name" '.services = [.services[] | select(.name != $n)]' "$GOST_CONFIG_FILE" > "$tmp"
  $SUDO mv "$tmp" "$GOST_CONFIG_FILE"
  $SUDO systemctl restart gost || true
  echo -e "${SUCCESS_SYMBOL} 已删除: $name"
}

# 引擎适配：realm（config.toml 直接追加）
ensure_realm_network() {
  if ! grep -q '^\[network\]' "$REALM_CONFIG" 2>/dev/null; then
    cat <<EOF | $SUDO tee -a "$REALM_CONFIG" >/dev/null
[network]
no_tcp = false
use_udp = true
ipv6_only = false
EOF
  fi
}

engine_realm_add() {
  local proto="$1" listen="$2" target="$3" name="$4"
  $SUDO mkdir -p "$(dirname "$REALM_CONFIG")" 2>/dev/null || true
  [ -f "$REALM_CONFIG" ] || $SUDO touch "$REALM_CONFIG"
  ensure_realm_network
  local use_tcp=false use_udp=false
  case "$proto" in
    tcp) use_tcp=true; use_udp=false ;;
    udp) use_tcp=false; use_udp=true ;;
    both) use_tcp=true; use_udp=true ;;
  esac
  cat <<EOF | $SUDO tee -a "$REALM_CONFIG" >/dev/null

[[endpoints]]
# Remark: ${name:-fwrd}
listen = "${listen}"
remote = "${target}"
use_tcp = ${use_tcp}
use_udp = ${use_udp}
EOF
  $SUDO systemctl restart realm || $SUDO systemctl start realm || true
  echo -e "${SUCCESS_SYMBOL} realm 添加成功"
}

engine_realm_list() {
  # 简单解析 endpoints（按脚本里展示格式）
  if [ "$OUTPUT" = "json" ]; then
    awk '/^\[\[endpoints\]\]/{f=1;next} f&&/^# Remark:/{r=substr($0,index($0,":")+2)} f&&/^listen/{l=$3;gsub(/\"/,"",l)} f&&/^remote/{m=$3;gsub(/\"/,"",m); printf "%s | %s -> %s\n", r,l,m; f=0}' "$REALM_CONFIG" 2>/dev/null | \
    python3 -c 'import sys,json;print(json.dumps([{"engine":"realm","remark":(l.split("|")[0] if "|" in l else ""),"listen":(l.split("|")[1] if "|" in l else ""),"target":(l.split("|")[2] if "|" in l else "")} for l in sys.stdin if l.strip()], ensure_ascii=False))' 2>/dev/null || echo '[]'
  else
    echo "Remark | Listen -> Target"
    awk '/^\[\[endpoints\]\]/{f=1;next} f&&/^# Remark:/{r=substr($0,index($0,":")+2)} f&&/^listen/{l=$3;gsub(/\"/,"",l)} f&&/^remote/{m=$3;gsub(/\"/,"",m); printf "%s | %s -> %s\n", r,l,m; f=0}' "$REALM_CONFIG" 2>/dev/null || true
  fi
}

# realm 删除：基于 remark 或 name 模式（name=listen 或 remark）
engine_realm_delete() {
  local key="$1"
  [ -z "$key" ] && { echo -e "${ERROR_SYMBOL} Please provide --name"; exit 2; }
  [ -f "$REALM_CONFIG" ] || { echo -e "${ERROR_SYMBOL} 未找到 $REALM_CONFIG"; exit 1; }
  local tmp_map=$(mktemp)
  # 输出: start end remark listen
  awk '
    BEGIN{start=0; remark=""; listen=""}
    /^\[\[endpoints\]\]/{
      if (start>0) { printf "%d %d %s %s\n", start, NR-1, remark, listen }
      start=NR; remark=""; listen=""; next
    }
    { if (start>0) {
        if ($0 ~ /^# Remark:[ \t]*/) { r=$0; sub(/^# Remark:[ \t]*/, "", r); remark=r }
        if ($0 ~ /^listen[ \t]*=/) { l=$0; match(l, /\"[^\"]+\"/); if (RSTART>0) listen=substr(l, RSTART+1, RLENGTH-2) }
      }
    }
    END{ if (start>0) printf "%d %d %s %s\n", start, NR, remark, listen }
  ' "$REALM_CONFIG" > "$tmp_map"
  # 精确匹配 remark==key 或 listen==key 的块，按范围删除
  local changed=0
  while read -r s e r l; do
    if [ "$r" = "$key" ] || [ "$l" = "$key" ]; then
      $SUDO sed -i "${s},${e}d" "$REALM_CONFIG"
      changed=1
    fi
  done < "$tmp_map"
  rm -f "$tmp_map"
  if [ "$changed" -eq 1 ]; then
    $SUDO systemctl restart realm || true
    echo -e "${SUCCESS_SYMBOL} realm deleted matching rules"
  else
    echo -e "${WARN_SYMBOL} No exact matching rule found"
  fi
}

# nftables：仅提供简化添加（DNAT），list 由 nft 自身输出
engine_nftables_add() {
  local proto="$1" listen="$2" target="$3" name="$4"
  # listen 仅提取外部端口
  local port
  port=$(echo "$listen" | awk -F: '{print $NF}')
  local tgt_host=$(echo "$target" | sed -E 's/^\[?([^\]]+)\]?:(.+)$/\1/')
  local tgt_port=$(echo "$target" | sed -E 's/^\[?([^\]]+)\]?:(.+)$/\2/')
  local family="ip"; [[ "$tgt_host" == *":"* ]] && family="ip6"
  local to_expr="$tgt_host:$tgt_port"; [ "$family" = "ip6" ] && to_expr="[$tgt_host]:$tgt_port"
  # 确保 nat 表存在
  nft list table $family nat >/dev/null 2>&1 || {
    $SUDO nft add table $family nat
    $SUDO nft add chain $family nat prerouting '{ type nat hook prerouting priority dstnat; policy accept; }'
    $SUDO nft add chain $family nat postrouting '{ type nat hook postrouting priority srcnat; policy accept; }'
    $SUDO nft add rule $family nat postrouting masquerade || true
  }
  if [ "$proto" = "tcp" ] || [ "$proto" = "both" ]; then
    $SUDO nft add rule $family nat prerouting tcp dport $port dnat to $to_expr comment "${name:-fwrd}"
  fi
  if [ "$proto" = "udp" ] || [ "$proto" = "both" ]; then
    $SUDO nft add rule $family nat prerouting udp dport $port dnat to $to_expr comment "${name:-fwrd}"
  fi
  echo -e "${SUCCESS_SYMBOL} nftables 添加 DNAT 成功"
}

engine_nftables_list() {
  if [ "$OUTPUT" = "json" ]; then
    echo '[]'
  else
    nft list table ip nat 2>/dev/null | cat
    nft list table ip6 nat 2>/dev/null | cat
  fi
}

# nftables 删除：按 proto + dport 精确删除 prerouting 规则，或按 comment 名称删除
engine_nftables_delete() {
  local spec="$1"
  [ -z "$spec" ] && { echo -e "${ERROR_SYMBOL} Please provide --name"; exit 2; }
  if echo "$spec" | grep -Eq '^(tcp|udp):[0-9]+$'; then
    local proto="${spec%%:*}"; local dport="${spec##*:}"
    for fam in ip ip6; do
      nft list ruleset -a 2>/dev/null | awk -v P="$proto" -v D="$dport" -v F="$fam" \
        '$0 ~ "table "F" nat" {intab=1} intab && $0 ~ "prerouting" && $0 ~ P" dport "D {print}' | \
        while read -r line; do
          handle=$(echo "$line" | sed -n 's/.*handle \([0-9]\+\).*/\1/p')
          [ -n "$handle" ] && $SUDO nft delete rule $fam nat prerouting handle "$handle" || true
        done
    done
    echo -e "${SUCCESS_SYMBOL} nftables 已尝试删除: $spec"
  else
    # 按 comment 名称删除
    local comment="$spec"
    for fam in ip ip6; do
      nft list ruleset -a 2>/dev/null | awk -v F="$fam" -v C="$comment" \
        '$0 ~ "table "F" nat" {intab=1} intab && $0 ~ "prerouting" && $0 ~ "comment \""C"\"" {print}' | \
        while read -r line; do
          handle=$(echo "$line" | sed -n 's/.*handle \([0-9]\+\).*/\1/p')
          [ -n "$handle" ] && $SUDO nft delete rule $fam nat prerouting handle "$handle" || true
        done
    done
    echo -e "${SUCCESS_SYMBOL} nftables 已尝试按 comment 删除: $comment"
  fi
}

# 命令分派
ensure_dirs
case "$CMD" in
  menu|"")
    # 交互式菜单模式
    while true; do
      clear
      echo -e "${BOLD}${BLUE}========== Unified Forwarding Management - fwrd ==========${PLAIN}"
      echo -e "${INFO_SYMBOL} ${YELLOW}Smart forwarding with auto-installation and detection${PLAIN}"
      echo
      echo -e "${BOLD}${BLUE}🚀 Quick Setup (No manual config needed):${PLAIN}"
      echo -e "  ${GREEN}1.${PLAIN} Web Forward ${YELLOW}[HTTP/HTTPS - Auto port]${PLAIN}"
      echo -e "  ${GREEN}2.${PLAIN} DNS Forward ${YELLOW}[Popular DNS - Auto port]${PLAIN}" 
      echo -e "  ${GREEN}3.${PLAIN} SSH/Remote ${YELLOW}[SSH/RDP/VNC - Auto port]${PLAIN}"
      echo
      echo -e "${BOLD}${BLUE}⚙️  Advanced Options:${PLAIN}"
      echo -e "  ${GREEN}4.${PLAIN} Custom Forward ${YELLOW}[Full control]${PLAIN}"
      echo -e "  ${GREEN}5.${PLAIN} Manage Rules ${YELLOW}[List/Delete]${PLAIN}"
      echo -e "  ${GREEN}6.${PLAIN} Service Control ${YELLOW}[Status/Logs]${PLAIN}"
      echo -e "  ${GREEN}7.${PLAIN} One-Click Presets ${YELLOW}[Common scenarios]${PLAIN}"
      echo
      echo -e "  ${GREEN}0.${PLAIN} Exit"
      echo -e "${BOLD}${BLUE}=========================================${PLAIN}"
      read -rp "Please select [0-7]: " msel
      case "$msel" in
        1) menu_quick_web_forward ;;
        2) menu_quick_dns_forward ;;
        3) menu_quick_ssh_forward ;;
        4) menu_custom_forward ;;
        5) menu_list_manage ;;
        6) menu_service_management ;;
        7) menu_one_click_presets ;;
        0) echo -e "${SUCCESS_SYMBOL} Goodbye!"; exit 0 ;;
        *) echo -e "${ERROR_SYMBOL} Invalid selection"; sleep 1 ;;
      esac
    done
    ;;
  add)
    [ -n "$ENGINE" ] && ensure_engine_ready "$ENGINE" || true
    [ -z "$ENGINE" ] && { echo -e "${ERROR_SYMBOL} 需要 --engine"; usage; exit 2; }
    [ -z "$PROTO" ] && { echo -e "${ERROR_SYMBOL} 需要 --proto"; usage; exit 2; }
    [ -z "$LISTEN" ] && { echo -e "${ERROR_SYMBOL} 需要 --listen"; usage; exit 2; }
    [ -z "$TARGET" ] && { echo -e "${ERROR_SYMBOL} 需要 --target"; usage; exit 2; }

    # 非交互自动扩展：--range 与 --target-udp
    if [ -n "${RANGE}" ]; then
      L_HOST="${LISTEN%:*}"; L_PORT_BASE="${LISTEN##*:}"
      T_HOST="${TARGET%:*}"; T_PORT="${TARGET##*:}"
      # 目标端口是否提供范围
      if [[ "$T_PORT" =~ ^[0-9]+-[0-9]+$ ]]; then
        T_START="${T_PORT%-*}"
        MAP_TYPE=2
      else
        MAP_TYPE=1
      fi
      if [ -n "${TARGET_UDP:-}" ]; then
        TU_HOST="${TARGET_UDP%:*}"; TU_PORT="${TARGET_UDP##*:}"
        if [[ "$TU_PORT" =~ ^[0-9]+-[0-9]+$ ]]; then
          TU_START="${TU_PORT%-*}"
        fi
      fi
      L_START="${RANGE%-*}"; L_END="${RANGE#*-}"
      if ! [[ "$L_START" =~ ^[0-9]+$ && "$L_END" =~ ^[0-9]+$ && "$L_START" -le "$L_END" ]]; then
        echo -e "${ERROR_SYMBOL} 端口范围无效"; exit 2
      fi
      p=$L_START
      while [ "$p" -le "$L_END" ]; do
        if [ -z "$L_HOST" ] || [ "$L_HOST" = "$LISTEN" ]; then NEW_LISTEN=":$p"; else NEW_LISTEN="${L_HOST}:$p"; fi
        if [ "$MAP_TYPE" = "2" ]; then CUR_T_PORT=$(( T_START + p - L_START )); else CUR_T_PORT="$T_PORT"; fi
        NEW_TARGET="${T_HOST}:${CUR_T_PORT}"

        if [ "$PROTO" = "both" ] && [ -n "${TARGET_UDP:-}" ]; then
          # TCP
          case "$ENGINE" in
            brook) engine_brook_add tcp "$NEW_LISTEN" "$NEW_TARGET" ${NAME:+"${NAME}-tcp-$p"} ;;
            gost) engine_gost_add tcp "$NEW_LISTEN" "$NEW_TARGET" ${NAME:+"${NAME}-tcp-$p"} ;;
            realm) engine_realm_add tcp "$NEW_LISTEN" "$NEW_TARGET" ${NAME:+"${NAME}-tcp-$p"} ;;
            nftables) engine_nftables_add tcp "$NEW_LISTEN" "$NEW_TARGET" ${NAME:+"${NAME}-tcp-$p"} ;;
          esac
          # UDP
          if [ -n "${TU_HOST:-}" ]; then
            if [ -n "${TU_START:-}" ]; then CUR_U_PORT=$(( TU_START + p - L_START )); else CUR_U_PORT=$CUR_T_PORT; fi
            NEW_UDP_TARGET="${TU_HOST}:${CUR_U_PORT}"
          else
            NEW_UDP_TARGET="$NEW_TARGET"
          fi
          case "$ENGINE" in
            brook) engine_brook_add udp "$NEW_LISTEN" "$NEW_UDP_TARGET" ${NAME:+"${NAME}-udp-$p"} ;;
            gost) engine_gost_add udp "$NEW_LISTEN" "$NEW_UDP_TARGET" ${NAME:+"${NAME}-udp-$p"} ;;
            realm) engine_realm_add udp "$NEW_LISTEN" "$NEW_UDP_TARGET" ${NAME:+"${NAME}-udp-$p"} ;;
            nftables) engine_nftables_add udp "$NEW_LISTEN" "$NEW_UDP_TARGET" ${NAME:+"${NAME}-udp-$p"} ;;
          esac
        else
          # 非分离：按协议处理
          if [ "$PROTO" = "both" ]; then
            case "$ENGINE" in
              brook) engine_brook_add tcp "$NEW_LISTEN" "$NEW_TARGET" ${NAME:+"${NAME}-tcp-$p"} ; engine_brook_add udp "$NEW_LISTEN" "$NEW_TARGET" ${NAME:+"${NAME}-udp-$p"} ;;
              gost) engine_gost_add tcp "$NEW_LISTEN" "$NEW_TARGET" ${NAME:+"${NAME}-tcp-$p"} ; engine_gost_add udp "$NEW_LISTEN" "$NEW_TARGET" ${NAME:+"${NAME}-udp-$p"} ;;
              realm) engine_realm_add tcp "$NEW_LISTEN" "$NEW_TARGET" ${NAME:+"${NAME}-tcp-$p"} ; engine_realm_add udp "$NEW_LISTEN" "$NEW_TARGET" ${NAME:+"${NAME}-udp-$p"} ;;
              nftables) engine_nftables_add tcp "$NEW_LISTEN" "$NEW_TARGET" ${NAME:+"${NAME}-tcp-$p"} ; engine_nftables_add udp "$NEW_LISTEN" "$NEW_TARGET" ${NAME:+"${NAME}-udp-$p"} ;;
            esac
          else
            case "$ENGINE" in
              brook) engine_brook_add "$PROTO" "$NEW_LISTEN" "$NEW_TARGET" ${NAME:+"${NAME}-$p"} ;;
              gost) engine_gost_add "$PROTO" "$NEW_LISTEN" "$NEW_TARGET" ${NAME:+"${NAME}-$p"} ;;
              realm) engine_realm_add "$PROTO" "$NEW_LISTEN" "$NEW_TARGET" ${NAME:+"${NAME}-$p"} ;;
              nftables) engine_nftables_add "$PROTO" "$NEW_LISTEN" "$NEW_TARGET" ${NAME:+"${NAME}-$p"} ;;
            esac
          fi
        fi
        p=$((p+1))
      done
    else
      # 单条：若 both 且提供 --target-udp，则拆分为两条
      if [ "$PROTO" = "both" ] && [ -n "${TARGET_UDP:-}" ]; then
        case "$ENGINE" in
          brook) engine_brook_add tcp "$LISTEN" "$TARGET" ${NAME:+"${NAME}-tcp"} ; engine_brook_add udp "$LISTEN" "$TARGET_UDP" ${NAME:+"${NAME}-udp"} ;;
          gost) engine_gost_add tcp "$LISTEN" "$TARGET" ${NAME:+"${NAME}-tcp"} ; engine_gost_add udp "$LISTEN" "$TARGET_UDP" ${NAME:+"${NAME}-udp"} ;;
          realm) engine_realm_add tcp "$LISTEN" "$TARGET" ${NAME:+"${NAME}-tcp"} ; engine_realm_add udp "$LISTEN" "$TARGET_UDP" ${NAME:+"${NAME}-udp"} ;;
          nftables) engine_nftables_add tcp "$LISTEN" "$TARGET" ${NAME:+"${NAME}-tcp"} ; engine_nftables_add udp "$LISTEN" "$TARGET_UDP" ${NAME:+"${NAME}-udp"} ;;
          *) echo -e "${ERROR_SYMBOL} 不支持的引擎: $ENGINE"; exit 2 ;;
        esac
      else
        case "$ENGINE" in
          brook) engine_brook_add "$PROTO" "$LISTEN" "$TARGET" "$NAME" ;;
          gost) engine_gost_add "$PROTO" "$LISTEN" "$TARGET" "$NAME" ;;
          realm) engine_realm_add "$PROTO" "$LISTEN" "$TARGET" "$NAME" ;;
          nftables) engine_nftables_add "$PROTO" "$LISTEN" "$TARGET" "$NAME" ;;
          *) echo -e "${ERROR_SYMBOL} 不支持的引擎: $ENGINE"; exit 2 ;;
        esac
      fi
    fi
    ;;
  list)
    case "$ENGINE" in
      brook|"" ) engine_brook_list ;;
    esac
    case "$ENGINE" in
      gost|"" ) engine_gost_list ;;
    esac
    case "$ENGINE" in
      realm|"" ) engine_realm_list ;;
    esac
    case "$ENGINE" in
      nftables|"" ) engine_nftables_list ;;
    esac
    ;;
  delete)
    [ -z "$ENGINE" ] && { echo -e "${ERROR_SYMBOL} 需要 --engine"; exit 2; }
    case "$ENGINE" in
      brook) engine_brook_delete "$NAME" ;;
      gost) engine_gost_delete "$NAME" ;;
      realm) engine_realm_delete "$NAME" ;;
      nftables) engine_nftables_delete "$NAME" ;;
      *) echo -e "${ERROR_SYMBOL} 暂不支持该引擎的 delete: $ENGINE"; exit 2 ;;
    esac
    ;;
  restart)
    case "$ENGINE" in
      gost) $SUDO systemctl restart gost && echo -e "${SUCCESS_SYMBOL} gost 重启完成" ;;
      realm) $SUDO systemctl restart realm && echo -e "${SUCCESS_SYMBOL} realm 重启完成" ;;
      *) echo -e "${ERROR_SYMBOL} 不支持的引擎: $ENGINE"; exit 2 ;;
    esac
    ;;
  status)
    case "$ENGINE" in
      gost) systemctl status gost --no-pager | cat ;;
      realm) systemctl status realm --no-pager | cat ;;
      brook) systemctl list-units | grep brook-forward | cat ;;
      nftables) systemctl status nftables --no-pager | cat ;;
      *) echo -e "${ERROR_SYMBOL} 不支持的引擎: $ENGINE"; exit 2 ;;
    esac
    ;;
  logs)
    case "$ENGINE" in
      gost) journalctl -u gost -n 50 --no-pager | cat ;;
      realm) journalctl -u realm -n 50 --no-pager | cat ;;
      brook) journalctl -u "brook-forward*" -n 20 --no-pager | cat || true ;;
      *) echo -e "${ERROR_SYMBOL} 不支持的引擎: $ENGINE"; exit 2 ;;
    esac
    ;;
  * ) usage; exit 2 ;;
esac

# ================ 交互式菜单函数 ================

# 智能端口生成和检测
find_available_port() {
  local start=${1:-10000}
  local end=${2:-65535}
  local preferred_ports=()
  local port
  
  # 根据范围推荐一些常用端口
  case "$start" in
    8000) preferred_ports=(8080 8088 8888 8000 8001 8008) ;;
    2200) preferred_ports=(2222 2200 2201 2202) ;;
    3300) preferred_ports=(3389 3390 3391 3392) ;;
    5900) preferred_ports=(5901 5902 5903 5904) ;;
    10053) preferred_ports=(10053 10054 10055 15353) ;;
  esac
  
  # 先尝试推荐端口
  for port in "${preferred_ports[@]}"; do
    if [ "$port" -ge "$start" ] && [ "$port" -le "$end" ]; then
      if ! netstat -tuln 2>/dev/null | grep -q ":$port " && ! ss -tuln 2>/dev/null | grep -q ":$port "; then
        echo "$port"
        return 0
      fi
    fi
  done
  
  # 随机选择
  for i in {1..20}; do
    port=$((RANDOM % (end - start + 1) + start))
    if ! netstat -tuln 2>/dev/null | grep -q ":$port " && ! ss -tuln 2>/dev/null | grep -q ":$port "; then
      echo "$port"
      return 0
    fi
  done
  echo "$start"
}

# 检测常用服务端口并提供建议
suggest_target_port() {
  local target_ip="$1"
  local suggestions=()
  
  echo -e "${BLUE}Detecting common services on $target_ip...${PLAIN}"
  
  # 检测常见端口
  local common_ports=(22 80 443 3389 5901 8080 8443)
  for port in "${common_ports[@]}"; do
    if timeout 2 bash -c "</dev/tcp/$target_ip/$port" 2>/dev/null; then
      case "$port" in
        22) suggestions+=("$port (SSH)") ;;
        80) suggestions+=("$port (HTTP)") ;;
        443) suggestions+=("$port (HTTPS)") ;;
        3389) suggestions+=("$port (RDP)") ;;
        5901) suggestions+=("$port (VNC)") ;;
        8080) suggestions+=("$port (HTTP-Alt)") ;;
        8443) suggestions+=("$port (HTTPS-Alt)") ;;
        *) suggestions+=("$port") ;;
      esac
    fi
  done
  
  if [ ${#suggestions[@]} -gt 0 ]; then
    echo -e "${SUCCESS_SYMBOL} Found services:"
    for i in "${!suggestions[@]}"; do
      echo -e "  ${GREEN}$((i+1)).${PLAIN} ${suggestions[$i]}"
    done
    read -rp "Select service port [1-${#suggestions[@]}] or enter custom: " port_choice
    if [[ "$port_choice" =~ ^[0-9]+$ ]] && [ "$port_choice" -ge 1 ] && [ "$port_choice" -le ${#suggestions[@]} ]; then
      echo "${suggestions[$((port_choice-1))]}" | cut -d' ' -f1
    else
      echo "$port_choice"
    fi
  else
    echo -e "${WARN_SYMBOL} No common services detected"
    read -rp "Enter target port manually: " manual_port
    echo "$manual_port"
  fi
}

# 引擎选择菜单
select_engine() {
  echo -e "${BLUE}Select forwarding engine:${PLAIN}"
  echo -e "  ${GREEN}1.${PLAIN} Brook - Simple and fast"
  echo -e "  ${GREEN}2.${PLAIN} GOST - Feature-rich"
  echo -e "  ${GREEN}3.${PLAIN} Realm - High performance"
  echo -e "  ${GREEN}4.${PLAIN} NFTables - Kernel-level (Linux only)"
  read -rp "Select engine [1-4]: " engine_choice
  case "$engine_choice" in
    1) echo "brook" ;;
    2) echo "gost" ;;
    3) echo "realm" ;;
    4) echo "nftables" ;;
    *) echo "brook" ;;
  esac
}

# 协议选择菜单
select_protocol() {
  local default_proto=${1:-both}
  echo -e "${BLUE}Select protocol:${PLAIN}"
  echo -e "  ${GREEN}1.${PLAIN} TCP only"
  echo -e "  ${GREEN}2.${PLAIN} UDP only"
  echo -e "  ${GREEN}3.${PLAIN} Both TCP and UDP (recommended)"
  read -rp "Select protocol [1-3] (default: 3): " proto_choice
  case "${proto_choice:-3}" in
    1) echo "tcp" ;;
    2) echo "udp" ;;
    3) echo "both" ;;
    *) echo "$default_proto" ;;
  esac
}

# 快速 Web 转发
menu_quick_web_forward() {
  clear
  echo -e "${BOLD}${BLUE}========== Quick Web Forward Setup ==========${PLAIN}"
  echo -e "${INFO_SYMBOL} This will forward HTTP/HTTPS traffic"
  echo
  
  ENGINE=$(select_engine)
  ensure_engine_ready "$ENGINE"
  
  echo -e "${BLUE}Select web service preset:${PLAIN}"
  echo -e "  ${GREEN}1.${PLAIN} HTTP (port 80) ${YELLOW}[Most common]${PLAIN}"
  echo -e "  ${GREEN}2.${PLAIN} HTTPS (port 443) ${YELLOW}[Secure web]${PLAIN}"
  echo -e "  ${GREEN}3.${PLAIN} HTTP Alternative (port 8080)"
  echo -e "  ${GREEN}4.${PLAIN} Auto-detect target services"
  read -rp "Select [1-4] (default: 1): " service_type
  service_type=${service_type:-1}
  
  read -rp "Target server IP or domain: " target_ip
  [ -z "$target_ip" ] && { echo -e "${ERROR_SYMBOL} Target IP required"; read -n1 -r -p "Press any key..."; return; }
  
  local local_port target_port proto="tcp"
  case "$service_type" in
    1) 
      local_port=$(find_available_port 8000 8999)
      target_port="80"
      echo -e "${SUCCESS_SYMBOL} Auto-selected local port: $local_port"
      ;;
    2) 
      local_port=$(find_available_port 8000 8999)
      target_port="443"
      echo -e "${SUCCESS_SYMBOL} Auto-selected local port: $local_port"
      ;;
    3)
      local_port=$(find_available_port 8000 8999)
      target_port="8080"
      echo -e "${SUCCESS_SYMBOL} Auto-selected local port: $local_port"
      ;;
    4)
      local_port=$(find_available_port 8000 8999)
      target_port=$(suggest_target_port "$target_ip")
      echo -e "${SUCCESS_SYMBOL} Auto-selected local port: $local_port"
      ;;
    *) return ;;
  esac
  
  local rule_name="web-${local_port}-to-${target_port}"
  echo
  echo -e "${BOLD}${BLUE}========== Summary ==========${PLAIN}"
  echo -e "${INFO_SYMBOL} Engine: ${YELLOW}$ENGINE${PLAIN}"
  echo -e "${INFO_SYMBOL} Rule: ${YELLOW}$rule_name${PLAIN}"
  echo -e "${INFO_SYMBOL} Forward: ${YELLOW}:$local_port${PLAIN} -> ${YELLOW}$target_ip:$target_port${PLAIN}"
  echo -e "${INFO_SYMBOL} Protocol: ${YELLOW}$proto${PLAIN}"
  echo
  
  read -rp "Create this forward rule? [Y/n]: " confirm
  if [[ ! "$confirm" =~ ^[Nn]$ ]]; then
    "$0" add --engine "$ENGINE" --proto "$proto" --listen ":$local_port" --target "$target_ip:$target_port" --name "$rule_name"
    echo -e "${SUCCESS_SYMBOL} Web forward created successfully!"
    echo -e "${INFO_SYMBOL} You can now access $target_ip:$target_port via localhost:$local_port"
  else
    echo -e "${WARN_SYMBOL} Creation cancelled"
  fi
  read -n1 -r -p "Press any key to continue..."
}

# 快速 DNS 转发
menu_quick_dns_forward() {
  clear
  echo -e "${BOLD}${BLUE}========== Quick DNS Forward Setup ==========${PLAIN}"
  echo -e "${INFO_SYMBOL} This will forward DNS traffic (TCP and UDP)"
  echo
  
  ENGINE=$(select_engine)
  ensure_engine_ready "$ENGINE"
  
  echo -e "${BLUE}Select DNS provider preset:${PLAIN}"
  echo -e "  ${GREEN}1.${PLAIN} Cloudflare DNS (1.1.1.1) ${YELLOW}[Fast & Private]${PLAIN}"
  echo -e "  ${GREEN}2.${PLAIN} Google DNS (8.8.8.8) ${YELLOW}[Reliable]${PLAIN}"
  echo -e "  ${GREEN}3.${PLAIN} Quad9 DNS (9.9.9.9) ${YELLOW}[Security focused]${PLAIN}"
  echo -e "  ${GREEN}4.${PLAIN} OpenDNS (208.67.222.222) ${YELLOW}[Content filtering]${PLAIN}"
  echo -e "  ${GREEN}5.${PLAIN} Custom DNS server"
  read -rp "Select [1-5] (default: 1): " dns_choice
  dns_choice=${dns_choice:-1}
  
  local target_ip dns_name
  case "$dns_choice" in
    1) target_ip="1.1.1.1"; dns_name="Cloudflare" ;;
    2) target_ip="8.8.8.8"; dns_name="Google" ;;
    3) target_ip="9.9.9.9"; dns_name="Quad9" ;;
    4) target_ip="208.67.222.222"; dns_name="OpenDNS" ;;
    5) 
      read -rp "Enter DNS server IP: " target_ip
      [ -z "$target_ip" ] && { echo -e "${ERROR_SYMBOL} DNS IP required"; read -n1 -r -p "Press any key..."; return; }
      dns_name="Custom"
      ;;
    *) return ;;
  esac
  
  local local_port=$(find_available_port 10053 15053)
  local rule_name="dns-${dns_name,,}-${local_port}"
  
  echo
  echo -e "${BOLD}${BLUE}========== Summary ==========${PLAIN}"
  echo -e "${INFO_SYMBOL} Engine: ${YELLOW}$ENGINE${PLAIN}"
  echo -e "${INFO_SYMBOL} DNS Provider: ${YELLOW}$dns_name ($target_ip)${PLAIN}"
  echo -e "${INFO_SYMBOL} Local DNS Port: ${YELLOW}$local_port${PLAIN}"
  echo -e "${INFO_SYMBOL} Rule: ${YELLOW}$rule_name${PLAIN}"
  echo -e "${INFO_SYMBOL} Protocol: ${YELLOW}TCP + UDP${PLAIN}"
  echo
  echo -e "${INFO_SYMBOL} Usage: Set your system DNS to ${YELLOW}127.0.0.1:$local_port${PLAIN}"
  
  read -rp "Create this DNS forward? [Y/n]: " confirm
  if [[ ! "$confirm" =~ ^[Nn]$ ]]; then
    "$0" add --engine "$ENGINE" --proto "both" --listen ":$local_port" --target "$target_ip:53" --name "$rule_name"
    echo -e "${SUCCESS_SYMBOL} DNS forward created successfully!"
    echo -e "${SUCCESS_SYMBOL} DNS service: ${YELLOW}$dns_name${PLAIN} via port ${YELLOW}$local_port${PLAIN}"
  else
    echo -e "${WARN_SYMBOL} Creation cancelled"
  fi
  read -n1 -r -p "Press any key to continue..."
}

# 快速 SSH/远程桌面转发
menu_quick_ssh_forward() {
  clear
  echo -e "${BOLD}${BLUE}========== Quick SSH/Remote Forward Setup ==========${PLAIN}"
  echo -e "${INFO_SYMBOL} This will forward SSH or remote desktop traffic"
  echo
  
  ENGINE=$(select_engine)
  ensure_engine_ready "$ENGINE"
  
  echo -e "${BLUE}Select remote service preset:${PLAIN}"
  echo -e "  ${GREEN}1.${PLAIN} SSH (port 22) ${YELLOW}[Terminal access]${PLAIN}"
  echo -e "  ${GREEN}2.${PLAIN} RDP (port 3389) ${YELLOW}[Windows remote desktop]${PLAIN}"
  echo -e "  ${GREEN}3.${PLAIN} VNC (port 5901) ${YELLOW}[Cross-platform remote]${PLAIN}"
  echo -e "  ${GREEN}4.${PLAIN} Auto-detect target services"
  echo -e "  ${GREEN}5.${PLAIN} Custom port"
  read -rp "Select [1-5] (default: 1): " service_choice
  service_choice=${service_choice:-1}
  
  read -rp "Target server IP: " target_ip
  [ -z "$target_ip" ] && { echo -e "${ERROR_SYMBOL} Target IP required"; read -n1 -r -p "Press any key..."; return; }
  
  local local_port target_port proto="tcp" service_name
  case "$service_choice" in
    1) 
      local_port=$(find_available_port 2200 2299)
      target_port="22"
      service_name="SSH"
      echo -e "${SUCCESS_SYMBOL} Auto-selected local port: $local_port"
      ;;
    2) 
      local_port=$(find_available_port 3300 3399)
      target_port="3389"
      service_name="RDP"
      echo -e "${SUCCESS_SYMBOL} Auto-selected local port: $local_port"
      ;;
    3)
      local_port=$(find_available_port 5900 5999)
      target_port="5901"
      service_name="VNC"
      echo -e "${SUCCESS_SYMBOL} Auto-selected local port: $local_port"
      ;;
    4)
      local_port=$(find_available_port 10000 19999)
      target_port=$(suggest_target_port "$target_ip")
      service_name="Auto-detected"
      echo -e "${SUCCESS_SYMBOL} Auto-selected local port: $local_port"
      ;;
    5)
      read -rp "Enter target port: " target_port
      local_port=$(find_available_port 10000 19999)
      service_name="Custom"
      echo -e "${SUCCESS_SYMBOL} Auto-selected local port: $local_port"
      ;;
    *) return ;;
  esac
  
  local rule_name="remote-${service_name,,}-${local_port}"
  
  echo
  echo -e "${BOLD}${BLUE}========== Summary ==========${PLAIN}"
  echo -e "${INFO_SYMBOL} Engine: ${YELLOW}$ENGINE${PLAIN}"
  echo -e "${INFO_SYMBOL} Service: ${YELLOW}$service_name${PLAIN}"
  echo -e "${INFO_SYMBOL} Local Port: ${YELLOW}$local_port${PLAIN}"
  echo -e "${INFO_SYMBOL} Target: ${YELLOW}$target_ip:$target_port${PLAIN}"
  echo -e "${INFO_SYMBOL} Rule: ${YELLOW}$rule_name${PLAIN}"
  echo
  echo -e "${INFO_SYMBOL} Usage: Connect to ${YELLOW}localhost:$local_port${PLAIN}"
  
  read -rp "Create this remote forward? [Y/n]: " confirm
  if [[ ! "$confirm" =~ ^[Nn]$ ]]; then
    "$0" add --engine "$ENGINE" --proto "$proto" --listen ":$local_port" --target "$target_ip:$target_port" --name "$rule_name"
    echo -e "${SUCCESS_SYMBOL} Remote forward created successfully!"
    echo -e "${SUCCESS_SYMBOL} $service_name service via port ${YELLOW}$local_port${PLAIN}"
  else
    echo -e "${WARN_SYMBOL} Creation cancelled"
  fi
  read -n1 -r -p "Press any key to continue..."
}

# 自定义转发规则
menu_custom_forward() {
  clear
  echo -e "${BOLD}${BLUE}========== Custom Forward Setup ==========${PLAIN}"
  echo -e "${INFO_SYMBOL} Create a custom forwarding rule with full control"
  echo
  
  ENGINE=$(select_engine)
  ensure_engine_ready "$ENGINE"
  
  PROTO=$(select_protocol)
  
  echo -e "${BLUE}Configure local listening:${PLAIN}"
  echo -e "  ${GREEN}1.${PLAIN} Auto-select available port ${YELLOW}[Recommended]${PLAIN}"
  echo -e "  ${GREEN}2.${PLAIN} Specify port manually"
  echo -e "  ${GREEN}3.${PLAIN} Port range forwarding ${YELLOW}[Advanced]${PLAIN}"
  read -rp "Select [1-3] (default: 1): " listen_choice
  listen_choice=${listen_choice:-1}
  
  local listen_addr local_port
  case "$listen_choice" in
    1)
      local_port=$(find_available_port)
      listen_addr=":$local_port"
      echo -e "${SUCCESS_SYMBOL} Auto-selected available port: $local_port"
      ;;
    2)
      read -rp "Enter local port [1-65535]: " local_port
      if [[ ! "$local_port" =~ ^[0-9]+$ ]] || [ "$local_port" -lt 1 ] || [ "$local_port" -gt 65535 ]; then
        echo -e "${ERROR_SYMBOL} Invalid port"; read -n1 -r -p "Press any key..."; return
      fi
      listen_addr=":$local_port"
      ;;
    3)
      read -rp "Port range start: " range_start
      read -rp "Port range end: " range_end
      if [[ ! "$range_start" =~ ^[0-9]+$ ]] || [[ ! "$range_end" =~ ^[0-9]+$ ]] || [ "$range_start" -ge "$range_end" ]; then
        echo -e "${ERROR_SYMBOL} Invalid range"; read -n1 -r -p "Press any key..."; return
      fi
      RANGE="$range_start-$range_end"
      listen_addr=":$range_start"
      echo -e "${SUCCESS_SYMBOL} Port range: $RANGE"
      ;;
    *) return ;;
  esac
  
  echo -e "${BLUE}Configure target:${PLAIN}"
  read -rp "Target IP or domain: " target_ip
  [ -z "$target_ip" ] && { echo -e "${ERROR_SYMBOL} Target required"; read -n1 -r -p "Press any key..."; return; }
  
  echo -e "${BLUE}Target port configuration:${PLAIN}"
  echo -e "  ${GREEN}1.${PLAIN} Auto-detect target services"
  echo -e "  ${GREEN}2.${PLAIN} Manual port entry"
  read -rp "Select [1-2] (default: 2): " target_choice
  target_choice=${target_choice:-2}
  
  local target_port
  case "$target_choice" in
    1) target_port=$(suggest_target_port "$target_ip") ;;
    2) read -rp "Enter target port: " target_port ;;
  esac
  
  [ -z "$target_port" ] && { echo -e "${ERROR_SYMBOL} Target port required"; read -n1 -r -p "Press any key..."; return; }
  
  echo -e "${BLUE}Rule naming:${PLAIN}"
  echo -e "  ${GREEN}1.${PLAIN} Auto-generate rule name"
  echo -e "  ${GREEN}2.${PLAIN} Custom rule name"
  read -rp "Select [1-2] (default: 1): " name_choice
  name_choice=${name_choice:-1}
  
  local rule_name
  case "$name_choice" in
    1) rule_name="custom-${local_port:-$range_start}-to-${target_port}" ;;
    2) read -rp "Enter rule name: " rule_name ;;
  esac
  
  local target_addr="$target_ip:$target_port"
  
  echo
  echo -e "${BOLD}${BLUE}========== Summary ==========${PLAIN}"
  echo -e "${INFO_SYMBOL} Engine: ${YELLOW}$ENGINE${PLAIN}"
  echo -e "${INFO_SYMBOL} Protocol: ${YELLOW}$PROTO${PLAIN}"
  echo -e "${INFO_SYMBOL} Listen: ${YELLOW}$listen_addr${PLAIN}"
  echo -e "${INFO_SYMBOL} Target: ${YELLOW}$target_addr${PLAIN}"
  [ -n "$rule_name" ] && echo -e "${INFO_SYMBOL} Rule Name: ${YELLOW}$rule_name${PLAIN}"
  [ -n "$RANGE" ] && echo -e "${INFO_SYMBOL} Port Range: ${YELLOW}$RANGE${PLAIN}"
  echo
  
  read -rp "Create this custom forward? [Y/n]: " confirm
  if [[ ! "$confirm" =~ ^[Nn]$ ]]; then
    if [ -n "$RANGE" ]; then
      "$0" add --engine "$ENGINE" --proto "$PROTO" --listen "$listen_addr" --target "$target_addr" ${rule_name:+--name "$rule_name"} --range "$RANGE"
    else
      "$0" add --engine "$ENGINE" --proto "$PROTO" --listen "$listen_addr" --target "$target_addr" ${rule_name:+--name "$rule_name"}
    fi
    echo -e "${SUCCESS_SYMBOL} Custom forward created successfully!"
  else
    echo -e "${WARN_SYMBOL} Creation cancelled"
  fi
  read -n1 -r -p "Press any key to continue..."
}

# 列出和管理规则
menu_list_manage() {
  while true; do
    clear
    echo -e "${BOLD}${BLUE}========== Rules Management ==========${PLAIN}"
    echo -e "  ${GREEN}1.${PLAIN} List all rules"
    echo -e "  ${GREEN}2.${PLAIN} List rules by engine"
    echo -e "  ${GREEN}3.${PLAIN} Delete rule"
    echo -e "  ${GREEN}4.${PLAIN} Delete all rules (by engine)"
    echo -e "  ${GREEN}9.${PLAIN} Back to main menu"
    read -rp "Select [1-4,9]: " choice
    
    case "$choice" in
      1)
        echo -e "${INFO_SYMBOL} All forwarding rules:"
        "$0" list
        ;;
      2)
        echo -e "${BLUE}Select engine:${PLAIN}"
        echo -e "  ${GREEN}1.${PLAIN} Brook"
        echo -e "  ${GREEN}2.${PLAIN} GOST" 
        echo -e "  ${GREEN}3.${PLAIN} Realm"
        echo -e "  ${GREEN}4.${PLAIN} NFTables"
        read -rp "Select [1-4]: " eng_choice
        case "$eng_choice" in
          1) "$0" list --engine brook ;;
          2) "$0" list --engine gost ;;
          3) "$0" list --engine realm ;;
          4) "$0" list --engine nftables ;;
        esac
        ;;
      3)
        read -rp "Engine [brook/gost/realm/nftables]: " del_engine
        read -rp "Rule name or service name: " del_name
        [ -n "$del_engine" ] && [ -n "$del_name" ] && "$0" delete --engine "$del_engine" --name "$del_name"
        ;;
      4)
        echo -e "${WARN_SYMBOL} This will delete ALL rules for the selected engine!"
        ENGINE=$(select_engine)
        read -rp "Type 'DELETE' to confirm: " confirm_delete
        if [ "$confirm_delete" = "DELETE" ]; then
          # 这里可以添加批量删除逻辑
          echo -e "${INFO_SYMBOL} Batch delete not implemented yet"
        fi
        ;;
      9) return ;;
    esac
    read -n1 -r -p "Press any key to continue..."
  done
}

# 服务管理
menu_service_management() {
  while true; do
    clear
    echo -e "${BOLD}${BLUE}========== Service Management ==========${PLAIN}"
    echo -e "  ${GREEN}1.${PLAIN} View all service status"
    echo -e "  ${GREEN}2.${PLAIN} Restart service"
    echo -e "  ${GREEN}3.${PLAIN} View service logs"
    echo -e "  ${GREEN}4.${PLAIN} Start/Stop service"
    echo -e "  ${GREEN}9.${PLAIN} Back to main menu"
    read -rp "Select [1-4,9]: " choice
    
    case "$choice" in
      1)
        echo -e "${INFO_SYMBOL} Brook services:"
        "$0" status --engine brook 2>/dev/null || echo "No brook services"
        echo -e "${INFO_SYMBOL} GOST service:"
        "$0" status --engine gost 2>/dev/null || echo "GOST not running"
        echo -e "${INFO_SYMBOL} Realm service:" 
        "$0" status --engine realm 2>/dev/null || echo "Realm not running"
        echo -e "${INFO_SYMBOL} NFTables service:"
        "$0" status --engine nftables 2>/dev/null || echo "NFTables not running"
        ;;
      2)
        echo -e "${BLUE}Select engine to restart:${PLAIN}"
        echo -e "  ${GREEN}1.${PLAIN} GOST"
        echo -e "  ${GREEN}2.${PLAIN} Realm"
        read -rp "Select [1-2]: " restart_choice
        case "$restart_choice" in
          1) "$0" restart --engine gost ;;
          2) "$0" restart --engine realm ;;
        esac
        ;;
      3)
        echo -e "${BLUE}Select engine to view logs:${PLAIN}"
        echo -e "  ${GREEN}1.${PLAIN} Brook"
        echo -e "  ${GREEN}2.${PLAIN} GOST"
        echo -e "  ${GREEN}3.${PLAIN} Realm"
        read -rp "Select [1-3]: " log_choice
        case "$log_choice" in
          1) "$0" logs --engine brook ;;
          2) "$0" logs --engine gost ;;
          3) "$0" logs --engine realm ;;
        esac
        ;;
      4)
        echo -e "${INFO_SYMBOL} Manual service control:"
        echo -e "${INFO_SYMBOL} Use systemctl start/stop/restart <service>"
        echo -e "${INFO_SYMBOL} Services: gost, realm, brook-forward-*"
        ;;
      9) return ;;
    esac
    read -n1 -r -p "Press any key to continue..."
  done
}

# 一键预设菜单
menu_one_click_presets() {
  clear
  echo -e "${BOLD}${BLUE}========== One-Click Presets ==========${PLAIN}"
  echo -e "${INFO_SYMBOL} Complete setups with minimal input - just provide target IP!"
  echo
  
  echo -e "${BLUE}Select a preset scenario:${PLAIN}"
  echo -e "  ${GREEN}1.${PLAIN} Web Proxy ${YELLOW}[HTTP+HTTPS with auto ports]${PLAIN}"
  echo -e "  ${GREEN}2.${PLAIN} Game Server ${YELLOW}[Common game ports]${PLAIN}"
  echo -e "  ${GREEN}3.${PLAIN} Development Environment ${YELLOW}[Dev ports 3000,8080,8000,5000]${PLAIN}"
  echo -e "  ${GREEN}4.${PLAIN} Security Suite ${YELLOW}[SSH + VNC + RDP]${PLAIN}"
  echo -e "  ${GREEN}5.${PLAIN} DNS + Web Combo ${YELLOW}[Cloudflare DNS + Web]${PLAIN}"
  read -rp "Select [1-5]: " preset_choice
  
  read -rp "Target server IP: " target_ip
  [ -z "$target_ip" ] && { echo -e "${ERROR_SYMBOL} Target IP required"; read -n1 -r -p "Press any key..."; return; }
  
  ENGINE=$(select_engine)
  ensure_engine_ready "$ENGINE"
  
  echo -e "${INFO_SYMBOL} Creating preset configuration..."
  
  case "$preset_choice" in
    1) # Web Proxy
      echo -e "${INFO_SYMBOL} Setting up web proxy..."
      local http_port=$(find_available_port 8000 8099)
      local https_port=$(find_available_port 8400 8499)
      "$0" add --engine "$ENGINE" --proto "tcp" --listen ":$http_port" --target "$target_ip:80" --name "preset-web-http-$http_port"
      "$0" add --engine "$ENGINE" --proto "tcp" --listen ":$https_port" --target "$target_ip:443" --name "preset-web-https-$https_port"
      echo -e "${SUCCESS_SYMBOL} Web proxy preset created!"
      echo -e "${INFO_SYMBOL} HTTP: ${YELLOW}localhost:$http_port${PLAIN} -> $target_ip:80"
      echo -e "${INFO_SYMBOL} HTTPS: ${YELLOW}localhost:$https_port${PLAIN} -> $target_ip:443"
      ;;
    2) # Game Server
      echo -e "${INFO_SYMBOL} Setting up game server forwards..."
      read -rp "Game server port (default: 25565 for Minecraft): " game_port
      game_port=${game_port:-25565}
      local local_game_port=$(find_available_port 25000 25999)
      "$0" add --engine "$ENGINE" --proto "both" --listen ":$local_game_port" --target "$target_ip:$game_port" --name "preset-game-$local_game_port"
      echo -e "${SUCCESS_SYMBOL} Game server preset created!"
      echo -e "${INFO_SYMBOL} Game: ${YELLOW}localhost:$local_game_port${PLAIN} -> $target_ip:$game_port"
      ;;
    3) # Development
      echo -e "${INFO_SYMBOL} Setting up development environment..."
      local dev_ports=(3000 8080 8000 5000)
      for port in "${dev_ports[@]}"; do
        local local_dev_port=$(find_available_port $((port + 1000)) $((port + 1999)))
        "$0" add --engine "$ENGINE" --proto "tcp" --listen ":$local_dev_port" --target "$target_ip:$port" --name "preset-dev-$port-$local_dev_port" 2>/dev/null
        echo -e "${SUCCESS_SYMBOL} Dev port $port -> ${YELLOW}localhost:$local_dev_port${PLAIN}"
      done
      echo -e "${SUCCESS_SYMBOL} Development preset complete!"
      ;;
    4) # Security Tools
      echo -e "${INFO_SYMBOL} Setting up security tools..."
      local ssh_port=$(find_available_port 2200 2299)
      local rdp_port=$(find_available_port 3300 3399)
      local vnc_port=$(find_available_port 5900 5999)
      "$0" add --engine "$ENGINE" --proto "tcp" --listen ":$ssh_port" --target "$target_ip:22" --name "preset-security-ssh-$ssh_port" 2>/dev/null
      "$0" add --engine "$ENGINE" --proto "tcp" --listen ":$rdp_port" --target "$target_ip:3389" --name "preset-security-rdp-$rdp_port" 2>/dev/null
      "$0" add --engine "$ENGINE" --proto "tcp" --listen ":$vnc_port" --target "$target_ip:5901" --name "preset-security-vnc-$vnc_port" 2>/dev/null
      echo -e "${SUCCESS_SYMBOL} Security suite preset created!"
      echo -e "${INFO_SYMBOL} SSH: ${YELLOW}localhost:$ssh_port${PLAIN} -> $target_ip:22"
      echo -e "${INFO_SYMBOL} RDP: ${YELLOW}localhost:$rdp_port${PLAIN} -> $target_ip:3389"
      echo -e "${INFO_SYMBOL} VNC: ${YELLOW}localhost:$vnc_port${PLAIN} -> $target_ip:5901"
      ;;
    5) # DNS + Web Combo
      echo -e "${INFO_SYMBOL} Setting up DNS + Web combo..."
      local dns_port=$(find_available_port 10053 15053)
      local web_port=$(find_available_port 8000 8099)
      "$0" add --engine "$ENGINE" --proto "both" --listen ":$dns_port" --target "1.1.1.1:53" --name "preset-combo-dns-$dns_port" 2>/dev/null
      "$0" add --engine "$ENGINE" --proto "tcp" --listen ":$web_port" --target "$target_ip:80" --name "preset-combo-web-$web_port" 2>/dev/null
      echo -e "${SUCCESS_SYMBOL} DNS + Web combo preset created!"
      echo -e "${INFO_SYMBOL} DNS: ${YELLOW}localhost:$dns_port${PLAIN} (Cloudflare)"
      echo -e "${INFO_SYMBOL} Web: ${YELLOW}localhost:$web_port${PLAIN} -> $target_ip:80"
      ;;
    *) 
      echo -e "${WARN_SYMBOL} Invalid selection"
      ;;
  esac
  
  read -n1 -r -p "Press any key to continue..."
}
