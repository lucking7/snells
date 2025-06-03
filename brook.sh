#!/bin/bash

# Brook端口转发统一管理脚本
# 支持功能: TCP转发、UDP转发、TCP+UDP转发、TCP和UDP分别转发到不同地址
# 版本: 1.0

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

  # 检测包管理器
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

  # 检查缺失的包
  for pkg in "${essential_pkgs[@]}"; do
    if ! command -v $pkg &>/dev/null; then
      pkgs_to_install+=($pkg)
    fi
  done

  # 安装缺失的包
  if [ ${#pkgs_to_install[@]} -gt 0 ]; then
    printf "${YELLOW}${INFO_SYMBOL} 缺失以下包: %s${PLAIN}\n" "${pkgs_to_install[*]}"
    printf "${YELLOW}${INFO_SYMBOL} 尝试使用 %s 安装...${PLAIN}\n" "$pkg_manager_detected"
    if [ "$pkg_manager_detected" == "apt-get" ]; then
      sudo apt-get update -y || printf "${RED}${ERROR_SYMBOL} 更新包列表失败。${PLAIN}\n"
    fi
    if sudo $pkg_manager_detected install -y "${pkgs_to_install[@]}"; then
      printf "${GREEN}${SUCCESS_SYMBOL} 成功安装: %s${PLAIN}\n" "${pkgs_to_install[*]}"
    else
      printf "${RED}${ERROR_SYMBOL} 安装失败。请手动安装后重试。${PLAIN}\n"
      exit 1
    fi
  fi

  # 检查并安装brook
  if ! command -v brook &>/dev/null; then
    printf "${YELLOW}${INFO_SYMBOL} Brook未安装。正在安装Brook...${PLAIN}\n"
    (bash <(curl -fsSL https://bash.ooo/nami.sh)) &
    show_loading $!
    nami install brook
    if command -v brook &>/dev/null; then
      printf "${GREEN}${SUCCESS_SYMBOL} Brook安装成功。${PLAIN}\n"
    else
      printf "${RED}${ERROR_SYMBOL} Brook安装失败。请手动安装。${PLAIN}\n"
      exit 1
    fi
  else
    printf "${GREEN}${SUCCESS_SYMBOL} Brook已安装。${PLAIN}\n"
  fi
}

# 设置配置目录
setup_config_dir() {
  if [ ! -d "$CONFIG_DIR" ]; then
    sudo mkdir -p "$CONFIG_DIR"
    printf "${GREEN}${SUCCESS_SYMBOL} 创建配置目录: %s${PLAIN}\n" "$CONFIG_DIR"
  fi

  if [ ! -f "$CONFIG_FILE" ]; then
    sudo touch "$CONFIG_FILE"
    printf "${GREEN}${SUCCESS_SYMBOL} 创建配置文件: %s${PLAIN}\n" "$CONFIG_FILE"
  fi
}

# 验证输入
validate_input() {
  local input=$1
  local input_type=$2

  case $input_type in
  "port")
    if ! [[ "$input" =~ ^[0-9]+$ ]] || [ "$input" -lt 1 ] || [ "$input" -gt 65535 ]; then
      printf "${RED}${ERROR_SYMBOL} 无效的端口号。必须在1-65535之间。${PLAIN}\n"
      return 1
    fi
    ;;
  "ip")
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
    if [[ "$input" =~ ^[0-9a-fA-F:]+$ ]]; then
      return 0
    fi
    printf "${RED}${ERROR_SYMBOL} 无效的IP地址格式。${PLAIN}\n"
    return 1
    ;;
  "hostname")
    if [[ "$input" =~ ^[a-zA-Z0-9]([-a-zA-Z0-9\.]{0,61}[a-zA-Z0-9])?$ ]]; then
      return 0
    fi
    printf "${RED}${ERROR_SYMBOL} 无效的主机名格式。${PLAIN}\n"
    return 1
    ;;
  esac
  return 0
}

# 生成服务名称
generate_service_name() {
  local local_port=$1
  local proto=$2
  echo "${SERVICE_PREFIX}-${local_port}-${proto}"
}

# 创建systemd服务
create_systemd_service() {
  local service_name=$1
  local local_port=$2
  local remote_addr=$3
  local proto=$4
  local service_file="${SERVICE_DIR}/${service_name}.service"

  # 根据协议类型构建命令
  local brook_cmd="/usr/local/bin/brook relay -f :${local_port} -t ${remote_addr}"
  
  # Brook relay命令支持--tcpTimeout和--udpTimeout参数
  case $proto in
    "tcp")
      brook_cmd="$brook_cmd --udpTimeout 0"  # 禁用UDP
      ;;
    "udp")
      brook_cmd="$brook_cmd --tcpTimeout 0"  # 禁用TCP
      ;;
    "both")
      # 默认TCP和UDP都启用
      ;;
  esac

  # 创建服务文件内容
  local service_content="[Unit]
Description=Brook Forward ${local_port} ${proto} to ${remote_addr}
After=network.target

[Service]
Type=simple
ExecStart=${brook_cmd}
Restart=always
RestartSec=5
User=nobody
Group=nogroup

[Install]
WantedBy=multi-user.target"

  # 写入服务文件
  echo "$service_content" | sudo tee "$service_file" > /dev/null
  
  # 设置权限
  sudo chmod 644 "$service_file"
  
  # 重载systemd配置
  sudo systemctl daemon-reload
  
  # 启用并启动服务
  sudo systemctl enable "$service_name" >/dev/null 2>&1
  sudo systemctl start "$service_name"
  
  if sudo systemctl is-active --quiet "$service_name"; then
    printf "${GREEN}${SUCCESS_SYMBOL} 服务 %s 启动成功${PLAIN}\n" "$service_name"
    return 0
  else
    printf "${RED}${ERROR_SYMBOL} 服务 %s 启动失败${PLAIN}\n" "$service_name"
    sudo journalctl -u "$service_name" --no-pager -n 10
    return 1
  fi
}

# 保存转发配置到文件
save_forward_config() {
  local local_port=$1
  local remote_addr=$2
  local proto=$3
  local service_name=$4
  
  echo "${service_name}|${local_port}|${remote_addr}|${proto}" | sudo tee -a "$CONFIG_FILE" > /dev/null
}

# 添加转发
add_forward() {
  printf "${CYAN}${BOLD}请选择转发类型:${PLAIN}\n"
  printf "  ${GREEN}1.${PLAIN} 仅TCP转发\n"
  printf "  ${GREEN}2.${PLAIN} 仅UDP转发\n"
  printf "  ${GREEN}3.${PLAIN} TCP+UDP转发到相同地址\n"
  printf "  ${GREEN}4.${PLAIN} TCP和UDP分别转发到不同地址\n"
  
  read -p "请选择 [1-4]: " forward_type
  
  case $forward_type in
    1|2|3|4)
      ;;
    *)
      printf "${RED}${ERROR_SYMBOL} 无效的选择${PLAIN}\n"
      return 1
      ;;
  esac

  # 获取本地端口
  while true; do
    read -p "请输入本地监听端口 [1-65535]: " local_port
    if validate_input "$local_port" "port"; then
      # 检查端口是否已被占用
      if lsof -i:$local_port >/dev/null 2>&1; then
        printf "${RED}${ERROR_SYMBOL} 端口 $local_port 已被占用${PLAIN}\n"
      else
        break
      fi
    fi
  done

  case $forward_type in
    1) # 仅TCP
      while true; do
        read -p "请输入目标地址 (IP:端口): " remote_addr
        if [[ "$remote_addr" =~ ^[^:]+:[0-9]+$ ]]; then
          remote_ip=$(echo "$remote_addr" | cut -d: -f1)
          remote_port=$(echo "$remote_addr" | cut -d: -f2)
          if (validate_input "$remote_ip" "ip" || validate_input "$remote_ip" "hostname") && validate_input "$remote_port" "port"; then
            break
          fi
        else
          printf "${RED}${ERROR_SYMBOL} 格式错误，请使用 IP:端口 格式${PLAIN}\n"
        fi
      done
      
      service_name=$(generate_service_name "$local_port" "tcp")
      create_systemd_service "$service_name" "$local_port" "$remote_addr" "tcp"
      save_forward_config "$local_port" "$remote_addr" "tcp" "$service_name"
      ;;
      
    2) # 仅UDP
      while true; do
        read -p "请输入目标地址 (IP:端口): " remote_addr
        if [[ "$remote_addr" =~ ^[^:]+:[0-9]+$ ]]; then
          remote_ip=$(echo "$remote_addr" | cut -d: -f1)
          remote_port=$(echo "$remote_addr" | cut -d: -f2)
          if (validate_input "$remote_ip" "ip" || validate_input "$remote_ip" "hostname") && validate_input "$remote_port" "port"; then
            break
          fi
        else
          printf "${RED}${ERROR_SYMBOL} 格式错误，请使用 IP:端口 格式${PLAIN}\n"
        fi
      done
      
      service_name=$(generate_service_name "$local_port" "udp")
      create_systemd_service "$service_name" "$local_port" "$remote_addr" "udp"
      save_forward_config "$local_port" "$remote_addr" "udp" "$service_name"
      ;;
      
    3) # TCP+UDP到相同地址
      while true; do
        read -p "请输入目标地址 (IP:端口): " remote_addr
        if [[ "$remote_addr" =~ ^[^:]+:[0-9]+$ ]]; then
          remote_ip=$(echo "$remote_addr" | cut -d: -f1)
          remote_port=$(echo "$remote_addr" | cut -d: -f2)
          if (validate_input "$remote_ip" "ip" || validate_input "$remote_ip" "hostname") && validate_input "$remote_port" "port"; then
            break
          fi
        else
          printf "${RED}${ERROR_SYMBOL} 格式错误，请使用 IP:端口 格式${PLAIN}\n"
        fi
      done
      
      service_name=$(generate_service_name "$local_port" "both")
      create_systemd_service "$service_name" "$local_port" "$remote_addr" "both"
      save_forward_config "$local_port" "$remote_addr" "both" "$service_name"
      ;;
      
    4) # TCP和UDP分别转发
      # TCP目标地址
      while true; do
        read -p "请输入TCP目标地址 (IP:端口): " tcp_remote_addr
        if [[ "$tcp_remote_addr" =~ ^[^:]+:[0-9]+$ ]]; then
          tcp_remote_ip=$(echo "$tcp_remote_addr" | cut -d: -f1)
          tcp_remote_port=$(echo "$tcp_remote_addr" | cut -d: -f2)
          if (validate_input "$tcp_remote_ip" "ip" || validate_input "$tcp_remote_ip" "hostname") && validate_input "$tcp_remote_port" "port"; then
            break
          fi
        else
          printf "${RED}${ERROR_SYMBOL} 格式错误，请使用 IP:端口 格式${PLAIN}\n"
        fi
      done
      
      # UDP目标地址
      while true; do
        read -p "请输入UDP目标地址 (IP:端口): " udp_remote_addr
        if [[ "$udp_remote_addr" =~ ^[^:]+:[0-9]+$ ]]; then
          udp_remote_ip=$(echo "$udp_remote_addr" | cut -d: -f1)
          udp_remote_port=$(echo "$udp_remote_addr" | cut -d: -f2)
          if (validate_input "$udp_remote_ip" "ip" || validate_input "$udp_remote_ip" "hostname") && validate_input "$udp_remote_port" "port"; then
            break
          fi
        else
          printf "${RED}${ERROR_SYMBOL} 格式错误，请使用 IP:端口 格式${PLAIN}\n"
        fi
      done
      
      # 创建TCP服务
      tcp_service_name=$(generate_service_name "$local_port" "tcp")
      create_systemd_service "$tcp_service_name" "$local_port" "$tcp_remote_addr" "tcp"
      save_forward_config "$local_port" "$tcp_remote_addr" "tcp" "$tcp_service_name"
      
      # 创建UDP服务
      udp_service_name=$(generate_service_name "$local_port" "udp")
      create_systemd_service "$udp_service_name" "$local_port" "$udp_remote_addr" "udp"
      save_forward_config "$local_port" "$udp_remote_addr" "udp" "$udp_service_name"
      ;;
  esac
  
  printf "${GREEN}${SUCCESS_SYMBOL} 转发添加成功！${PLAIN}\n"
}

# 列出所有转发
list_forwards() {
  printf "${CYAN}${BOLD}当前活动的Brook转发:${PLAIN}\n"
  printf "${CYAN}%-5s %-20s %-10s %-25s %-8s %-10s${PLAIN}\n" "编号" "服务名称" "本地端口" "目标地址" "协议" "状态"
  printf "${CYAN}%s${PLAIN}\n" "--------------------------------------------------------------------------------"
  
  local count=0
  local services=$(systemctl list-units --type=service --all | grep "^${SERVICE_PREFIX}" | awk '{print $1}')
  
  if [ -z "$services" ]; then
    printf "${YELLOW}${WARN_SYMBOL} 没有找到活动的转发服务${PLAIN}\n"
    return
  fi
  
  for service in $services; do
    ((count++))
    local service_name=$(echo $service | sed 's/.service$//')
    local status="未知"
    
    if systemctl is-active --quiet "$service"; then
      status="${GREEN}运行中${PLAIN}"
    else
      status="${RED}已停止${PLAIN}"
    fi
    
    # 从配置文件读取信息
    local info=$(grep "^${service_name}|" "$CONFIG_FILE" 2>/dev/null | head -1)
    if [ -n "$info" ]; then
      local local_port=$(echo "$info" | cut -d'|' -f2)
      local remote_addr=$(echo "$info" | cut -d'|' -f3)
      local proto=$(echo "$info" | cut -d'|' -f4)
      
      printf "%-5s %-20s %-10s %-25s %-8s %b\n" "$count" "$service_name" "$local_port" "$remote_addr" "$proto" "$status"
    else
      # 如果配置文件中没有，尝试从服务名称解析
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
  
  local services=($(systemctl list-units --type=service --all | grep "^${SERVICE_PREFIX}" | awk '{print $1}' | sed 's/.service$//'))
  
  if [ ${#services[@]} -eq 0 ]; then
    return
  fi
  
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
    # 停止并禁用服务
    sudo systemctl stop "$service_name" 2>/dev/null
    sudo systemctl disable "$service_name" 2>/dev/null
    
    # 删除服务文件
    sudo rm -f "${SERVICE_DIR}/${service_name}.service"
    
    # 从配置文件中删除
    sudo sed -i "/^${service_name}|/d" "$CONFIG_FILE"
    
    # 重载systemd
    sudo systemctl daemon-reload
    
    printf "${GREEN}${SUCCESS_SYMBOL} 服务 %s 已删除${PLAIN}\n" "$service_name"
  else
    printf "${YELLOW}${INFO_SYMBOL} 已取消删除${PLAIN}\n"
  fi
}

# 卸载brook
uninstall_brook() {
  printf "${YELLOW}${WARN_SYMBOL} 此操作将卸载Brook并删除所有转发服务。确定要继续吗? [y/N]: ${PLAIN}"
  read -r confirm
  
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    printf "${YELLOW}${INFO_SYMBOL} 已取消卸载${PLAIN}\n"
    return
  fi
  
  printf "${CYAN}${INFO_SYMBOL} 停止所有Brook转发服务...${PLAIN}\n"
  
  # 停止并删除所有brook转发服务
  local services=$(systemctl list-units --type=service --all | grep "^${SERVICE_PREFIX}" | awk '{print $1}')
  for service in $services; do
    sudo systemctl stop "$service" 2>/dev/null
    sudo systemctl disable "$service" 2>/dev/null
    sudo rm -f "${SERVICE_DIR}/$service"
  done
  
  # 重载systemd
  sudo systemctl daemon-reload
  
  # 删除配置文件和目录
  sudo rm -rf "$CONFIG_DIR"
  
  # 卸载brook
  if command -v nami &>/dev/null; then
    printf "${CYAN}${INFO_SYMBOL} 卸载Brook...${PLAIN}\n"
    nami remove brook
  else
    # 如果没有nami，尝试直接删除brook二进制文件
    sudo rm -f /usr/local/bin/brook
  fi
  
  printf "${GREEN}${SUCCESS_SYMBOL} Brook已完全卸载${PLAIN}\n"
}

# 显示菜单
show_menu() {
  printf "\n${PURPLE}${BOLD}========== Brook 端口转发管理 ==========${PLAIN}\n"
  printf "  ${GREEN}1.${PLAIN} 添加转发\n"
  printf "  ${GREEN}2.${PLAIN} 列出所有转发\n"
  printf "  ${GREEN}3.${PLAIN} 删除转发\n"
  printf "  ${GREEN}4.${PLAIN} 重启所有服务\n"
  printf "  ${GREEN}5.${PLAIN} 查看服务日志\n"
  printf "  ${GREEN}6.${PLAIN} 卸载Brook\n"
  printf "  ${GREEN}0.${PLAIN} 退出\n"
  printf "${PURPLE}${BOLD}=======================================${PLAIN}\n"
}

# 重启所有服务
restart_all_services() {
  printf "${CYAN}${INFO_SYMBOL} 重启所有Brook转发服务...${PLAIN}\n"
  
  local services=$(systemctl list-units --type=service --all | grep "^${SERVICE_PREFIX}" | awk '{print $1}')
  local count=0
  
  for service in $services; do
    if sudo systemctl restart "$service"; then
      ((count++))
      printf "${GREEN}${SUCCESS_SYMBOL} %s 重启成功${PLAIN}\n" "$service"
    else
      printf "${RED}${ERROR_SYMBOL} %s 重启失败${PLAIN}\n" "$service"
    fi
  done
  
  printf "${GREEN}${SUCCESS_SYMBOL} 共重启 %d 个服务${PLAIN}\n" "$count"
}

# 查看服务日志
view_service_logs() {
  list_forwards
  
  local services=($(systemctl list-units --type=service --all | grep "^${SERVICE_PREFIX}" | awk '{print $1}' | sed 's/.service$//'))
  
  if [ ${#services[@]} -eq 0 ]; then
    return
  fi
  
  printf "\n"
  read -p "请输入要查看日志的服务编号 (输入0查看所有): " choice
  
  if [ "$choice" -eq 0 ]; then
    printf "${CYAN}${INFO_SYMBOL} 显示所有Brook服务的最新日志...${PLAIN}\n"
    sudo journalctl -u "${SERVICE_PREFIX}*" --no-pager -n 50
  elif [ "$choice" -ge 1 ] && [ "$choice" -le ${#services[@]} ]; then
    local service_name=${services[$((choice-1))]}
    printf "${CYAN}${INFO_SYMBOL} 显示 %s 的日志...${PLAIN}\n" "$service_name"
    sudo journalctl -u "$service_name" --no-pager -n 50
  else
    printf "${RED}${ERROR_SYMBOL} 无效的选择${PLAIN}\n"
  fi
}

# 主函数
main() {
  # 检查root权限
  if [ "$EUID" -eq 0 ]; then
    printf "${YELLOW}${WARN_SYMBOL} 检测到root用户。建议使用普通用户运行此脚本。${PLAIN}\n"
  fi
  
  # 初始化
  check_and_install_dependencies
  setup_config_dir
  
  # 主循环
  while true; do
    show_menu
    read -p "请选择操作 [0-6]: " choice
    
    case $choice in
      1) add_forward ;;
      2) list_forwards ;;
      3) delete_forward ;;
      4) restart_all_services ;;
      5) view_service_logs ;;
      6) uninstall_brook; break ;;
      0) 
        printf "${GREEN}${SUCCESS_SYMBOL} 感谢使用，再见！${PLAIN}\n"
        break 
        ;;
      *)
        printf "${RED}${ERROR_SYMBOL} 无效的选择，请重试${PLAIN}\n"
        ;;
    esac
  done
}

# 运行主函数
main "$@" 
