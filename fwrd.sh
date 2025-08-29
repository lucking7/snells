#!/bin/bash

# 统一端口转发管理脚本 (FWRD)
# 支持引擎：GOST、Realm（可扩展）
# 功能：安装/升级、添加规则、列表、删除、服务管理、卸载
# 注意：实际服务配置与测试应在远程Linux测试服务器执行

set -o errexit
set -o nounset
set -o pipefail

# 颜色与符号
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

# 提权
if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
else
  SUDO="sudo"
fi

SERVICE_DIR="/etc/systemd/system"

# GOST 路径
GOST_CONFIG_DIR="/etc/gost"
GOST_CONFIG_FILE="${GOST_CONFIG_DIR}/config.json"

# Realm 路径
REALM_DIR="/root/realm"
REALM_CONFIG_DIR="/root/.realm"
REALM_CONFIG_FILE="${REALM_CONFIG_DIR}/config.toml"

# 通用工具
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
  printf "${SUCCESS_SYMBOL}${GREEN}%s${PLAIN}\n" "[OK]"
}

require_cmd() {
  if ! command -v "$1" &>/dev/null; then
    printf "${ERROR_SYMBOL} 缺少命令: %s，请先安装。${PLAIN}\n" "$1"
    return 1
  fi
}

pkg_manager=""
detect_pkg_manager() {
  if command -v apt-get &>/dev/null; then pkg_manager="apt-get"; return 0; fi
  if command -v dnf &>/dev/null; then pkg_manager="dnf"; return 0; fi
  if command -v yum &>/dev/null; then pkg_manager="yum"; return 0; fi
  if command -v brew &>/dev/null; then pkg_manager="brew"; return 0; fi
  pkg_manager=""
  return 1
}

install_pkgs() {
  local pkgs=("$@")
  if [ ${#pkgs[@]} -eq 0 ]; then return 0; fi
  if ! detect_pkg_manager; then
    printf "${WARN_SYMBOL} 未找到包管理器，请手动安装: %s${PLAIN}\n" "${pkgs[*]}"
    return 1
  fi
  
  case "$pkg_manager" in
    "apt-get")
      $SUDO apt-get update -y || true
      $SUDO "$pkg_manager" install -y "${pkgs[@]}"
      ;;
    "brew")
      # macOS 上使用 brew，通常不需要 sudo
      brew install "${pkgs[@]}" || true
      ;;
    *)
      $SUDO "$pkg_manager" install -y "${pkgs[@]}"
      ;;
  esac
}

detect_os() {
  if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    OS_TYPE="linux"
  elif [[ "$OSTYPE" == "darwin"* ]]; then
    OS_TYPE="macos"
  else
    OS_TYPE="unknown"
  fi
}

ensure_base_deps() {
  detect_os
  local need=(curl tar sed awk grep)
  local optional=()
  
  # 根据操作系统添加不同的依赖
  if [ "$OS_TYPE" = "linux" ]; then
    need+=(systemctl realpath)
    optional+=(jq lsof wget)
  elif [ "$OS_TYPE" = "macos" ]; then
    optional+=(jq lsof wget)
  fi
  
  # 检查必需工具
  local critical_miss=()
  for c in "${need[@]}"; do 
    command -v "$c" &>/dev/null || critical_miss+=("$c")
  done
  
  # 检查可选工具
  local optional_miss=()
  for c in "${optional[@]}"; do 
    command -v "$c" &>/dev/null || optional_miss+=("$c")
  done
  
  # 安装缺失的工具
  if [ ${#critical_miss[@]} -gt 0 ] || [ ${#optional_miss[@]} -gt 0 ]; then
    local all_miss=("${critical_miss[@]}" "${optional_miss[@]}")
    printf "${INFO_SYMBOL} 检测到缺失工具: %s${PLAIN}\n" "${all_miss[*]}"
    
    if detect_pkg_manager; then
      printf "${INFO_SYMBOL} 尝试使用 %s 自动安装...${PLAIN}\n" "$pkg_manager"
      install_pkgs "${all_miss[@]}" || true
    else
      printf "${WARN_SYMBOL} 无可用包管理器，请手动安装缺失工具${PLAIN}\n"
    fi
  fi
  
  # 最终检查关键工具
  for c in "${need[@]}"; do 
    if ! command -v "$c" &>/dev/null; then
      printf "${ERROR_SYMBOL} 关键工具仍然缺失: %s${PLAIN}\n" "$c"
      if [ "$OS_TYPE" = "macos" ] && [ "$c" = "systemctl" ]; then
        printf "${WARN_SYMBOL} macOS 上 systemctl 不可用，服务管理功能将被禁用${PLAIN}\n"
        continue
      fi
      return 1
    fi
  done
  
  printf "${SUCCESS_SYMBOL} 依赖检查完成${PLAIN}\n"
}

validate_port() {
  local p=$1
  [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -ge 1 ] && [ "$p" -le 65535 ]
}

validate_host() {
  local h=$1
  # IPv4 / IPv6(粗略) / 主机名
  [[ "$h" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && return 0
  [[ "$h" =~ : ]] && return 0
  [[ "$h" =~ ^[A-Za-z0-9._-]+$ ]] && return 0
  return 1
}

find_free_port() {
  local min=${1:-10000}
  local max=${2:-65000}
  if command -v shuf &>/dev/null; then
    while true; do
      local port; port=$(shuf -i ${min}-${max} -n 1)
      if ! lsof -iTCP:"$port" -sTCP:LISTEN -P -n >/dev/null 2>&1; then echo "$port"; return 0; fi
    done
  else
    while true; do
      local port=$(( min + RANDOM % (max - min + 1) ))
      if ! lsof -iTCP:"$port" -sTCP:LISTEN -P -n >/dev/null 2>&1; then echo "$port"; return 0; fi
    done
  fi
}

pause_any() { read -n1 -r -p "按任意键继续..."; echo; }

# 获取公网IP信息
get_public_ip() {
  local ipv4="" ipv6="" country="" isp=""
  
  # 获取 IPv4 地址 (多种方式，容错处理)
  for method in dig_opendns dig_google api_ipify api_httpbin; do
    case $method in
      "dig_opendns")
        if command -v dig &>/dev/null; then
          ipv4=$(timeout 3 dig +short myip.opendns.com @resolver1.opendns.com 2>/dev/null | grep -E '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$' | head -1 || true)
        fi
        ;;
      "dig_google")
        if command -v dig &>/dev/null && [ -z "$ipv4" ]; then
          ipv4=$(timeout 3 dig +short txt ch whoami.cloudflare @1.1.1.1 2>/dev/null | tr -d '"' | grep -E '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$' | head -1 || true)
        fi
        ;;
      "api_ipify")
        if [ -z "$ipv4" ] && command -v curl &>/dev/null; then
          ipv4=$(timeout 3 curl -s4 --max-time 3 https://api.ipify.org 2>/dev/null | grep -E '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$' || true)
        fi
        ;;
      "api_httpbin")
        if [ -z "$ipv4" ] && command -v curl &>/dev/null; then
          ipv4=$(timeout 3 curl -s4 --max-time 3 https://httpbin.org/ip 2>/dev/null | grep -o '"origin":"[^"]*' | cut -d'"' -f4 | grep -E '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$' || true)
        fi
        ;;
    esac
    [ -n "$ipv4" ] && break
  done
  
  # 获取 IPv6 地址 (多种方式，容错处理)
  for method in dig_google api_ipify api_httpbin; do
    case $method in
      "dig_google")
        if command -v dig &>/dev/null; then
          ipv6=$(timeout 3 dig +short -6 TXT ch whoami.cloudflare @2606:4700:4700::1111 2>/dev/null | tr -d '"' | grep -E '^[0-9a-fA-F:]+$' | head -1 || true)
        fi
        ;;
      "api_ipify")
        if [ -z "$ipv6" ] && command -v curl &>/dev/null; then
          ipv6=$(timeout 3 curl -s6 --max-time 3 https://api6.ipify.org 2>/dev/null | grep -E '^[0-9a-fA-F:]+$' || true)
        fi
        ;;
      "api_httpbin")
        if [ -z "$ipv6" ] && command -v curl &>/dev/null; then
          ipv6=$(timeout 3 curl -s6 --max-time 3 https://httpbin.org/ip 2>/dev/null | grep -o '"origin":"[^"]*' | cut -d'"' -f4 | grep -E '^[0-9a-fA-F:]+$' || true)
        fi
        ;;
    esac
    [ -n "$ipv6" ] && break
  done
  
  # 获取地理位置信息 (基于IPv4，容错处理)
  if [ -n "$ipv4" ] && command -v curl &>/dev/null; then
    local geo_info
    # 尝试 ipapi.co
    geo_info=$(timeout 3 curl -s --max-time 3 "https://ipapi.co/${ipv4}/json/" 2>/dev/null || true)
    if [ -n "$geo_info" ]; then
      country=$(echo "$geo_info" | grep -o '"country_name":"[^"]*' | cut -d'"' -f4 | head -1 || true)
      isp=$(echo "$geo_info" | grep -o '"org":"[^"]*' | cut -d'"' -f4 | head -1 || true)
    fi
    
    # 备用: ip-api.com
    if [ -z "$country" ]; then
      geo_info=$(timeout 3 curl -s --max-time 3 "http://ip-api.com/json/${ipv4}?fields=country,isp" 2>/dev/null || true)
      if [ -n "$geo_info" ]; then
        country=$(echo "$geo_info" | grep -o '"country":"[^"]*' | cut -d'"' -f4 | head -1 || true)
        isp=$(echo "$geo_info" | grep -o '"isp":"[^"]*' | cut -d'"' -f4 | head -1 || true)
      fi
    fi
  fi
  
  # 设置默认值
  [ -z "$ipv4" ] && ipv4="N/A"
  [ -z "$ipv6" ] && ipv6="N/A"  
  [ -z "$country" ] && country="N/A"
  [ -z "$isp" ] && isp="N/A"
  
  # 导出变量供其他函数使用
  PUBLIC_IPV4="$ipv4"
  PUBLIC_IPV6="$ipv6"
  PUBLIC_COUNTRY="$country"
  PUBLIC_ISP="$isp"
}
# 依赖初始化
ensure_base_deps

# -------------------- GOST 引擎 --------------------
ensure_gost_layout() {
  if [ ! -d "$GOST_CONFIG_DIR" ]; then
    $SUDO mkdir -p "$GOST_CONFIG_DIR"
    $SUDO chmod 755 "$GOST_CONFIG_DIR"
  fi
  if [ ! -f "$GOST_CONFIG_FILE" ]; then
    echo '{"services":[]}' | $SUDO tee "$GOST_CONFIG_FILE" >/dev/null
    $SUDO chmod 644 "$GOST_CONFIG_FILE"
  fi
}

install_gost() {
  if command -v gost &>/dev/null; then
    printf "${SUCCESS_SYMBOL} 已检测到gost${PLAIN}\n"; return 0; fi
  
  printf "${INFO_SYMBOL} 安装gost...${PLAIN}\n"
  
  if [ "$OS_TYPE" = "macos" ]; then
    printf "${WARN_SYMBOL} macOS 环境检测到，跳过 gost 安装${PLAIN}\n"
    printf "${INFO_SYMBOL} 在 macOS 上请手动安装: brew install gost 或从 GitHub 下载${PLAIN}\n"
    return 0
  fi
  
  if command -v curl &>/dev/null; then
    # 检查是否有足够权限
    if [ "$(id -u)" -ne 0 ] && [ -z "$SUDO" ]; then
      printf "${ERROR_SYMBOL} 安装 gost 需要 root 权限${PLAIN}\n"
      return 1
    fi
    
    (bash <(curl -fsSL https://github.com/go-gost/gost/raw/master/install.sh) --install) &
    show_loading $!
  else
    printf "${ERROR_SYMBOL} 缺少 curl，无法下载 gost${PLAIN}\n"
    return 1
  fi
  
  if ! command -v gost &>/dev/null; then
    printf "${ERROR_SYMBOL} gost安装失败，请手动安装。${PLAIN}\n"; return 1; fi
  printf "${SUCCESS_SYMBOL} gost安装完成${PLAIN}\n"
}

apply_gost_config() {
  ensure_gost_layout
  if ! command -v gost &>/dev/null; then install_gost || return 1; fi
  
  if [ "$OS_TYPE" = "macos" ]; then
    printf "${WARN_SYMBOL} macOS 环境，跳过 systemd 服务创建${PLAIN}\n"
    printf "${INFO_SYMBOL} 配置已更新到: %s${PLAIN}\n" "$GOST_CONFIG_FILE"
    printf "${INFO_SYMBOL} 手动启动: gost -C \"%s\"${PLAIN}\n" "$GOST_CONFIG_FILE"
    return 0
  fi
  
  # Linux 环境创建 systemd 服务
  local abs
  if command -v realpath &>/dev/null; then
    abs=$(realpath "$GOST_CONFIG_FILE")
  else
    abs="$GOST_CONFIG_FILE"
  fi
  
  local svc="${SERVICE_DIR}/gost.service"
  local content="[Unit]\nDescription=GOST Proxy Service\nAfter=network.target\nWants=network.target\n\n[Service]\nExecStart=/usr/local/bin/gost -C \"$abs\"\nRestart=always\nRestartSec=5\nUser=gost\nGroup=gost\nNoNewPrivileges=true\nPrivateTmp=true\nProtectSystem=strict\nProtectHome=true\nLimitNOFILE=infinity\nCapabilityBoundingSet=CAP_NET_BIND_SERVICE\n\n[Install]\nWantedBy=multi-user.target\n"
  
  # 确保用户
  if ! id gost &>/dev/null; then $SUDO useradd --system --no-create-home --shell /bin/false gost || true; fi
  echo -e "$content" | $SUDO tee "$svc" >/dev/null
  $SUDO systemctl daemon-reload
  $SUDO systemctl enable gost >/dev/null 2>&1 || true
  if $SUDO systemctl restart gost; then
    printf "${SUCCESS_SYMBOL} gost.service 已启动${PLAIN}\n"
  else
    printf "${ERROR_SYMBOL} gost.service 启动失败${PLAIN}\n"
    $SUDO journalctl -u gost --no-pager -n 20 || true
    return 1
  fi
}

add_gost_rule() {
  ensure_gost_layout
  printf "${INFO_SYMBOL} 选择协议: 1) TCP 2) UDP 3) 同时 (默认3): ${PLAIN}"; read -r psel; psel=${psel:-3}
  local proto="tcp-udp"; case $psel in 1) proto="tcp";; 2) proto="udp";; esac
  printf "${INFO_SYMBOL} 本地端口(留空随机): ${PLAIN}"; read -r lp
  if [ -z "$lp" ]; then lp=$(find_free_port); printf "${INFO_SYMBOL} 选择端口: %s${PLAIN}\n" "$lp"; fi
  validate_port "$lp" || { printf "${ERROR_SYMBOL} 端口无效${PLAIN}\n"; return 1; }
  printf "${INFO_SYMBOL} 目标IP/域名: ${PLAIN}"; read -r rip; validate_host "$rip" || { printf "${ERROR_SYMBOL} 地址无效${PLAIN}\n"; return 1; }
  printf "${INFO_SYMBOL} 目标端口: ${PLAIN}"; read -r rp; validate_port "$rp" || { printf "${ERROR_SYMBOL} 端口无效${PLAIN}\n"; return 1; }
  if [[ $rip == *:* ]] && [[ $rip != \[*\]* ]]; then rip="[$rip]"; fi
  local listen=":$lp" target="${rip}:${rp}"
  local name_base="fwrd-${lp}-to-${rp}"; local nodes_json="[{\"name\":\"target-0\",\"addr\":\"$target\"}]"
  local tmp=$(mktemp)
  if [ "$proto" = "tcp-udp" ]; then
    local tcpn="${name_base}-tcp"; local udpn="${name_base}-udp"
    jq --arg tn "$tcpn" --arg un "$udpn" --arg a "$listen" --arg n0 "$target" \
      '.services += [
        {name:$tn, addr:$a, handler:{type:"tcp"}, listener:{type:"tcp"}, forwarder:{nodes:[{name:"target-0", addr:$n0}]}},
        {name:$un, addr:$a, handler:{type:"udp"}, listener:{type:"udp"}, forwarder:{nodes:[{name:"target-0", addr:$n0}]}}
      ]' "$GOST_CONFIG_FILE" > "$tmp"
  else
    jq --arg sn "${name_base}-${proto}" --arg a "$listen" --arg p "$proto" --arg n0 "$target" \
      '.services += [{name:$sn, addr:$a, handler:{type:$p}, listener:{type:$p}, forwarder:{nodes:[{name:"target-0", addr:$n0}]}}]' \
      "$GOST_CONFIG_FILE" > "$tmp"
  fi
  jq empty "$tmp" >/dev/null 2>&1 || { printf "${ERROR_SYMBOL} JSON生成失败${PLAIN}\n"; rm -f "$tmp"; return 1; }
  $SUDO mv "$tmp" "$GOST_CONFIG_FILE"; $SUDO chmod 644 "$GOST_CONFIG_FILE"
  apply_gost_config
}

list_gost_rules() {
  if [ ! -f "$GOST_CONFIG_FILE" ]; then printf "${WARN_SYMBOL} 无gost配置${PLAIN}\n"; return; fi
  printf "${BLUE}GOST 规则：${PLAIN}\n"
  jq -r '.services[] | select(.forwarder!=null) | [.name,.addr, (.forwarder.nodes[0].addr//""), (.handler.type//"")] | @tsv' "$GOST_CONFIG_FILE" 2>/dev/null \
    | awk 'BEGIN{FS="\t"; printf "%-3s %-35s %-18s %-24s %-6s\n","#","Name","Listen","Target","Proto"; print "--------------------------------------------------------------------------------"} {printf "%-3d %-35s %-18s %-24s %-6s\n", NR,$1,$2,$3,$4}'
}

delete_gost_rule() {
  if [ ! -f "$GOST_CONFIG_FILE" ]; then printf "${WARN_SYMBOL} 无gost配置${PLAIN}\n"; return; fi
  mapfile -t L < <(jq -r '.services[] | select(.forwarder!=null) | .name' "$GOST_CONFIG_FILE")
  if [ ${#L[@]} -eq 0 ]; then printf "${WARN_SYMBOL} 没有规则${PLAIN}\n"; return; fi
  for i in "${!L[@]}"; do printf "%d) %s\n" "$((i+1))" "${L[$i]}"; done
  printf "选择删除编号: "; read -r idx
  [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -ge 1 ] && [ "$idx" -le ${#L[@]} ] || { printf "${ERROR_SYMBOL} 无效选择${PLAIN}\n"; return; }
  local name="${L[$((idx-1))]}"
  local tmp=$(mktemp)
  jq --arg n "$name" '.services = [.services[] | select(.name!=$n)]' "$GOST_CONFIG_FILE" > "$tmp" || { rm -f "$tmp"; printf "${ERROR_SYMBOL} 更新失败${PLAIN}\n"; return; }
  $SUDO mv "$tmp" "$GOST_CONFIG_FILE"
  apply_gost_config
}
# -------------------- Realm 引擎 --------------------
ensure_realm_layout() {
  $SUDO mkdir -p "$REALM_DIR" "$REALM_CONFIG_DIR"
  if [ ! -f "$REALM_CONFIG_FILE" ]; then
    cat <<EOF | $SUDO tee "$REALM_CONFIG_FILE" >/dev/null
[network]
no_tcp = false
use_udp = true
ipv6_only = false
EOF
  fi
}

install_realm() {
  if [ -x "${REALM_DIR}/realm" ]; then printf "${SUCCESS_SYMBOL} 已检测到realm${PLAIN}\n"; return 0; fi
  printf "${INFO_SYMBOL} 安装realm...${PLAIN}\n"
  
  if [ "$OS_TYPE" = "macos" ]; then
    printf "${WARN_SYMBOL} macOS 环境检测到，跳过 realm 安装${PLAIN}\n"
    printf "${INFO_SYMBOL} 在 macOS 上请手动安装: brew install realm 或从 GitHub 下载${PLAIN}\n"
    return 0
  fi
  
  local api; api=$(curl -s https://api.github.com/repos/zhboner/realm/releases/latest || true)
  local ver; ver=$(echo "$api" | grep -o '"tag_name": *"[^"]*' | sed 's/.*"\(.*\)"/\1/' | head -1)
  [ -z "$ver" ] && ver="v2.6.2"
  local arch=$(uname -m); local os=$(uname -s | tr '[:upper:]' '[:lower:]')
  local url=""
  case "$arch-$os" in
    x86_64-linux) url="https://github.com/zhboner/realm/releases/download/${ver}/realm-x86_64-unknown-linux-gnu.tar.gz";;
    aarch64-linux) url="https://github.com/zhboner/realm/releases/download/${ver}/realm-aarch64-unknown-linux-gnu.tar.gz";;
    armv7l-linux|arm-linux) url="https://github.com/zhboner/realm/releases/download/${ver}/realm-arm-unknown-linux-gnueabi.tar.gz";;
    x86_64-darwin) url="https://github.com/zhboner/realm/releases/download/${ver}/realm-x86_64-apple-darwin.tar.gz";;
    *) url="https://github.com/zhboner/realm/releases/download/${ver}/realm-x86_64-unknown-linux-gnu.tar.gz";;
  esac
  
  if ! command -v wget &>/dev/null; then
    printf "${ERROR_SYMBOL} 缺少 wget，无法下载 realm${PLAIN}\n"
    return 1
  fi
  
  (cd "$REALM_DIR" && wget -qO realm.tar.gz "$url" && tar -xzf realm.tar.gz && chmod +x realm && rm -f realm.tar.gz) &
  show_loading $!
  [ -x "${REALM_DIR}/realm" ] || { printf "${ERROR_SYMBOL} realm安装失败${PLAIN}\n"; return 1; }
  
  # 只在 Linux 上创建 systemd 服务
  if [ "$OS_TYPE" = "linux" ]; then
    if ! id realm &>/dev/null; then $SUDO useradd --system --no-create-home --shell /bin/false realm || true; fi
    cat <<EOF | $SUDO tee "${SERVICE_DIR}/realm.service" >/dev/null
[Unit]
Description=Realm Service
After=network-online.target
Wants=network-online.target systemd-networkd-wait-online.service

[Service]
Type=simple
User=realm
Group=realm
Restart=on-failure
RestartSec=5s
WorkingDirectory=${REALM_DIR}
ExecStart=${REALM_DIR}/realm -c ${REALM_CONFIG_FILE}
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
    $SUDO systemctl enable realm >/dev/null 2>&1 || true
    $SUDO systemctl restart realm || true
  else
    printf "${INFO_SYMBOL} 非 Linux 环境，跳过 systemd 服务创建${PLAIN}\n"
    printf "${INFO_SYMBOL} 手动启动: %s/realm -c %s${PLAIN}\n" "$REALM_DIR" "$REALM_CONFIG_FILE"
  fi
}

add_realm_rule() {
  ensure_realm_layout; install_realm || true
  printf "${INFO_SYMBOL} 选择协议: 1) TCP 2) UDP 3) 同时 (默认3): ${PLAIN}"; read -r psel; psel=${psel:-3}
  local use_tcp=true use_udp=true
  case $psel in 1) use_udp=false;; 2) use_tcp=false;; esac
  printf "${INFO_SYMBOL} 本地端口(留空随机): ${PLAIN}"; read -r lp
  if [ -z "$lp" ]; then lp=$(find_free_port); printf "${INFO_SYMBOL} 选择端口: %s${PLAIN}\n" "$lp"; fi
  validate_port "$lp" || { printf "${ERROR_SYMBOL} 端口无效${PLAIN}\n"; return 1; }
  printf "${INFO_SYMBOL} 监听地址版本: 1) IPv4(0.0.0.0) 2) IPv6([::]) (默认1): ${PLAIN}"; read -r ipver; ipver=${ipver:-1}
  local listen="0.0.0.0"; [ "$ipver" = "2" ] && listen="[::]"
  printf "${INFO_SYMBOL} 目标IP/域名: ${PLAIN}"; read -r rip; validate_host "$rip" || { printf "${ERROR_SYMBOL} 地址无效${PLAIN}\n"; return 1; }
  printf "${INFO_SYMBOL} 目标端口: ${PLAIN}"; read -r rp; validate_port "$rp" || { printf "${ERROR_SYMBOL} 端口无效${PLAIN}\n"; return 1; }
  local remark
  printf "${INFO_SYMBOL} 备注(可选): ${PLAIN}"; read -r remark; remark=${remark:-"Forward"}
  cat <<EOF | $SUDO tee -a "$REALM_CONFIG_FILE" >/dev/null

[[endpoints]]
# Remark: $remark
listen = "${listen}:${lp}"
remote = "${rip}:${rp}"
use_tcp = ${use_tcp}
use_udp = ${use_udp}
EOF
  if [ "$OS_TYPE" = "linux" ] && command -v systemctl &>/dev/null; then
    $SUDO systemctl restart realm || true
    printf "${SUCCESS_SYMBOL} 已添加Realm规则并重启服务${PLAIN}\n"
  else
    printf "${SUCCESS_SYMBOL} 已添加Realm规则${PLAIN}\n"
    printf "${INFO_SYMBOL} 手动重启: %s/realm -c %s${PLAIN}\n" "$REALM_DIR" "$REALM_CONFIG_FILE"
  fi
}

list_realm_rules() {
  if [ ! -f "$REALM_CONFIG_FILE" ]; then printf "${WARN_SYMBOL} 无realm配置${PLAIN}\n"; return; fi
  printf "${BLUE}Realm 规则：${PLAIN}\n"
  awk '
    BEGIN{idx=0; in=0; printf "%-3s %-18s %-24s %-6s %-6s\n","#","Listen","Remote","TCP","UDP"; print "-----------------------------------------------------------"}
    /^\[\[endpoints\]\]/{in=1; l=""; r=""; t=""; u=""; next}
    in && /^listen *=/{l=$0; sub(/.*= *"/,"",l); sub(/"/ ,"",l)}
    in && /^remote *=/{r=$0; sub(/.*= *"/,"",r); sub(/"/ ,"",r)}
    in && /^use_tcp *=/{t=$0; sub(/.*= */,"",t)}
    in && /^use_udp *=/{u=$0; sub(/.*= */,"",u); idx++; printf "%-3d %-18s %-24s %-6s %-6s\n",idx,l,r,t,u; in=0}
  ' "$REALM_CONFIG_FILE"
}

delete_realm_rule() {
  if [ ! -f "$REALM_CONFIG_FILE" ]; then printf "${WARN_SYMBOL} 无realm配置${PLAIN}\n"; return; fi
  # 生成块索引
  mapfile -t starts < <(nl -ba "$REALM_CONFIG_FILE" | grep "\[\[endpoints\]\]" | awk '{print $1}')
  if [ ${#starts[@]} -eq 0 ]; then printf "${WARN_SYMBOL} 无规则${PLAIN}\n"; return; fi
  # 粗略列出
  list_realm_rules
  printf "选择删除编号: "; read -r idx
  [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -ge 1 ] && [ "$idx" -le ${#starts[@]} ] || { printf "${ERROR_SYMBOL} 无效选择${PLAIN}\n"; return; }
  local s=${starts[$((idx-1))]}
  # 查找下一个块或文件末尾
  local e; e=$(nl -ba "$REALM_CONFIG_FILE" | awk -v S=$s 'NR>S && /\[\[endpoints\]\]/{print $1; exit}')
  if [ -z "$e" ]; then e=$(wc -l < "$REALM_CONFIG_FILE"); fi
  $SUDO sed -i "${s},${e}d" "$REALM_CONFIG_FILE"
  $SUDO systemctl restart realm || true
  printf "${SUCCESS_SYMBOL} 已删除Realm规则并重启服务${PLAIN}\n"
}
# -------------------- 统一菜单与卸载 --------------------
install_or_update_menu() {
  printf "\n${BOLD}${BLUE}=== 安装/升级 引擎 ===${PLAIN}\n"
  printf "  1) 安装/升级 GOST\n"
  printf "  2) 安装/升级 Realm\n"
  printf "  0) 返回\n"
  printf "选择: "; read -r c
  case $c in
    1) ensure_gost_layout; install_gost; pause_any ;;
    2) ensure_realm_layout; install_realm; pause_any ;;
    0) return ;;
    *) printf "${WARN_SYMBOL} 无效选择${PLAIN}\n"; pause_any ;;
  esac
}

# 统一规则列表显示
list_all_rules() {
  printf "\n${BOLD}${BLUE}=== 所有转发规则 ===${PLAIN}\n"
  printf "%-3s %-8s %-35s %-18s %-24s %-8s %-10s\n" "#" "引擎" "名称/备注" "监听地址" "目标地址" "协议" "状态"
  printf "%s\n" "----------------------------------------------------------------------------------------"
  
  local count=0
  
  # 显示 GOST 规则
  if [ -f "$GOST_CONFIG_FILE" ]; then
    while IFS="|" read -r name listen_addr target_addr proto; do
      if [ -n "$name" ]; then
        count=$((count + 1))
        local status="未知"
        if [ "$OS_TYPE" = "linux" ] && command -v systemctl &>/dev/null; then
          if systemctl is-active --quiet gost 2>/dev/null; then
            status="${GREEN}运行中${PLAIN}"
          else
            status="${RED}已停止${PLAIN}"
          fi
        else
          status="${YELLOW}手动${PLAIN}"
        fi
        printf "%-3s %-8s %-35s %-18s %-24s %-8s %b\n" "$count" "GOST" "$name" "$listen_addr" "$target_addr" "$proto" "$status"
      fi
    done < <(jq -r '.services[] | select(.forwarder!=null) | [.name,.addr, (.forwarder.nodes[0].addr//""), (.handler.type//"")] | @tsv' "$GOST_CONFIG_FILE" 2>/dev/null | tr '\t' '|')
  fi
  
  # 显示 Realm 规则
  if [ -f "$REALM_CONFIG_FILE" ]; then
    local realm_count=0
    while read -r line; do
      if [[ "$line" =~ ^\[\[endpoints\]\] ]]; then
        realm_count=$((realm_count + 1))
        count=$((count + 1))
        local status="未知"
        if [ "$OS_TYPE" = "linux" ] && command -v systemctl &>/dev/null; then
          if systemctl is-active --quiet realm 2>/dev/null; then
            status="${GREEN}运行中${PLAIN}"
          else
            status="${RED}已停止${PLAIN}"
          fi
        else
          status="${YELLOW}手动${PLAIN}"
        fi
        printf "%-3s %-8s %-35s %-18s %-24s %-8s %b\n" "$count" "Realm" "规则-$realm_count" "..." "..." "..." "$status"
      fi
    done < "$REALM_CONFIG_FILE"
  fi
  
  if [ $count -eq 0 ]; then
    printf "${WARN_SYMBOL} 没有找到转发规则${PLAIN}\n"
  else
    printf "\n${INFO_SYMBOL} 共 ${BLUE}%d${PLAIN} 条规则\n" "$count"
  fi
}

# 统一规则删除
delete_any_rule() {
  list_all_rules
  if [ "$(count_total_rules)" -eq 0 ]; then return; fi
  
  printf "\n${INFO_SYMBOL} 选择要删除的规则:\n"
  printf "  ${YELLOW}g) 删除 GOST 规则${PLAIN}\n"
  printf "  ${YELLOW}r) 删除 Realm 规则${PLAIN}\n"
  printf "  0) 返回\n"
  printf "选择: "; read -r engine_choice
  
  case $engine_choice in
    g|G) delete_gost_rule ;;
    r|R) delete_realm_rule ;;
    0) return ;;
    *) printf "${WARN_SYMBOL} 无效选择${PLAIN}\n" ;;
  esac
}

# 统计总规则数
count_total_rules() {
  local total=0
  if [ -f "$GOST_CONFIG_FILE" ]; then
    local gost_count=$(jq -r '.services[] | select(.forwarder!=null) | .name' "$GOST_CONFIG_FILE" 2>/dev/null | wc -l)
    total=$((total + gost_count))
  fi
  if [ -f "$REALM_CONFIG_FILE" ]; then
    local realm_count=$(grep -c '^\[\[endpoints\]\]' "$REALM_CONFIG_FILE" 2>/dev/null || echo 0)
    total=$((total + realm_count))
  fi
  echo $total
}

# 新建规则选择引擎
add_new_rule() {
  printf "\n${BOLD}${BLUE}=== 新建转发规则 ===${PLAIN}\n"
  printf "请选择转发引擎:\n"
  printf "  ${GREEN}1) GOST${PLAIN} - 功能丰富，支持多种协议和端口范围\n"
  printf "  ${GREEN}2) Realm${PLAIN} - 轻量高效，支持 TCP/UDP 分离转发\n"
  printf "  0) 返回\n"
  printf "选择: "; read -r engine_choice
  
  case $engine_choice in
    1) add_gost_rule ;;
    2) add_realm_rule ;;
    0) return ;;
    *) printf "${WARN_SYMBOL} 无效选择${PLAIN}\n"; pause_any ;;
  esac
}

engine_rule_menu() {
  while true; do
    printf "\n${BOLD}${BLUE}=== 规则管理 ===${PLAIN}\n"
    printf "  ${GREEN}1) 新建规则${PLAIN}\n"
    printf "  ${BLUE}2) 列出所有规则${PLAIN}\n"
    printf "  ${YELLOW}3) 删除规则${PLAIN}\n"
    printf "  ${BLUE}4) 列出 GOST 规则${PLAIN}\n"
    printf "  ${BLUE}5) 列出 Realm 规则${PLAIN}\n"
    printf "  0) 返回\n"
    printf "选择: "; read -r c
    case $c in
      1) add_new_rule; pause_any ;;
      2) list_all_rules; pause_any ;;
      3) delete_any_rule; pause_any ;;
      4) list_gost_rules; pause_any ;;
      5) list_realm_rules; pause_any ;;
      0) return ;;
      *) printf "${WARN_SYMBOL} 无效选择${PLAIN}\n"; pause_any ;;
    esac
  done
}

service_menu() {
  detect_os
  printf "\n${BOLD}${BLUE}=== 服务管理 ===${PLAIN}\n"
  
  if [ "$OS_TYPE" = "linux" ] && command -v systemctl &>/dev/null; then
    printf "  1) 启动 gost.service\n"
    printf "  2) 停止 gost.service\n"
    printf "  3) 重启 gost.service\n"
    printf "  4) 查看 gost 日志\n"
    printf "  5) 启动 realm.service\n"
    printf "  6) 停止 realm.service\n"
    printf "  7) 重启 realm.service\n"
    printf "  8) 查看 realm 日志\n"
  else
    printf "  ${YELLOW}1) 手动启动 GOST${PLAIN}\n"
    printf "  ${YELLOW}2) 查看 GOST 配置${PLAIN}\n"
    printf "  ${YELLOW}3) 手动启动 Realm${PLAIN}\n"
    printf "  ${YELLOW}4) 查看 Realm 配置${PLAIN}\n"
  fi
  printf "  0) 返回\n"
  printf "选择: "; read -r c
  
  if [ "$OS_TYPE" = "linux" ] && command -v systemctl &>/dev/null; then
    case $c in
      1) $SUDO systemctl start gost || true; ;;
      2) $SUDO systemctl stop gost || true; ;;
      3) $SUDO systemctl restart gost || true; ;;
      4) $SUDO journalctl -u gost --no-pager -n 50 || true; ;;
      5) $SUDO systemctl start realm || true; ;;
      6) $SUDO systemctl stop realm || true; ;;
      7) $SUDO systemctl restart realm || true; ;;
      8) $SUDO journalctl -u realm --no-pager -n 50 || true; ;;
      0) return ;;
      *) printf "${WARN_SYMBOL} 无效选择${PLAIN}\n" ;;
    esac
  else
    case $c in
      1) 
        if [ -f "$GOST_CONFIG_FILE" ]; then
          printf "${INFO_SYMBOL} 启动命令: gost -C \"%s\"${PLAIN}\n" "$GOST_CONFIG_FILE"
          if command -v gost &>/dev/null; then
            printf "${INFO_SYMBOL} 后台启动: nohup gost -C \"%s\" > /tmp/gost.log 2>&1 &${PLAIN}\n" "$GOST_CONFIG_FILE"
          else
            printf "${WARN_SYMBOL} gost 未安装${PLAIN}\n"
          fi
        else
          printf "${WARN_SYMBOL} GOST 配置文件不存在${PLAIN}\n"
        fi
        ;;
      2) 
        if [ -f "$GOST_CONFIG_FILE" ]; then
          printf "${INFO_SYMBOL} GOST 配置文件: %s${PLAIN}\n" "$GOST_CONFIG_FILE"
          cat "$GOST_CONFIG_FILE" 2>/dev/null || printf "${WARN_SYMBOL} 无法读取配置文件${PLAIN}\n"
        else
          printf "${WARN_SYMBOL} GOST 配置文件不存在${PLAIN}\n"
        fi
        ;;
      3) 
        if [ -f "$REALM_CONFIG_FILE" ]; then
          printf "${INFO_SYMBOL} 启动命令: %s/realm -c \"%s\"${PLAIN}\n" "$REALM_DIR" "$REALM_CONFIG_FILE"
          if [ -x "${REALM_DIR}/realm" ]; then
            printf "${INFO_SYMBOL} 后台启动: nohup %s/realm -c \"%s\" > /tmp/realm.log 2>&1 &${PLAIN}\n" "$REALM_DIR" "$REALM_CONFIG_FILE"
          else
            printf "${WARN_SYMBOL} realm 未安装${PLAIN}\n"
          fi
        else
          printf "${WARN_SYMBOL} Realm 配置文件不存在${PLAIN}\n"
        fi
        ;;
      4) 
        if [ -f "$REALM_CONFIG_FILE" ]; then
          printf "${INFO_SYMBOL} Realm 配置文件: %s${PLAIN}\n" "$REALM_CONFIG_FILE"
          cat "$REALM_CONFIG_FILE" 2>/dev/null || printf "${WARN_SYMBOL} 无法读取配置文件${PLAIN}\n"
        else
          printf "${WARN_SYMBOL} Realm 配置文件不存在${PLAIN}\n"
        fi
        ;;
      0) return ;;
      *) printf "${WARN_SYMBOL} 无效选择${PLAIN}\n" ;;
    esac
  fi
  pause_any
}

uninstall_menu() {
  printf "\n${BOLD}${BLUE}=== 卸载 ===${PLAIN}\n"
  printf "  1) 卸载 GOST (移除服务与配置)\n"
  printf "  2) 卸载 Realm (移除服务与目录)\n"
  printf "  0) 返回\n"
  printf "选择: "; read -r c
  case $c in
    1)
      $SUDO systemctl stop gost || true
      $SUDO systemctl disable gost || true
      $SUDO rm -f "${SERVICE_DIR}/gost.service" || true
      $SUDO systemctl daemon-reload || true
      $SUDO rm -rf "$GOST_CONFIG_DIR" || true
      if command -v gost &>/dev/null; then $SUDO rm -f "$(command -v gost)" || true; fi
      printf "${SUCCESS_SYMBOL} GOST 已卸载${PLAIN}\n";
      ;;
    2)
      $SUDO systemctl stop realm || true
      $SUDO systemctl disable realm || true
      $SUDO rm -f "${SERVICE_DIR}/realm.service" || true
      $SUDO systemctl daemon-reload || true
      $SUDO rm -rf "$REALM_DIR" "$REALM_CONFIG_DIR" || true
      printf "${SUCCESS_SYMBOL} Realm 已卸载${PLAIN}\n";
      ;;
    0) return ;;
    *) printf "${WARN_SYMBOL} 无效选择${PLAIN}\n" ;;
  esac
  pause_any
}

show_environment_info() {
  detect_os
  
  # 获取公网IP信息 (后台运行，避免阻塞)
  if [ -z "${PUBLIC_IPV4:-}" ]; then
    printf "${INFO_SYMBOL} 正在获取网络信息...\r"
    get_public_ip
    printf "                                \r"  # 清除提示
  fi
  
  printf "\n${BOLD}${BLUE}==== 环境信息 ====${PLAIN}\n"
  printf "操作系统: %s\n" "$OS_TYPE"
  printf "用户权限: %s\n" "$([ "$(id -u)" -eq 0 ] && echo "root" || echo "普通用户")"
  
  # 显示网络信息
  printf "\n${BOLD}网络信息:${PLAIN}\n"
  printf "  IPv4: ${GREEN}%s${PLAIN}\n" "${PUBLIC_IPV4:-N/A}"
  printf "  IPv6: ${GREEN}%s${PLAIN}\n" "${PUBLIC_IPV6:-N/A}"
  if [ "${PUBLIC_COUNTRY:-N/A}" != "N/A" ] || [ "${PUBLIC_ISP:-N/A}" != "N/A" ]; then
    printf "  位置: ${YELLOW}%s${PLAIN}\n" "${PUBLIC_COUNTRY:-N/A}"
    printf "  ISP:  ${YELLOW}%s${PLAIN}\n" "${PUBLIC_ISP:-N/A}"
  fi
  
  if [ "$OS_TYPE" != "linux" ]; then
    printf "\n${WARN_SYMBOL} ${YELLOW}注意: 当前非Linux环境，实际部署请在远程Linux服务器执行${PLAIN}\n"
    printf "${INFO_SYMBOL} 远程测试服务器: ssh -i unit04 root@23.141.4.67${PLAIN}\n"
  fi
  
  # 检查关键工具
  printf "\n工具状态:\n"
  local tools=(curl tar sed awk grep)
  if [ "$OS_TYPE" = "linux" ]; then
    tools+=(systemctl jq lsof wget dig)
  else
    tools+=(jq lsof wget dig)
  fi
  
  local available=0 total=${#tools[@]}
  for tool in "${tools[@]}"; do
    if command -v "$tool" &>/dev/null; then
      printf "  ✓ %s\n" "$tool"
      available=$((available + 1))
    else
      printf "  ✗ %s (缺失)\n" "$tool"
    fi
  done
  
  # 显示工具完整度
  if [ $total -gt 0 ]; then
    local percentage=$((available * 100 / total))
    if [ $percentage -ge 90 ]; then
      printf "\n${SUCCESS_SYMBOL} 工具完整度: ${GREEN}%d%%${PLAIN} (%d/%d)\n" "$percentage" "$available" "$total"
    elif [ $percentage -ge 70 ]; then
      printf "\n${WARN_SYMBOL} 工具完整度: ${YELLOW}%d%%${PLAIN} (%d/%d)\n" "$percentage" "$available" "$total"
    else
      printf "\n${ERROR_SYMBOL} 工具完整度: ${RED}%d%%${PLAIN} (%d/%d)\n" "$percentage" "$available" "$total"
    fi
  fi
}

main_menu() {
  ensure_base_deps
  while true; do
    show_environment_info
    printf "\n${BOLD}${BLUE}==== FWRD 统一转发管理 ====${PLAIN}\n"
    printf "  1) 安装/升级 引擎\n"
    printf "  2) 规则管理 (新增/列表/删除)\n"
    printf "  3) 服务管理\n"
    printf "  4) 卸载\n"
    printf "  ${BLUE}r) 刷新网络信息${PLAIN}\n"
    printf "  0) 退出\n"
    printf "选择: "; read -r c
    case $c in
      1) install_or_update_menu ;;
      2) engine_rule_menu ;;
      3) service_menu ;;
      4) uninstall_menu ;;
      r|R) 
        printf "${INFO_SYMBOL} 正在刷新网络信息...\n"
        unset PUBLIC_IPV4 PUBLIC_IPV6 PUBLIC_COUNTRY PUBLIC_ISP
        get_public_ip
        printf "${SUCCESS_SYMBOL} 网络信息已刷新${PLAIN}\n"
        sleep 1
        ;;
      0) printf "${SUCCESS_SYMBOL} 再见${PLAIN}\n"; exit 0 ;;
      *) printf "${WARN_SYMBOL} 无效选择${PLAIN}\n"; ;;
    esac
  done
}



main_menu "$@"
