#!/bin/bash

# Brook端口转发统一管理脚本
# 支持功能: TCP转发、UDP转发、TCP+UDP转发、TCP和UDP分别转发到不同地址
# 版本: 1.4.4 - 修复read颜色兼容性问题, 菜单增加版本号显示

VERSION="1.4.4"

# 颜色定义
PLAIN='\033[0m'
BLACK='\033[0;30m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m' # 加粗黄色以示警告
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[0;37m'

BOLD='\033[1m'
UNDERLINE='\033[4m'

# 主题颜色别名
COLOR_PRIMARY_TEXT="${PLAIN}" # 大部分普通文本
COLOR_INFO_TEXT="${CYAN}"    # 一般信息，提示符
COLOR_INFO_ACCENT="${BLUE}"  # 补充信息，静态提示
COLOR_SUCCESS="${GREEN}"    # 成功操作
COLOR_ERROR="${RED}"      # 错误信息
COLOR_WARNING="${YELLOW}"  # 警告信息
COLOR_MENU_BORDER="${PURPLE}" # 菜单边框和主标题
COLOR_MENU_ITEM="${GREEN}"   # 菜单项编号
COLOR_IP_INFO="${GREEN}"     # IP信息高亮

# 符号定义 (使用主题颜色和加粗)
SUCCESS_SYMBOL="${BOLD}${COLOR_SUCCESS}[+]${PLAIN}"
ERROR_SYMBOL="${BOLD}${COLOR_ERROR}[x]${PLAIN}"
INFO_SYMBOL="${BOLD}${COLOR_INFO_TEXT}[i]${PLAIN}"
WARN_SYMBOL="${BOLD}${COLOR_WARNING}[!]${PLAIN}"

# 服务文件目录
SERVICE_DIR="/etc/systemd/system"
SERVICE_PREFIX="brook-forward"

# 配置目录
CONFIG_DIR="/etc/brook"
CONFIG_FILE="$CONFIG_DIR/forwards.conf"

# 脚本运行者的HOME目录，用于定位nami安装
SCRIPT_RUNNER_HOME="$HOME"

# 检查是否为root用户，决定是否需要sudo前缀
if [ "$EUID" -eq 0 ]; then
  SUDO=""
else
  SUDO="sudo"
fi

# 显示加载动画
show_loading() {
  local pid=$1
  local delay=0.2
  local spinstr='|/-\\'
  local temp
  printf " "
  while ps -p $pid &>/dev/null; do
    temp=${spinstr#?}
    printf "[%c]  " "$spinstr"
    spinstr=$temp${spinstr%"$temp"}
    sleep $delay
    printf "\\b\\b\\b\\b\\b"
  done
  printf "\\b\\b\\b\\b\\b"
  printf "${SUCCESS_SYMBOL}${COLOR_SUCCESS}%s${PLAIN}\n" "[OK]"
}

# 检查并安装依赖和brook
check_and_install_dependencies() {
  printf "${BOLD}${COLOR_INFO_ACCENT}执行初始设置和依赖检查...${PLAIN}\n"
  
  local essential_pkgs=("lsof" "curl" "jq" "net-tools")
  local pkgs_to_install=()
  local pkg_manager_detected=""

  if command -v apt-get &>/dev/null; then
    pkg_manager_detected="apt-get"
  elif command -v yum &>/dev/null; then
    pkg_manager_detected="yum"
  elif command -v dnf &>/dev/null; then
    pkg_manager_detected="dnf"
  else
    printf "${ERROR_SYMBOL} 未找到支持的包管理器。请手动安装依赖。${PLAIN}\n"
    exit 1
  fi

  for pkg in "${essential_pkgs[@]}"; do
    if ! command -v $pkg &>/dev/null; then
      pkgs_to_install+=($pkg)
    fi
  done

  if [ ${#pkgs_to_install[@]} -gt 0 ]; then
    printf "${WARN_SYMBOL} 缺失以下包: ${COLOR_WARNING}%s${PLAIN}\n" "${pkgs_to_install[*]}"
    printf "${INFO_SYMBOL} 尝试使用 ${COLOR_INFO_ACCENT}%s${PLAIN} 安装...${PLAIN}\n" "$pkg_manager_detected"
    if [ "$pkg_manager_detected" == "apt-get" ]; then
      $SUDO apt-get update -y || printf "${ERROR_SYMBOL} 更新包列表失败。${PLAIN}\n"
    fi
    if $SUDO $pkg_manager_detected install -y "${pkgs_to_install[@]}"; then
      printf "${SUCCESS_SYMBOL} 成功安装: ${COLOR_SUCCESS}%s${PLAIN}\n" "${pkgs_to_install[*]}"
    else
      printf "${ERROR_SYMBOL} 安装失败。请手动安装后重试。${PLAIN}\n"
      exit 1
    fi
  fi

  # 简化Brook检测，优先使用二进制安装方式
  if ! command -v brook &>/dev/null || ! brook --help &>/dev/null; then
    printf "${WARN_SYMBOL} Brook未安装或无法执行。开始安装Brook...${PLAIN}\n"
    
    # 直接使用二进制安装，避免nami复杂性
    install_brook_binary
    return $?
  else
    printf "${SUCCESS_SYMBOL} Brook已安装并可执行。${PLAIN}\n"
  fi
  return 0
}

# 下载安装brook二进制文件
install_brook_binary() {
  printf "${INFO_SYMBOL} 正在下载Brook二进制文件...${PLAIN}\n"
  
  # 检测系统架构
  ARCH=$(uname -m)
  case $ARCH in
    x86_64|amd64) BROOK_ARCH="amd64" ;; 
    aarch64|arm64) BROOK_ARCH="arm64" ;; 
    i386|i686) BROOK_ARCH="386" ;; 
    *) printf "${ERROR_SYMBOL} 不支持的系统架构: ${COLOR_ERROR}%s${PLAIN}\n" "$ARCH"; return 1 ;;
  esac
  
  # 检测操作系统
  OS=$(uname -s | tr '[:upper:]' '[:lower:]')
  case $OS in
    linux) BROOK_OS="linux" ;; 
    darwin) BROOK_OS="darwin" ;; 
    *) printf "${ERROR_SYMBOL} 不支持的操作系统: ${COLOR_ERROR}%s${PLAIN}\n" "$OS"; return 1 ;;
  esac
  
  # 获取最新版本
  printf "${INFO_SYMBOL} 获取Brook最新版本信息...${PLAIN}\n"
  BROOK_VERSION=$(curl -s --connect-timeout 10 https://api.github.com/repos/txthinking/brook/releases/latest | grep -o '"tag_name": "v[^"]*' | sed 's/"tag_name": "v//g' | head -1)
  if [ -z "$BROOK_VERSION" ]; then
    BROOK_VERSION="20250202"  # 备用版本
    printf "${WARN_SYMBOL} 无法获取最新版本，使用默认版本: ${COLOR_WARNING}%s${PLAIN}\n" "$BROOK_VERSION"
  else
    printf "${SUCCESS_SYMBOL} 检测到Brook版本: ${COLOR_SUCCESS}%s${PLAIN}\n" "$BROOK_VERSION"
  fi
  
  # 构建下载URL
  BROOK_URL="https://github.com/txthinking/brook/releases/download/v${BROOK_VERSION}/brook_${BROOK_OS}_${BROOK_ARCH}"
  printf "${INFO_SYMBOL} 下载地址: ${COLOR_INFO_ACCENT}%s${PLAIN}\n" "$BROOK_URL"
  
  # 下载brook
  printf "${INFO_SYMBOL} 正在下载Brook...${PLAIN}\n"
  if curl -L --connect-timeout 30 --max-time 300 -o /tmp/brook "$BROOK_URL"; then
    if [ -s /tmp/brook ]; then
      printf "${SUCCESS_SYMBOL} Brook下载成功${PLAIN}\n"
    else
      printf "${ERROR_SYMBOL} 下载的文件为空${PLAIN}\n"
      return 1
    fi
  else
    printf "${ERROR_SYMBOL} Brook下载失败${PLAIN}\n"
    return 1
  fi
  
  # 安装brook
  printf "${INFO_SYMBOL} 安装Brook到 /usr/local/bin/...${PLAIN}\n"
  $SUDO chmod +x /tmp/brook
  if $SUDO mv /tmp/brook /usr/local/bin/brook; then
    printf "${SUCCESS_SYMBOL} Brook文件安装成功${PLAIN}\n"
  else
    printf "${ERROR_SYMBOL} Brook安装失败${PLAIN}\n"
    return 1
  fi
  
  # 验证安装
  printf "${INFO_SYMBOL} 验证Brook安装...${PLAIN}\n"
  if command -v brook &>/dev/null && brook --help &>/dev/null; then
    printf "${SUCCESS_SYMBOL} Brook安装成功并可正常执行${PLAIN}\n"
    brook --version 2>/dev/null || printf "${INFO_SYMBOL} Brook版本: ${COLOR_INFO_ACCENT}%s${PLAIN}\n" "$BROOK_VERSION"
    return 0
  else
    printf "${ERROR_SYMBOL} Brook安装后无法执行${PLAIN}\n"
    return 1
  fi
}

# 设置配置目录
setup_config_dir() {
  if [ ! -d "$CONFIG_DIR" ]; then
    $SUDO mkdir -p "$CONFIG_DIR"
    printf "${SUCCESS_SYMBOL} 创建配置目录: ${COLOR_INFO_ACCENT}%s${PLAIN}\n" "$CONFIG_DIR"
  fi
  if [ ! -f "$CONFIG_FILE" ]; then
    $SUDO touch "$CONFIG_FILE"
    printf "${SUCCESS_SYMBOL} 创建配置文件: ${COLOR_INFO_ACCENT}%s${PLAIN}\n" "$CONFIG_FILE"
  fi
}

# 验证输入
validate_input() {
  local input=$1
  local input_type=$2
  case $input_type in
  "port") if ! [[ "$input" =~ ^[0-9]+$ ]] || [ "$input" -lt 1 ] || [ "$input" -gt 65535 ]; then printf "${ERROR_SYMBOL} 无效的端口号。必须在1-65535之间。${PLAIN}\n"; return 1; fi ;;
  "ip") 
    # IPv4验证
    if [[ "$input" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then 
      IFS='.' read -r -a octets <<<"$input"
      for octet in "${octets[@]}"; do 
        if [ "$octet" -gt 255 ]; then 
          printf "${ERROR_SYMBOL} 无效的IPv4地址。${PLAIN}\n"
          return 1
        fi
      done
      return 0
    fi
    # 改进的IPv6验证 - 基本格式检查
    if [[ "$input" =~ ^([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}$ ]] || [[ "$input" =~ ^::([0-9a-fA-F]{0,4}:){0,6}[0-9a-fA-F]{0,4}$ ]] || [[ "$input" =~ ^([0-9a-fA-F]{0,4}:){1,6}::$ ]]; then 
      return 0
    fi
    printf "${ERROR_SYMBOL} 无效的IP地址格式。${PLAIN}\n"
    return 1 
    ;; 
  "hostname") 
    # 支持域名和主机名格式，包括下划线
    if [[ "$input" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\._-]{0,61}[a-zA-Z0-9])?$ ]] || [[ "$input" =~ ^[a-zA-Z0-9\._-]{1,63}(\.[a-zA-Z0-9\._-]{1,63})*$ ]]; then 
      return 0
    fi
    printf "${ERROR_SYMBOL} 无效的主机名格式。${PLAIN}\n"
    return 1 
    ;; 
esac; return 0;
}

# 生成服务名称
generate_service_name() {
  local local_port=$1
  local proto=$2
  local listen_ip_suffix=$(echo "$3" | sed 's/[:\[\]]//g' | sed 's/\.//g')
  if [ -n "$listen_ip_suffix" ] && [ "$listen_ip_suffix" != "0000" ] && [ "$listen_ip_suffix" != "" ]; then
    echo "${SERVICE_PREFIX}-${listen_ip_suffix}-${local_port}-${proto}"
  else
    echo "${SERVICE_PREFIX}-${local_port}-${proto}"
  fi
}

# 创建systemd服务
create_systemd_service() {
  local service_name=$1
  local listen_on_address_param=$2
  local local_port=$3
  local remote_addr=$4
  local proto=$5
  local service_file="${SERVICE_DIR}/${service_name}.service"
  local brook_exec_command_for_service

  # 简化Brook路径检测，优先使用实际可用的brook路径
  if command -v brook &>/dev/null && brook --help &>/dev/null; then
    brook_exec_command_for_service=$(command -v brook)
  elif [ -x "/usr/local/bin/brook" ] && /usr/local/bin/brook --help &>/dev/null; then
    brook_exec_command_for_service="/usr/local/bin/brook"
  else
    printf "${ERROR_SYMBOL} 无法确定Brook的有效执行命令。请确保Brook已正确安装。${PLAIN}\n"
    return 1
  fi
  
  printf "${INFO_SYMBOL} Systemd服务将使用以下Brook命令: ${COLOR_INFO_ACCENT}%s${PLAIN}\n" "$brook_exec_command_for_service"

  local brook_relay_cmd_line="${brook_exec_command_for_service} relay -f ${listen_on_address_param} -t ${remote_addr}"
  # 根据Brook实际行为，timeout设为0可能用于禁用对应协议
  case $proto in 
    "tcp") 
      brook_relay_cmd_line+=" --udpTimeout 0" 
      ;; 
    "udp") 
      brook_relay_cmd_line+=" --tcpTimeout 0" 
      ;; 
    # "both" 情况不添加超时参数，保持默认行为
  esac

  local service_content="[Unit]
Description=Brook Forward from ${listen_on_address_param} to ${remote_addr} proto ${proto}
After=network.target
StartLimitIntervalSec=60
StartLimitBurst=3

[Service]
Type=simple
ExecStart=${brook_relay_cmd_line}
Restart=always
RestartSec=5
User=root
Group=root
Environment=\"PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\"
# 安全性设置
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target"

  echo -e "$service_content" | $SUDO tee "$service_file" > /dev/null
  $SUDO chmod 644 "$service_file"; $SUDO systemctl daemon-reload
  $SUDO systemctl enable "$service_name" >/dev/null 2>&1; $SUDO systemctl start "$service_name"
  
  if $SUDO systemctl is-active --quiet "$service_name"; then 
    printf "${SUCCESS_SYMBOL} 服务 ${COLOR_SUCCESS}%s${PLAIN} 启动成功\n" "$service_name"
    return 0
  else 
    printf "${ERROR_SYMBOL} 服务 ${COLOR_ERROR}%s${PLAIN} 启动失败。请检查日志 (选项 5)。\n" "$service_name"
    return 1
  fi
}

# 保存转发配置到文件
save_forward_config() {
  local service_name=$1
  local listen_address=$2
  local remote_addr=$3
  local proto=$4
  echo "${service_name}|${listen_address}|${remote_addr}|${proto}" | $SUDO tee -a "$CONFIG_FILE" > /dev/null
}

# 添加转发
add_forward() {
  printf "\n${BOLD}${COLOR_MENU_BORDER}--- 添加转发规则 ---${PLAIN}\n"
  echo -e "${COLOR_INFO_TEXT}请选择转发类型:${PLAIN}\n  ${COLOR_MENU_ITEM}1.${PLAIN} 仅TCP转发\n  ${COLOR_MENU_ITEM}2.${PLAIN} 仅UDP转发\n  ${COLOR_MENU_ITEM}3.${PLAIN} TCP+UDP转发到相同目标\n  ${COLOR_MENU_ITEM}4.${PLAIN} TCP和UDP分别转发到不同目标"
  echo -e "${COLOR_INFO_TEXT}请选择 [1-4]: ${PLAIN}\c"
  read forward_type
  if ! [[ "$forward_type" =~ ^[1-4]$ ]]; then printf "${ERROR_SYMBOL} 无效的选择${PLAIN}\n"; return 1; fi

  local local_port
  while true; do 
    echo -e "${COLOR_INFO_TEXT}请输入本地监听端口 [1-65535]: ${PLAIN}\c"
    read local_port
    if validate_input "$local_port" "port"; then
      if lsof -iTCP:$local_port -iUDP:$local_port >/dev/null 2>&1 || netstat -tuln | grep -qw ":${local_port}" || grep -q "|[^|]*:${local_port}|.*|" "$CONFIG_FILE" 2>/dev/null; then
        printf "${ERROR_SYMBOL} 端口 ${COLOR_ERROR}%s${PLAIN} 已被占用或已配置Brook转发。\n" "$local_port"
      else break; fi
    fi
  done
  
  echo -e "${COLOR_INFO_TEXT}请选择监听地址范围:${PLAIN}\n  ${COLOR_MENU_ITEM}1.${PLAIN} 所有网络接口 (0.0.0.0 和 ::, 推荐, ${BOLD}默认${PLAIN})\n  ${COLOR_MENU_ITEM}2.${PLAIN} 仅 IPv4 (0.0.0.0)\n  ${COLOR_MENU_ITEM}3.${PLAIN} 仅 IPv6 ([::])\n  ${COLOR_MENU_ITEM}4.${PLAIN} 指定本地IP地址"
  echo -e "${COLOR_INFO_TEXT}请选择 [1-4, 默认1]: ${PLAIN}\c"
  read listen_scope_choice
  listen_scope_choice=${listen_scope_choice:-1}
  local listen_ip_for_brook="" final_listen_arg_for_brook=""

  case $listen_scope_choice in
    1) listen_ip_for_brook="";; # Brook handles :port as all interfaces
    2) listen_ip_for_brook="0.0.0.0";; 
    3) listen_ip_for_brook="::";; 
    4) while true; do 
         echo -e "${COLOR_INFO_TEXT}请输入要监听的本地IP地址: ${PLAIN}\c"
         read specific_listen_ip
         if validate_input "$specific_listen_ip" "ip"; then listen_ip_for_brook="$specific_listen_ip"; break; fi; done ;;
    *) printf "${WARN_SYMBOL} 无效选择，使用默认 (所有接口)。${PLAIN}\n"; listen_ip_for_brook="";;
  esac

  if [ -z "$listen_ip_for_brook" ]; then final_listen_arg_for_brook=":${local_port}";
  elif [[ "$listen_ip_for_brook" == *":"* ]]; then final_listen_arg_for_brook="[${listen_ip_for_brook}]:${local_port}";
  else final_listen_arg_for_brook="${listen_ip_for_brook}:${local_port}"; fi
  printf "${INFO_SYMBOL} 服务将监听于: ${COLOR_IP_INFO}%s${PLAIN}\n" "$final_listen_arg_for_brook"

  case $forward_type in
    1|2|3) # TCP only, UDP only, or Both to same target
      local proto_str="tcp"
      if [ "$forward_type" -eq 2 ]; then proto_str="udp"; fi
      if [ "$forward_type" -eq 3 ]; then proto_str="both"; fi
      
      while true; do 
        echo -e "${COLOR_INFO_TEXT}请输入目标IP地址或域名: ${PLAIN}\c"
        read remote_ip; if validate_input "$remote_ip" "ip" || validate_input "$remote_ip" "hostname"; then break; fi;
      done
      while true; do
        echo -e "${COLOR_INFO_TEXT}请输入目标端口 [1-65535]: ${PLAIN}\c"
        read remote_port; if validate_input "$remote_port" "port"; then break; fi;
      done
      remote_addr="${remote_ip}:${remote_port}"
      printf "${INFO_SYMBOL} 目标地址: ${COLOR_INFO_ACCENT}%s${PLAIN}\n" "$remote_addr"
      
      service_name=$(generate_service_name "$local_port" "$proto_str" "$listen_ip_for_brook")
      if create_systemd_service "$service_name" "$final_listen_arg_for_brook" "$local_port" "$remote_addr" "$proto_str"; then
        save_forward_config "$service_name" "$final_listen_arg_for_brook" "$remote_addr" "$proto_str"
        printf "${SUCCESS_SYMBOL} 转发添加成功！${PLAIN}\n"
      else
        printf "${ERROR_SYMBOL} 添加转发失败，服务未能启动。${PLAIN}\n"
      fi
      ;;
    4) # TCP and UDP to different targets
      printf "\n${BOLD}${COLOR_MENU_BORDER}--- TCP转发设置 ---${PLAIN}\n"
      local tcp_remote_ip tcp_remote_port tcp_remote_addr udp_remote_ip udp_remote_port udp_remote_addr
      while true; do
        echo -e "${COLOR_INFO_TEXT}请输入TCP目标IP地址或域名: ${PLAIN}\c"
        read tcp_remote_ip; if validate_input "$tcp_remote_ip" "ip" || validate_input "$tcp_remote_ip" "hostname"; then break; fi;
      done
      while true; do
        echo -e "${COLOR_INFO_TEXT}请输入TCP目标端口 [1-65535]: ${PLAIN}\c"
        read tcp_remote_port; if validate_input "$tcp_remote_port" "port"; then break; fi;
      done
      tcp_remote_addr="${tcp_remote_ip}:${tcp_remote_port}"; printf "${INFO_SYMBOL} TCP目标地址: ${COLOR_INFO_ACCENT}%s${PLAIN}\n" "$tcp_remote_addr"
      
      printf "\n${BOLD}${COLOR_MENU_BORDER}--- UDP转发设置 ---${PLAIN}\n"
      while true; do
        echo -e "${COLOR_INFO_TEXT}请输入UDP目标IP地址或域名: ${PLAIN}\c"
        read udp_remote_ip; if validate_input "$udp_remote_ip" "ip" || validate_input "$udp_remote_ip" "hostname"; then break; fi;
      done
      while true; do
        echo -e "${COLOR_INFO_TEXT}请输入UDP目标端口 [1-65535]: ${PLAIN}\c"
        read udp_remote_port; if validate_input "$udp_remote_port" "port"; then break; fi;
      done
      udp_remote_addr="${udp_remote_ip}:${udp_remote_port}"; printf "${INFO_SYMBOL} UDP目标地址: ${COLOR_INFO_ACCENT}%s${PLAIN}\n" "$udp_remote_addr"
      
      local tcp_service_name=$(generate_service_name "$local_port" "tcp" "$listen_ip_for_brook") 
      local udp_service_name=$(generate_service_name "$local_port" "udp" "$listen_ip_for_brook")
      local tcp_success=false udp_success=false
      if create_systemd_service "$tcp_service_name" "$final_listen_arg_for_brook" "$local_port" "$tcp_remote_addr" "tcp"; then
        save_forward_config "$tcp_service_name" "$final_listen_arg_for_brook" "$tcp_remote_addr" "tcp"; tcp_success=true
      fi
      
      if create_systemd_service "$udp_service_name" "$final_listen_arg_for_brook" "$local_port" "$udp_remote_addr" "udp"; then
        save_forward_config "$udp_service_name" "$final_listen_arg_for_brook" "$udp_remote_addr" "udp"; udp_success=true
      fi
      
      if $tcp_success && $udp_success; then printf "${SUCCESS_SYMBOL} TCP和UDP转发均添加成功！${PLAIN}\n"; 
      elif $tcp_success; then printf "${WARN_SYMBOL} TCP转发添加成功，UDP转发失败。${PLAIN}\n";
      elif $udp_success; then printf "${WARN_SYMBOL} UDP转发添加成功，TCP转发失败。${PLAIN}\n";
      else printf "${ERROR_SYMBOL} TCP和UDP转发均添加失败。${PLAIN}\n"; fi
      ;;
  esac
}

# 列出所有转发
list_forwards() {
  printf "\n${BOLD}${COLOR_MENU_BORDER}--- 当前活动的Brook转发 ---${PLAIN}\n"
  printf "${BOLD}${COLOR_INFO_ACCENT}%-5s %-30s %-20s %-25s %-8s %-10s${PLAIN}\n" "编号" "服务名称" "本地监听" "目标地址" "协议" "状态"
  printf "${COLOR_MENU_BORDER}%s${PLAIN}\n" "---------------------------------------------------------------------------------------------------"
  
  local count=0
  # 修复：直接查找systemd服务文件
  local service_files=($($SUDO find /etc/systemd/system -name "${SERVICE_PREFIX}-*.service" 2>/dev/null | sort))
  
  if [ ${#service_files[@]} -eq 0 ]; then
    printf "${WARN_SYMBOL} 没有找到活动的转发服务${PLAIN}\n"
    return
  fi
  
  for service_file in "${service_files[@]}"; do
    ((count++))
    local service_name=$(basename "$service_file" .service)
    local status="未知"
    
    # 检查服务状态
    if $SUDO systemctl is-active --quiet "$service_name" 2>/dev/null; then
      status="${COLOR_SUCCESS}运行中${PLAIN}"
    elif $SUDO systemctl is-failed --quiet "$service_name" 2>/dev/null; then
      status="${COLOR_ERROR}失败${PLAIN}"
    else
      status="${COLOR_ERROR}已停止${PLAIN}"
    fi
    
    # 从配置文件获取信息
    local info=$(grep "^${service_name}|" "$CONFIG_FILE" 2>/dev/null | head -1)
    if [ -n "$info" ]; then
      local listen_address=$(echo "$info" | cut -d'|' -f2)
      local remote_addr=$(echo "$info" | cut -d'|' -f3)
      local proto=$(echo "$info" | cut -d'|' -f4)
      printf "%-5s %-30s %-20s %-25s %-8s %b\n" "$count" "$service_name" "$listen_address" "$remote_addr" "$proto" "$status"
    else
      # 从服务名称解析信息
      local parts=(${service_name//-/ })
      if [ ${#parts[@]} -ge 4 ]; then
        local local_port=${parts[2]}
        local proto=${parts[3]}
        printf "%-5s %-30s %-20s %-25s %-8s %b\n" "$count" "$service_name" ":${local_port} (?)" "未知" "$proto" "$status"
      fi
    fi
  done
  
  printf "\n${INFO_SYMBOL} 共 ${COLOR_INFO_ACCENT}%d${PLAIN} 个转发服务\n" "$count"
}

# 删除转发
delete_forward() {
  list_forwards
  
  # 使用和list_forwards相同的查询方式
  local service_files=($($SUDO find /etc/systemd/system -name "${SERVICE_PREFIX}-*.service" 2>/dev/null | sort))
  
  if [ ${#service_files[@]} -eq 0 ]; then 
    return
  fi
  
  # 创建服务名称数组
  local services=()
  for service_file in "${service_files[@]}"; do
    services+=($(basename "$service_file" .service))
  done
  
  printf "\n"
  echo -e "${WARN_SYMBOL} 确定要删除服务 %s 吗? [y/N]: ${PLAIN}\c"
  read -r confirm
  
  if [[ "$confirm" =~ ^[Yy]$ ]]; then
    $SUDO systemctl stop "${services[$((choice-1))]} 2>/dev/null
    $SUDO systemctl disable "${services[$((choice-1))]} 2>/dev/null
    $SUDO rm -f "${SERVICE_DIR}/${services[$((choice-1))]}.service"
    $SUDO sed -i "/^${services[$((choice-1))]}|/d" "$CONFIG_FILE" 2>/dev/null
    $SUDO systemctl daemon-reload
    printf "${SUCCESS_SYMBOL} 服务 %s 已删除${PLAIN}\n" "${services[$((choice-1))]}"
  else
    printf "${WARN_SYMBOL} 已取消删除${PLAIN}\n"
  fi
}

# 卸载brook
uninstall_brook() {
  printf "${WARN_SYMBOL} 此操作将卸载Brook并删除所有转发服务。确定要继续吗? [y/N]: ${PLAIN}\c"
  read -r confirm_brook
  if [[ ! "$confirm_brook" =~ ^[Yy]$ ]]; then printf "${WARN_SYMBOL} 已取消卸载Brook${PLAIN}\n"; return 1; fi

  printf "${INFO_SYMBOL} 停止所有Brook转发服务...${PLAIN}\n"
  local service_files=($($SUDO find /etc/systemd/system -name "${SERVICE_PREFIX}-*.service" 2>/dev/null))
  
  for service_file in "${service_files[@]}"; do
    local service_name=$(basename "$service_file" .service)
    $SUDO systemctl stop "$service_name" 2>/dev/null
    $SUDO systemctl disable "$service_name" 2>/dev/null
    $SUDO rm -f "$service_file"
  done
  $SUDO systemctl daemon-reload
  $SUDO rm -rf "$CONFIG_DIR" 2>/dev/null

  # 简化Brook卸载，直接删除二进制文件
  printf "${INFO_SYMBOL} 卸载Brook...${PLAIN}\n"
  if command -v brook &>/dev/null; then
    local brook_path=$(command -v brook)
    $SUDO rm -f "$brook_path" 2>/dev/null
    printf "${SUCCESS_SYMBOL} Brook已从 %s 删除${PLAIN}\n" "$brook_path"
  fi
  
  # 清理可能的其他位置
  $SUDO rm -f /usr/local/bin/brook 2>/dev/null
  
  printf "${SUCCESS_SYMBOL} Brook已完全卸载${PLAIN}\n"
  return 0
}

# 获取简洁的IP信息用于菜单显示
get_simple_ip_info() {
  if ! command -v curl &>/dev/null; then 
    echo "网络工具未就绪"
    return 1
  fi
  
  # 获取IPv4信息
  local ipv4_info=$(curl -s4 --connect-timeout 3 https://ipinfo.io/json 2>/dev/null)
  if [ -n "$ipv4_info" ] && echo "$ipv4_info" | grep -q '"ip"'; then
    local ip=$(echo "$ipv4_info" | grep -o '"ip": "[^"]*' | cut -d'"' -f4)
    local country=$(echo "$ipv4_info" | grep -o '"country": "[^"]*' | cut -d'"' -f4)
    local city=$(echo "$ipv4_info" | grep -o '"city": "[^"]*' | cut -d'"' -f4)
    local org=$(echo "$ipv4_info" | grep -o '"org": "[^"]*' | cut -d'"' -f4 | sed 's/AS[0-9]* //')
    echo "${ip} | ${country}, ${city} | ${org}"
  else
    echo "无法获取IP信息"
  fi
}

# 获取详细IP信息
get_enhanced_ip_info() {
  if ! command -v curl &>/dev/null; then 
    echo "网络工具未就绪"
    return 1
  fi
  
  local ipv4_info ipv6_info result_info=""
  
  # 获取IPv4信息
  ipv4_info=$(curl -s4 --connect-timeout 3 https://ipinfo.io/json 2>/dev/null)
  if [ -n "$ipv4_info" ] && echo "$ipv4_info" | grep -q '"ip"'; then
    local ipv4=$(echo "$ipv4_info" | grep -o '"ip": "[^"]*' | cut -d'"' -f4)
    local country=$(echo "$ipv4_info" | grep -o '"country": "[^"]*' | cut -d'"' -f4)
    local city=$(echo "$ipv4_info" | grep -o '"city": "[^"]*' | cut -d'"' -f4)
    result_info="IPv4: ${GREEN}${ipv4}${PLAIN} (${country}, ${city})"
  else
    result_info="IPv4: 无连接"
  fi
  
  # 检测IPv6连接
  if curl -s6 --connect-timeout 2 https://ipv6.icanhazip.com >/dev/null 2>&1; then
    ipv6_info=$(curl -s6 --connect-timeout 3 https://ipinfo.io/json 2>/dev/null)
    if [ -n "$ipv6_info" ] && echo "$ipv6_info" | grep -q '"ip"'; then
      local ipv6=$(echo "$ipv6_info" | grep -o '"ip": "[^"]*' | cut -d'"' -f4)
      result_info="${result_info} | IPv6: 支持"
    else
      result_info="${result_info} | IPv6: 检测中"
    fi
  else
    result_info="${result_info} | IPv6: 不支持"
  fi
  
  echo "$result_info"
}

# 显示详细IP信息
show_ip_info() {
  printf "\n${CYAN}${BOLD}========== 网络信息详情 ==========${PLAIN}\n"
  
  if ! command -v curl &>/dev/null; then 
    printf "${RED}${ERROR_SYMBOL} 未找到curl命令，无法获取IP信息${PLAIN}\n"
    return 1
  fi
  
  printf "${CYAN}${INFO_SYMBOL} IPv4地址信息:${PLAIN}\n"
  local ipv4_info=$(curl -s4 --connect-timeout 5 https://ipinfo.io/json 2>/dev/null)
  
  if [ -n "$ipv4_info" ] && echo "$ipv4_info" | grep -q '"ip"'; then
    if command -v jq &>/dev/null; then
      echo "$ipv4_info" | jq .
    else
      echo "$ipv4_info" | grep -E '("ip"|"country"|"city"|"region"|"org"|"loc"|"timezone")'
    fi
  else
    printf "${RED}${ERROR_SYMBOL} 无法获取IPv4公网信息${PLAIN}\n"
  fi
  
  printf "\n${CYAN}${INFO_SYMBOL} IPv6地址信息:${PLAIN}\n"
  if curl -s6 --connect-timeout 3 https://ipv6.icanhazip.com >/dev/null 2>&1; then
    local ipv6_info=$(curl -s6 --connect-timeout 5 https://ipinfo.io/json 2>/dev/null)
    
    if [ -n "$ipv6_info" ] && echo "$ipv6_info" | grep -q '"ip"'; then
      if command -v jq &>/dev/null; then
        echo "$ipv6_info" | jq .
      else
        echo "$ipv6_info" | grep -E '("ip"|"country"|"city"|"region"|"org"|"loc")'
      fi
    else
      printf "${YELLOW}${WARN_SYMBOL} IPv6连接可用，但无法获取详细信息${PLAIN}\n"
    fi
  else
    printf "${YELLOW}${WARN_SYMBOL} 没有检测到IPv6连接${PLAIN}\n"
  fi
  
  # 网络连接性测试
  printf "\n${CYAN}${INFO_SYMBOL} 网络连接性测试:${PLAIN}\n"
  
  printf "DNS解析测试: "
  if timeout 3 nslookup google.com >/dev/null 2>&1; then
    printf "${GREEN}正常${PLAIN}\n"
  else
    printf "${RED}失败${PLAIN}\n"
  fi
  
  printf "HTTP连接测试: "
  if timeout 3 curl -s http://www.google.com >/dev/null 2>&1; then
    printf "${GREEN}正常${PLAIN}\n"
  else
    printf "${RED}失败${PLAIN}\n"
  fi
  
  printf "HTTPS连接测试: "
  if timeout 3 curl -s https://www.google.com >/dev/null 2>&1; then
    printf "${GREEN}正常${PLAIN}\n"
  else
    printf "${RED}失败${PLAIN}\n"
  fi
  
  printf "\n"
}

# 显示菜单
show_menu() {
  local ip_info=$(get_simple_ip_info)
  printf "\n${BOLD}${COLOR_MENU_BORDER}========== Brook 端口转发管理 (v%s) ==========${PLAIN}\n" "$VERSION"
  if [ -n "$ip_info" ] && [ "$ip_info" != "无法获取IP信息" ] && [ "$ip_info" != "网络工具未就绪" ]; then printf "${INFO_SYMBOL} 本机IP: ${COLOR_IP_INFO}%s${PLAIN}\n" "$ip_info";
  else printf "${WARN_SYMBOL} 本机IP信息: ${COLOR_WARNING}%s${PLAIN}\n" "$ip_info"; fi
  printf "${BOLD}${COLOR_MENU_BORDER}----------------------------------------------------${PLAIN}\n"
  echo -e "  ${COLOR_MENU_ITEM}1.${PLAIN} 添加转发\n  ${COLOR_MENU_ITEM}2.${PLAIN} 列出所有转发\n  ${COLOR_MENU_ITEM}3.${PLAIN} 删除转发\n  ${COLOR_MENU_ITEM}4.${PLAIN} 重启所有服务\n  ${COLOR_MENU_ITEM}5.${PLAIN} 查看服务日志\n  ${COLOR_MENU_ITEM}6.${PLAIN} 测试转发功能\n  ${COLOR_MENU_ITEM}7.${PLAIN} 卸载Brook\n  ${COLOR_MENU_ITEM}8.${PLAIN} 显示详细IP信息\n  ${COLOR_MENU_ITEM}0.${PLAIN} 退出"
  printf "${BOLD}${COLOR_MENU_BORDER}====================================================${PLAIN}\n"
}

# 重启所有服务
restart_all_services() {
  printf "${CYAN}${INFO_SYMBOL} 重启所有Brook转发服务...${PLAIN}\n"
  
  local service_files=($($SUDO find /etc/systemd/system -name "${SERVICE_PREFIX}-*.service" 2>/dev/null | sort))
  
  if [ ${#service_files[@]} -eq 0 ]; then
    printf "${YELLOW}${WARN_SYMBOL} 没有找到Brook转发服务${PLAIN}\n"
    return
  fi
  
  local count=0
  for service_file in "${service_files[@]}"; do 
    local service_name=$(basename "$service_file" .service)
    if $SUDO systemctl restart "$service_name" 2>/dev/null; then 
      ((count++))
      printf "${SUCCESS_SYMBOL} %s 重启成功${PLAIN}\n" "$service_name"
    else 
      printf "${ERROR_SYMBOL} %s 重启失败${PLAIN}\n" "$service_name"
    fi
  done
  
  printf "${SUCCESS_SYMBOL} 共重启 %d 个服务${PLAIN}\n" "$count"
}

# 查看服务日志
view_service_logs() {
  list_forwards
  
  local service_files=($($SUDO find /etc/systemd/system -name "${SERVICE_PREFIX}-*.service" 2>/dev/null | sort))
  
  if [ ${#service_files[@]} -eq 0 ]; then 
    return
  fi
  
  # 创建服务名称数组
  local services=()
  for service_file in "${service_files[@]}"; do
    services+=($(basename "$service_file" .service))
  done
  
  printf "\n"
  echo -e "${COLOR_INFO_TEXT}请输入要查看日志的服务编号 (输入0查看所有): ${PLAIN}\c"
  read choice
  
  if [ "$choice" -eq 0 ]; then 
    printf "${CYAN}${INFO_SYMBOL} 显示所有Brook服务的最新日志...${PLAIN}\n"
    for service_name in "${services[@]}"; do
      printf "\n${CYAN}=== %s 日志 ===${PLAIN}\n" "$service_name"
      $SUDO journalctl -u "$service_name" --no-pager -n 10 2>/dev/null || printf "${YELLOW}${WARN_SYMBOL} 无法获取 %s 的日志${PLAIN}\n" "$service_name"
    done
  elif [ "$choice" -ge 1 ] && [ "$choice" -le ${#services[@]} ]; then 
    local service_name=${services[$((choice-1))]}
    printf "${CYAN}${INFO_SYMBOL} 显示 %s 的日志...${PLAIN}\n" "$service_name"
    $SUDO journalctl -u "$service_name" --no-pager -n 50 2>/dev/null || printf "${YELLOW}${WARN_SYMBOL} 无法获取 %s 的日志${PLAIN}\n" "$service_name"
  else 
    printf "${ERROR_SYMBOL} 无效的选择${PLAIN}\n"
  fi
}

# 测试Brook转发功能
test_brook_forward() {
  list_forwards
  
  local service_files=($($SUDO find /etc/systemd/system -name "${SERVICE_PREFIX}-*.service" 2>/dev/null | sort))
  
  if [ ${#service_files[@]} -eq 0 ]; then 
    return
  fi
  
  # 创建服务名称数组
  local services=()
  for service_file in "${service_files[@]}"; do
    services+=($(basename "$service_file" .service))
  done
  
  printf "\n"
  echo -e "${COLOR_INFO_TEXT}请输入要测试的服务编号 (输入0取消): ${PLAIN}\c"
  read choice
  
  if [ "$choice" -eq 0 ]; then 
    printf "${YELLOW}${INFO_SYMBOL} 已取消测试${PLAIN}\n"
    return
  fi
  
  if [ "$choice" -lt 1 ] || [ "$choice" -gt ${#services[@]} ]; then 
    printf "${ERROR_SYMBOL} 无效的选择${PLAIN}\n"
    return
  fi
  
  local service_name=${services[$((choice-1))]}
  local info=$(grep "^${service_name}|" "$CONFIG_FILE" 2>/dev/null | head -1)
  
  if [ -n "$info" ]; then
    local local_port=$(echo "$info" | cut -d'|' -f2)
    local remote_addr=$(echo "$info" | cut -d'|' -f3)
    local proto=$(echo "$info" | cut -d'|' -f4)
    
    printf "${CYAN}${INFO_SYMBOL} 测试转发: 本地端口 %s (%s) -> %s${PLAIN}\n" "$local_port" "$proto" "$remote_addr"
    
    # 检查服务状态
    printf "${CYAN}${INFO_SYMBOL} 检查服务状态...${PLAIN}\n"
    if $SUDO systemctl is-active --quiet "$service_name" 2>/dev/null; then
      printf "${SUCCESS_SYMBOL} 服务 %s 正在运行${PLAIN}\n" "$service_name"
    else
      printf "${ERROR_SYMBOL} 服务 %s 未运行，尝试启动...${PLAIN}\n" "$service_name"
      if $SUDO systemctl start "$service_name" 2>/dev/null; then
        printf "${SUCCESS_SYMBOL} 服务已启动${PLAIN}\n"
      else
        printf "${ERROR_SYMBOL} 服务启动失败${PLAIN}\n"
        return
      fi
    fi
    
    # 简单的端口连通性测试
    printf "${CYAN}${INFO_SYMBOL} 测试端口连通性...${PLAIN}\n"
    if timeout 3 bash -c "</dev/tcp/127.0.0.1/${local_port}" 2>/dev/null; then
      printf "${SUCCESS_SYMBOL} 本地端口 %s 可达${PLAIN}\n" "$local_port"
    else
      printf "${YELLOW}${WARN_SYMBOL} 本地端口 %s 无法连接或目标服务器无响应${PLAIN}\n" "$local_port"
    fi
  else
    printf "${ERROR_SYMBOL} 无法获取服务信息${PLAIN}\n"
  fi
}

# 主函数
main() {
  if [ "$EUID" -ne 0 ]; then if ! command -v sudo &>/dev/null; then printf "${ERROR_SYMBOL}检测到非root用户，且sudo命令未找到。请以root用户运行或安装sudo。${PLAIN}\n"; exit 1; fi; printf "${WARN_SYMBOL} 检测到非root用户，部分操作将需要sudo权限。${PLAIN}\n"; else printf "${INFO_SYMBOL} 检测到root用户。${PLAIN}\n"; fi
  if ! check_and_install_dependencies; then printf "${ERROR_SYMBOL} 初始化或依赖安装失败，脚本终止。${PLAIN}\n"; exit 1; fi
  setup_config_dir
  while true; do
    show_menu
    echo -e "${COLOR_INFO_TEXT}请选择操作 [0-8]: ${PLAIN}\c"
    read choice
    case $choice in
      1) add_forward ;; 
      2) list_forwards ;; 
      3) delete_forward ;; 
      4) restart_all_services ;;
      5) view_service_logs ;; 
      6) test_brook_forward ;;
      7) uninstall_brook; if [ $? -eq 0 ]; then break; fi ;; # 卸载成功后退出
      8) show_ip_info ;; 
      0) printf "${SUCCESS_SYMBOL} 感谢使用，再见！${PLAIN}\n"; break ;; 
      *) printf "${ERROR_SYMBOL} 无效的选择，请重试${PLAIN}\n" ;;
    esac
  done
}

main "$@" 
