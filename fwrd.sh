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

# 检查服务状态和健康度
check_service_health() {
  local service_name=$1
  if [ "$OS_TYPE" != "linux" ] || ! command -v systemctl &>/dev/null; then
    printf "${WARN_SYMBOL} 非 Linux 环境，无法检查 systemd 服务状态${PLAIN}\n"
    return 1
  fi
  
  printf "\n${BOLD}${BLUE}=== %s 服务状态 ===${PLAIN}\n" "$service_name"
  
  # 基本状态检查
  if systemctl is-active --quiet "$service_name"; then
    printf "${SUCCESS_SYMBOL} 服务状态: ${GREEN}运行中${PLAIN}\n"
  elif systemctl is-failed --quiet "$service_name"; then
    printf "${ERROR_SYMBOL} 服务状态: ${RED}失败${PLAIN}\n"
  else
    printf "${WARN_SYMBOL} 服务状态: ${YELLOW}已停止${PLAIN}\n"
  fi
  
  # 启用状态
  if systemctl is-enabled --quiet "$service_name" 2>/dev/null; then
    printf "${SUCCESS_SYMBOL} 开机启动: ${GREEN}已启用${PLAIN}\n"
  else
    printf "${WARN_SYMBOL} 开机启动: ${YELLOW}未启用${PLAIN}\n"
  fi
  
  # 重启次数和失败检查
  local restart_count
  restart_count=$(systemctl show "$service_name" --property=NRestarts --value 2>/dev/null || echo "0")
  printf "${INFO_SYMBOL} 重启次数: %s\n" "$restart_count"
  
  # 最近日志
  printf "\n${BLUE}最近日志 (5 条):${PLAIN}\n"
  journalctl -u "$service_name" --no-pager -n 5 --output=short-precise 2>/dev/null || printf "${WARN_SYMBOL} 无法获取日志${PLAIN}\n"
}

# 服务自愈功能
auto_heal_service() {
  local service_name=$1
  if [ "$OS_TYPE" != "linux" ] || ! command -v systemctl &>/dev/null; then
    return 1
  fi
  
  printf "${INFO_SYMBOL} 正在检查 %s 服务健康状态...${PLAIN}\n" "$service_name"
  
  if ! systemctl is-active --quiet "$service_name"; then
    printf "${WARN_SYMBOL} 服务未运行，尝试启动...${PLAIN}\n"
    if systemctl start "$service_name"; then
      printf "${SUCCESS_SYMBOL} 服务启动成功${PLAIN}\n"
    else
      printf "${ERROR_SYMBOL} 服务启动失败，尝试重置...${PLAIN}\n"
      systemctl reset-failed "$service_name" 2>/dev/null || true
      if systemctl start "$service_name"; then
        printf "${SUCCESS_SYMBOL} 重置后启动成功${PLAIN}\n"
      else
        printf "${ERROR_SYMBOL} 服务启动失败，请检查配置${PLAIN}\n"
        return 1
      fi
    fi
  else
    printf "${SUCCESS_SYMBOL} 服务运行正常${PLAIN}\n"
  fi
}

# 获取公网IP信息 - 分别查询 IPv4 和 IPv6 的完整信息
get_public_ip() {
  local ipv4="" ipv6="" ipv4_country="" ipv4_city="" ipv4_asn="" ipv4_isp=""
  local ipv6_country="" ipv6_city="" ipv6_asn="" ipv6_isp=""
  
  # 获取 IPv4 信息和 ASN
  if command -v curl &>/dev/null; then
    printf "${INFO_SYMBOL} 获取 IPv4 信息...\r"
    local ipv4_info
    ipv4_info=$(timeout 5 curl -4 -s --max-time 5 "https://ipapi.co/json" 2>/dev/null || true)
    
    if [ -n "$ipv4_info" ] && echo "$ipv4_info" | grep -q '"ip"'; then
      if command -v jq &>/dev/null; then
        # 使用 jq 解析 JSON
        ipv4=$(echo "$ipv4_info" | jq -r '.ip // ""')
        ipv4_country=$(echo "$ipv4_info" | jq -r '.country_name // ""')
        ipv4_city=$(echo "$ipv4_info" | jq -r '.city // ""')
        ipv4_asn=$(echo "$ipv4_info" | jq -r '.asn // ""')
        ipv4_isp=$(echo "$ipv4_info" | jq -r '.org // ""')
      else
        # 使用 grep 解析 JSON
        ipv4=$(echo "$ipv4_info" | grep -o '"ip":"[^"]*' | cut -d'"' -f4)
        ipv4_country=$(echo "$ipv4_info" | grep -o '"country_name":"[^"]*' | cut -d'"' -f4)
        ipv4_city=$(echo "$ipv4_info" | grep -o '"city":"[^"]*' | cut -d'"' -f4)
        ipv4_asn=$(echo "$ipv4_info" | grep -o '"asn":"[^"]*' | cut -d'"' -f4)
        ipv4_isp=$(echo "$ipv4_info" | grep -o '"org":"[^"]*' | cut -d'"' -f4)
      fi
    fi
    
    # 如果 ipapi.co 失败，尝试备用方法获取 IPv4
    if [ -z "$ipv4" ]; then
      ipv4=$(timeout 3 curl -4 -s --max-time 3 https://api.ipify.org 2>/dev/null | grep -E '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$' || true)
    fi
  fi
  
  # 获取 IPv6 地址和 ASN
  if command -v curl &>/dev/null; then
    printf "${INFO_SYMBOL} 获取 IPv6 信息...\r"
    
    # 先获取 IPv6 地址
    for method in api6_ipify dig_cloudflare ipapi_co; do
      case $method in
        "api6_ipify")
          ipv6=$(timeout 3 curl -6 -s --max-time 3 https://api6.ipify.org 2>/dev/null | grep -E '^[0-9a-fA-F:]+$' || true)
          ;;
        "dig_cloudflare")
          if [ -z "$ipv6" ] && command -v dig &>/dev/null; then
            ipv6=$(timeout 3 dig +short -6 TXT ch whoami.cloudflare @2606:4700:4700::1111 2>/dev/null | tr -d '"' | grep -E '^[0-9a-fA-F:]+$' | head -1 || true)
          fi
          ;;
        "ipapi_co")
          if [ -z "$ipv6" ]; then
            ipv6=$(timeout 3 curl -6 -s --max-time 3 "https://ipapi.co/ip" 2>/dev/null | grep -E '^[0-9a-fA-F:]+$' || true)
          fi
          ;;
      esac
      [ -n "$ipv6" ] && break
    done
    
    # 如果获取到 IPv6，查询其 ASN 信息
    if [ -n "$ipv6" ] && [ "$ipv6" != "N/A" ]; then
      printf "${INFO_SYMBOL} 获取 IPv6 ASN 信息...\r"
      local ipv6_info
      ipv6_info=$(timeout 5 curl -6 -s --max-time 5 "https://ipapi.co/json" 2>/dev/null || true)
      
      if [ -n "$ipv6_info" ] && echo "$ipv6_info" | grep -q '"ip"'; then
        if command -v jq &>/dev/null; then
          ipv6_country=$(echo "$ipv6_info" | jq -r '.country_name // ""')
          ipv6_city=$(echo "$ipv6_info" | jq -r '.city // ""')
          ipv6_asn=$(echo "$ipv6_info" | jq -r '.asn // ""')
          ipv6_isp=$(echo "$ipv6_info" | jq -r '.org // ""')
        else
          ipv6_country=$(echo "$ipv6_info" | grep -o '"country_name":"[^"]*' | cut -d'"' -f4)
          ipv6_city=$(echo "$ipv6_info" | grep -o '"city":"[^"]*' | cut -d'"' -f4)
          ipv6_asn=$(echo "$ipv6_info" | grep -o '"asn":"[^"]*' | cut -d'"' -f4)
          ipv6_isp=$(echo "$ipv6_info" | grep -o '"org":"[^"]*' | cut -d'"' -f4)
        fi
      fi
    fi
  fi
  
  # 清理和验证数据
  [ -z "$ipv4" ] && ipv4="N/A"
  [ -z "$ipv6" ] && ipv6="N/A"
  [ -z "$ipv4_country" ] && ipv4_country="N/A"
  [ -z "$ipv4_city" ] && ipv4_city="N/A"
  [ -z "$ipv4_asn" ] && ipv4_asn="N/A"
  [ -z "$ipv4_isp" ] && ipv4_isp="N/A"
  [ -z "$ipv6_country" ] && ipv6_country="N/A"
  [ -z "$ipv6_city" ] && ipv6_city="N/A"
  [ -z "$ipv6_asn" ] && ipv6_asn="N/A"
  [ -z "$ipv6_isp" ] && ipv6_isp="N/A"
  
  # 导出变量供其他函数使用
  PUBLIC_IPV4="$ipv4"
  PUBLIC_IPV6="$ipv6"
  PUBLIC_IPV4_COUNTRY="$ipv4_country"
  PUBLIC_IPV4_CITY="$ipv4_city"
  PUBLIC_IPV4_ASN="$ipv4_asn"
  PUBLIC_IPV4_ISP="$ipv4_isp"
  PUBLIC_IPV6_COUNTRY="$ipv6_country"
  PUBLIC_IPV6_CITY="$ipv6_city"
  PUBLIC_IPV6_ASN="$ipv6_asn"
  PUBLIC_IPV6_ISP="$ipv6_isp"
  
  printf "                    \r"  # 清除获取信息提示
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
  local content="[Unit]
Description=GOST Proxy Service
After=network-online.target
Wants=network-online.target systemd-networkd-wait-online.service
StartLimitIntervalSec=60
StartLimitBurst=3

[Service]
Type=simple
ExecStart=/usr/local/bin/gost -C \"$abs\"
Restart=on-failure
RestartSec=5s
User=gost
Group=gost
Environment=\"PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\"

# 安全性设置
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=/var/log

# 高并发支持
LimitNOFILE=infinity

# 网络权限
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target"
  
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
  
  # macOS 上也尝试安装，但使用不同的策略
  if [ "$OS_TYPE" = "macos" ]; then
    # 尝试使用 brew 安装
    if command -v brew &>/dev/null; then
      printf "${INFO_SYMBOL} 尝试使用 brew 安装 realm...${PLAIN}\n"
      if brew install realm 2>/dev/null; then
        printf "${SUCCESS_SYMBOL} realm 通过 brew 安装成功${PLAIN}\n"
        return 0
      else
        printf "${WARN_SYMBOL} brew 安装失败，尝试手动下载...${PLAIN}\n"
      fi
    fi
    
    # 手动下载 macOS 版本
    local arch=$(uname -m)
    local ver="v2.6.2"  # 使用稳定版本
    local url=""
    
    case "$arch" in
      x86_64) url="https://github.com/zhboner/realm/releases/download/${ver}/realm-x86_64-apple-darwin.tar.gz";;
      arm64) url="https://github.com/zhboner/realm/releases/download/${ver}/realm-aarch64-apple-darwin.tar.gz";;
      *) 
        printf "${ERROR_SYMBOL} 不支持的 macOS 架构: %s${PLAIN}\n" "$arch"
        printf "${INFO_SYMBOL} 请手动从 GitHub 下载适合的版本${PLAIN}\n"
        return 1
        ;;
    esac
    
    # 创建目录并下载
    mkdir -p "$REALM_DIR" 2>/dev/null || true
    if command -v curl &>/dev/null; then
      printf "${INFO_SYMBOL} 下载 macOS 版本...${PLAIN}\n"
      (cd "$REALM_DIR" && curl -L -o realm.tar.gz "$url" && tar -xzf realm.tar.gz && chmod +x realm && rm -f realm.tar.gz) &
      show_loading $!
      if [ -x "${REALM_DIR}/realm" ]; then
        printf "${SUCCESS_SYMBOL} realm 安装成功${PLAIN}\n"
        return 0
      else
        printf "${ERROR_SYMBOL} realm 安装失败${PLAIN}\n"
        return 1
      fi
    else
      printf "${ERROR_SYMBOL} 缺少 curl，无法下载${PLAIN}\n"
      return 1
    fi
  fi
  
  local api; api=$(curl -s https://api.github.com/repos/zhboner/realm/releases/latest || true)
  local ver
  if command -v jq &>/dev/null && [ -n "$api" ]; then
    ver=$(echo "$api" | jq -r '.tag_name // ""')
  else
    ver=$(echo "$api" | grep -o '"tag_name": *"[^"]*' | sed 's/.*"\([^"]*\)".*/\1/' | head -1)
  fi
  
  # 验证版本号格式
  if [ -z "$ver" ] || ! [[ "$ver" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf "${WARN_SYMBOL} 无法获取有效版本号，使用默认版本${PLAIN}\n"
    ver="v2.6.2"
  fi
  
  printf "${INFO_SYMBOL} 使用版本: %s${PLAIN}\n" "$ver"
  local arch=$(uname -m); local os=$(uname -s | tr '[:upper:]' '[:lower:]')
  local url=""
  case "$arch-$os" in
    x86_64-linux) url="https://github.com/zhboner/realm/releases/download/${ver}/realm-x86_64-unknown-linux-gnu.tar.gz";;
    aarch64-linux) url="https://github.com/zhboner/realm/releases/download/${ver}/realm-aarch64-unknown-linux-gnu.tar.gz";;
    armv7l-linux|arm-linux) url="https://github.com/zhboner/realm/releases/download/${ver}/realm-arm-unknown-linux-gnueabi.tar.gz";;
    x86_64-darwin) url="https://github.com/zhboner/realm/releases/download/${ver}/realm-x86_64-apple-darwin.tar.gz";;
    *) url="https://github.com/zhboner/realm/releases/download/${ver}/realm-x86_64-unknown-linux-gnu.tar.gz";;
  esac
  
  # 确保下载目录存在
  $SUDO mkdir -p "$REALM_DIR"
  
  printf "${INFO_SYMBOL} 下载 URL: %s${PLAIN}\n" "$url"
  
  # 使用 curl 或 wget 下载
  local download_success=false
  if command -v curl &>/dev/null; then
    printf "${INFO_SYMBOL} 使用 curl 下载...${PLAIN}\n"
    if curl -L --connect-timeout 30 --max-time 300 -o "${REALM_DIR}/realm.tar.gz" "$url"; then
      download_success=true
    fi
  elif command -v wget &>/dev/null; then
    printf "${INFO_SYMBOL} 使用 wget 下载...${PLAIN}\n"
    if wget -O "${REALM_DIR}/realm.tar.gz" "$url"; then
      download_success=true
    fi
  else
    printf "${ERROR_SYMBOL} 缺少下载工具 (curl 或 wget)${PLAIN}\n"
    return 1
  fi
  
  if [ "$download_success" = false ]; then
    printf "${ERROR_SYMBOL} 下载失败${PLAIN}\n"
    return 1
  fi
  
  # 检查下载文件
  if [ ! -f "${REALM_DIR}/realm.tar.gz" ] || [ ! -s "${REALM_DIR}/realm.tar.gz" ]; then
    printf "${ERROR_SYMBOL} 下载的文件无效或为空${PLAIN}\n"
    rm -f "${REALM_DIR}/realm.tar.gz"
    return 1
  fi
  
  printf "${INFO_SYMBOL} 解压文件...${PLAIN}\n"
  if (cd "$REALM_DIR" && tar -xzf realm.tar.gz && chmod +x realm && rm -f realm.tar.gz); then
    if [ -x "${REALM_DIR}/realm" ]; then
      printf "${SUCCESS_SYMBOL} realm 下载解压成功${PLAIN}\n"
    else
      printf "${ERROR_SYMBOL} 解压后找不到 realm 可执行文件${PLAIN}\n"
      return 1
    fi
  else
    printf "${ERROR_SYMBOL} 解压失败${PLAIN}\n"
    return 1
  fi
  
  # 只在 Linux 上创建 systemd 服务
  if [ "$OS_TYPE" = "linux" ]; then
    if ! id realm &>/dev/null; then $SUDO useradd --system --no-create-home --shell /bin/false realm || true; fi
    cat <<EOF | $SUDO tee "${SERVICE_DIR}/realm.service" >/dev/null
[Unit]
Description=Realm Proxy Service
After=network-online.target
Wants=network-online.target systemd-networkd-wait-online.service
StartLimitIntervalSec=60
StartLimitBurst=3

[Service]
Type=simple
User=realm
Group=realm
Restart=on-failure
RestartSec=5s
WorkingDirectory=${REALM_DIR}
ExecStart=${REALM_DIR}/realm -c ${REALM_CONFIG_FILE}
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# 安全性设置
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=/var/log

# 高并发支持
LimitNOFILE=infinity

# 网络权限
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
        # 清理目标地址，移除可能的警告信息和特殊字符
        target_addr=$(echo "$target_addr" | sed 's/⚠️.*$//' | sed 's/[[:space:]]*$//')
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

# 统一规则删除 - 直接选择编号删除
delete_any_rule() {
  # 构建规则列表
  local rule_list=()
  local rule_engines=()
  local rule_names=()
  local count=0
  
  printf "\n${BOLD}${BLUE}=== 删除转发规则 ===${PLAIN}\n"
  printf "%-3s %-8s %-35s %-18s %-24s %-8s\n" "#" "引擎" "名称/备注" "监听地址" "目标地址" "协议"
  printf "%s\n" "--------------------------------------------------------------------------------"
  
  # 收集 GOST 规则
  if [ -f "$GOST_CONFIG_FILE" ]; then
    while IFS="|" read -r name listen_addr target_addr proto; do
      if [ -n "$name" ]; then
        count=$((count + 1))
        # 清理目标地址，移除可能的警告信息和特殊字符
        target_addr=$(echo "$target_addr" | sed 's/⚠️.*$//' | sed 's/[[:space:]]*$//')
        printf "%-3s %-8s %-35s %-18s %-24s %-8s\n" "$count" "GOST" "$name" "$listen_addr" "$target_addr" "$proto"
        rule_engines+=("gost")
        rule_names+=("$name")
      fi
    done < <(jq -r '.services[] | select(.forwarder!=null) | [.name,.addr, (.forwarder.nodes[0].addr//""), (.handler.type//"")] | @tsv' "$GOST_CONFIG_FILE" 2>/dev/null | tr '\t' '|')
  fi
  
  # 收集 Realm 规则
  if [ -f "$REALM_CONFIG_FILE" ]; then
    local realm_idx=0
    local in_endpoint=0
    local listen_val remote_val tcp_val udp_val remark_val
    
    while IFS= read -r line; do
      if [[ "$line" =~ ^\[\[endpoints\]\] ]]; then
        if [ $in_endpoint -eq 1 ] && [ -n "$listen_val" ]; then
          # 输出上一个端点
          realm_idx=$((realm_idx + 1))
          count=$((count + 1))
          local proto_display="both"
          if [ "$tcp_val" = "true" ] && [ "$udp_val" = "false" ]; then proto_display="tcp"; fi
          if [ "$tcp_val" = "false" ] && [ "$udp_val" = "true" ]; then proto_display="udp"; fi
          printf "%-3s %-8s %-35s %-18s %-24s %-8s\n" "$count" "Realm" "${remark_val:-规则-$realm_idx}" "$listen_val" "$remote_val" "$proto_display"
          rule_engines+=("realm")
          rule_names+=("$realm_idx")
        fi
        in_endpoint=1
        listen_val=""; remote_val=""; tcp_val=""; udp_val=""; remark_val=""
      elif [ $in_endpoint -eq 1 ]; then
        if [[ "$line" =~ ^#.*Remark:.*(.*)$ ]]; then
          remark_val=$(echo "$line" | sed 's/^#.*Remark: *//')
        elif [[ "$line" =~ ^listen.*=.*\"(.*)\" ]]; then
          listen_val=$(echo "$line" | sed 's/^listen.*= *"\([^"]*\)".*/\1/')
        elif [[ "$line" =~ ^remote.*=.*\"(.*)\" ]]; then
          remote_val=$(echo "$line" | sed 's/^remote.*= *"\([^"]*\)".*/\1/')
        elif [[ "$line" =~ ^use_tcp.*=.*(.*)$ ]]; then
          tcp_val=$(echo "$line" | sed 's/^use_tcp.*= *//' | tr -d ' ')
        elif [[ "$line" =~ ^use_udp.*=.*(.*)$ ]]; then
          udp_val=$(echo "$line" | sed 's/^use_udp.*= *//' | tr -d ' ')
        fi
      fi
    done < "$REALM_CONFIG_FILE"
    
    # 处理最后一个端点
    if [ $in_endpoint -eq 1 ] && [ -n "$listen_val" ]; then
      realm_idx=$((realm_idx + 1))
      count=$((count + 1))
      local proto_display="both"
      if [ "$tcp_val" = "true" ] && [ "$udp_val" = "false" ]; then proto_display="tcp"; fi
      if [ "$tcp_val" = "false" ] && [ "$udp_val" = "true" ]; then proto_display="udp"; fi
      printf "%-3s %-8s %-35s %-18s %-24s %-8s\n" "$count" "Realm" "${remark_val:-规则-$realm_idx}" "$listen_val" "$remote_val" "$proto_display"
      rule_engines+=("realm")
      rule_names+=("$realm_idx")
    fi
  fi
  
  if [ $count -eq 0 ]; then
    printf "${WARN_SYMBOL} 没有可删除的规则${PLAIN}\n"
    return
  fi
  
  printf "\n${INFO_SYMBOL} 共 ${BLUE}%d${PLAIN} 条规则\n" "$count"
  printf "${YELLOW}删除选项:${PLAIN}\n"
  printf "  ${GREEN}单个删除${PLAIN}: 输入规则编号 (1-%d)\n" "$count"
  printf "  ${YELLOW}批量删除${PLAIN}: 输入多个编号，用空格分隔 (如: 1 3 5)\n"
  printf "  ${RED}全部删除${PLAIN}: 输入 'all' 删除所有规则\n"
  printf "  ${BLUE}返回${PLAIN}: 输入 0\n"
  printf "请选择: "; read -r choice
  
  if [ "$choice" = "0" ]; then
    printf "${INFO_SYMBOL} 已取消删除${PLAIN}\n"
    return
  fi
  
  # 处理 'all' 全部删除
  if [ "$choice" = "all" ]; then
    printf "${RED}${WARN_SYMBOL} 警告: 这将删除所有 %d 条转发规则！${PLAIN}\n" "$count"
    printf "${YELLOW}确定要删除所有规则吗? 请输入 'YES' 确认: ${PLAIN}"
    read -r confirm_all
    if [ "$confirm_all" = "YES" ]; then
      delete_all_rules
      return
    else
      printf "${INFO_SYMBOL} 已取消全部删除${PLAIN}\n"
      return
    fi
  fi
  
  # 处理批量删除 (空格分隔的数字)
  if [[ "$choice" =~ [[:space:]] ]]; then
    local choices_array=($choice)
    local valid_choices=()
    
    # 验证所有输入的编号
    for num in "${choices_array[@]}"; do
      if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le $count ]; then
        valid_choices+=("$num")
      else
        printf "${ERROR_SYMBOL} 无效编号: %s${PLAIN}\n" "$num"
        return
      fi
    done
    
    if [ ${#valid_choices[@]} -eq 0 ]; then
      printf "${ERROR_SYMBOL} 没有有效的规则编号${PLAIN}\n"
      return
    fi
    
    printf "${WARN_SYMBOL} 确定要删除 %d 条规则吗? [y/N]: ${PLAIN}" "${#valid_choices[@]}"
    read -r confirm_batch
    
    if [[ "$confirm_batch" =~ ^[Yy]$ ]]; then
      # 按倒序删除，避免编号变化影响
      local sorted_choices=($(printf '%s\n' "${valid_choices[@]}" | sort -nr))
      local deleted_count=0
      
      for num in "${sorted_choices[@]}"; do
        local selected_engine="${rule_engines[$((num-1))]}"
        local selected_name="${rule_names[$((num-1))]}"
        
        if [ "$selected_engine" = "gost" ]; then
          local tmp=$(mktemp)
          jq --arg n "$selected_name" '.services = [.services[] | select(.name!=$n)]' "$GOST_CONFIG_FILE" > "$tmp" && {
            $SUDO mv "$tmp" "$GOST_CONFIG_FILE"
            deleted_count=$((deleted_count + 1))
          } || rm -f "$tmp"
        else
          # Realm 规则删除逻辑
          local starts
          mapfile -t starts < <(nl -ba "$REALM_CONFIG_FILE" | grep "\[\[endpoints\]\]" | awk '{print $1}')
          if [ "$selected_name" -le ${#starts[@]} ]; then
            local s=${starts[$((selected_name-1))]}
            local e
            e=$(nl -ba "$REALM_CONFIG_FILE" | awk -v S=$s 'NR>S && /\[\[endpoints\]\]/{print $1; exit}')
            if [ -z "$e" ]; then e=$(wc -l < "$REALM_CONFIG_FILE"); fi
            $SUDO sed -i "${s},${e}d" "$REALM_CONFIG_FILE"
            deleted_count=$((deleted_count + 1))
          fi
        fi
      done
      
      # 重启服务
      if [ "$OS_TYPE" = "linux" ] && command -v systemctl &>/dev/null; then
        apply_gost_config
        $SUDO systemctl restart realm || true
      fi
      
      printf "${SUCCESS_SYMBOL} 批量删除完成，共删除 %d 条规则${PLAIN}\n" "$deleted_count"
    else
      printf "${INFO_SYMBOL} 已取消批量删除${PLAIN}\n"
    fi
    return
  fi
  
  # 处理单个删除
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt $count ]; then
    printf "${ERROR_SYMBOL} 无效选择${PLAIN}\n"
    return
  fi
  
  local selected_engine="${rule_engines[$((choice-1))]}"
  local selected_name="${rule_names[$((choice-1))]}"
  
  printf "${WARN_SYMBOL} 确定要删除规则 #%d (%s) 吗? [y/N]: ${PLAIN}" "$choice" "$selected_engine"
  read -r confirm
  
  if [[ "$confirm" =~ ^[Yy]$ ]]; then
    if [ "$selected_engine" = "gost" ]; then
      # 删除 GOST 规则
      local tmp=$(mktemp)
      jq --arg n "$selected_name" '.services = [.services[] | select(.name!=$n)]' "$GOST_CONFIG_FILE" > "$tmp" || { rm -f "$tmp"; printf "${ERROR_SYMBOL} 删除失败${PLAIN}\n"; return; }
      $SUDO mv "$tmp" "$GOST_CONFIG_FILE"
      apply_gost_config
      printf "${SUCCESS_SYMBOL} GOST 规则已删除${PLAIN}\n"
    else
      # 删除 Realm 规则 (按索引)
      local starts
      mapfile -t starts < <(nl -ba "$REALM_CONFIG_FILE" | grep "\[\[endpoints\]\]" | awk '{print $1}')
      if [ "$selected_name" -le ${#starts[@]} ]; then
        local s=${starts[$((selected_name-1))]}
        local e
        e=$(nl -ba "$REALM_CONFIG_FILE" | awk -v S=$s 'NR>S && /\[\[endpoints\]\]/{print $1; exit}')
        if [ -z "$e" ]; then e=$(wc -l < "$REALM_CONFIG_FILE"); fi
        $SUDO sed -i "${s},${e}d" "$REALM_CONFIG_FILE"
        if [ "$OS_TYPE" = "linux" ] && command -v systemctl &>/dev/null; then
          $SUDO systemctl restart realm || true
        fi
        printf "${SUCCESS_SYMBOL} Realm 规则已删除${PLAIN}\n"
      else
        printf "${ERROR_SYMBOL} Realm 规则删除失败${PLAIN}\n"
      fi
    fi
  else
    printf "${INFO_SYMBOL} 已取消删除${PLAIN}\n"
  fi
}

# 一键删除所有规则
delete_all_rules() {
  local deleted_gost=0 deleted_realm=0
  
  printf "${INFO_SYMBOL} 正在删除所有规则...${PLAIN}\n"
  
  # 删除所有 GOST 规则
  if [ -f "$GOST_CONFIG_FILE" ]; then
    local gost_count
    gost_count=$(jq -r '.services[] | select(.forwarder!=null) | .name' "$GOST_CONFIG_FILE" 2>/dev/null | wc -l || echo 0)
    if [ "$gost_count" -gt 0 ]; then
      echo '{"services":[]}' | $SUDO tee "$GOST_CONFIG_FILE" >/dev/null
      deleted_gost=$gost_count
      printf "${SUCCESS_SYMBOL} 删除了 %d 条 GOST 规则${PLAIN}\n" "$deleted_gost"
    fi
  fi
  
  # 删除所有 Realm 规则
  if [ -f "$REALM_CONFIG_FILE" ]; then
    local realm_count
    realm_count=$(grep -c '^\[\[endpoints\]\]' "$REALM_CONFIG_FILE" 2>/dev/null || echo 0)
    if [ "$realm_count" -gt 0 ]; then
      # 保留 [network] 部分，删除所有 [[endpoints]]
      $SUDO sed -i '/^\[\[endpoints\]\]/,$d' "$REALM_CONFIG_FILE"
      deleted_realm=$realm_count
      printf "${SUCCESS_SYMBOL} 删除了 %d 条 Realm 规则${PLAIN}\n" "$deleted_realm"
    fi
  fi
  
  # 重启服务
  if [ "$OS_TYPE" = "linux" ] && command -v systemctl &>/dev/null; then
    if [ $deleted_gost -gt 0 ]; then
      apply_gost_config
    fi
    if [ $deleted_realm -gt 0 ]; then
      $SUDO systemctl restart realm || true
    fi
  fi
  
  local total_deleted=$((deleted_gost + deleted_realm))
  printf "${SUCCESS_SYMBOL} ${GREEN}全部删除完成！共删除 %d 条规则${PLAIN}\n" "$total_deleted"
}

# 统计总规则数
count_total_rules() {
  local total=0
  if [ -f "$GOST_CONFIG_FILE" ]; then
    local gost_count
    gost_count=$(jq -r '.services[] | select(.forwarder!=null) | .name' "$GOST_CONFIG_FILE" 2>/dev/null | wc -l || echo 0)
    # 确保 gost_count 是数字
    if [[ "$gost_count" =~ ^[0-9]+$ ]]; then
      total=$((total + gost_count))
    fi
  fi
  if [ -f "$REALM_CONFIG_FILE" ]; then
    local realm_count
    realm_count=$(grep -c '^\[\[endpoints\]\]' "$REALM_CONFIG_FILE" 2>/dev/null || echo 0)
    # 确保 realm_count 是数字
    if [[ "$realm_count" =~ ^[0-9]+$ ]]; then
      total=$((total + realm_count))
    fi
  fi
  echo "$total"
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
    printf "  ${GREEN}1) 新建规则${PLAIN} (选择引擎)\n"
    printf "  ${BLUE}2) 列出所有规则${PLAIN} (统一显示)\n"
    printf "  ${YELLOW}3) 删除规则${PLAIN} (直接选择编号)\n"
    printf "  ${BLUE}━━━━━━━━━━━━━━━━━━━━━━${PLAIN}\n"
    printf "  ${BLUE}4) 列出 GOST 规则${PLAIN} (单独查看)\n"
    printf "  ${BLUE}5) 列出 Realm 规则${PLAIN} (单独查看)\n"
    printf "  0) 返回主菜单\n"
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
    printf "  ${GREEN}GOST 服务:${PLAIN}\n"
    printf "    1) 启动 gost.service\n"
    printf "    2) 停止 gost.service\n"
    printf "    3) 重启 gost.service\n"
    printf "    4) 查看 gost 状态和日志\n"
    printf "  ${GREEN}Realm 服务:${PLAIN}\n"
    printf "    5) 启动 realm.service\n"
    printf "    6) 停止 realm.service\n"
    printf "    7) 重启 realm.service\n"
    printf "    8) 查看 realm 状态和日志\n"
    printf "  ${BLUE}高级功能:${PLAIN}\n"
    printf "    9) 服务健康检查和自愈\n"
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
      1) 
        printf "${INFO_SYMBOL} 启动 GOST 服务...${PLAIN}\n"
        $SUDO systemctl start gost && auto_heal_service gost
        ;;
      2) 
        printf "${INFO_SYMBOL} 停止 GOST 服务...${PLAIN}\n"
        $SUDO systemctl stop gost || true
        ;;
      3) 
        printf "${INFO_SYMBOL} 重启 GOST 服务...${PLAIN}\n"
        $SUDO systemctl restart gost && auto_heal_service gost
        ;;
      4) check_service_health gost ;;
      5) 
        printf "${INFO_SYMBOL} 启动 Realm 服务...${PLAIN}\n"
        $SUDO systemctl start realm && auto_heal_service realm
        ;;
      6) 
        printf "${INFO_SYMBOL} 停止 Realm 服务...${PLAIN}\n"
        $SUDO systemctl stop realm || true
        ;;
      7) 
        printf "${INFO_SYMBOL} 重启 Realm 服务...${PLAIN}\n"
        $SUDO systemctl restart realm && auto_heal_service realm
        ;;
      8) check_service_health realm ;;
      9) 
        printf "${INFO_SYMBOL} 执行服务健康检查和自愈...${PLAIN}\n"
        auto_heal_service gost
        auto_heal_service realm
        ;;
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
  
  # 显示网络信息 - 分别显示 IPv4 和 IPv6 的 ASN 信息
  printf "\n${BOLD}网络信息:${PLAIN}\n"
  
  # IPv4 信息和 ASN
  if [ "${PUBLIC_IPV4:-N/A}" != "N/A" ]; then
    # 构建 IPv4 位置信息
    local ipv4_location=""
    if [ "${PUBLIC_IPV4_CITY:-N/A}" != "N/A" ] && [ "${PUBLIC_IPV4_COUNTRY:-N/A}" != "N/A" ]; then
      ipv4_location=" (${PUBLIC_IPV4_CITY}, ${PUBLIC_IPV4_COUNTRY})"
    elif [ "${PUBLIC_IPV4_COUNTRY:-N/A}" != "N/A" ]; then
      ipv4_location=" (${PUBLIC_IPV4_COUNTRY})"
    fi
    
    printf "  IPv4: ${GREEN}%s${PLAIN}%s\n" "${PUBLIC_IPV4}" "$ipv4_location"
    
    # IPv4 ASN 信息 - 对齐显示
    if [ "${PUBLIC_IPV4_ASN:-N/A}" != "N/A" ] || [ "${PUBLIC_IPV4_ISP:-N/A}" != "N/A" ]; then
      local ipv4_asn_info=""
      if [ "${PUBLIC_IPV4_ASN:-N/A}" != "N/A" ]; then
        ipv4_asn_info="${PUBLIC_IPV4_ASN}"
      fi
      if [ "${PUBLIC_IPV4_ISP:-N/A}" != "N/A" ]; then
        if [ -n "$ipv4_asn_info" ]; then
          ipv4_asn_info="${ipv4_asn_info} - ${PUBLIC_IPV4_ISP}"
        else
          ipv4_asn_info="${PUBLIC_IPV4_ISP}"
        fi
      fi
      printf "  ASN:  ${YELLOW}%s${PLAIN}\n" "$ipv4_asn_info"
    fi
  else
    printf "  IPv4: ${YELLOW}获取中...${PLAIN}\n"
  fi
  
  # IPv6 信息和 ASN
  if [ "${PUBLIC_IPV6:-N/A}" != "N/A" ]; then
    # 构建 IPv6 位置信息
    local ipv6_location=""
    if [ "${PUBLIC_IPV6_CITY:-N/A}" != "N/A" ] && [ "${PUBLIC_IPV6_COUNTRY:-N/A}" != "N/A" ]; then
      ipv6_location=" (${PUBLIC_IPV6_CITY}, ${PUBLIC_IPV6_COUNTRY})"
    elif [ "${PUBLIC_IPV6_COUNTRY:-N/A}" != "N/A" ]; then
      ipv6_location=" (${PUBLIC_IPV6_COUNTRY})"
    fi
    
    printf "  IPv6: ${GREEN}%s${PLAIN}%s\n" "${PUBLIC_IPV6}" "$ipv6_location"
    
    # IPv6 ASN 信息 - 对齐显示
    if [ "${PUBLIC_IPV6_ASN:-N/A}" != "N/A" ] || [ "${PUBLIC_IPV6_ISP:-N/A}" != "N/A" ]; then
      local ipv6_asn_info=""
      if [ "${PUBLIC_IPV6_ASN:-N/A}" != "N/A" ]; then
        ipv6_asn_info="${PUBLIC_IPV6_ASN}"
      fi
      if [ "${PUBLIC_IPV6_ISP:-N/A}" != "N/A" ]; then
        if [ -n "$ipv6_asn_info" ]; then
          ipv6_asn_info="${ipv6_asn_info} - ${PUBLIC_IPV6_ISP}"
        else
          ipv6_asn_info="${PUBLIC_IPV6_ISP}"
        fi
      fi
      printf "  ASN:  ${YELLOW}%s${PLAIN} (IPv6)\n" "$ipv6_asn_info"
    fi
  fi
  
  if [ "$OS_TYPE" != "linux" ]; then
    printf "\n${WARN_SYMBOL} ${YELLOW}注意: 当前非Linux环境，实际部署请在远程Linux服务器执行${PLAIN}\n"
    printf "${INFO_SYMBOL} 远程测试服务器: ssh -i unit04 root@23.141.4.67${PLAIN}\n"
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
        unset PUBLIC_IPV4 PUBLIC_IPV6 PUBLIC_IPV4_COUNTRY PUBLIC_IPV4_CITY PUBLIC_IPV4_ASN PUBLIC_IPV4_ISP
        unset PUBLIC_IPV6_COUNTRY PUBLIC_IPV6_CITY PUBLIC_IPV6_ASN PUBLIC_IPV6_ISP
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
