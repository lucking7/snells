#!/bin/bash

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

# Service files directory
SERVICE_DIR="/etc/systemd/system"
CONFIG_DIR="/etc/gost"
CONFIG_FILE="$CONFIG_DIR/config.yml"

# Check and install necessary components
check_and_install() {
  local packages=("gost" "lsof" "curl" "grep")
  for package in "${packages[@]}"; do
    if ! command -v $package &>/dev/null && [ "$package" != "gost" ]; then
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
      
      case $package in
      "gost")
        (bash <(curl -fsSL https://github.com/go-gost/gost/raw/master/install.sh) --install) &
        ;;
      *)
        if ! sudo $PKG_MANAGER update -y; then
          echo -e "${RED}Failed to update package list.${PLAIN}"
          continue
        fi
        if ! sudo $PKG_MANAGER install $package -y; then
          echo -e "${RED}Failed to install $package. Please install it manually.${PLAIN}"
          continue
        fi
        ;;
      esac
      show_loading $!
      if command -v $package &>/dev/null || [ "$package" = "gost" ]; then
        echo -e "${GREEN}$package installed successfully.${PLAIN}"
      else
        echo -e "${RED}Failed to install $package. Please install it manually.${PLAIN}"
      fi
    fi
  done
  
  # Install gost if not already installed
  if ! command -v gost &>/dev/null; then
    echo -e "${YELLOW}Installing gost...${PLAIN}"
    (bash <(curl -fsSL https://github.com/go-gost/gost/raw/master/install.sh) --install) &
    show_loading $!
    if ! command -v gost &>/dev/null; then
      echo -e "${RED}Failed to install gost. Please install it manually.${PLAIN}"
    else
      echo -e "${GREEN}gost installed successfully.${PLAIN}"
    fi
  fi

  # Ensure Gost config directory exists
  sudo mkdir -p "$CONFIG_DIR"
  # Create empty config if it doesn't exist
  if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${YELLOW}Creating initial GOST config file: $CONFIG_FILE${PLAIN}"
    sudo bash -c "echo \"services:\" > \"$CONFIG_FILE\""
  fi

  # Check if the file format is correct
  local first_line=$(head -n 1 "$CONFIG_FILE" 2>/dev/null)
  if [ -z "$first_line" ] || [[ "$first_line" != "services:"* ]]; then
    echo -e "${YELLOW}修复配置文件格式: $CONFIG_FILE${PLAIN}"
    local temp_file=$(mktemp)
    echo "services:" > "$temp_file"
    if [ -s "$CONFIG_FILE" ]; then
      if grep -q "^- name:" "$CONFIG_FILE"; then
        cat "$CONFIG_FILE" | sed 's/^-/  -/' >> "$temp_file"
      else
        # File has some other content, preserve it
        cat "$CONFIG_FILE" | grep -v "^services: \[\]" >> "$temp_file"
      fi
    fi
    sudo mv "$temp_file" "$CONFIG_FILE"
  fi

  # Ensure the central gost service exists and is enabled
  setup_central_gost_service
}

# Function to setup the central gost systemd service
setup_central_gost_service() {
  local service_name="gost"
  local service_file="$SERVICE_DIR/$service_name.service"

  if [ ! -f "$service_file" ]; then
    echo -e "${YELLOW}Creating central GOST service file: $service_file${PLAIN}"
    sudo bash -c "cat << EOF > \"$service_file\"
[Unit]
Description=GOST Central Service
After=network.target network-online.target nss-lookup.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/gost -C $CONFIG_FILE
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF"
    echo -e "${YELLOW}Reloading systemd daemon...${PLAIN}"
    sudo systemctl daemon-reload
    echo -e "${YELLOW}Enabling and starting $service_name service...${PLAIN}"
    sudo systemctl enable "$service_name"
    sudo systemctl start "$service_name"
  else
    # Ensure the service is running if it already exists
    if ! sudo systemctl is-active --quiet "$service_name"; then
        echo -e "${YELLOW}Central GOST service ($service_name) is inactive. Starting...${PLAIN}"
        sudo systemctl start "$service_name"
    fi
    # Optional: Ensure it's enabled
     if ! sudo systemctl is-enabled --quiet "$service_name"; then
        echo -e "${YELLOW}Central GOST service ($service_name) is not enabled. Enabling...${PLAIN}"
        sudo systemctl enable "$service_name"
    fi
  fi
}

# Reload the central GOST service
reload_gost_service() {
  echo -e "${YELLOW}Reloading GOST service...${PLAIN}"
  if systemctl is-active --quiet gost; then
    sudo systemctl restart gost
    echo -e "${GREEN}GOST service restarted successfully.${PLAIN}"
  else
    sudo systemctl start gost
    echo -e "${GREEN}GOST service started.${PLAIN}"
  fi
}

# Function to validate IP address (basic check)
validate_ip() {
  local ip=$1
  # Simple regex for IPv4 and allowing IPv6 common patterns (more complex validation possible)
  if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || [[ "$ip" =~ ^::1$ ]] || [[ "$ip" =~ ^[0-9a-fA-F:]+$ ]]; then
    return 0 # Valid format (basic check)
  else
    return 1 # Invalid format
  fi
}

# Function to validate port number
validate_port() {
    local port=$1
    if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
        return 0 # Valid port
    else
        return 1 # Invalid port
    fi
}

# Function to parse port input (single, list, range) - Add port validation
parse_ports() {
  local input_ports=$1
  local parsed_ports=()
  local has_error=0
  IFS=',' read -ra ADDR <<< "$input_ports"
  for i in "${ADDR[@]}"; do
    if [[ $i == *-* ]]; then
      local start_port=$(echo $i | cut -d'-' -f1)
      local end_port=$(echo $i | cut -d'-' -f2)
      if validate_port "$start_port" && validate_port "$end_port" && [ "$start_port" -le "$end_port" ]; then
        for (( port=start_port; port<=end_port; port++ )); do
          if validate_port "$port"; then
             parsed_ports+=($port)
          else
             echo "Error: Port $port in range '$i' is invalid." >&2
             has_error=1
          fi
        done
      else
        echo "Error: Invalid port range '$i' (ports must be 1-65535 and start <= end)." >&2
        has_error=1
      fi
    elif validate_port "$i"; then
      parsed_ports+=($i)
    else
      echo "Error: Invalid port format or value '$i' (must be 1-65535)." >&2
      has_error=1
    fi
  done

  if [ $has_error -eq 1 ]; then
      return 1
  fi
  echo "${parsed_ports[@]}" # Return space-separated list
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

# Function to create a forwarding service using direct writing to config file
create_forward_service() {
  echo -e "${CYAN}=== 创建新的端口转发规则 ===${PLAIN}"

  # Get protocol type
  echo -e "${CYAN}选择协议类型:${PLAIN}"
  echo -e "${GREEN}1.${PLAIN} TCP"
  echo -e "${GREEN}2.${PLAIN} UDP"
  echo -e "${GREEN}3.${PLAIN} TCP+UDP ${YELLOW}(默认)${PLAIN}"
  read -p "选择 [1-3] (默认: 3): " protocol_choice
  
  local protocol="tcp+udp"
  case $protocol_choice in
    1) protocol="tcp" ;;
    2) protocol="udp" ;;
    *) protocol="tcp+udp" ;; # Default to both
  esac
  
  echo -e "${YELLOW}选择的协议: ${BOLD}${protocol^^}${PLAIN}"

  # Get port information
  echo -e "${YELLOW}输入本地端口。例如: ${WHITE}8080${PLAIN}, ${WHITE}8080,8081${PLAIN}, ${WHITE}8080-8090${PLAIN}"
  echo -e "${YELLOW}(留空自动分配随机端口)${PLAIN}"
  read -p "本地端口: " local_ports_input
  
  # If empty, assign a random port
  if [ -z "$local_ports_input" ]; then
    local_port=$(find_free_port)
    local_ports_input="$local_port"
    echo -e "${YELLOW}已分配随机端口: ${BOLD}$local_port${PLAIN}"
  fi
  
  read -p "目标IP: " target_ip
  read -p "目标端口: " target_port_input

  # --- Input Validation ---
  if [ -z "$target_ip" ]; then
      echo -e "${RED}目标IP不能为空${PLAIN}"
      return 1
  fi
  
  if ! validate_ip "$target_ip"; then
      echo -e "${RED}无效的目标IP地址: $target_ip${PLAIN}"
      return 1
  fi
  
  if [ -z "$target_port_input" ]; then
      echo -e "${RED}目标端口不能为空${PLAIN}"
      return 1
  fi
  
  if ! validate_port "$target_port_input"; then
      echo -e "${RED}无效的目标端口: $target_port_input. 必须在1到65535之间.${PLAIN}"
      return 1
  fi
  
  local parsed_local_ports
  parsed_local_ports=$(parse_ports "$local_ports_input")
  if [ $? -ne 0 ]; then
      echo -e "${RED}解析本地端口失败。请检查格式和值。${PLAIN}"
      return 1
  fi
  
  if [ -z "$parsed_local_ports" ]; then
    echo -e "${RED}没有指定有效的本地端口。${PLAIN}"
    return 1
  fi
  # --- End Validation ---

  # Ensure config directory and file exist
  sudo mkdir -p "$CONFIG_DIR"
  if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${YELLOW}创建基础配置文件: $CONFIG_FILE${PLAIN}"
    sudo bash -c "echo \"services:\" > \"$CONFIG_FILE\""
  fi

  # Check if the file is empty or doesn't start with services:
  local first_line=$(head -n 1 "$CONFIG_FILE")
  if [ -z "$first_line" ] || [[ "$first_line" != "services:"* ]]; then
    echo -e "${YELLOW}修复配置文件格式: $CONFIG_FILE${PLAIN}"
    # Create a temporary file with proper format
    local temp_file=$(mktemp)
    echo "services:" > "$temp_file"
    # If there's existing content that doesn't start with services:, append it properly
    if [ -s "$CONFIG_FILE" ]; then
      if [[ "$first_line" == "- name:"* ]]; then
        # File already has service entries but missing the services: header
        cat "$CONFIG_FILE" | sed 's/^-/  -/' >> "$temp_file"
      else
        # File has some other content, preserve it with proper indentation
        cat "$CONFIG_FILE" >> "$temp_file"
      fi
    fi
    sudo mv "$temp_file" "$CONFIG_FILE"
  fi

  # Backup the existing config
  local backup_file="${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  echo -e "${YELLOW}备份当前配置到 $backup_file...${PLAIN}"
  sudo cp "$CONFIG_FILE" "$backup_file" || { echo -e "${RED}创建备份失败。中止操作。${PLAIN}"; return 1; }

  echo -e "${YELLOW}添加服务到 $CONFIG_FILE...${PLAIN}"

  # Process each local port
  local changes_made=0
  for local_port in $parsed_local_ports; do
    # Create unique service name for each port (shortened name for better display)
    local short_target="${target_ip##*.}"
    if [ -z "$short_target" ]; then
      short_target="${target_ip}"
    fi
    
    # Create separate entries for TCP and UDP if needed
    if [ "$protocol" = "tcp" ] || [ "$protocol" = "tcp+udp" ]; then
      local tcp_service_name="tcp-${local_port}-to-${short_target}-${target_port_input}"
      echo -e "  ${CYAN}处理: TCP 本地 ${WHITE}:$local_port${PLAIN} -> 目标 ${WHITE}$target_ip:$target_port_input${PLAIN}"
      
      # Add TCP service with proper indentation
      sudo bash -c "cat >> \"$CONFIG_FILE\" << EOF
  - name: $tcp_service_name
    addr: ':$local_port'
    handler:
      type: tcp
    listener:
      type: tcp
    forwarder:
      nodes:
      - name: target-tcp-$local_port-$target_port_input
        addr: '$target_ip:$target_port_input'
        connector:
          type: forward
        dialer:
          type: tcp
EOF"
      changes_made=1
    fi
    
    if [ "$protocol" = "udp" ] || [ "$protocol" = "tcp+udp" ]; then
      local udp_service_name="udp-${local_port}-to-${short_target}-${target_port_input}"
      echo -e "  ${CYAN}处理: UDP 本地 ${WHITE}:$local_port${PLAIN} -> 目标 ${WHITE}$target_ip:$target_port_input${PLAIN}"
      
      # Add UDP service with proper indentation
      sudo bash -c "cat >> \"$CONFIG_FILE\" << EOF
  - name: $udp_service_name
    addr: ':$local_port'
    handler:
      type: udp
    listener:
      type: udp
    forwarder:
      nodes:
      - name: target-udp-$local_port-$target_port_input
        addr: '$target_ip:$target_port_input'
        connector:
          type: forward
        dialer:
          type: udp
EOF"
      changes_made=1
    fi
  done

  # Reload gost service if changes were made
  if [ $changes_made -eq 1 ]; then
    reload_gost_service
    echo -e "${GREEN}转发规则已创建并应用${PLAIN}"
  else
    echo -e "${YELLOW}没有添加新服务（可能是由于服务名称/监听器已存在）。${PLAIN}"
    # Remove unused backup if no changes made
    sudo rm "$backup_file"
  fi
}

# Function to list existing forwarding services with custom parsing
list_forward_services() {
  echo -e "${CYAN}=== 转发规则列表 ===${PLAIN}"
  
  # Check if central service is running
  if systemctl is-active --quiet gost; then
    central_service_status="${GREEN}运行中${PLAIN}"
  else
    central_service_status="${RED}已停止${PLAIN}"
  fi
  
  echo -e "中央GOST服务状态: ${central_service_status}"
  echo "----------------------------------------------------------------------------------------------------"

  if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${YELLOW}配置文件不存在: $CONFIG_FILE${PLAIN}"
    return 0
  fi
  
  # Check if config file has proper format
  local first_line=$(head -n 1 "$CONFIG_FILE")
  if [ -z "$first_line" ] || [[ "$first_line" != "services:"* ]]; then
    echo -e "${YELLOW}配置文件格式不正确，尝试修复...${PLAIN}"
    local temp_file=$(mktemp)
    echo "services:" > "$temp_file"
    if [ -s "$CONFIG_FILE" ]; then
      if grep -q "^- name:" "$CONFIG_FILE"; then
        cat "$CONFIG_FILE" | sed 's/^-/  -/' >> "$temp_file"
      else
        cat "$CONFIG_FILE" >> "$temp_file"
      fi
    fi
    sudo mv "$temp_file" "$CONFIG_FILE"
    echo -e "${GREEN}配置文件已修复${PLAIN}"
  fi
  
  # Read the YAML file directly using grep and awk to extract services
  local services=$(grep -E "^  - name:" "$CONFIG_FILE")
  if [ -z "$services" ]; then
    echo -e "${YELLOW}在 $CONFIG_FILE 中没有找到转发服务。${PLAIN}"
    return 0
  fi
  
  # Print header
  printf "%-5s %-25s %-10s %-15s %-20s %-15s\\n" "编号" "服务名称" "协议" "本地地址" "目标地址" "目标端口"
  echo "----------------------------------------------------------------------------------------------------"
  
  local counter=1
  local current_service=""
  local current_protocol=""
  local current_addr=""
  local current_target_addr=""
  
  # Parse the YAML file line by line
  while IFS= read -r line; do
    if [[ "$line" =~ ^\ \ -\ name:\ (.*) ]]; then
      # New service found
      current_service="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^\ \ \ \ addr:\ \'?(.*?)\'? ]]; then
      # Local address
      current_addr="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ \ \ \ \ \ \ type:\ (tcp|udp) ]]; then
      # Protocol (first match in the service is the handler type)
      if [ -z "$current_protocol" ]; then
        current_protocol="${BASH_REMATCH[1]}"
      fi
    elif [[ "$line" =~ \ \ \ \ \ \ \ \ addr:\ \'?(.*?)\'? ]]; then
      # Target address
      current_target_addr="${BASH_REMATCH[1]}"
      
      # Extract target IP and port
      local target_ip
      local target_port
      
      if [[ "$current_target_addr" == *":"* ]]; then
        target_ip=$(echo "$current_target_addr" | cut -d':' -f1)
        target_port=$(echo "$current_target_addr" | cut -d':' -f2)
      else
        target_ip="$current_target_addr"
        target_port="未知"
      fi
      
      # Shorten display of service name to avoid overflow
      local display_name="$current_service"
      if [ ${#display_name} -gt 25 ]; then
        display_name="${display_name:0:22}..."
      fi
      
      # If we have all the information, print the service details
      if [ -n "$current_service" ] && [ -n "$current_protocol" ] && [ -n "$current_addr" ] && [ -n "$current_target_addr" ]; then
        printf "%-5s %-25s %-10s %-15s %-20s %-15s\\n" \
          "$counter" \
          "$display_name" \
          "${current_protocol^^}" \
          "$current_addr" \
          "$target_ip" \
          "$target_port"
        
        # Reset for next service
        current_service=""
        current_protocol=""
        current_addr=""
        current_target_addr=""
        
        ((counter++))
      fi
    fi
  done < "$CONFIG_FILE"
  
  echo "----------------------------------------------------------------------------------------------------"
  return $((counter - 1))
}

# Function to delete a service by number
delete_service_by_number() {
  local service_number=$1
  
  if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}配置文件不存在: $CONFIG_FILE${PLAIN}"
    return 1
  fi
  
  # List all services
  local services=($(grep -n "^  - name:" "$CONFIG_FILE" | cut -d':' -f1))
  local service_count=${#services[@]}
  
  if [ $service_count -eq 0 ]; then
    echo -e "${RED}没有找到服务。${PLAIN}"
    return 1
  fi
  
  if [ $service_number -le 0 ] || [ $service_number -gt $service_count ]; then
    echo -e "${RED}无效的服务编号: $service_number${PLAIN}"
    return 1
  fi
  
  # Get the service name
  local service_line=${services[$((service_number-1))]}
  local service_name=$(sed -n "${service_line}p" "$CONFIG_FILE" | awk '{print $3}')
  
  echo -e -n "确定要删除服务 ${BOLD}$service_name${PLAIN}? (${GREEN}Y${PLAIN}/${RED}N${PLAIN}): "
  read confirm
  
  if [[ $confirm == [Yy]* ]]; then
    # Find the start and end lines of the service
    local end_line
    
    if [ $service_number -eq $service_count ]; then
      # Last service, use end of file
      end_line=$(wc -l < "$CONFIG_FILE")
    else
      # Not last service, use line before next service
      end_line=$((${services[$service_number]}-1))
    fi
    
    # Create backup
    local backup_file="${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
    echo -e "${YELLOW}备份当前配置到 $backup_file...${PLAIN}"
    sudo cp "$CONFIG_FILE" "$backup_file" || { echo -e "${RED}创建备份失败。中止操作。${PLAIN}"; return 1; }
    
    # Create a temporary file with the service removed
    local temp_file=$(mktemp)
    
    # Keep lines before service
    if [ $service_line -gt 1 ]; then
      sed -n "1,$((service_line-1))p" "$CONFIG_FILE" > "$temp_file"
    fi
    
    # Keep lines after service
    if [ $end_line -lt $(wc -l < "$CONFIG_FILE") ]; then
      sed -n "$((end_line+1)),\$p" "$CONFIG_FILE" >> "$temp_file"
    fi
    
    # Replace original file with temporary file
    sudo mv "$temp_file" "$CONFIG_FILE"
    
    # Reload service
    reload_gost_service
    
    echo -e "${GREEN}服务 $service_name 已成功删除${PLAIN}"
  else
    echo -e "${YELLOW}取消删除。${PLAIN}"
  fi
}

# Function to edit an existing service
edit_forward_service() {
  local service_number=$1
  
  if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}配置文件不存在: $CONFIG_FILE${PLAIN}"
    return 1
  fi
  
  # List all services
  local services=($(grep -n "^  - name:" "$CONFIG_FILE" | cut -d':' -f1))
  local service_count=${#services[@]}
  
  if [ $service_count -eq 0 ]; then
    echo -e "${RED}没有找到服务。${PLAIN}"
    return 1
  fi
  
  if [ $service_number -le 0 ] || [ $service_number -gt $service_count ]; then
    echo -e "${RED}无效的服务编号: $service_number${PLAIN}"
    return 1
  fi
  
  # Get the service name
  local service_line=${services[$((service_number-1))]}
  local service_name=$(sed -n "${service_line}p" "$CONFIG_FILE" | awk '{print $3}')
  
  # Find information about the service
  local start_line=$service_line
  local end_line
  
  if [ $service_number -eq $service_count ]; then
    # Last service, use end of file
    end_line=$(wc -l < "$CONFIG_FILE")
  else
    # Not last service, use line before next service
    end_line=$((${services[$service_number]}-1))
  fi
  
  # Extract current values
  local service_block=$(sed -n "${start_line},${end_line}p" "$CONFIG_FILE")
  local current_addr=$(echo "$service_block" | grep "addr:" | head -n 1 | awk '{print $2}' | tr -d "':")
  local current_protocol=$(echo "$service_block" | grep -A 1 "handler:" | grep "type:" | awk '{print $2}')
  local current_target_addr=$(echo "$service_block" | grep -A 3 "nodes:" | grep "addr:" | awk '{print $2}' | tr -d "'")
  
  local current_target_ip
  local current_target_port
  
  if [[ "$current_target_addr" == *":"* ]]; then
    current_target_ip=$(echo "$current_target_addr" | cut -d':' -f1)
    current_target_port=$(echo "$current_target_addr" | cut -d':' -f2)
  else
    current_target_ip="$current_target_addr"
    current_target_port="未知"
  fi
  
  echo -e "${CYAN}--- 编辑规则: $service_name ---${PLAIN}"
  echo -e "  协议: ${current_protocol^^}"
  echo -e "  本地地址: $current_addr"
  echo -e "  当前目标IP: $current_target_ip"
  echo -e "  当前目标端口: $current_target_port"
  echo -e "---------------------------------------"
  echo -e "${YELLOW}输入新值（留空保持当前值）:${PLAIN}"
  
  # Get new target IP
  read -p "新目标IP [$current_target_ip]: " new_target_ip
  if [ -z "$new_target_ip" ]; then
    new_target_ip=$current_target_ip
  elif ! validate_ip "$new_target_ip"; then
    echo -e "${RED}无效的目标IP地址: $new_target_ip${PLAIN}"
    return 1
  fi
  
  # Get new target port
  read -p "新目标端口 [$current_target_port]: " new_target_port
  if [ -z "$new_target_port" ]; then
    new_target_port=$current_target_port
  elif ! validate_port "$new_target_port"; then
    echo -e "${RED}无效的目标端口: $new_target_port. 必须在1到65535之间.${PLAIN}"
    return 1
  fi
  
  # Check if changes were actually made
  if [ "$new_target_ip" == "$current_target_ip" ] && [ "$new_target_port" == "$current_target_port" ]; then
    echo -e "${YELLOW}没有检测到变更。编辑取消。${PLAIN}"
    return 0
  fi
  
  # Prepare the new target address string
  local new_target_full_addr="$new_target_ip:$new_target_port"
  
  echo -e -n "应用更改? (目标: ${BOLD}$new_target_full_addr${PLAIN}) (${GREEN}Y${PLAIN}/${RED}N${PLAIN}): "
  read confirm
  
  if [[ $confirm == [Yy]* ]]; then
    # Create backup
    local backup_file="${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
    echo -e "${YELLOW}备份当前配置到 $backup_file...${PLAIN}"
    sudo cp "$CONFIG_FILE" "$backup_file" || { echo -e "${RED}创建备份失败。中止操作。${PLAIN}"; return 1; }
    
    # Create a temporary file
    local temp_file=$(mktemp)
    
    # Keep lines before service
    if [ $start_line -gt 1 ]; then
      sed -n "1,$((start_line-1))p" "$CONFIG_FILE" > "$temp_file"
    fi
    
    # Process the service block and update the target address
    sed -n "${start_line},${end_line}p" "$CONFIG_FILE" | sed "s|addr: '$current_target_addr'|addr: '$new_target_full_addr'|g" >> "$temp_file"
    
    # Keep lines after service
    if [ $end_line -lt $(wc -l < "$CONFIG_FILE") ]; then
      sed -n "$((end_line+1)),\$p" "$CONFIG_FILE" >> "$temp_file"
    fi
    
    # Replace original file with temporary file
    sudo mv "$temp_file" "$CONFIG_FILE"
    
    # Reload service
    reload_gost_service
    
    echo -e "${GREEN}服务 $service_name 已成功更新${PLAIN}"
  else
    echo -e "${YELLOW}取消编辑。${PLAIN}"
  fi
}

# Function to manage existing forwarding services
manage_forward_services() {
  while true; do
    echo -e "\\n${CYAN}=== 管理转发规则 ===${PLAIN}"
    echo -e "${GREEN}1.${PLAIN} 列出规则"
    echo -e "${GREEN}2.${PLAIN} 添加新规则"
    echo -e "${GREEN}3.${PLAIN} 编辑规则(按编号)"
    echo -e "${GREEN}4.${PLAIN} 删除规则(按编号)"
    echo -e "${GREEN}5.${PLAIN} 返回主菜单"
    read -p "$(echo -e ${YELLOW}"请选择 [1-5]: "${PLAIN})" choice

    case $choice in
    1) list_forward_services ;;
    2) create_forward_service ;; # Direct call to add function
    3)
      list_forward_services
      local service_count=$?
      if [ $service_count -gt 0 ]; then
        read -p "输入要编辑的规则编号: " service_number_to_edit
        edit_forward_service "$service_number_to_edit"
      else
        echo -e "${YELLOW}没有可编辑的规则。${PLAIN}"
        sleep 1
      fi
      ;;
    4)
      list_forward_services
      local service_count=$?
      if [ $service_count -gt 0 ]; then
        read -p "输入要删除的规则编号: " service_number_to_delete
        delete_service_by_number "$service_number_to_delete"
      else
        echo -e "${YELLOW}没有可删除的规则。${PLAIN}"
        sleep 1
      fi
      ;;
    5) return ;;
    *) echo -e "${RED}无效的选择。请重试。${PLAIN}" ;;
    esac
  done
}

# Function to display service status and control
service_control() {
  while true; do
    echo -e "\\n${CYAN}=== GOST服务控制 ===${PLAIN}"
    
    # Check current status
    if systemctl is-active --quiet gost; then
      echo -e "GOST服务状态: ${GREEN}运行中${PLAIN}"
    else
      echo -e "GOST服务状态: ${RED}已停止${PLAIN}"
    fi
    
    echo -e "${GREEN}1.${PLAIN} 启动服务"
    echo -e "${GREEN}2.${PLAIN} 停止服务"
    echo -e "${GREEN}3.${PLAIN} 重启服务"
    echo -e "${GREEN}4.${PLAIN} 查看服务日志"
    echo -e "${GREEN}5.${PLAIN} 返回主菜单"
    read -p "$(echo -e ${YELLOW}"请选择 [1-5]: "${PLAIN})" choice

    case $choice in
    1)
      echo -e "${YELLOW}启动GOST服务...${PLAIN}"
      sudo systemctl start gost
      if systemctl is-active --quiet gost; then
        echo -e "${GREEN}GOST服务已成功启动${PLAIN}"
      else
        echo -e "${RED}启动GOST服务失败${PLAIN}"
      fi
      ;;
    2)
      echo -e "${YELLOW}停止GOST服务...${PLAIN}"
      sudo systemctl stop gost
      if ! systemctl is-active --quiet gost; then
        echo -e "${GREEN}GOST服务已成功停止${PLAIN}"
      else
        echo -e "${RED}停止GOST服务失败${PLAIN}"
      fi
      ;;
    3)
      echo -e "${YELLOW}重启GOST服务...${PLAIN}"
      sudo systemctl restart gost
      if systemctl is-active --quiet gost; then
        echo -e "${GREEN}GOST服务已成功重启${PLAIN}"
      else
        echo -e "${RED}重启GOST服务失败${PLAIN}"
      fi
      ;;
    4)
      echo -e "${CYAN}GOST服务日志 (按q退出):${PLAIN}"
      sudo journalctl -u gost -f
      ;;
    5) return ;;
    *) echo -e "${RED}无效的选择。请重试。${PLAIN}" ;;
    esac
    
    # Skip the "press any key" if we viewed logs
    if [ "$choice" != "4" ]; then
      read -n1 -r -p "按任意键继续..."
    fi
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

# 添加一个检测和列出旧式GOST服务的函数
list_legacy_services() {
  echo -e "${CYAN}=== 旧式GOST服务列表 (systemd服务) ===${PLAIN}"
  echo "----------------------------------------------------------------------------------------------------"
  
  # 查找所有gost开头的systemd服务文件(除了主gost服务)
  local counter=1
  local found=0
  printf "%-5s %-30s %-10s %-30s\\n" "编号" "服务名称" "状态" "命令行"
  echo "----------------------------------------------------------------------------------------------------"
  
  for service_file in "$SERVICE_DIR"/gost-*.service; do
    if [ -e "$service_file" ]; then
      found=1
      local service_name=$(basename "$service_file" .service)
      local status=$(systemctl is-active "$service_name")
      local cmd=$(grep "ExecStart=" "$service_file" | sed 's/ExecStart=//' | head -n 1)
      
      # 截断过长的命令行
      if [ ${#cmd} -gt 30 ]; then
        cmd="${cmd:0:27}..."
      fi
      
      printf "%-5s %-30s %-10s %-30s\\n" \
        "$counter" \
        "$service_name" \
        "$status" \
        "$cmd"
      
      ((counter++))
    fi
  done
  
  if [ $found -eq 0 ]; then
    echo -e "${YELLOW}没有发现旧式GOST服务。${PLAIN}"
  fi
  
  echo "----------------------------------------------------------------------------------------------------"
  return $((counter - 1))
}

# 删除旧式GOST服务
delete_legacy_service() {
  local service_number=$1
  local counter=1
  
  for service_file in "$SERVICE_DIR"/gost-*.service; do
    if [ -e "$service_file" ]; then
      if [ $counter -eq $service_number ]; then
        local service_name=$(basename "$service_file" .service)
        
        echo -e -n "确定要删除服务 ${BOLD}$service_name${PLAIN}? (${GREEN}Y${PLAIN}/${RED}N${PLAIN}): "
        read confirm
        
        if [[ $confirm == [Yy]* ]]; then
          # 停止并禁用服务
          sudo systemctl stop "$service_name"
          sudo systemctl disable "$service_name"
          
          # 删除服务文件
          sudo rm "$service_file"
          sudo systemctl daemon-reload
          
          echo -e "${GREEN}服务 $service_name 已成功删除${PLAIN}"
        else
          echo -e "${YELLOW}取消删除。${PLAIN}"
        fi
        
        return
      fi
      
      ((counter++))
    fi
  done
  
  echo -e "${RED}未找到指定编号的服务。${PLAIN}"
}

# 迁移旧式服务到配置文件
migrate_legacy_service() {
  local service_number=$1
  local counter=1
  
  for service_file in "$SERVICE_DIR"/gost-*.service; do
    if [ -e "$service_file" ]; then
      if [ $counter -eq $service_number ]; then
        local service_name=$(basename "$service_file" .service)
        local cmd=$(grep "ExecStart=" "$service_file" | sed 's/ExecStart=//' | head -n 1)
        
        # 解析命令行获取参数
        local protocol=""
        local local_port=""
        local target_addr=""
        local target_port=""
        
        if [[ "$cmd" =~ -L=([^:]+)://([^/]+)/(.+) ]]; then
          protocol="${BASH_REMATCH[1]}"
          local_addr="${BASH_REMATCH[2]}"
          target="${BASH_REMATCH[3]}"
          
          # 处理本地端口
          if [[ "$local_addr" == *":"* ]]; then
            local_port=$(echo "$local_addr" | cut -d: -f2)
          fi
          
          # 处理目标地址和端口
          if [[ "$target" == *":"* ]]; then
            target_addr=$(echo "$target" | cut -d: -f1)
            target_port=$(echo "$target" | cut -d: -f2)
          fi
        fi
        
        # 如果能成功解析命令行参数，添加到配置文件
        if [ -n "$protocol" ] && [ -n "$local_port" ] && [ -n "$target_addr" ] && [ -n "$target_port" ]; then
          echo -e "${YELLOW}正在迁移服务 ${BOLD}$service_name${PLAIN}${YELLOW} 到配置文件...${PLAIN}"
          
          # 使用解析出的参数创建新的配置项
          local short_target="${target_addr##*.}"
          if [ -z "$short_target" ]; then
            short_target="${target_addr}"
          fi
          
          # 检查配置文件格式
          local first_line=$(head -n 1 "$CONFIG_FILE")
          if [ -z "$first_line" ] || [[ "$first_line" != "services:"* ]]; then
            echo -e "${YELLOW}修复配置文件格式: $CONFIG_FILE${PLAIN}"
            local temp_file=$(mktemp)
            echo "services:" > "$temp_file"
            if [ -s "$CONFIG_FILE" ]; then
              if grep -q "^- name:" "$CONFIG_FILE"; then
                cat "$CONFIG_FILE" | sed 's/^-/  -/' >> "$temp_file"
              else
                cat "$CONFIG_FILE" >> "$temp_file"
              fi
            fi
            sudo mv "$temp_file" "$CONFIG_FILE"
          fi
          
          # 备份配置文件
          local backup_file="${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
          sudo cp "$CONFIG_FILE" "$backup_file" || { echo -e "${RED}创建备份失败。中止操作。${PLAIN}"; return 1; }
          
          # 添加服务到配置文件，使用正确的缩进
          sudo bash -c "cat >> \"$CONFIG_FILE\" << EOF
  - name: ${protocol}-${local_port}-to-${short_target}-${target_port}
    addr: ':$local_port'
    handler:
      type: $protocol
    listener:
      type: $protocol
    forwarder:
      nodes:
      - name: target-${protocol}-${local_port}-${target_port}
        addr: '$target_addr:$target_port'
        connector:
          type: forward
        dialer:
          type: $protocol
EOF"
          
          # 删除旧服务
          sudo systemctl stop "$service_name"
          sudo systemctl disable "$service_name"
          sudo rm "$service_file"
          sudo systemctl daemon-reload
          
          # 重载GOST服务
          reload_gost_service
          
          echo -e "${GREEN}服务 $service_name 已成功迁移到配置文件${PLAIN}"
        else
          echo -e "${RED}无法解析服务命令行，迁移失败: $cmd${PLAIN}"
        fi
        
        return
      fi
      
      ((counter++))
    fi
  done
  
  echo -e "${RED}未找到指定编号的服务。${PLAIN}"
}

# 旧式服务管理菜单
manage_legacy_services() {
  while true; do
    echo -e "\\n${CYAN}=== 管理旧式GOST服务 ===${PLAIN}"
    echo -e "${GREEN}1.${PLAIN} 列出旧式服务"
    echo -e "${GREEN}2.${PLAIN} 删除旧式服务"
    echo -e "${GREEN}3.${PLAIN} 迁移到配置文件"
    echo -e "${GREEN}4.${PLAIN} 返回主菜单"
    read -p "$(echo -e ${YELLOW}"请选择 [1-4]: "${PLAIN})" choice

    case $choice in
    1) list_legacy_services ;;
    2)
      list_legacy_services
      local service_count=$?
      if [ $service_count -gt 0 ]; then
        read -p "输入要删除的服务编号: " service_number_to_delete
        delete_legacy_service "$service_number_to_delete"
      else
        sleep 1
      fi
      ;;
    3)
      list_legacy_services
      local service_count=$?
      if [ $service_count -gt 0 ]; then
        read -p "输入要迁移的服务编号: " service_number_to_migrate
        migrate_legacy_service "$service_number_to_migrate"
      else
        sleep 1
      fi
      ;;
    4) return ;;
    *) echo -e "${RED}无效的选择。请重试。${PLAIN}" ;;
    esac
  done
}

# Main menu
main_menu() {
  while true; do
    clear
    get_ip_info
    echo -e "${BOLD}${BLUE}==================== Gost端口转发管理 ====================${PLAIN}"
    echo -e "  ${CYAN}IPv4: ${WHITE}$IPV4 ${YELLOW}($COUNTRY_V4)${PLAIN}"
    echo -e "  ${CYAN}IPv6: ${WHITE}$IPV6 ${YELLOW}($COUNTRY_V6)${PLAIN}"
    echo -e "${BOLD}${BLUE}=========================================================================${PLAIN}"
    echo -e "${GREEN}1.${PLAIN} 管理转发规则"
    echo -e "${GREEN}2.${PLAIN} 管理GOST服务"
    echo -e "${GREEN}3.${PLAIN} 管理旧式服务"
    echo -e "${GREEN}4.${PLAIN} 退出"
    echo -e "${BOLD}${BLUE}=========================================================================${PLAIN}"
    read -p "$(echo -e ${YELLOW}"请选择 [1-4]: "${PLAIN})" choice

    case $choice in
    1) manage_forward_services ;;
    2) service_control ;;
    3) manage_legacy_services ;;
    4)
      echo -e "${GREEN}感谢使用。再见！${PLAIN}"
      exit 0
      ;;
    *) echo -e "${RED}无效的选择。请重试。${PLAIN}" ;;
    esac
  done
}

# Check and install necessary components
check_and_install

# Execute main menu
main_menu
