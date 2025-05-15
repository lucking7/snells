#!/bin/bash

# GOST端口转发统一管理脚本
# 该脚本使用GOST配置文件管理所有端口转发，通过单一systemd服务运行
# 版本: 2.0
# 支持功能: 单端口转发、端口范围转发、配置文件管理
# 注意: 该脚本默认使用配置文件方式管理所有转发，不再创建多个systemd服务

# Color definitions
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

# Service files directory
SERVICE_DIR="./gost_config/services"

# Config directory and file
CONFIG_DIR="./gost_config"
CONFIG_FILE="$CONFIG_DIR/config.json"

# Simplified loading animation
show_loading() {
  local pid=$1
  local delay=0.2
  local spinstr='|/-\'
  local temp
  echo -n " "
  while ps -p $pid &>/dev/null; do
    temp=${spinstr#?}
    printf "[%c]  " "$spinstr"
    spinstr=$temp${spinstr%"$temp"}
    sleep $delay
    printf "\b\b\b\b\b"
  done
  echo -ne "\b\b\b\b\b"
  echo -e "${GREEN}[OK]${PLAIN}"
}

# Input validation function
validate_input() {
  local input=$1
  local input_type=$2

  case $input_type in
  "port")
    if ! [[ "$input" =~ ^[0-9]+$ ]] || [ "$input" -lt 1 ] || [ "$input" -gt 65535 ]; then
      echo -e "${RED}Invalid port number. Must be between 1-65535.${PLAIN}"
      return 1
    fi
    ;;
  "ip")
    # IPv4 validation
    if [[ "$input" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      # Check each octet is <= 255
      IFS='.' read -r -a octets <<<"$input"
      for octet in "${octets[@]}"; do
        if [ "$octet" -gt 255 ]; then
          echo -e "${RED}Invalid IPv4 address. Each octet must be <= 255.${PLAIN}"
          return 1
        fi
      done
      return 0
    fi

    # IPv6 validation (simplified check)
    if [[ "$input" =~ ^[0-9a-fA-F:]+$ ]]; then
      return 0
    fi

    echo -e "${RED}Invalid IP address format.${PLAIN}"
    return 1
    ;;
  "hostname")
    if [[ "$input" =~ ^[a-zA-Z0-9]([-a-zA-Z0-9\.]{0,61}[a-zA-Z0-9])?$ ]]; then
      return 0
    fi

    echo -e "${RED}Invalid hostname format.${PLAIN}"
    return 1
    ;;
  esac

  return 0
}

# Check and install necessary components
check_and_install() {
  # 只在gost未安装时进行检查
  if ! command -v gost &>/dev/null; then
    echo -e "${YELLOW}gost not found. Checking and installing dependencies...${PLAIN}"
    
    local packages=("lsof" "curl" "grep" "systemd" "jq")
    for package in "${packages[@]}"; do
      if ! command -v $package &>/dev/null; then
        echo -e "${YELLOW}Package ${BOLD}$package${PLAIN}${YELLOW} not found. Installing...${PLAIN}"

        # Detect package manager
        if command -v apt-get &>/dev/null; then
          PKG_MANAGER="apt-get"
        elif command -v yum &>/dev/null; then
          PKG_MANAGER="yum"
        elif command -v dnf &>/dev/null; then
          PKG_MANAGER="dnf"
        else
          PKG_MANAGER="apt-get"
        fi

        if ! sudo $PKG_MANAGER update -y; then
          echo -e "${RED}Failed to update package list. Please check your network connection or system status.${PLAIN}"
          continue
        fi
        if ! sudo $PKG_MANAGER install $package -y; then
          echo -e "${RED}Failed to install $package. Please install it manually.${PLAIN}"
          continue
        fi
        
        if command -v $package &>/dev/null; then
          echo -e "${GREEN}$package installed successfully.${PLAIN}"
        else
          echo -e "${RED}Failed to install $package. Please install it manually.${PLAIN}"
          if [ "$package" = "jq" ]; then
            echo -e "${YELLOW}jq is recommended for JSON configuration management but not required.${PLAIN}"
          fi
        fi
      fi
    done

    # Install gost
    echo -e "${YELLOW}Installing gost...${PLAIN}"
    (bash <(curl -fsSL https://github.com/go-gost/gost/raw/master/install.sh) --install) &
    show_loading $!
    if ! command -v gost &>/dev/null; then
      echo -e "${RED}Failed to install gost. Please install it manually.${PLAIN}"
    else
      echo -e "${GREEN}gost installed successfully.${PLAIN}"
    fi
  fi
}

# Ensure config directory and file exist
ensure_config_dir() {
  if [ ! -d "$CONFIG_DIR" ]; then
    mkdir -p "$CONFIG_DIR"
    echo -e "${GREEN}Created config directory: $CONFIG_DIR${PLAIN}"
  fi

  # Create basic config file structure if it doesn't exist
  if [ ! -f "$CONFIG_FILE" ]; then
    cat <<EOF >"$CONFIG_FILE"
{
  "services": []
}
EOF
    echo -e "${GREEN}Created base config file: $CONFIG_FILE${PLAIN}"
  fi
}

# Add forwarding to config file
add_forward_to_config() {
  local name=$1
  local listen_addr=$2
  local target_addr=$3
  local proto=$4

  # Ensure config directory and file exist
  ensure_config_dir

  # 创建临时文件来存放新的JSON配置
  local temp_file=$(mktemp)
  
  # 拆分协议类型，如果是tcp-udp，需要分别创建两个服务
  if [ "$proto" = "tcp-udp" ]; then
    # 创建TCP服务
    local tcp_service='{
      "name": "'$name'-tcp",
      "addr": "'$listen_addr'",
      "handler": {
        "type": "tcp"
      },
      "listener": {
        "type": "tcp"
      },
      "forwarder": {
        "nodes": [
          {
            "name": "target-0",
            "addr": "'$target_addr'"
          }
        ]
      }
    }'
    
    # 创建UDP服务
    local udp_service='{
      "name": "'$name'-udp",
      "addr": "'$listen_addr'",
      "handler": {
        "type": "udp"
      },
      "listener": {
        "type": "udp"
      },
      "forwarder": {
        "nodes": [
          {
            "name": "target-0",
            "addr": "'$target_addr'"
          }
        ]
      }
    }'
    
    # 使用jq将新服务添加到配置文件中
    if command -v jq &>/dev/null; then
      jq '.services += ['"$tcp_service"', '"$udp_service"']' "$CONFIG_FILE" > "$temp_file"
      if [ $? -eq 0 ]; then
        mv "$temp_file" "$CONFIG_FILE"
      else
        echo -e "${RED}Error adding services to config file.${PLAIN}"
        rm -f "$temp_file"
        return 1
      fi
    else
      # 如果没有jq，则使用简单的文本处理
      sed -i '/"services": \[/a \    '"$tcp_service"',' "$CONFIG_FILE"
      sed -i '/"services": \[/a \    '"$udp_service"',' "$CONFIG_FILE"
    fi
  else
    # 创建单协议服务
    local service='{
      "name": "'$name'",
      "addr": "'$listen_addr'",
      "handler": {
        "type": "'$proto'"
      },
      "listener": {
        "type": "'$proto'"
      },
      "forwarder": {
        "nodes": [
          {
            "name": "target-0",
            "addr": "'$target_addr'"
          }
        ]
      }
    }'
    
    # 使用jq将新服务添加到配置文件中
    if command -v jq &>/dev/null; then
      jq '.services += ['"$service"']' "$CONFIG_FILE" > "$temp_file"
      if [ $? -eq 0 ]; then
        mv "$temp_file" "$CONFIG_FILE"
      else
        echo -e "${RED}Error adding service to config file.${PLAIN}"
        rm -f "$temp_file"
        return 1
      fi
    else
      # 如果没有jq，则尝试使用简单的文本处理
      # 先检查文件是否为空或只有基本结构
      if grep -q '"services": \[\]' "$CONFIG_FILE"; then
        # 如果services数组为空
        sed -i "s/\"services\": \[\]/\"services\": \[$service\]/g" "$CONFIG_FILE"
      else
        # 如果services数组已经有内容
        sed -i "/\"services\": \[/a \    $service," "$CONFIG_FILE"
      fi
    fi
  fi

  echo -e "${GREEN}Added forwarding to config file.${PLAIN}"
}

# Apply configuration file
apply_config() {
  # 检查配置文件是否存在
  if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}Config file not found at: $CONFIG_FILE${PLAIN}"
    echo -e "${YELLOW}Initializing base config file...${PLAIN}"
    ensure_config_dir
    echo -e "${GREEN}Created base config file. Please add forwarding entries.${PLAIN}"
    return 1
  fi

  # 检查配置文件格式
  if ! grep -q '"services"' "$CONFIG_FILE"; then
    echo -e "${RED}Invalid config file format. Missing 'services' section.${PLAIN}"
    echo -e "${YELLOW}Would you like to reset the config file? (y/N)${PLAIN}"
    read reset_config
    if [[ $reset_config == [Yy]* ]]; then
      ensure_config_dir
      echo -e "${GREEN}Reset config file to base template.${PLAIN}"
    fi
    return 1
  fi

  # 检查gost命令是否存在
  if ! command -v gost &>/dev/null; then
    echo -e "${RED}gost command not found. Please install it first.${PLAIN}"
    return 1
  fi

  echo -e "${CYAN}Stopping existing gost services...${PLAIN}"

  # 停止旧的gost服务
  if systemctl is-active --quiet gost; then
    systemctl stop gost
  fi

  # 停止所有现有的转发服务
  for service in "$SERVICE_DIR"/gost-*.service; do
    if [ -f "$service" ]; then
      service_name=$(basename "$service" .service)
      echo -e "${YELLOW}Stopping $service_name...${PLAIN}"
      systemctl stop "$service_name" &>/dev/null
    fi
  done

  echo -e "${CYAN}Creating gost service to apply config file...${PLAIN}"

  # 创建服务文件
  cat <<EOF >"$SERVICE_DIR/gost.service"
[Unit]
Description=GOST Proxy Service
After=network.target

[Service]
ExecStart=/usr/local/bin/gost -C $CONFIG_FILE
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  # 重新加载systemd配置并启动服务
  systemctl daemon-reload
  systemctl enable gost

  echo -e "${CYAN}Starting gost service...${PLAIN}"
  if ! systemctl start gost; then
    echo -e "${RED}Failed to start gost service. Checking for errors...${PLAIN}"
    journalctl -u gost --no-pager -n 20
    return 1
  fi

  # 验证服务状态
  status=$(systemctl is-active gost)
  if [ "$status" = "active" ]; then
    echo -e "${GREEN}Gost service is running successfully!${PLAIN}"

    # 显示所有配置的转发
    echo -e "${CYAN}Configured forwarding services from $CONFIG_FILE:${PLAIN}"
    local counter=1

    # 解析配置文件中的转发条目
    while IFS="|" read -r name listen_addr target_addr proto; do
      if [ ! -z "$name" ]; then
        # 提取端口号和目标信息
        local local_port=$(echo "$listen_addr" | grep -o ':[0-9]\+\(-[0-9]\+\)*' | sed 's/://')
        target_ip=$(echo "$target_addr" | grep -o '[^:]*' | head -1)
        target_port=$(echo "$target_addr" | grep -o ':[0-9]\+\(-[0-9]\+\)*' | sed 's/://')

        echo -e "  ${GREEN}$counter.${PLAIN} Port $local_port ($proto) -> $target_ip:$target_port [$name]"

        ((counter++))
      fi
    done < <(parse_config_file)

    if [ $counter -eq 1 ]; then
      echo -e "${YELLOW}No forwarding entries found in config file.${PLAIN}"
    fi
  else
    echo -e "${RED}Failed to start gost service. Service status is: $status${PLAIN}"
    return 1
  fi

  echo -e "${GREEN}Successfully applied configuration from: $CONFIG_FILE${PLAIN}"
  return 0
}

# Function to find an available port
find_free_port() {
  local port
  while true; do
    port=$(shuf -i 10000-65000 -n 1)
    if ! lsof -iTCP -sTCP:LISTEN | grep -q ":$port "; then
      echo $port
      return
    fi
  done
}

# Function to create a forwarding service
create_forward_service() {
  echo -e "${CYAN}=== Create a new port forwarding ===${PLAIN}"

  # Get port information
  read -p "Local port (default: random available port): " local_port
  if [ -n "$local_port" ]; then
    if ! validate_input "$local_port" "port"; then
      read -n1 -r -p "Press any key to try again..."
      return
    fi
  else
    local_port=$(find_free_port)
    echo -e "${YELLOW}Selected available local port: ${BOLD}$local_port${PLAIN}"
  fi

  read -p "Target IP or hostname: " target_ip
  if [ -z "$target_ip" ]; then
    echo -e "${RED}Target IP or hostname cannot be empty.${PLAIN}"
    read -n1 -r -p "Press any key to try again..."
    return
  fi

  read -p "Target port: " target_port
  if ! validate_input "$target_port" "port"; then
    read -n1 -r -p "Press any key to try again..."
    return
  fi

  # Handle IPv6 addresses
  if [[ $target_ip == *:* ]] && [[ $target_ip != \[*\] ]]; then
    target_ip="[$target_ip]"
  fi

  # Select protocol
  echo -e "${CYAN}Select protocol:${PLAIN}"
  echo -e "${GREEN}1.${PLAIN} TCP"
  echo -e "${GREEN}2.${PLAIN} UDP"
  echo -e "${GREEN}3.${PLAIN} Both TCP & UDP ${YELLOW}(default)${PLAIN}"
  read -p "Select [1-3] (default: 3): " protocol_type

  case $protocol_type in
  1)
    proto="tcp"
    ;;
  2)
    proto="udp"
    ;;
  *)
    proto="tcp-udp"
    ;;
  esac

  # 创建服务名称
  service_name="forward-$local_port-to-$target_port"
  
  # 添加到配置文件
  add_forward_to_config "$service_name" ":$local_port" "$target_ip:$target_port" "$proto"
  
  # 询问是否立即应用
    read -p "Apply config file now? (Y/n): " apply_now
    if [[ $apply_now != "n" && $apply_now != "N" ]]; then
      apply_config
  fi
}

# Function to create port range forwarding
create_port_range_forward() {
  echo -e "${CYAN}=== Create Port Range Forwarding ===${PLAIN}"
  echo -e "${GREEN}1.${PLAIN} Many-to-One (Multiple local ports to one target port)"
  echo -e "${GREEN}2.${PLAIN} Many-to-Many (Each local port maps to corresponding target port)"
  read -p "Select forwarding type [1-2]: " range_type

  read -p "Local port range start: " local_start
  if ! validate_input "$local_start" "port"; then
    read -n1 -r -p "Press any key to try again..."
    return
  fi

  read -p "Local port range end: " local_end
  if ! validate_input "$local_end" "port"; then
    read -n1 -r -p "Press any key to try again..."
    return
  fi

  if [ "$local_start" -gt "$local_end" ]; then
    echo -e "${RED}Start port cannot be greater than end port.${PLAIN}"
    read -n1 -r -p "Press any key to try again..."
    return
  fi

  read -p "Target IP or hostname: " target_ip
  if [ -z "$target_ip" ]; then
    echo -e "${RED}Target IP or hostname cannot be empty.${PLAIN}"
    read -n1 -r -p "Press any key to try again..."
    return
  fi

  # Handle IPv6 addresses
  if [[ $target_ip == *:* ]] && [[ $target_ip != \[*\] ]]; then
    target_ip="[$target_ip]"
  fi

  # Select protocol
  echo -e "${CYAN}Select protocol:${PLAIN}"
  echo -e "${GREEN}1.${PLAIN} TCP"
  echo -e "${GREEN}2.${PLAIN} UDP"
  echo -e "${GREEN}3.${PLAIN} Both TCP & UDP ${YELLOW}(default)${PLAIN}"
  read -p "Select [1-3] (default: 3): " protocol_type

  case $protocol_type in
  1)
    proto="tcp"
    ;;
  2)
    proto="udp"
    ;;
  *)
    proto="tcp-udp"
    ;;
  esac

  # 创建临时文件来存放新的JSON配置
  local temp_file=$(mktemp)
  
  # 按照所选协议定义相应的处理器和监听器类型
  local handler_type
  local listener_type

  if [ "$range_type" = "1" ]; then
    # Many-to-One forwarding
    read -p "Target port: " target_port
    if ! validate_input "$target_port" "port"; then
      read -n1 -r -p "Press any key to try again..."
      rm -f "$temp_file"
      return
    fi

    service_name="range-${local_start}-${local_end}-to-${target_port}"
    target_addr="${target_ip}:${target_port}"
  else
    # Many-to-Many forwarding
    read -p "Target port range start: " target_start
    if ! validate_input "$target_start" "port"; then
      read -n1 -r -p "Press any key to try again..."
      rm -f "$temp_file"
      return
    fi

    # Calculate target port range
    local port_count=$((local_end - local_start + 1))
    local target_end=$((target_start + port_count - 1))

    service_name="range-${local_start}-${local_end}-to-${target_start}-${target_end}"
    target_addr="${target_ip}:${target_start}-${target_end}"
  fi
  
  # 拆分协议类型，如果是tcp-udp，创建两个服务
  local services_json=""
  
  if [ "$proto" = "tcp-udp" ]; then
    # TCP服务
    local tcp_service='{
      "name": "'$service_name'-tcp",
      "addr": ":'"${local_start}-${local_end}"'",
      "handler": {
        "type": "tcp" 
      },
      "listener": {
        "type": "tcp"
      },
      "forwarder": {
        "nodes": [
          {
            "name": "target-0",
            "addr": "'$target_addr'"
          }
        ]
      }
    }'
    
    # UDP服务
    local udp_service='{
      "name": "'$service_name'-udp",
      "addr": ":'"${local_start}-${local_end}"'",
      "handler": {
        "type": "udp"
      },
      "listener": {
        "type": "udp"
      },
      "forwarder": {
        "nodes": [
          {
            "name": "target-0",
            "addr": "'$target_addr'"
          }
        ]
      }
    }'
    
    services_json="$tcp_service, $udp_service"
  else
    # 单协议服务
    local service='{
      "name": "'$service_name'",
      "addr": ":'"${local_start}-${local_end}"'",
      "handler": {
        "type": "'$proto'"
      },
      "listener": {
        "type": "'$proto'"
      },
      "forwarder": {
        "nodes": [
          {
            "name": "target-0",
            "addr": "'$target_addr'"
          }
        ]
      }
    }'
    
    services_json="$service"
  fi
  
  # 确保配置目录存在
  ensure_config_dir
  
  # 添加服务到配置文件
  if command -v jq &>/dev/null; then
    # 使用jq添加服务
    if [ "$proto" = "tcp-udp" ]; then
      jq '.services += ['"$tcp_service"', '"$udp_service"']' "$CONFIG_FILE" > "$temp_file"
    else
      jq '.services += ['"$service"']' "$CONFIG_FILE" > "$temp_file"
    fi
    
    if [ $? -eq 0 ]; then
      mv "$temp_file" "$CONFIG_FILE"
    else
      echo -e "${RED}Error adding service to config file.${PLAIN}"
      rm -f "$temp_file"
      return 1
    fi
  else
    # 简单文本处理
    if grep -q '"services": \[\]' "$CONFIG_FILE"; then
      # services数组为空
      sed -i "s/\"services\": \[\]/\"services\": \[$services_json\]/g" "$CONFIG_FILE"
    else
      # services数组已有内容
      if [ "$proto" = "tcp-udp" ]; then
        sed -i "/\"services\": \[/a \    $tcp_service," "$CONFIG_FILE"
        sed -i "/\"services\": \[/a \    $udp_service," "$CONFIG_FILE"
      else
        sed -i "/\"services\": \[/a \    $service," "$CONFIG_FILE"
      fi
    fi
  fi
  
  rm -f "$temp_file"
  
  echo -e "${GREEN}Port range forwarding added to config file.${PLAIN}"
  echo -e "${CYAN}Service details:${PLAIN}"
  echo -e "  ${GREEN}- Name: $service_name${PLAIN}"
  echo -e "  ${GREEN}- Ports: $local_start-$local_end${PLAIN}"
  echo -e "  ${GREEN}- Protocol: $proto${PLAIN}"
  
  # 询问是否立即应用
  read -p "Apply config file now? (Y/n): " apply_now
  if [[ $apply_now != "n" && $apply_now != "N" ]]; then
    apply_config
  fi
}

# Function to list existing forwarding services
list_forward_services() {
  echo -e "${CYAN}=== Forwarding Services List ===${PLAIN}"
  local counter=1
  local config_found=0

  echo -e "${BLUE}Config File Forwarding Services:${PLAIN}"
  printf "%-5s %-30s %-15s %-15s %-15s %-10s\n" "No." "Service Name" "Local Port/Range" "Target Address" "Target Port" "Type"
  echo "----------------------------------------------------------------------------------------"

  if [ -f "$CONFIG_FILE" ]; then
    # 检查gost服务状态
    local gost_status=$(systemctl is-active gost 2>/dev/null)
    [ -z "$gost_status" ] && gost_status="inactive"

    # 解析配置文件
    while IFS="|" read -r name listen_addr target_addr proto; do
      if [ ! -z "$name" ]; then
        config_found=1

        # 提取端口号和目标信息
        local local_port=$(echo "$listen_addr" | grep -o ':[0-9]\+\(-[0-9]\+\)*' | sed 's/://')
        target_ip=$(echo "$target_addr" | grep -o '[^:]*' | head -1)
        target_port=$(echo "$target_addr" | grep -o ':[0-9]\+\(-[0-9]\+\)*' | sed 's/://')

        printf "%-5s %-30s %-15s %-15s %-15s %-10s\n" \
          "$counter" "$name" "$local_port" "$target_ip" "$target_port" "$proto"

        ((counter++))
      fi
    done < <(parse_config_file)

    if [ $config_found -eq 0 ]; then
      echo -e "${YELLOW}No forwarding services found in config file.${PLAIN}"
    else
      echo -e "\n${BLUE}Service Status:${PLAIN} ${gost_status}"
    fi
  else
    echo -e "${YELLOW}Config file not found at: $CONFIG_FILE${PLAIN}"
  fi

  if [ $config_found -eq 0 ]; then
    echo -e "${YELLOW}No forwarding services found.${PLAIN}"
  fi
}

# Function to manage existing forwarding services
manage_forward_services() {
  while true; do
    echo -e "\n${CYAN}=== Manage Forwarding Services ===${PLAIN}"
    echo -e "${GREEN}1.${PLAIN} List all services"
    echo -e "${GREEN}2.${PLAIN} Delete forwarding service"
    echo -e "${GREEN}3.${PLAIN} Modify forwarding service"
    echo -e "${GREEN}4.${PLAIN} Add new forwarding service"
    echo -e "${GREEN}5.${PLAIN} Start service (apply config)"
    echo -e "${GREEN}6.${PLAIN} Stop service"
    echo -e "${GREEN}7.${PLAIN} Restart service"
    echo -e "${GREEN}8.${PLAIN} Check service status"
    echo -e "${GREEN}9.${PLAIN} Return to main menu"
    read -p "$(echo -e ${YELLOW}"Please select [1-9]: "${PLAIN})" choice

    case $choice in
    1) list_forward_services ;;
    2)
      list_forward_services
      read -p "Enter the forwarding service number to delete: " service_number
      delete_config_forward "$service_number"
      ;;
    3)
      list_forward_services
      read -p "Enter the forwarding service number to modify: " service_number
      edit_config_forward "$service_number"
      ;;
    4)
      echo -e "${CYAN}Select forwarding type:${PLAIN}"
      echo -e "${GREEN}1.${PLAIN} Single port forwarding"
      echo -e "${GREEN}2.${PLAIN} Port range forwarding"
      read -p "Select [1-2]: " forwarding_type
      case $forwarding_type in
      1) create_forward_service ;;
      2) create_port_range_forward ;;
      *) echo -e "${RED}Invalid selection.${PLAIN}" ;;
      esac
      ;;
    5)
      echo -e "${CYAN}Starting GOST service (applying config)...${PLAIN}"
      apply_config
      ;;
    6)
      echo -e "${CYAN}Stopping GOST service...${PLAIN}"
      if systemctl is-active --quiet gost; then
        systemctl stop gost
        echo -e "${GREEN}GOST service stopped.${PLAIN}"
      else
        echo -e "${YELLOW}GOST service is not running.${PLAIN}"
      fi
      ;;
    7)
      echo -e "${CYAN}Restarting GOST service...${PLAIN}"
      if systemctl is-active --quiet gost; then
        systemctl restart gost
        echo -e "${GREEN}GOST service restarted.${PLAIN}"
      else
        systemctl start gost
        echo -e "${GREEN}GOST service started.${PLAIN}"
      fi
      ;;
    8)
      # 检查服务状态
      local status=$(systemctl is-active gost)
      if [ "$status" = "active" ]; then
        echo -e "${GREEN}GOST service is running.${PLAIN}"
        echo -e "${CYAN}GOST Process Information:${PLAIN}"
        ps aux | grep "/usr/local/bin/gost -C" | grep -v grep
        echo -e "${CYAN}GOST Service Logs (last 10 lines):${PLAIN}"
        journalctl -u gost --no-pager -n 10
      else
        echo -e "${RED}GOST service is not running (status: $status).${PLAIN}"
        echo -e "${CYAN}Check service logs with: ${YELLOW}journalctl -u gost${PLAIN}"
      fi
      ;;
    9) return ;;
    *) echo -e "${RED}Invalid selection. Please try again.${PLAIN}" ;;
    esac

    read -n1 -r -p "Press any key to continue..."
  done
}

# Configuration file management
config_file_management() {
  while true; do
    echo -e "\n${CYAN}=== Configuration File Management ===${PLAIN}"
    echo -e "${GREEN}1.${PLAIN} Initialize/reset config file"
    echo -e "${GREEN}2.${PLAIN} Apply current config file"
    echo -e "${GREEN}3.${PLAIN} View config file"
    echo -e "${GREEN}4.${PLAIN} Edit config file"
    echo -e "${GREEN}5.${PLAIN} Backup config file"
    echo -e "${GREEN}6.${PLAIN} Restore config from backup"
    echo -e "${GREEN}7.${PLAIN} Format config file (requires jq)"
    echo -e "${GREEN}8.${PLAIN} Return to main menu"
    read -p "$(echo -e ${YELLOW}"Please select [1-8]: "${PLAIN})" choice

    case $choice in
    1)
      read -p "This will reset your config. Are you sure? (y/N): " confirm
      if [[ $confirm == [Yy]* ]]; then
        rm -f "$CONFIG_FILE"
        ensure_config_dir
        echo -e "${GREEN}Config file reset to empty template.${PLAIN}"
      else
        echo -e "${YELLOW}Operation cancelled.${PLAIN}"
      fi
      ;;
    2)
      if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}Config file not found. Please initialize it first.${PLAIN}"
      else
        apply_config
      fi
      ;;
    3)
      if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}Config file not found. Please initialize it first.${PLAIN}"
      else
        echo -e "${CYAN}Config file content:${PLAIN}"
        if command -v jq &>/dev/null; then
          jq . "$CONFIG_FILE" | cat -n
        else
          cat -n "$CONFIG_FILE"
        fi
      fi
      ;;
    4)
        ensure_config_dir
      
      # 检测可用的编辑器
      local editor=""
      for e in nano vim vi; do
        if command -v $e &>/dev/null; then
          editor=$e
          break
        fi
      done
      
      if [ -z "$editor" ]; then
        echo -e "${RED}No suitable editor found (nano, vim, vi). Please install one.${PLAIN}"
      else
        $editor "$CONFIG_FILE"
        
        # 验证JSON格式
        if command -v jq &>/dev/null; then
          if jq . "$CONFIG_FILE" > /dev/null 2>&1; then
            echo -e "${GREEN}Config file format is valid.${PLAIN}"
          else
            echo -e "${RED}WARNING: Config file format is invalid! This may cause issues when applying the config.${PLAIN}"
          fi
        fi
        
        read -p "Do you want to apply the edited config now? (y/N): " apply_now
        if [[ $apply_now == [Yy]* ]]; then
          apply_config
        fi
      fi
      ;;
    5)
      if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}Config file not found. Nothing to backup.${PLAIN}"
      else
        local backup_file="$CONFIG_DIR/config-$(date +%Y%m%d-%H%M%S).json.bak"
        cp "$CONFIG_FILE" "$backup_file"
        echo -e "${GREEN}Config file backed up to: $backup_file${PLAIN}"
      fi
      ;;
    6)
      # 列出所有备份文件
      local backups=($CONFIG_DIR/config-*.json.bak)
      if [ ${#backups[@]} -eq 0 ] || [ ! -f "${backups[0]}" ]; then
        echo -e "${RED}No backup files found in $CONFIG_DIR${PLAIN}"
      else
        echo -e "${CYAN}Available backup files:${PLAIN}"
        local i=1
        for backup in "${backups[@]}"; do
          if [ -f "$backup" ]; then
            echo -e "${GREEN}$i.${PLAIN} $(basename "$backup") ($(date -r "$backup" '+%Y-%m-%d %H:%M:%S'))"
            ((i++))
        fi
      done

        read -p "Select backup to restore [1-$((i-1))]: " backup_num
        if [[ "$backup_num" =~ ^[0-9]+$ ]] && [ "$backup_num" -ge 1 ] && [ "$backup_num" -le $((i-1)) ]; then
          selected=${backups[$((backup_num-1))]}
          read -p "Restore from $selected? This will overwrite your current config. (y/N): " confirm
          if [[ $confirm == [Yy]* ]]; then
            cp "$selected" "$CONFIG_FILE"
            echo -e "${GREEN}Config restored from: $selected${PLAIN}"
            read -p "Apply the restored config now? (Y/n): " apply_now
            if [[ $apply_now != [Nn]* ]]; then
              apply_config
            fi
          else
            echo -e "${YELLOW}Restore cancelled.${PLAIN}"
          fi
        else
          echo -e "${RED}Invalid selection.${PLAIN}"
        fi
      fi
      ;;
    7)
      if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}Config file not found. Please initialize it first.${PLAIN}"
      else
        if command -v jq &>/dev/null; then
          local temp_file=$(mktemp)
          if jq . "$CONFIG_FILE" > "$temp_file" 2>/dev/null; then
            mv "$temp_file" "$CONFIG_FILE"
            echo -e "${GREEN}Config file formatted successfully.${PLAIN}"
          else
            rm -f "$temp_file"
            echo -e "${RED}Failed to format config file. JSON format may be invalid.${PLAIN}"
          fi
        else
          echo -e "${RED}jq tool is required for formatting. Please install it first.${PLAIN}"
          echo -e "${YELLOW}On Debian/Ubuntu: sudo apt-get install jq${PLAIN}"
          echo -e "${YELLOW}On CentOS/RHEL: sudo yum install jq${PLAIN}"
        fi
      fi
      ;;
    8) return ;;
    *) echo -e "${RED}Invalid selection. Please try again.${PLAIN}" ;;
    esac

    read -n1 -r -p "Press any key to continue..."
  done
}

# Get IP address information
get_ip_info() {
  IPV4=$(curl -s -4 https://cloudflare.com/cdn-cgi/trace | grep ip | cut -d= -f2)
  COUNTRY_V4=$(curl -s -4 https://cloudflare.com/cdn-cgi/trace | grep loc | cut -d= -f2)
  IPV6=$(curl -s -6 https://cloudflare.com/cdn-cgi/trace | grep ip | cut -d= -f2)
  COUNTRY_V6=$(curl -s -6 https://cloudflare.com/cdn-cgi/trace | grep loc | cut -d= -f2)
  [ -z "$IPV4" ] && IPV4="N/A"
  [ -z "$IPV6" ] && IPV6="N/A"
  [ -z "$COUNTRY_V4" ] && COUNTRY_V4="N/A"
  [ -z "$COUNTRY_V6" ] && COUNTRY_V6="N/A"
}

# Function to parse config file
parse_config_file() {
  if [ ! -f "$CONFIG_FILE" ]; then
    return 1
  fi

  # 检查是否有解析JSON的工具
  if command -v jq &>/dev/null; then
    # 使用jq解析
    local services=$(jq -r '.services[] | select(.forwarder != null) | 
      .name + "|" + 
      .addr + "|" + 
      (.forwarder.nodes[0].addr // "") + "|" + 
      (.handler.type // "")' "$CONFIG_FILE" 2>/dev/null)
    
    # 输出结果
    echo "$services"
  else
    # 简单解析JSON（只能处理基本格式）
    local result=()
    local content=$(cat "$CONFIG_FILE")
    
    # 提取服务数组
    local services_section=$(echo "$content" | sed -n '/"services":/,/\]/p')
    
    # 逐个提取服务
  local name=""
    local addr=""
  local target_addr=""
    local handler_type=""
    local in_service=0
    local in_handler=0
    local in_forwarder=0
    local in_nodes=0

  while IFS= read -r line; do
      if [[ "$line" =~ \"name\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
        if [ $in_service -eq 1 ]; then
          # 如果已经在一个服务中, 保存当前服务信息并重置
          if [ ! -z "$name" ] && [ ! -z "$addr" ] && [ ! -z "$target_addr" ] && [ ! -z "$handler_type" ]; then
            result+=("$name|$addr|$target_addr|$handler_type")
          fi
          name=""
          addr=""
      target_addr=""
          handler_type=""
          in_handler=0
          in_forwarder=0
          in_nodes=0
        fi
        
        in_service=1
        name="${BASH_REMATCH[1]}"
      elif [[ "$line" =~ \"addr\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]] && [ -z "$addr" ] && [ $in_service -eq 1 ]; then
        addr="${BASH_REMATCH[1]}"
      elif [[ "$line" =~ \"handler\"[[:space:]]*: ]]; then
        in_handler=1
      elif [[ "$line" =~ \"type\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]] && [ $in_handler -eq 1 ] && [ -z "$handler_type" ]; then
        handler_type="${BASH_REMATCH[1]}"
      elif [[ "$line" =~ \"forwarder\"[[:space:]]*: ]]; then
        in_forwarder=1
      elif [[ "$line" =~ \"nodes\"[[:space:]]*: ]] && [ $in_forwarder -eq 1 ]; then
        in_nodes=1
      elif [[ "$line" =~ \"addr\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]] && [ $in_nodes -eq 1 ] && [ -z "$target_addr" ]; then
      target_addr="${BASH_REMATCH[1]}"
    fi
    done < <(echo "$services_section")
    
    # 处理最后一个服务
    if [ ! -z "$name" ] && [ ! -z "$addr" ] && [ ! -z "$target_addr" ] && [ ! -z "$handler_type" ]; then
      result+=("$name|$addr|$target_addr|$handler_type")
  fi

  # 输出结果
  for item in "${result[@]}"; do
    echo "$item"
  done
  fi
}

# Function to delete a forwarding entry from config file
delete_config_forward() {
  local entry_number=$1
  
  # 检查参数
  if [ -z "$entry_number" ] || ! [[ "$entry_number" =~ ^[0-9]+$ ]]; then
    echo -e "${RED}Invalid service number.${PLAIN}"
    return 1
  fi

  if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}Config file not found.${PLAIN}"
    return 1
  fi

  # 解析配置文件中的转发条目
  local entries=()
  while IFS="|" read -r name listen_addr target_addr proto; do
    if [ ! -z "$name" ]; then
      entries+=("$name")
    fi
  done < <(parse_config_file)

  # 检查输入有效性
  if [ $entry_number -lt 1 ] || [ $entry_number -gt ${#entries[@]} ]; then
    echo -e "${RED}Invalid entry number.${PLAIN}"
    return 1
  fi

  # 获取要删除的服务名
  local target_name=${entries[$entry_number - 1]}

  echo -e -n "Are you sure you want to delete the forwarding entry ${BOLD}$target_name${PLAIN}? (${GREEN}Y${PLAIN}/${RED}N${PLAIN}): "
  read confirm
  if [[ $confirm != [Yy]* ]]; then
    echo -e "${YELLOW}Deletion cancelled.${PLAIN}"
    return 0
  fi

  # 使用jq删除服务
  if command -v jq &>/dev/null; then
    # 使用jq进行高级处理
    local temp_file=$(mktemp)
    
    # 对于tcp-udp协议服务，可能会分成两个服务，需要删除同名服务
    if [[ "$target_name" == *-tcp ]] || [[ "$target_name" == *-udp ]]; then
      # 提取基本名称
      local base_name=$(echo "$target_name" | sed 's/-tcp$\|-udp$//')
      
      # 删除tcp和udp服务
      jq --arg name "$base_name-tcp" --arg name2 "$base_name-udp" \
        '.services = [.services[] | select(.name != $name and .name != $name2)]' "$CONFIG_FILE" > "$temp_file"
    else
      # 直接删除指定名称的服务
      jq --arg name "$target_name" '.services = [.services[] | select(.name != $name)]' "$CONFIG_FILE" > "$temp_file"
    fi
    
    if [ $? -eq 0 ]; then
      mv "$temp_file" "$CONFIG_FILE"
    else
      echo -e "${RED}Error updating config file.${PLAIN}"
      rm -f "$temp_file"
      return 1
    fi
  else
    echo -e "${YELLOW}jq tool is recommended for JSON manipulation. Using simple pattern matching instead.${PLAIN}"

  # 创建临时文件
  local temp_file=$(mktemp)

    # 简单替换方式：将配置文件转换为单行，然后通过正则替换
    tr -d '\n' < "$CONFIG_FILE" | 
    sed 's/  */ /g' |
    sed "s/\({[^{}]*\"name\"[^{}]*\"$target_name\"[^{}]*}\),\?//g" > "$temp_file"
    
    # 重新格式化JSON（如果没有jq，至少尝试保持基本格式）
    if command -v python3 &>/dev/null; then
      python3 -m json.tool "$temp_file" > "$CONFIG_FILE"
    else
      # 尝试简单分割以维持基本可读性
      cat "$temp_file" | sed "s/\([{}[],]\)/\1\n/g" > "$CONFIG_FILE"
    fi
    
    echo -e "${YELLOW}Basic removal attempted. Recommend verifying the config file.${PLAIN}"
  fi

  echo -e "${GREEN}Entry deleted successfully.${PLAIN}"
  read -p "Apply config file now? (Y/n): " apply_now
  if [[ $apply_now != "n" && $apply_now != "N" ]]; then
    apply_config
  fi

  return 0
}

# Function to edit a forwarding entry in config file
edit_config_forward() {
  local entry_number=$1
  
  # 检查参数
  if [ -z "$entry_number" ] || ! [[ "$entry_number" =~ ^[0-9]+$ ]]; then
    echo -e "${RED}Invalid service number.${PLAIN}"
    return 1
  fi

  if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}Config file not found.${PLAIN}"
    return 1
  fi

  # 解析配置文件中的转发条目
  local entries=()
  local entry_details=()
  while IFS="|" read -r name listen_addr target_addr proto; do
    if [ ! -z "$name" ]; then
      entries+=("$name")
      entry_details+=("$name|$listen_addr|$target_addr|$proto")
    fi
  done < <(parse_config_file)

  # 检查输入有效性
  if [ $entry_number -lt 1 ] || [ $entry_number -gt ${#entries[@]} ]; then
    echo -e "${RED}Invalid entry number.${PLAIN}"
    return 1
  fi

  # 获取要编辑的服务详情
  IFS="|" read -r name listen_addr target_addr proto <<<"${entry_details[$entry_number - 1]}"

  # 检查是否为TCP-UDP双协议的一部分
  local is_part_of_pair=0
  if [[ "$name" == *-tcp ]] || [[ "$name" == *-udp ]]; then
    is_part_of_pair=1
    local base_name=$(echo "$name" | sed 's/-tcp$\|-udp$//')
    local related_service=""
    
    if [[ "$name" == *-tcp ]]; then
      related_service="$base_name-udp"
      echo -e "${YELLOW}This service is paired with $related_service. Both will be updated.${PLAIN}"
    else
      related_service="$base_name-tcp"
      echo -e "${YELLOW}This service is paired with $related_service. Both will be updated.${PLAIN}"
    fi
  fi

  echo -e "${CYAN}Editing forwarding entry: ${BOLD}$name${PLAIN}"

  # 提取当前端口和目标信息
  local current_local_port=$(echo "$listen_addr" | grep -o ':[0-9]\+\(-[0-9]\+\)*' | sed 's/://')
  local current_target_ip=$(echo "$target_addr" | grep -o '[^:]*' | head -1)
  local current_target_port=$(echo "$target_addr" | grep -o ':[0-9]\+\(-[0-9]\+\)*' | sed 's/://')

  # 获取新设置
  read -p "New local port (leave empty for $current_local_port): " new_local_port
  [ -z "$new_local_port" ] && new_local_port=$current_local_port

  if ! validate_input "$new_local_port" "port"; then
    read -n1 -r -p "Press any key to try again..."
    return 1
  fi

  read -p "New target IP or hostname (leave empty for $current_target_ip): " new_target_ip
  [ -z "$new_target_ip" ] && new_target_ip=$current_target_ip

  read -p "New target port (leave empty for $current_target_port): " new_target_port
  [ -z "$new_target_port" ] && new_target_port=$current_target_port

  if ! validate_input "$new_target_port" "port"; then
    read -n1 -r -p "Press any key to try again..."
    return 1
  fi

  # 处理IPv6地址
  if [[ $new_target_ip == *:* ]] && [[ $new_target_ip != \[*\] ]]; then
    new_target_ip="[$new_target_ip]"
  fi

  # 协议不建议直接修改，如需更改可以删除后重新创建
  local new_proto=$proto
  
  # 如果是双协议的一部分，不允许修改协议
  if [ $is_part_of_pair -eq 1 ]; then
    echo -e "${YELLOW}Cannot change protocol for paired service. Delete and recreate to change protocol.${PLAIN}"
  fi

  # 确认更改
  echo -e "\n${CYAN}New settings:${PLAIN}"
  echo -e "${GREEN}Local port:${PLAIN} $new_local_port"
  echo -e "${GREEN}Target:${PLAIN} $new_target_ip:$new_target_port"
  echo -e "${GREEN}Protocol:${PLAIN} $new_proto"

  read -p "Apply these changes? (Y/n): " confirm
  if [[ $confirm == "n" || $confirm == "N" ]]; then
    echo -e "${YELLOW}Edit cancelled.${PLAIN}"
    return 0
  fi

  # 使用jq更新JSON配置
  if command -v jq &>/dev/null; then
  local temp_file=$(mktemp)

    if [ $is_part_of_pair -eq 1 ]; then
      # 获取基本名和对应服务名
      local base_name=$(echo "$name" | sed 's/-tcp$\|-udp$//')
      local tcp_name="$base_name-tcp"
      local udp_name="$base_name-udp"
      
      # 更新两个相关的服务
      jq --arg tcp "$tcp_name" --arg udp "$udp_name" \
         --arg addr ":$new_local_port" --arg target "$new_target_ip:$new_target_port" \
         '(.services[] | select(.name == $tcp or .name == $udp)) |= 
          (.addr = $addr | .forwarder.nodes[0].addr = $target)' \
         "$CONFIG_FILE" > "$temp_file"
    else
      # 更新单一服务
      jq --arg name "$name" --arg addr ":$new_local_port" \
         --arg target "$new_target_ip:$new_target_port" \
         '(.services[] | select(.name == $name)) |= 
          (.addr = $addr | .forwarder.nodes[0].addr = $target)' \
         "$CONFIG_FILE" > "$temp_file"
    fi
    
    if [ $? -eq 0 ]; then
      mv "$temp_file" "$CONFIG_FILE"
    else
      echo -e "${RED}Error updating config file.${PLAIN}"
      rm -f "$temp_file"
      return 1
    fi
  else
    echo -e "${RED}jq tool is required for editing JSON config. Please install it:${PLAIN}"
    echo -e "${YELLOW}On Debian/Ubuntu: sudo apt-get install jq${PLAIN}"
    echo -e "${YELLOW}On CentOS/RHEL: sudo yum install jq${PLAIN}"
    read -n1 -r -p "Press any key to continue..."
    return 1
  fi

  echo -e "${GREEN}Entry updated successfully.${PLAIN}"
  read -p "Apply config file now? (Y/n): " apply_now
  if [[ $apply_now != "n" && $apply_now != "N" ]]; then
    apply_config
  fi

  return 0
}

# Function to clean up old systemd services
cleanup_old_services() {
  echo -e "${CYAN}=== Cleaning up old systemd services ===${PLAIN}"
  
  local found=0
  local count=0
  
  # 显示所有gost相关服务
  echo -e "${BLUE}Found GOST related systemd services:${PLAIN}"
  for service_file in "$SERVICE_DIR"/gost-*.service; do
    if [ -e "$service_file" ]; then
      found=1
      count=$((count + 1))
      service_name=$(basename "$service_file" .service)
      status=$(systemctl is-active "$service_name")
      echo -e "  ${GREEN}$count.${PLAIN} $service_name (Status: $status)"
    fi
  done
  
  if [ $found -eq 0 ]; then
    echo -e "${YELLOW}No old GOST systemd services found.${PLAIN}"
    return
  fi
  
  echo -e "${YELLOW}Warning: This will disable and remove all individual GOST systemd services.${PLAIN}"
  echo -e "${YELLOW}All port forwarding should be managed through the config file instead.${PLAIN}"
  read -p "Are you sure you want to continue? (y/N): " confirm
  
  if [[ $confirm != [Yy]* ]]; then
    echo -e "${YELLOW}Operation cancelled.${PLAIN}"
    return
  fi
  
  # 停止并禁用所有服务
  for service_file in "$SERVICE_DIR"/gost-*.service; do
    if [ -e "$service_file" ]; then
      service_name=$(basename "$service_file" .service)
      echo -e "${CYAN}Stopping and disabling $service_name...${PLAIN}"
      systemctl stop "$service_name" &>/dev/null
      systemctl disable "$service_name" &>/dev/null
    fi
  done
  
  # 删除服务文件
  echo -e "${CYAN}Removing service files...${PLAIN}"
  for service_file in "$SERVICE_DIR"/gost-*.service; do
    if [ -e "$service_file" ]; then
      rm -f "$service_file"
    fi
  done
  
  # 重新加载systemd配置
  systemctl daemon-reload
  
  echo -e "${GREEN}Successfully removed $count old GOST systemd services.${PLAIN}"
  
  # 询问是否立即应用配置文件
  read -p "Apply config file now? (Y/n): " apply_now
  if [[ $apply_now != "n" && $apply_now != "N" ]]; then
    apply_config
  fi
}

# Main menu
main_menu() {
  while true; do
    clear
    get_ip_info
    echo -e "${BOLD}${BLUE}==================== Gost Port Forwarding Management ====================${PLAIN}"
    echo -e "  ${CYAN}IPv4: ${WHITE}$IPV4 ${YELLOW}($COUNTRY_V4)${PLAIN}"
    echo -e "  ${CYAN}IPv6: ${WHITE}$IPV6 ${YELLOW}($COUNTRY_V6)${PLAIN}"
    echo -e "${BOLD}${BLUE}=========================================================================${PLAIN}"
    echo -e "${GREEN}1.${PLAIN} Create Single Port Forwarding"
    echo -e "${GREEN}2.${PLAIN} Create Port Range Forwarding"
    echo -e "${GREEN}3.${PLAIN} Manage Forwarding Services"
    echo -e "${GREEN}4.${PLAIN} Configuration File Management"
    echo -e "${GREEN}5.${PLAIN} Clean Up Old Systemd Services"
    echo -e "${GREEN}6.${PLAIN} Exit"
    echo -e "${BOLD}${BLUE}=========================================================================${PLAIN}"
    read -p "$(echo -e ${YELLOW}"Please select [1-6]: "${PLAIN})" choice

    case $choice in
    1) create_forward_service ;;
    2) create_port_range_forward ;;
    3) manage_forward_services ;;
    4) config_file_management ;;
    5) cleanup_old_services ;;
    6)
      echo -e "${GREEN}Thank you for using. Goodbye!${PLAIN}"
      exit 0
      ;;
    *) echo -e "${RED}Invalid selection. Please try again.${PLAIN}" ;;
    esac
    read -n1 -r -p "Press any key to return to the main menu..."
  done
}

# 检查gost是否安装，只在必要时进行依赖检查
if ! command -v gost &>/dev/null; then
  check_and_install
fi

# Execute main menu
main_menu
