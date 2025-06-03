#!/bin/bash

# Brook端口转发统一管理脚本
# 支持功能: TCP转发、UDP转发、TCP+UDP转发、TCP和UDP分别转发到不同地址
# 版本: 1.4.1 - 修复服务列表显示问题，简化界面，移除emoji适配服务器环境

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
PURPLE='\033[1;35m'
CYAN='\033[1;36m'
WHITE='\033[1;37m'
BOLD='\033[1m'
UNDERLINE='\033[4m'
PLAIN='\033[0m'

# 服务文件目录
SERVICE_DIR="/etc/systemd/system"
SERVICE_PREFIX="brook-forward"

# 配置目录
CONFIG_DIR="/etc/brook"
CONFIG_FILE="$CONFIG_DIR/forwards.conf"

# 符号定义
SUCCESS_SYMBOL="[+]"
ERROR_SYMBOL="[x]"
INFO_SYMBOL="[i]"
WARN_SYMBOL="[!]"

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
  printf "${GREEN}%s%b${PLAIN}\n" "[OK]"
}

# 检查并安装依赖和brook
check_and_install_dependencies() {
  printf "${BLUE}${INFO_SYMBOL} 执行初始设置和依赖检查...${PLAIN}\n"
  
  local essential_pkgs=("lsof" "curl" "jq")
  local pkgs_to_install=()
  local pkg_manager_detected=""

  if command -v apt-get &>/dev/null; then
    pkg_manager_detected="apt-get"
  elif command -v yum &>/dev/null; then
    pkg_manager_detected="yum"
  elif command -v dnf &>/dev/null; then
    pkg_manager_detected="dnf"
  else
    printf "${RED}${ERROR_SYMBOL} 未找到支持的包管理器。请手动安装依赖。${PLAIN}\n"
    exit 1
  fi

  for pkg in "${essential_pkgs[@]}"; do
    if ! command -v $pkg &>/dev/null; then
      pkgs_to_install+=($pkg)
    fi
  done

  if [ ${#pkgs_to_install[@]} -gt 0 ]; then
    printf "${YELLOW}${INFO_SYMBOL} 缺失以下包: %s${PLAIN}\n" "${pkgs_to_install[*]}"
    printf "${YELLOW}${INFO_SYMBOL} 尝试使用 %s 安装...${PLAIN}\n" "$pkg_manager_detected"
    if [ "$pkg_manager_detected" == "apt-get" ]; then
      $SUDO apt-get update -y || printf "${RED}${ERROR_SYMBOL} 更新包列表失败。${PLAIN}\n"
    fi
    if $SUDO $pkg_manager_detected install -y "${pkgs_to_install[@]}"; then
      printf "${GREEN}${SUCCESS_SYMBOL} 成功安装: %s${PLAIN}\n" "${pkgs_to_install[*]}"
    else
      printf "${RED}${ERROR_SYMBOL} 安装失败。请手动安装后重试。${PLAIN}\n"
      exit 1
    fi
  fi

  # 检查Brook是否安装 - 使用多种检测方式
  local brook_available=false
  local nami_bin_path="${SCRIPT_RUNNER_HOME}/.nami/bin"
  
  if command -v brook &>/dev/null && brook --help &>/dev/null; then
    brook_available=true
  elif [ -x "${nami_bin_path}/brook" ] && "${nami_bin_path}/brook" --help &>/dev/null; then
    brook_available=true
  fi
  
  if ! $brook_available; then
    printf "${YELLOW}${INFO_SYMBOL} Brook未安装或无法执行。尝试安装/修复...${PLAIN}\n"
    
    local nami_bin_path="${SCRIPT_RUNNER_HOME}/.nami/bin"
    
    if ! command -v nami &>/dev/null && ! [ -x "${nami_bin_path}/nami" ]; then
      printf "${CYAN}${INFO_SYMBOL} Nami未安装，开始安装nami...${PLAIN}\n"
      local nami_install_script_url="https://bash.ooo/nami.sh"
      local tmp_nami_script="/tmp/nami_install_temp.sh"
      curl -fsSL "$nami_install_script_url" -o "$tmp_nami_script" || {
          printf "${RED}${ERROR_SYMBOL} 下载nami安装脚本失败 (%s)。${PLAIN}\n" "$nami_install_script_url";
          install_brook_binary; return $?;
      }
      # 从下载的脚本中移除 'exec -l $SHELL' 这一行
      sed -i.bak '/^exec -l /d' "$tmp_nami_script"
      
      bash "$tmp_nami_script"
      local nami_install_status=$?
      rm -f "$tmp_nami_script" "$tmp_nami_script.bak"

      if [ $nami_install_status -ne 0 ]; then
        printf "${RED}${ERROR_SYMBOL} Nami安装脚本执行失败。${PLAIN}\n"
        install_brook_binary
        return $?
      fi
      printf "${GREEN}${SUCCESS_SYMBOL} Nami已安装。${PLAIN}\n"
    fi
    
    if ! echo "$PATH" | grep -qF "${nami_bin_path}"; then export PATH="${nami_bin_path}:$PATH"; printf "${INFO_SYMBOL} Nami路径已添加到当前会话PATH: %s${PLAIN}\n" "$nami_bin_path"; fi

    local nami_cmd="nami"
    if ! command -v nami &>/dev/null; then
        if [ -x "${nami_bin_path}/nami" ]; then
            nami_cmd="${nami_bin_path}/nami"
        else
            printf "${RED}${ERROR_SYMBOL} Nami安装后仍无法找到命令，尝试手动下载brook...${PLAIN}\n"; install_brook_binary; return $?;
        fi 
    fi

    printf "${CYAN}${INFO_SYMBOL} 使用 '$nami_cmd' 安装Brook...${PLAIN}\n"
    $nami_cmd install brook || {
      printf "${RED}${ERROR_SYMBOL} 使用nami安装brook失败，尝试手动下载...${PLAIN}\n"
      install_brook_binary
      return $?
    }
    
    # 检查Brook是否安装成功 - 使用多种方式验证
    if command -v brook &>/dev/null && brook --help &>/dev/null; then
      printf "${GREEN}${SUCCESS_SYMBOL} Brook安装成功并可执行。${PLAIN}\n"
    elif [ -x "${nami_bin_path}/brook" ] && "${nami_bin_path}/brook" --help &>/dev/null; then
      printf "${GREEN}${SUCCESS_SYMBOL} Brook安装成功并可执行。${PLAIN}\n"
    elif $nami_cmd run brook --help &>/dev/null; then
      printf "${GREEN}${SUCCESS_SYMBOL} Brook安装成功并可执行。${PLAIN}\n"
    else
      printf "${RED}${ERROR_SYMBOL} Nami安装Brook后，Brook仍无法执行，尝试手动下载...${PLAIN}\n"
      install_brook_binary
      return $?
    fi
  else
    printf "${GREEN}${SUCCESS_SYMBOL} Brook已安装并可执行。${PLAIN}\n"
  fi
  return 0
}

# 手动下载安装brook二进制文件 (作为nami安装失败的备用方案)
install_brook_binary() {
  printf "${CYAN}${INFO_SYMBOL} 尝试手动下载Brook二进制文件...${PLAIN}\n"
  ARCH=$(uname -m)
  case $ARCH in
    x86_64|amd64) BROOK_ARCH="amd64" ;; aarch64|arm64) BROOK_ARCH="arm64" ;; i386|i686) BROOK_ARCH="386" ;; 
    *) printf "${RED}${ERROR_SYMBOL} 不支持的系统架构: %s${PLAIN}\n" "$ARCH"; return 1 ;;
  esac
  OS=$(uname -s | tr '[:upper:]' '[:lower:]')
  case $OS in
    linux) BROOK_OS="linux" ;; darwin) BROOK_OS="darwin" ;; 
    *) printf "${RED}${ERROR_SYMBOL} 不支持的操作系统: %s${PLAIN}\n" "$OS"; return 1 ;;
  esac
  
  BROOK_VERSION=$(curl -s https://api.github.com/repos/txthinking/brook/releases/latest | grep -o '"tag_name": "v[^"]*' | sed 's/"tag_name": "v//g')
  BROOK_VERSION=${BROOK_VERSION:-20230401} # 默认版本
  printf "${GREEN}${SUCCESS_SYMBOL} 使用Brook版本: %s for ${BROOK_OS}/${BROOK_ARCH}${PLAIN}\n" "$BROOK_VERSION"
  
  BROOK_URL="https://github.com/txthinking/brook/releases/download/v${BROOK_VERSION}/brook_${BROOK_OS}_${BROOK_ARCH}"
  # 旧版Brook可能没有版本号在文件名中 (brook_linux_amd64)
  BROOK_URL_LEGACY="https://github.com/txthinking/brook/releases/download/v${BROOK_VERSION}/brook_${BROOK_OS}_${BROOK_ARCH}" 
  # 更正：brook_VERSION 应该从文件名中去掉
  BROOK_URL_CORRECTED="https://github.com/txthinking/brook/releases/download/v${BROOK_VERSION}/brook_${BROOK_OS}_${BROOK_ARCH}"
  # 实际的brook release文件名通常是 brook_linux_amd64 (无版本号), 但URL路径有版本号
  # 因此，下载的文件名是 brook, URL是 .../vVERSION/brook_os_arch
  # Let's use BROOK_URL_CORRECTED

  printf "${CYAN}${INFO_SYMBOL} 正在下载Brook: %s${PLAIN}\n" "$BROOK_URL_CORRECTED"
  curl -L -o /tmp/brook "$BROOK_URL_CORRECTED"
  if [ $? -ne 0 ] || [ ! -s /tmp/brook ]; then
    printf "${RED}${ERROR_SYMBOL} 下载Brook失败 (URL: %s)。请手动安装。${PLAIN}\n" "$BROOK_URL_CORRECTED"
    return 1
  fi
  
  $SUDO chmod +x /tmp/brook
  $SUDO mv /tmp/brook /usr/local/bin/brook
  
  if command -v brook &>/dev/null && brook --help &>/dev/null; then
    printf "${GREEN}${SUCCESS_SYMBOL} Brook手动安装成功。${PLAIN}\n"
    return 0
  else
    printf "${RED}${ERROR_SYMBOL} Brook手动安装后仍无法执行。请检查/usr/local/bin。${PLAIN}\n"
    return 1
  fi
}

# 设置配置目录
setup_config_dir() {
  if [ ! -d "$CONFIG_DIR" ]; then
    $SUDO mkdir -p "$CONFIG_DIR"
    printf "${GREEN}${SUCCESS_SYMBOL} 创建配置目录: %s${PLAIN}\n" "$CONFIG_DIR"
  fi
  if [ ! -f "$CONFIG_FILE" ]; then
    $SUDO touch "$CONFIG_FILE"
    printf "${GREEN}${SUCCESS_SYMBOL} 创建配置文件: %s${PLAIN}\n" "$CONFIG_FILE"
  fi
}

# 验证输入
validate_input() {
  local input=$1
  local input_type=$2
  case $input_type in
  "port") if ! [[ "$input" =~ ^[0-9]+$ ]] || [ "$input" -lt 1 ] || [ "$input" -gt 65535 ]; then printf "${RED}${ERROR_SYMBOL} 无效的端口号。必须在1-65535之间。${PLAIN}\n"; return 1; fi ;;
  "ip") 
    # IPv4验证
    if [[ "$input" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then 
      IFS='.' read -r -a octets <<<"$input"
      for octet in "${octets[@]}"; do 
        if [ "$octet" -gt 255 ]; then 
          printf "${RED}${ERROR_SYMBOL} 无效的IPv4地址。${PLAIN}\n"
          return 1
        fi
      done
      return 0
    fi
    # 改进的IPv6验证 - 基本格式检查
    if [[ "$input" =~ ^([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}$ ]] || [[ "$input" =~ ^::([0-9a-fA-F]{0,4}:){0,6}[0-9a-fA-F]{0,4}$ ]] || [[ "$input" =~ ^([0-9a-fA-F]{0,4}:){1,6}::$ ]]; then 
      return 0
    fi
    printf "${RED}${ERROR_SYMBOL} 无效的IP地址格式。${PLAIN}\n"
    return 1 
    ;; 
  "hostname") 
    # 支持域名和主机名格式，包括下划线
    if [[ "$input" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\._-]{0,61}[a-zA-Z0-9])?$ ]] || [[ "$input" =~ ^[a-zA-Z0-9\._-]{1,63}(\.[a-zA-Z0-9\._-]{1,63})*$ ]]; then 
      return 0
    fi
    printf "${RED}${ERROR_SYMBOL} 无效的主机名格式。${PLAIN}\n"
    return 1 
    ;; 
esac; return 0;
}

# 生成服务名称
generate_service_name() { local local_port=$1; local proto=$2; echo "${SERVICE_PREFIX}-${local_port}-${proto}"; }

# 创建systemd服务
create_systemd_service() {
  local service_name=$1; local local_port=$2; local remote_addr=$3; local proto=$4
  local service_file="${SERVICE_DIR}/${service_name}.service"
  local nami_bin_dir_for_service="${SCRIPT_RUNNER_HOME}/.nami/bin"
  local brook_exec_command_for_service

  # 确定Brook执行命令的优先级，确保使用绝对路径避免PATH问题:
  # 1. /path/to/user/home/.nami/bin/brook (nami安装的brook绝对路径)
  # 2. brook in PATH (如果brook在PATH中且可用)
  # 3. /usr/local/bin/brook (手动安装的brook)
  # 4. nami run brook (如果nami可用，作为最后选择)

  if [ -x "${nami_bin_dir_for_service}/brook" ] && "${nami_bin_dir_for_service}/brook" --help &>/dev/null; then
    brook_exec_command_for_service="${nami_bin_dir_for_service}/brook"
  elif command -v brook &>/dev/null && brook --help &>/dev/null; then
    brook_exec_command_for_service=$(command -v brook)
  elif [ -x "/usr/local/bin/brook" ] && /usr/local/bin/brook --help &>/dev/null; then
    brook_exec_command_for_service="/usr/local/bin/brook"
  elif command -v nami &>/dev/null && nami run brook --help &>/dev/null; then
    brook_exec_command_for_service="nami run brook"
  elif [ -x "${nami_bin_dir_for_service}/nami" ] && "${nami_bin_dir_for_service}/nami" run brook --help &>/dev/null; then
    brook_exec_command_for_service="${nami_bin_dir_for_service}/nami run brook"
  else
    printf "${RED}${ERROR_SYMBOL} 无法确定Brook的有效执行命令。请确保Brook已正确安装。${PLAIN}\n"
    return 1
  fi
  
  printf "${CYAN}${INFO_SYMBOL} Systemd服务将使用以下Brook命令: ${GREEN}%s${PLAIN}\n" "$brook_exec_command_for_service"

  local brook_relay_cmd_line="${brook_exec_command_for_service} relay -f :${local_port} -t ${remote_addr}"
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
Description=Brook Forward ${local_port} ${proto} to ${remote_addr}
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
Environment=\"PATH=${nami_bin_dir_for_service}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\"
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
  
  if $SUDO systemctl is-active --quiet "$service_name"; then printf "${GREEN}${SUCCESS_SYMBOL} 服务 %s 启动成功${PLAIN}\n" "$service_name"; return 0;
  else printf "${RED}${ERROR_SYMBOL} 服务 %s 启动失败。请检查日志 (选项 5)。${PLAIN}\n" "$service_name"; return 1; fi
}

# 保存转发配置到文件
save_forward_config() { local local_port=$1; local remote_addr=$2; local proto=$3; local service_name=$4; echo "${service_name}|${local_port}|${remote_addr}|${proto}" | $SUDO tee -a "$CONFIG_FILE" > /dev/null; }

# 添加转发
add_forward() {
  printf "${CYAN}${BOLD}请选择转发类型:${PLAIN}\n"
  printf "  ${GREEN}1.${PLAIN} 仅TCP转发\n"
  printf "  ${GREEN}2.${PLAIN} 仅UDP转发\n"
  printf "  ${GREEN}3.${PLAIN} TCP+UDP转发到相同地址\n"
  printf "  ${GREEN}4.${PLAIN} TCP和UDP分别转发到不同地址\n"
  read -p "请选择 [1-4]: " forward_type
  if ! [[ "$forward_type" =~ ^[1-4]$ ]]; then printf "${RED}${ERROR_SYMBOL} 无效的选择${PLAIN}\n"; return 1; fi

  while true; do 
    read -p "请输入本地监听端口 [1-65535]: " local_port
    if validate_input "$local_port" "port"; then 
      # 检查端口是否被占用 (TCP和UDP)
      if lsof -i:$local_port >/dev/null 2>&1 || netstat -tuln | grep -q ":$local_port "; then 
        printf "${RED}${ERROR_SYMBOL} 端口 $local_port 已被占用${PLAIN}\n"
      else 
        # 检查是否已有Brook服务使用此端口
        if grep -q "|$local_port|" "$CONFIG_FILE" 2>/dev/null; then
          printf "${RED}${ERROR_SYMBOL} 端口 $local_port 已被Brook转发服务占用${PLAIN}\n"
        else
          break
        fi
      fi
    fi
  done

  case $forward_type in
    1|2|3) # TCP only, UDP only, or Both to same target
      local proto_str="tcp"
      if [ "$forward_type" -eq 2 ]; then proto_str="udp"; fi
      if [ "$forward_type" -eq 3 ]; then proto_str="both"; fi
      
      while true; do read -p "请输入目标IP地址或域名: " remote_ip; if validate_input "$remote_ip" "ip" || validate_input "$remote_ip" "hostname"; then break; fi; done
      while true; do read -p "请输入目标端口 [1-65535]: " remote_port; if validate_input "$remote_port" "port"; then break; fi; done
      remote_addr="${remote_ip}:${remote_port}"
      printf "${CYAN}${INFO_SYMBOL} 目标地址: ${remote_addr}${PLAIN}\n"
      
      service_name=$(generate_service_name "$local_port" "$proto_str")
      if create_systemd_service "$service_name" "$local_port" "$remote_addr" "$proto_str"; then
        save_forward_config "$local_port" "$remote_addr" "$proto_str" "$service_name"
        printf "${GREEN}${SUCCESS_SYMBOL} 转发添加成功！${PLAIN}\n"
      else
        printf "${RED}${ERROR_SYMBOL} 添加转发失败，服务未能启动。${PLAIN}\n"
      fi
      ;;
    4) # TCP and UDP to different targets
      printf "${CYAN}${BOLD}TCP转发设置:${PLAIN}\n"
      while true; do read -p "请输入TCP目标IP地址或域名: " tcp_remote_ip; if validate_input "$tcp_remote_ip" "ip" || validate_input "$tcp_remote_ip" "hostname"; then break; fi; done
      while true; do read -p "请输入TCP目标端口 [1-65535]: " tcp_remote_port; if validate_input "$tcp_remote_port" "port"; then break; fi; done
      tcp_remote_addr="${tcp_remote_ip}:${tcp_remote_port}"
      printf "${CYAN}${INFO_SYMBOL} TCP目标地址: ${tcp_remote_addr}${PLAIN}\n"
      
      printf "\n${CYAN}${BOLD}UDP转发设置:${PLAIN}\n"
      while true; do read -p "请输入UDP目标IP地址或域名: " udp_remote_ip; if validate_input "$udp_remote_ip" "ip" || validate_input "$udp_remote_ip" "hostname"; then break; fi; done
      while true; do read -p "请输入UDP目标端口 [1-65535]: " udp_remote_port; if validate_input "$udp_remote_port" "port"; then break; fi; done
      udp_remote_addr="${udp_remote_ip}:${udp_remote_port}"
      printf "${CYAN}${INFO_SYMBOL} UDP目标地址: ${udp_remote_addr}${PLAIN}\n"
      
      tcp_service_name=$(generate_service_name "$local_port" "tcp")
      udp_service_name=$(generate_service_name "$local_port" "udp") # Note: Using same local port for both services implies they are distinct (tcp vs udp)
      
      tcp_success=false
      if create_systemd_service "$tcp_service_name" "$local_port" "$tcp_remote_addr" "tcp"; then
        save_forward_config "$local_port" "$tcp_remote_addr" "tcp" "$tcp_service_name"
        tcp_success=true
      fi
      
      udp_success=false
      if create_systemd_service "$udp_service_name" "$local_port" "$udp_remote_addr" "udp"; then
        save_forward_config "$local_port" "$udp_remote_addr" "udp" "$udp_service_name"
        udp_success=true
      fi
      
      if $tcp_success && $udp_success; then printf "${GREEN}${SUCCESS_SYMBOL} TCP和UDP转发均添加成功！${PLAIN}\n"; 
      elif $tcp_success; then printf "${YELLOW}${WARN_SYMBOL} TCP转发添加成功，UDP转发失败。${PLAIN}\n";
      elif $udp_success; then printf "${YELLOW}${WARN_SYMBOL} UDP转发添加成功，TCP转发失败。${PLAIN}\n";
      else printf "${RED}${ERROR_SYMBOL} TCP和UDP转发均添加失败。${PLAIN}\n"; fi
      ;;
  esac
}

# 列出所有转发
list_forwards() {
  printf "${CYAN}${BOLD}当前活动的Brook转发:${PLAIN}\n"
  printf "${CYAN}%-5s %-20s %-10s %-25s %-8s %-10s${PLAIN}\n" "编号" "服务名称" "本地端口" "目标地址" "协议" "状态"
  printf "${CYAN}%s${PLAIN}\n" "--------------------------------------------------------------------------------"
  
  local count=0
  # 修复：直接查找systemd服务文件
  local service_files=($($SUDO find /etc/systemd/system -name "${SERVICE_PREFIX}-*.service" 2>/dev/null | sort))
  
  if [ ${#service_files[@]} -eq 0 ]; then
    printf "${YELLOW}${WARN_SYMBOL} 没有找到活动的转发服务${PLAIN}\n"
    return
  fi
  
  for service_file in "${service_files[@]}"; do
    ((count++))
    local service_name=$(basename "$service_file" .service)
    local status="未知"
    
    # 检查服务状态
    if $SUDO systemctl is-active --quiet "$service_name" 2>/dev/null; then
      status="${GREEN}运行中${PLAIN}"
    elif $SUDO systemctl is-failed --quiet "$service_name" 2>/dev/null; then
      status="${RED}失败${PLAIN}"
    else
      status="${RED}已停止${PLAIN}"
    fi
    
    # 从配置文件获取信息
    local info=$(grep "^${service_name}|" "$CONFIG_FILE" 2>/dev/null | head -1)
    if [ -n "$info" ]; then
      local local_port=$(echo "$info" | cut -d'|' -f2)
      local remote_addr=$(echo "$info" | cut -d'|' -f3)
      local proto=$(echo "$info" | cut -d'|' -f4)
      printf "%-5s %-20s %-10s %-25s %-8s %b\n" "$count" "$service_name" "$local_port" "$remote_addr" "$proto" "$status"
    else
      # 从服务名称解析信息
      local parts=(${service_name//-/ })
      if [ ${#parts[@]} -ge 4 ]; then
        local local_port=${parts[2]}
        local proto=${parts[3]}
        printf "%-5s %-20s %-10s %-25s %-8s %b\n" "$count" "$service_name" "$local_port" "未知" "$proto" "$status"
      fi
    fi
  done
  
  printf "\n${CYAN}${INFO_SYMBOL} 共 %d 个转发服务${PLAIN}\n" "$count"
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
  read -p "请输入要删除的服务编号 (输入0取消): " choice
  
  if [ "$choice" -eq 0 ]; then 
    printf "${YELLOW}${INFO_SYMBOL} 已取消删除${PLAIN}\n"
    return
  fi
  
  if [ "$choice" -lt 1 ] || [ "$choice" -gt ${#services[@]} ]; then 
    printf "${RED}${ERROR_SYMBOL} 无效的选择${PLAIN}\n"
    return
  fi
  
  local service_name=${services[$((choice-1))]}
  printf "${YELLOW}${WARN_SYMBOL} 确定要删除服务 %s 吗? [y/N]: ${PLAIN}" "$service_name"
  read -r confirm
  
  if [[ "$confirm" =~ ^[Yy]$ ]]; then
    $SUDO systemctl stop "$service_name" 2>/dev/null
    $SUDO systemctl disable "$service_name" 2>/dev/null
    $SUDO rm -f "${SERVICE_DIR}/${service_name}.service"
    $SUDO sed -i "/^${service_name}|/d" "$CONFIG_FILE" 2>/dev/null
    $SUDO systemctl daemon-reload
    printf "${GREEN}${SUCCESS_SYMBOL} 服务 %s 已删除${PLAIN}\n" "$service_name"
  else
    printf "${YELLOW}${INFO_SYMBOL} 已取消删除${PLAIN}\n"
  fi
}

# 卸载brook
uninstall_brook() {
  printf "${YELLOW}${WARN_SYMBOL} 此操作将卸载Brook并删除所有转发服务。确定要继续吗? [y/N]: ${PLAIN}"
  read -r confirm_brook
  if [[ ! "$confirm_brook" =~ ^[Yy]$ ]]; then printf "${YELLOW}${INFO_SYMBOL} 已取消卸载Brook${PLAIN}\n"; return 1; fi

  printf "${CYAN}${INFO_SYMBOL} 停止所有Brook转发服务...${PLAIN}\n"
  local service_files=($($SUDO find /etc/systemd/system -name "${SERVICE_PREFIX}-*.service" 2>/dev/null))
  
  for service_file in "${service_files[@]}"; do
    local service_name=$(basename "$service_file" .service)
    $SUDO systemctl stop "$service_name" 2>/dev/null
    $SUDO systemctl disable "$service_name" 2>/dev/null
    $SUDO rm -f "$service_file"
  done
  $SUDO systemctl daemon-reload
  $SUDO rm -rf "$CONFIG_DIR" 2>/dev/null

  local nami_cmd="nami"
  local nami_bin_path="${SCRIPT_RUNNER_HOME}/.nami/bin"
  if ! command -v nami &>/dev/null && [ -x "${nami_bin_path}/nami" ]; then nami_cmd="${nami_bin_path}/nami"; fi

  if command -v $nami_cmd &>/dev/null; then
    printf "${CYAN}${INFO_SYMBOL} 卸载Brook (使用 $nami_cmd)...${PLAIN}\n"
    $nami_cmd remove brook 2>/dev/null || printf "${YELLOW}${WARN_SYMBOL} 使用nami卸载Brook失败${PLAIN}\n"
  else
    printf "${YELLOW}${WARN_SYMBOL} Nami命令未找到，尝试直接删除Brook文件...${PLAIN}\n"
    $SUDO rm -f /usr/local/bin/brook 2>/dev/null # 尝试标准路径
    $SUDO rm -f "${nami_bin_path}/brook" 2>/dev/null # 尝试nami的bin路径下的brook
  fi
  printf "${GREEN}${SUCCESS_SYMBOL} Brook已完全卸载${PLAIN}\n"

  # 询问是否卸载Nami
  if command -v $nami_cmd &>/dev/null || [ -d "${SCRIPT_RUNNER_HOME}/.nami" ]; then # 只有在找到nami或nami目录时才询问
    printf "\n${YELLOW}${WARN_SYMBOL} 是否也卸载Nami (包管理器)？这将移除Nami本身及其所有已安装的包。 [y/N]: ${PLAIN}"
    read -r confirm_nami
    if [[ "$confirm_nami" =~ ^[Yy]$ ]]; then
      printf "${CYAN}${INFO_SYMBOL} 卸载Nami...${PLAIN}\n"
      if command -v $nami_cmd &>/dev/null; then
        # 如果nami命令可用，尝试用nami卸载自身 (虽然nami可能没有这个功能)
        # 通常卸载nami是删除其目录和清除PATH
        printf "${YELLOW}${INFO_SYMBOL} Nami没有 'nami remove nami' 这样的命令。将删除Nami目录和相关的PATH配置。${PLAIN}\n"
      fi
      $SUDO rm -rf "${SCRIPT_RUNNER_HOME}/.nami"
      printf "${GREEN}${SUCCESS_SYMBOL} Nami目录 (${SCRIPT_RUNNER_HOME}/.nami) 已删除。${PLAIN}\n"
      printf "${YELLOW}${WARN_SYMBOL} 请手动从您的shell配置文件 (如 .bashrc, .zshrc) 中移除 'export PATH=$HOME/.nami/bin:$PATH' 这一行。${PLAIN}\n"
    else
      printf "${INFO_SYMBOL} 已选择不卸载Nami。${PLAIN}\n"
    fi
  fi
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
  
  printf "\n${PURPLE}${BOLD}========== Brook 端口转发管理 ==========${PLAIN}\n"
  
  if [ -n "$ip_info" ]; then
    printf "${CYAN}${INFO_SYMBOL} 本机IP: ${GREEN}%s${PLAIN}\n" "$ip_info"
  fi
  
  printf "${PURPLE}${BOLD}---------------------------------------${PLAIN}\n"
  printf "  ${GREEN}1.${PLAIN} 添加转发\n"
  printf "  ${GREEN}2.${PLAIN} 列出所有转发\n"
  printf "  ${GREEN}3.${PLAIN} 删除转发\n"
  printf "  ${GREEN}4.${PLAIN} 重启所有服务\n"
  printf "  ${GREEN}5.${PLAIN} 查看服务日志\n"
  printf "  ${GREEN}6.${PLAIN} 测试转发功能\n"
  printf "  ${GREEN}7.${PLAIN} 卸载Brook\n"
  printf "  ${GREEN}8.${PLAIN} 显示详细IP信息\n"
  printf "  ${GREEN}0.${PLAIN} 退出\n"
  printf "${PURPLE}${BOLD}=======================================${PLAIN}\n"
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
      printf "${GREEN}${SUCCESS_SYMBOL} %s 重启成功${PLAIN}\n" "$service_name"
    else 
      printf "${RED}${ERROR_SYMBOL} %s 重启失败${PLAIN}\n" "$service_name"
    fi
  done
  
  printf "${GREEN}${SUCCESS_SYMBOL} 共重启 %d 个服务${PLAIN}\n" "$count"
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
  read -p "请输入要查看日志的服务编号 (输入0查看所有): " choice
  
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
    printf "${RED}${ERROR_SYMBOL} 无效的选择${PLAIN}\n"
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
  read -p "请输入要测试的服务编号 (输入0取消): " choice
  
  if [ "$choice" -eq 0 ]; then 
    printf "${YELLOW}${INFO_SYMBOL} 已取消测试${PLAIN}\n"
    return
  fi
  
  if [ "$choice" -lt 1 ] || [ "$choice" -gt ${#services[@]} ]; then 
    printf "${RED}${ERROR_SYMBOL} 无效的选择${PLAIN}\n"
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
      printf "${GREEN}${SUCCESS_SYMBOL} 服务 %s 正在运行${PLAIN}\n" "$service_name"
    else
      printf "${RED}${ERROR_SYMBOL} 服务 %s 未运行，尝试启动...${PLAIN}\n" "$service_name"
      if $SUDO systemctl start "$service_name" 2>/dev/null; then
        printf "${GREEN}${SUCCESS_SYMBOL} 服务已启动${PLAIN}\n"
      else
        printf "${RED}${ERROR_SYMBOL} 服务启动失败${PLAIN}\n"
        return
      fi
    fi
    
    # 简单的端口连通性测试
    printf "${CYAN}${INFO_SYMBOL} 测试端口连通性...${PLAIN}\n"
    if timeout 3 bash -c "</dev/tcp/127.0.0.1/${local_port}" 2>/dev/null; then
      printf "${GREEN}${SUCCESS_SYMBOL} 本地端口 %s 可达${PLAIN}\n" "$local_port"
    else
      printf "${YELLOW}${WARN_SYMBOL} 本地端口 %s 无法连接或目标服务器无响应${PLAIN}\n" "$local_port"
    fi
  else
    printf "${RED}${ERROR_SYMBOL} 无法获取服务信息${PLAIN}\n"
  fi
}

# 主函数
main() {
  if [ "$EUID" -ne 0 ]; then # 提示非root用户需要sudo
    if ! command -v sudo &>/dev/null; then
      printf "${RED}${ERROR_SYMBOL}检测到非root用户，且sudo命令未找到。请以root用户运行或安装sudo。${PLAIN}\n"
      exit 1
    fi
    printf "${YELLOW}${WARN_SYMBOL} 检测到非root用户，部分操作将需要sudo权限。${PLAIN}\n"
  else
    printf "${YELLOW}${WARN_SYMBOL} 检测到root用户。${PLAIN}\n"
  fi
  
  if ! check_and_install_dependencies; then
    printf "${RED}${ERROR_SYMBOL} 初始化或依赖安装失败，脚本终止。${PLAIN}\n"
    exit 1
  fi
  setup_config_dir
  
  while true; do
    show_menu
    read -p "请选择操作 [0-8]: " choice
    case $choice in
      1) add_forward ;; 
      2) list_forwards ;; 
      3) delete_forward ;; 
      4) restart_all_services ;;
      5) view_service_logs ;; 
      6) test_brook_forward ;;
      7) uninstall_brook; if [ $? -eq 0 ]; then break; fi ;; # 卸载成功后退出
      8) show_ip_info ;; 
      0) printf "${GREEN}${SUCCESS_SYMBOL} 感谢使用，再见！${PLAIN}\n"; break ;; 
      *) printf "${RED}${ERROR_SYMBOL} 无效的选择，请重试${PLAIN}\n" ;;
    esac
  done
}

main "$@" 
