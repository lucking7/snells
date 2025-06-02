#!/bin/bash

# GOST端口转发统一管理脚本
# 该脚本使用GOST配置文件管理所有端口转发，通过单一systemd服务运行
# 版本: 2.2
# 支持功能: 单端口转发、端口范围转发、配置文件管理
# 注意: 该脚本默认使用配置文件方式管理所有转发

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

# Service files directory - Standard systemd path
SERVICE_DIR="/etc/systemd/system"

# 默认配置目录和文件（将在setup_config_dir中被修改）
CONFIG_DIR="./gost_config"
CONFIG_FILE="$CONFIG_DIR/config.json"

# Symbols for messages
SUCCESS_SYMBOL="[+]"
ERROR_SYMBOL="[x]"
INFO_SYMBOL="[i]"
WARN_SYMBOL="[!]"

# Function to check and install essential dependencies and gost
check_and_install_dependencies_and_gost() {
  printf "${BLUE} ${INFO_SYMBOL}Performing initial setup and dependency check...${PLAIN}\n"
  
  local essential_pkgs=("lsof" "jq" "realpath") # realpath is needed for absolute config path
  local utility_pkgs=("curl" "grep" "shuf") # 添加shuf作为可选工具检查
  local pkgs_to_install=()
  local pkg_manager_detected=""

  if command -v apt-get &>/dev/null; then
    pkg_manager_detected="apt-get"
  elif command -v yum &>/dev/null; then
    pkg_manager_detected="yum"
  elif command -v dnf &>/dev/null; then
    pkg_manager_detected="dnf"
  else
    printf "${RED} ${ERROR_SYMBOL}No supported package manager (apt-get, yum, dnf) found. Please install dependencies manually.${PLAIN}\n"
    for pkg in "${essential_pkgs[@]}"; do
        if ! command -v $pkg &>/dev/null; then
            printf "${RED} ${ERROR_SYMBOL}CRITICAL: Essential package '$pkg' is missing. Script cannot continue.${PLAIN}\n"
            exit 1
        fi
    done
    printf "${YELLOW} ${WARN_SYMBOL}Assuming essential dependencies are present as no package manager was found for installation.${PLAIN}\n"
  fi

  if [ -n "$pkg_manager_detected" ]; then
    for pkg in "${essential_pkgs[@]}" "${utility_pkgs[@]}"; do # Combined check
      if ! command -v $pkg &>/dev/null; then
        pkgs_to_install+=($pkg)
      fi
    done

    if [ ${#pkgs_to_install[@]} -gt 0 ]; then
      printf "${YELLOW} ${INFO_SYMBOL}The following packages are missing or not found: %s.${PLAIN}\n" "${pkgs_to_install[*]}"
      printf "${YELLOW} ${INFO_SYMBOL}Attempting to install them using %s (requires sudo)...${PLAIN}\n" "$pkg_manager_detected"
      if [ "$pkg_manager_detected" == "apt-get" ]; then
        sudo apt-get update -y || printf "${RED} ${ERROR_SYMBOL}Failed to update package lists.${PLAIN}\n"
      fi
      if sudo $pkg_manager_detected install -y "${pkgs_to_install[@]}"; then
        printf "${GREEN} ${SUCCESS_SYMBOL}Successfully attempted installation of: %s.${PLAIN}\n" "${pkgs_to_install[*]}"
      else
        printf "${RED} ${ERROR_SYMBOL}Failed to install some packages. Please check errors and install them manually.${PLAIN}\n"
      fi
    fi
  fi

  for pkg in "${essential_pkgs[@]}"; do
    if ! command -v $pkg &>/dev/null; then
      printf "${RED} ${ERROR_SYMBOL}CRITICAL: Essential package '$pkg' is still missing after installation attempt.${PLAIN}\n"
      printf "${RED} ${ERROR_SYMBOL}Please install '$pkg' manually and re-run the script. Exiting.${PLAIN}\n"
      exit 1
    fi
  done
  printf "${GREEN} ${SUCCESS_SYMBOL}Essential dependencies (lsof, jq, realpath) are installed.${PLAIN}\n"

  if ! command -v gost &>/dev/null; then
    printf "${YELLOW} ${INFO_SYMBOL}gost not found. Attempting to install gost...${PLAIN}\n"
    if command -v curl &>/dev/null; then
      (bash <(curl -fsSL https://github.com/go-gost/gost/raw/master/install.sh) --install) &
      show_loading $! 
      if command -v gost &>/dev/null; then
        printf "${GREEN} ${SUCCESS_SYMBOL}gost installed successfully.${PLAIN}\n"
      else
        printf "${RED} ${ERROR_SYMBOL}Failed to install gost. Please install it manually from https://github.com/go-gost/gost ${PLAIN}\n"
      fi
    else
      printf "${RED} ${ERROR_SYMBOL}curl is not installed. Cannot download gost install script. Please install curl and gost manually.${PLAIN}\n"
    fi
  else
    printf "${GREEN} ${SUCCESS_SYMBOL}gost is already installed.${PLAIN}\n"
  fi
  printf "${BLUE} ${INFO_SYMBOL}Initial setup and dependency check complete.${PLAIN}\n"
}

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

# 检查和创建配置目录
setup_config_dir() {
  # 尝试标准位置，优先级: /etc/gost/ > $HOME/gost/ > ./gost_config
  if [ -d "/etc/gost" ] || (sudo mkdir -p /etc/gost && sudo chmod 755 /etc/gost 2>/dev/null); then
    CONFIG_DIR="/etc/gost"
    printf "${GREEN} ${SUCCESS_SYMBOL}使用标准配置目录: ${CONFIG_DIR}${PLAIN}\n"
  elif [ -d "$HOME/gost" ] || mkdir -p "$HOME/gost" 2>/dev/null; then
    CONFIG_DIR="$HOME/gost"
    printf "${YELLOW} ${WARN_SYMBOL}无法创建/etc/gost目录，使用用户主目录: ${CONFIG_DIR}${PLAIN}\n"
  else
    CONFIG_DIR="./gost_config"
    mkdir -p "$CONFIG_DIR" 2>/dev/null
    printf "${YELLOW} ${WARN_SYMBOL}无法使用标准目录，使用当前目录: ${CONFIG_DIR}${PLAIN}\n"
  fi
  CONFIG_FILE="$CONFIG_DIR/config.json"
  
  # 如果是非标准目录，提示用户
  if [[ "$CONFIG_DIR" != "/etc/gost" ]]; then
    printf "${YELLOW} ${WARN_SYMBOL}警告: 不使用标准配置目录可能导致与系统服务集成问题${PLAIN}\n"
    printf "${YELLOW} ${WARN_SYMBOL}建议使用管理员权限运行此脚本，或手动创建/etc/gost目录${PLAIN}\n"
  fi
}

# 在检查依赖后调用配置目录设置函数
check_and_install_dependencies_and_gost
setup_config_dir

validate_input() {
  local input=$1
  local input_type=$2

  case $input_type in
  "port")
    if ! [[ "$input" =~ ^[0-9]+$ ]] || [ "$input" -lt 1 ] || [ "$input" -gt 65535 ]; then
      printf "${RED} ${ERROR_SYMBOL}Invalid port number. Must be between 1-65535.${PLAIN}\n"
      return 1
    fi
    ;;
  "ip")
    if [[ "$input" =~ ^([0-9]{1,3}\\.){3}[0-9]{1,3}$ ]]; then
      IFS='.' read -r -a octets <<<"$input"
      for octet in "${octets[@]}"; do
        if [ "$octet" -gt 255 ]; then
          printf "${RED} ${ERROR_SYMBOL}Invalid IPv4 address. Each octet must be <= 255.${PLAIN}\n"
          return 1
        fi
      done
      return 0
    fi
    if [[ "$input" =~ ^[0-9a-fA-F:]+$ ]]; then # Simplified IPv6 check
      return 0
    fi
    printf "${RED} ${ERROR_SYMBOL}Invalid IP address format.${PLAIN}\n"
    return 1
    ;;
  "hostname")
    if [[ "$input" =~ ^[a-zA-Z0-9]([-a-zA-Z0-9\\.]{0,61}[a-zA-Z0-9])?$ ]]; then
      return 0
    fi
    printf "${RED} ${ERROR_SYMBOL}Invalid hostname format.${PLAIN}\n"
    return 1
    ;;
  esac
  return 0
}

ensure_config_dir() {
  # 目录创建已由 setup_config_dir 处理，或对于非sudo路径由mkdir -p处理
  if [ ! -d "$CONFIG_DIR" ]; then
    # 此处的mkdir -p主要用于 $HOME/gost 或 ./gost_config 的情况
    # 因为 /etc/gost 应该在 setup_config_dir 中用 sudo 创建了
    if [[ "$CONFIG_DIR" == "/etc/"* ]]; then
      sudo mkdir -p "$CONFIG_DIR" 2>/dev/null
    else
      mkdir -p "$CONFIG_DIR" 2>/dev/null
    fi
    printf "${GREEN} ${SUCCESS_SYMBOL}Created config directory: %s${PLAIN}\n" "$CONFIG_DIR"
  fi

  if [ ! -f "$CONFIG_FILE" ]; then
    json_content='{ \n  "services": [] \n}'
    # 根据CONFIG_DIR是否在/etc/下判断是否需要sudo
    if [[ "$CONFIG_DIR" == "/etc/"* ]]; then
      echo -e "$json_content" | sudo tee "$CONFIG_FILE" > /dev/null
      sudo chown root:root "$CONFIG_FILE"  # 设置正确的所有者
      sudo chmod 644 "$CONFIG_FILE"       # 确保world-readable
      sudo chmod 755 "$CONFIG_DIR"        # 确保目录可访问
      printf "${GREEN} ${SUCCESS_SYMBOL}Created base config file (with sudo): %s${PLAIN}\n" "$CONFIG_FILE"
    else
      echo -e "$json_content" > "$CONFIG_FILE"
      chmod 644 "$CONFIG_FILE" # 确保nobody用户可读 (如果gost以其他用户运行，也可能有帮助)
      printf "${GREEN} ${SUCCESS_SYMBOL}Created base config file: %s${PLAIN}\n" "$CONFIG_FILE"
    fi
  else
    # 如果文件已存在，也确保权限正确，以防手动更改或旧脚本创建的文件权限不当
    if [[ "$CONFIG_DIR" == "/etc/"* ]]; then
      # 确保正确的所有者和权限
      sudo chown root:root "$CONFIG_FILE"
      sudo chmod 644 "$CONFIG_FILE"
      sudo chmod 755 "$CONFIG_DIR"
      printf "${YELLOW} ${WARN_SYMBOL}Fixed permissions for existing config file${PLAIN}\n"
    else
      chmod 644 "$CONFIG_FILE"
    fi
  fi
  
  # 验证nobody用户是否可以读取配置文件
  if [[ "$CONFIG_DIR" == "/etc/"* ]]; then
    if ! sudo -u nobody test -r "$CONFIG_FILE" 2>/dev/null; then
      printf "${RED} ${ERROR_SYMBOL}Warning: nobody user cannot read config file. Attempting to fix...${PLAIN}\n"
      sudo chmod 644 "$CONFIG_FILE"
      sudo chmod 755 "$CONFIG_DIR"
      if ! sudo -u nobody test -r "$CONFIG_FILE" 2>/dev/null; then
        printf "${RED} ${ERROR_SYMBOL}Failed to fix permissions. Consider using alternative config location.${PLAIN}\n"
        return 1
      else
        printf "${GREEN} ${SUCCESS_SYMBOL}Fixed permissions - nobody user can now read config file.${PLAIN}\n"
      fi
    fi
  fi
}

add_forward_to_config() {
  local name=$1
  local listen_addr=$2
  local nodes_json_array_string=$3 # JSON string for the "nodes" array
  local proto=$4

  ensure_config_dir
  local temp_file=$(mktemp)
  
  if [ "$proto" = "tcp-udp" ]; then
    # For tcp-udp, we create two services, each with the same multi-target forwarder
    # Ensure names are distinct if the base name was already specific
    local base_name_for_pair="$name"
    # If name already ends with -tcp or -udp (e.g. from single proto converted to tcp-udp), strip it for base.
    if [[ "$name" == *-tcp || "$name" == *-udp ]]; then
        base_name_for_pair="${name%-*}"
    fi

    local tcp_service_template='{
      "name": "%s-tcp",
      "addr": "%s",
      "handler": { "type": "tcp" },
      "listener": { "type": "tcp" },
      "forwarder": { "nodes": %s }
    }'
    local udp_service_template='{
      "name": "%s-udp",
      "addr": "%s",
      "handler": { "type": "udp" },
      "listener": { "type": "udp" },
      "forwarder": { "nodes": %s }
    }'
    local tcp_service_json
    printf -v tcp_service_json "$tcp_service_template" "$base_name_for_pair" "$listen_addr" "$nodes_json_array_string"
    local udp_service_json
    printf -v udp_service_json "$udp_service_template" "$base_name_for_pair" "$listen_addr" "$nodes_json_array_string"

    jq ".services += [${tcp_service_json}, ${udp_service_json}]" "$CONFIG_FILE" > "$temp_file"
  else 
    local service_template='{
      "name": "%s",
      "addr": "%s",
      "handler": { "type": "%s" },
      "listener": { "type": "%s" },
      "forwarder": { "nodes": %s }
    }'
    local service_json
    printf -v service_json "$service_template" "$name" "$listen_addr" "$proto" "$proto" "$nodes_json_array_string"
    jq ".services += [${service_json}]" "$CONFIG_FILE" > "$temp_file"
  fi
  
  if [ $? -eq 0 ]; then
    if [[ "$CONFIG_FILE" == "/etc/gost/"* ]]; then
        sudo mv "$temp_file" "$CONFIG_FILE"
        sudo chown root:root "$CONFIG_FILE" # Ensure correct ownership
        sudo chmod 644 "$CONFIG_FILE"      # Ensure correct permissions
    else
        mv "$temp_file" "$CONFIG_FILE"
        chmod 644 "$CONFIG_FILE" # Ensure correct permissions for non-sudo
    fi
  else
    printf "${RED} ${ERROR_SYMBOL}Error adding service(s) to config file using jq.${PLAIN}\\n"
    rm -f "$temp_file"
    return 1
  fi
  # If mv failed above, temp_file would still exist unless caught by jq error.
  # If mv succeeded, temp_file is gone. No explicit rm needed here if logic is correct.
  printf "${GREEN} ${SUCCESS_SYMBOL}Added forwarding to config file.${PLAIN}\\n"
}

apply_config() {
  if [ ! -f "$CONFIG_FILE" ]; then
    printf "${RED} ${ERROR_SYMBOL}Config file not found at: %s${PLAIN}\n" "$CONFIG_FILE"
    ensure_config_dir
    printf "${YELLOW} ${WARN_SYMBOL}Base config file created. Please add forwarding entries and try again.${PLAIN}\n"
    return 1
  fi

  if ! command -v gost &>/dev/null; then
    printf "${RED} ${ERROR_SYMBOL}gost command not found. Please install it first.${PLAIN}\n"
    return 1
  fi

  # 检测配置文件格式 - 支持JSON和YAML
  local file_ext="${CONFIG_FILE##*.}"
  if [ "$file_ext" = "json" ]; then
    if ! jq empty "$CONFIG_FILE" >/dev/null 2>&1; then
      printf "${RED} ${ERROR_SYMBOL}Invalid JSON format in %s. Please fix it manually.${PLAIN}\n" "$CONFIG_FILE"
      return 1
    fi
  elif [ "$file_ext" = "yml" ] || [ "$file_ext" = "yaml" ]; then
    if ! command -v yq &>/dev/null; then
      printf "${YELLOW} ${WARN_SYMBOL}YAML配置文件检查需要yq工具，跳过格式验证.${PLAIN}\n"
    else
      if ! yq eval . "$CONFIG_FILE" >/dev/null 2>&1; then 
        printf "${RED} ${ERROR_SYMBOL}Invalid YAML format in %s. Please fix it manually.${PLAIN}\n" "$CONFIG_FILE"
        return 1
      fi
    fi
  else
    printf "${YELLOW} ${WARN_SYMBOL}Unknown config file format: %s. Assuming JSON.${PLAIN}\n" "$file_ext"
    if ! jq empty "$CONFIG_FILE" >/dev/null 2>&1; then
      printf "${RED} ${ERROR_SYMBOL}Invalid JSON format in %s. Please fix it manually.${PLAIN}\n" "$CONFIG_FILE"
      return 1
    fi
  fi
  
  printf "${YELLOW} ${WARN_SYMBOL}WARNING: The gost service will run as User=nobody, Group=nogroup.${PLAIN}\n"
  printf "${YELLOW} ${WARN_SYMBOL}Please ensure the config file '$CONFIG_FILE' (absolute path: $(realpath "$CONFIG_FILE")) is readable by this user/group.${PLAIN}\n"
  printf "${YELLOW} ${WARN_SYMBOL}You might need to adjust permissions (e.g., sudo chmod 644 $(realpath "$CONFIG_FILE")).${PLAIN}\n"

  printf "${CYAN} ${INFO_SYMBOL}Stopping existing gost service (if any)...${PLAIN}\n"
  if systemctl is-active --quiet gost; then
    sudo systemctl stop gost
  fi
  for old_service_file in "$SERVICE_DIR"/gost-*.service; do
    if [ -f "$old_service_file" ]; then
      service_name=$(basename "$old_service_file" .service)
      if [ "$service_name" != "gost" ]; then 
        printf "${YELLOW} ${INFO_SYMBOL}Stopping and disabling old service %s...${PLAIN}\n" "$service_name"
        sudo systemctl stop "$service_name" &>/dev/null
        sudo systemctl disable "$service_name" &>/dev/null
        sudo rm -f "$old_service_file"
      fi
    fi
  done

  printf "${CYAN} ${INFO_SYMBOL}Creating and configuring gost systemd service...${PLAIN}\n"
  
  local abs_config_file
  if ! abs_config_file=$(realpath "$CONFIG_FILE"); then
    printf "${RED} ${ERROR_SYMBOL}Failed to get absolute path for %s. Make sure 'realpath' is installed.${PLAIN}\n" "$CONFIG_FILE"
    return 1
  fi

  # 根据配置文件格式调整启动参数
  local config_param=""
  if [ "$file_ext" = "json" ] || [ "$file_ext" = "yml" ] || [ "$file_ext" = "yaml" ]; then
    config_param="-C \"$abs_config_file\""
  else  
    config_param="-C \"$abs_config_file\""
  fi

# 创建gost用户（如果不存在）
if ! id "gost" &>/dev/null; then
  printf "${CYAN} ${INFO_SYMBOL}Creating gost system user...${PLAIN}\n"
  sudo useradd --system --no-create-home --shell /bin/false gost 2>/dev/null || {
    printf "${YELLOW} ${WARN_SYMBOL}Failed to create gost user, using nobody instead${PLAIN}\n"
    GOST_USER="nobody"
    GOST_GROUP="nogroup"
  }
  if [ -z "$GOST_USER" ]; then
    GOST_USER="gost"
    GOST_GROUP="gost"
    # 确保gost用户可以读取配置文件
    if [[ "$CONFIG_DIR" == "/etc/"* ]]; then
      sudo chown -R root:gost "$CONFIG_DIR"
      sudo chmod -R 750 "$CONFIG_DIR"
      sudo chmod 640 "$CONFIG_FILE"
    fi
  fi
else
  GOST_USER="gost"
  GOST_GROUP="gost"
  # 确保gost用户可以读取配置文件
  if [[ "$CONFIG_DIR" == "/etc/"* ]]; then
    sudo chown -R root:gost "$CONFIG_DIR"
    sudo chmod -R 750 "$CONFIG_DIR"
    sudo chmod 640 "$CONFIG_FILE"
  fi
fi

SERVICE_FILE_CONTENT=$(cat <<EOF
[Unit]
Description=GOST Proxy Service
After=network.target
Wants=network.target

[Service]
ExecStart=/usr/local/bin/gost $config_param
Restart=always
RestartSec=5
User=$GOST_USER
Group=$GOST_GROUP
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/log
CapabilityBoundingSet=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
)

  echo "$SERVICE_FILE_CONTENT" | sudo tee "$SERVICE_DIR/gost.service" > /dev/null
  if [ $? -ne 0 ]; then
    printf "${RED} ${ERROR_SYMBOL}Failed to write gost.service file. Check sudo permissions or if '%s' is writable.${PLAIN}\n" "$SERVICE_DIR"
    return 1
  fi

  sudo systemctl daemon-reload
  sudo systemctl enable gost

  printf "${CYAN} ${INFO_SYMBOL}Starting gost service...${PLAIN}\n"
  if ! sudo systemctl start gost; then
    printf "${RED} ${ERROR_SYMBOL}Failed to start gost service. Checking for errors...${PLAIN}\n"
    sudo journalctl -u gost --no-pager -n 20
    return 1
  fi

  if sudo systemctl is-active --quiet gost; then
    printf "${GREEN} ${SUCCESS_SYMBOL}Gost service is running successfully!${PLAIN}\n"
    printf "${CYAN} ${INFO_SYMBOL}Configured forwarding services from %s:${PLAIN}\n" "$CONFIG_FILE"
    local counter=1
    while IFS="|" read -r name listen_addr target_addr proto; do
      if [ ! -z "$name" ]; then
        local local_port=$(echo "$listen_addr" | grep -o ':[0-9]\+\(-[0-9]\+\)*' | sed 's/://')
        target_ip=$(echo "$target_addr" | grep -o '[^:]*' | head -1)
        target_port=$(echo "$target_addr" | grep -o ':[0-9]\+\(-[0-9]\+\)*' | sed 's/://')
        printf "  ${GREEN}%s.${PLAIN} Port %s (%s) -> %s:%s [%s]${PLAIN}\n" "$counter" "$local_port" "$proto" "$target_ip" "$target_port" "$name"
        ((counter++))
      fi
    done < <(parse_config_file)
    if [ $counter -eq 1 ]; then
      printf "${YELLOW} ${WARN_SYMBOL}No forwarding entries found in config file.${PLAIN}\n"
    fi
  else
    printf "${RED} ${ERROR_SYMBOL}Failed to start gost service. Service status is inactive.${PLAIN}\n"
    sudo journalctl -u gost --no-pager -n 20
    return 1
  fi
  printf "${GREEN} ${SUCCESS_SYMBOL}Successfully applied configuration from: %s${PLAIN}\n" "$CONFIG_FILE"
  return 0
}

find_free_port() {
  local port min_port=10000 max_port=65000
  
  # 检查是否有shuf命令
  if command -v shuf &>/dev/null; then
    # 使用shuf生成随机端口
    while true; do
      port=$(shuf -i $min_port-$max_port -n 1)
      if ! lsof -iTCP:"$port" -sTCP:LISTEN -P -n > /dev/null 2>&1; then
        echo $port
        return
      fi
    done
  else
    # 备用方法：使用$RANDOM
    while true; do
      # $RANDOM生成0-32767的随机数，所以需要调整范围
      port=$(( $min_port + $RANDOM % ($max_port - $min_port + 1) ))
      if ! lsof -iTCP:"$port" -sTCP:LISTEN -P -n > /dev/null 2>&1; then
        echo $port
        return
      fi
    done
  fi
}

create_forward_service() {
  printf "${CYAN}${INFO_SYMBOL}=== Create a new port forwarding ===${PLAIN}\\\n"
  read -p "Local port (default: random available port): " local_port
  if [ -n "$local_port" ]; then
    if ! validate_input "$local_port" "port"; then
      read -n1 -r -p "Press any key to try again..."
      return
    fi
  else
    local_port=$(find_free_port)
    printf "${YELLOW} ${INFO_SYMBOL}Selected available local port: ${BOLD}%s${PLAIN}${YELLOW}\\\n" "$local_port" # Ensure PLAIN is reset
  fi

  printf "${CYAN}${INFO_SYMBOL}Select protocol:${PLAIN}\\\n"
  printf "${GREEN}1.${PLAIN} TCP (to a single target)\\\n"
  printf "${GREEN}2.${PLAIN} UDP (to a single target)\\\n"
  printf "${GREEN}3.${PLAIN} Both TCP & UDP (to the SAME single target) ${YELLOW}(default)${PLAIN}\\\n"
  printf "${GREEN}4.${PLAIN} Split: TCP to one target, UDP to a DIFFERENT target (same local port)\\\n"
  read -p "Select [1-4] (default: 3): " protocol_choice

  local proto_selected # Can be "tcp", "udp", "tcp-udp" (for same targets), or "tcp-udp-split"

  case $protocol_choice in
  1) proto_selected="tcp" ;;
  2) proto_selected="udp" ;;
  4) proto_selected="tcp-udp-split" ;;
  *) proto_selected="tcp-udp" ;; # Default is 3, or any other input
  esac

  if [ "$proto_selected" = "tcp-udp-split" ]; then
    # --- Handle TCP-UDP Split to Different Targets (remains unchanged) ---
    printf "\\n${CYAN}${INFO_SYMBOL}Configuring TCP forwarding leg:${PLAIN}\\\n"
    local tcp_target_ip tcp_target_port
    while true; do
      read -p "TCP Target IP or hostname: " tcp_target_ip
      if [ -z "$tcp_target_ip" ]; then
        printf "${RED} ${ERROR_SYMBOL}TCP Target IP or hostname cannot be empty.${PLAIN}\\\n"
        read -n1 -r -p "Press any key to try again..."
        continue
      fi
      break
    done
    while true; do
      read -p "TCP Target port: " tcp_target_port
      if ! validate_input "$tcp_target_port" "port"; then
        read -n1 -r -p "Press any key to try again..."
        continue
      fi
      break
    done

    if [[ $tcp_target_ip == *:* ]] && [[ $tcp_target_ip != \\\\[*\\] ]]; then # Check for IPv6 and ensure brackets
        tcp_target_ip="[$tcp_target_ip]"
    fi
    local tcp_nodes_json_array_string=\'[{\"name\":\"target-0\",\"addr\":\"\'"${tcp_target_ip}:${tcp_target_port}"\'\"}]\'
    local tcp_service_name="forward-$local_port-to-$tcp_target_port-tcp"

    printf "\\n${CYAN}${INFO_SYMBOL}Configuring UDP forwarding leg:${PLAIN}\\\n"
    local udp_target_ip udp_target_port
    while true; do
      read -p "UDP Target IP or hostname: " udp_target_ip
      if [ -z "$udp_target_ip" ]; then
        printf "${RED} ${ERROR_SYMBOL}UDP Target IP or hostname cannot be empty.${PLAIN}\\\n"
        read -n1 -r -p "Press any key to try again..."
        continue
      fi
      break
    done
    while true; do
      read -p "UDP Target port: " udp_target_port
      if ! validate_input "$udp_target_port" "port"; then
        read -n1 -r -p "Press any key to try again..."
        continue
      fi
      break
    done
    if [[ $udp_target_ip == *:* ]] && [[ $udp_target_ip != \\\\[*\\] ]]; then # Check for IPv6 and ensure brackets
      udp_target_ip="[$udp_target_ip]"
    fi
    local udp_nodes_json_array_string=\'[{\"name\":\"target-0\",\"addr\":\"\'"${udp_target_ip}:${udp_target_port}"\'\"}]\'
    local udp_service_name="forward-$local_port-to-$udp_target_port-udp"

    add_forward_to_config "$tcp_service_name" ":$local_port" "$tcp_nodes_json_array_string" "tcp"
    local add_tcp_rc=$?
    add_forward_to_config "$udp_service_name" ":$local_port" "$udp_nodes_json_array_string" "udp"
    local add_udp_rc=$?

    if [ $add_tcp_rc -ne 0 ] || [ $add_udp_rc -ne 0 ]; then
      printf "${RED} ${ERROR_SYMBOL}Failed to add one or both forwarding legs for split configuration.${PLAIN}\\\n"
    fi

  else
    # --- Handle TCP, UDP, or TCP-UDP to a SINGLE Target ---
    printf "\\n${CYAN}${INFO_SYMBOL}Enter details for the Target (for %s traffic):${PLAIN}\\\n" "$proto_selected"
    local target_ip target_port

    while true; do
      read -p "Target IP or hostname: " target_ip
      if [ -z "$target_ip" ]; then
        printf "${RED} ${ERROR_SYMBOL}Target IP or hostname cannot be empty.${PLAIN}\\\n"
        read -n1 -r -p "Press any key to try again..."
        continue
      fi
      break
    done

    while true; do
      read -p "Target port: " target_port
      if ! validate_input "$target_port" "port"; then
        read -n1 -r -p "Press any key to try again..."
        continue
      fi
      break
    done

    if [[ $target_ip == *:* ]] && [[ $target_ip != \\\\[*\\] ]]; then # Check for IPv6 and ensure brackets
      target_ip="[$target_ip]"
    fi
    
    local nodes_json_array_string=\'[{\"name\":\"target-0\",\"addr\":\"\'"${target_ip}:${target_port}"\'\"}]\'
    local service_name="forward-$local_port-to-$target_port"
        
    add_forward_to_config "$service_name" ":$local_port" "$nodes_json_array_string" "$proto_selected"
  fi
  
  read -p "Apply config file now? (Y/n): " apply_now
  if [[ $apply_now != "n" && $apply_now != "N" ]]; then
      apply_config
  fi
}

create_port_range_forward() {
  printf "${CYAN}${INFO_SYMBOL}=== Create Port Range Forwarding ===${PLAIN}\\n"
  printf "${GREEN}1.${PLAIN} Many-to-One (Multiple local ports to one target port)\\n"
  printf "${GREEN}2.${PLAIN} Many-to-Many (Each local port maps to corresponding target port)\\n"
  read -p "Select forwarding type [1-2]: " range_type

  read -p "Local port range start: " local_start
  if ! validate_input "$local_start" "port"; then read -n1 -r -p "Press any key..." ; return; fi
  read -p "Local port range end: " local_end
  if ! validate_input "$local_end" "port"; then read -n1 -r -p "Press any key..." ; return; fi

  if [ "$local_start" -gt "$local_end" ]; then
    printf "${RED} ${ERROR_SYMBOL}Start port cannot be greater than end port.${PLAIN}\\n"
    read -n1 -r -p "Press any key to try again..."
    return
  fi

  read -p "Target IP or hostname: " target_ip
  if [ -z "$target_ip" ]; then printf "${RED} ${ERROR_SYMBOL}Target IP or hostname cannot be empty.${PLAIN}"; read -n1 -r -p "Press any key..." ; return; fi

  if [[ $target_ip == *:* ]] && [[ $target_ip != \\[\\[*\\] ]]; then target_ip="[$target_ip]"; fi

  printf "${CYAN}${INFO_SYMBOL}Select protocol:${PLAIN}\\n"
  printf "${GREEN}1.${PLAIN} TCP\\n"
  printf "${GREEN}2.${PLAIN} UDP\\n"
  printf "${GREEN}3.${PLAIN} Both TCP & UDP ${YELLOW}(default)${PLAIN}\\n"
  read -p "Select [1-3] (default: 3): " protocol_type
  case $protocol_type in 1) proto="tcp";; 2) proto="udp";; *) proto="tcp-udp";; esac

  local service_name target_addr

  if [ "$range_type" = "1" ]; then
    read -p "Target port: " target_port
    if ! validate_input "$target_port" "port"; then read -n1 -r -p "Press any key..." ; return; fi
    service_name="range-${local_start}-${local_end}-to-${target_port}"
    target_addr="${target_ip}:${target_port}"
  else # range_type is "2" (Many-to-Many)
    read -p "Target port range start: " target_start
    if ! validate_input "$target_start" "port"; then read -n1 -r -p "Press any key..." ; return; fi
    local port_count=$((local_end - local_start + 1))
    local target_end=$((target_start + port_count - 1))
    # Validate target_end port
    if [ "$target_end" -gt 65535 ]; then
        printf "${RED} ${ERROR_SYMBOL}Calculated target end port (%s) exceeds 65535.${PLAIN}\\n" "$target_end"
        read -n1 -r -p "Press any key to try again..."
        return
    fi
    service_name="range-${local_start}-${local_end}-to-${target_start}-${target_end}"
    target_addr="${target_ip}:${target_start}-${target_end}"
  fi
  
  # For port range forwarding, there's effectively one "node" in gost terms,
  # whose address might itself be a range.
  local nodes_json_array_string='[{"name":"target-0","addr":"'$target_addr'"}]'
  
  add_forward_to_config "$service_name" ":${local_start}-${local_end}" "$nodes_json_array_string" "$proto"
  
  printf "${GREEN} ${SUCCESS_SYMBOL}Port range forwarding added to config file.${PLAIN}\\n"
  printf "  ${CYAN}${INFO_SYMBOL}- Name: %s${PLAIN}\\n" "$service_name"
  printf "  ${CYAN}${INFO_SYMBOL}- Local Ports: %s-%s${PLAIN}\\n" "$local_start" "$local_end"
  printf "  ${CYAN}${INFO_SYMBOL}- Target Address: %s${PLAIN}\\n" "$target_addr" # Display the target_addr string
  printf "  ${CYAN}${INFO_SYMBOL}- Protocol: %s${PLAIN}\\n" "$proto"
  
  read -p "Apply config file now? (Y/n): " apply_now
  if [[ $apply_now != "n" && $apply_now != "N" ]]; then
    apply_config
  fi
}

list_forward_services() {
  printf "${CYAN}${INFO_SYMBOL}=== Forwarding Services List ===${PLAIN}\n"
  local counter=1
  local config_found=0

  printf "${BLUE}Config File Forwarding Services:${PLAIN}\n"
  printf "%-5s %-35s %-20s %-20s %-15s %-10s\n" "No." "Service Name" "Local Port/Range" "Target Address" "Target Port" "Type"
  printf "%s\n" "-----------------------------------------------------------------------------------------------------"

  if [ -f "$CONFIG_FILE" ]; then
    local gost_status=$(systemctl is-active gost 2>/dev/null)
    [ -z "$gost_status" ] && gost_status="inactive"

    while IFS="|" read -r name listen_addr target_addr proto; do
      if [ ! -z "$name" ]; then
        config_found=1
        local local_port=$(echo "$listen_addr" | grep -o ':[0-9]\+\(-[0-9]\+\)*' | sed 's/://')
        target_ip=$(echo "$target_addr" | grep -o '[^:]*' | head -1)
        target_port=$(echo "$target_addr" | grep -o ':[0-9]\+\(-[0-9]\+\)*' | sed 's/://')

        printf "%-5s %-35s %-20s %-20s %-15s %-10s\n" \
          "$counter" "$name" "$local_port" "$target_ip" "$target_port" "$proto"
        ((counter++))
      fi
    done < <(parse_config_file)

    if [ $config_found -eq 0 ]; then
      printf "${YELLOW} ${WARN_SYMBOL}No forwarding services found in config file.${PLAIN}\n"
    else
      printf "\n${BLUE}Service Status:${PLAIN} %s\n" "$gost_status"
    fi
  else
    printf "${YELLOW} ${WARN_SYMBOL}Config file not found at: %s${PLAIN}\n" "$CONFIG_FILE"
  fi

  if [ $config_found -eq 0 ] && [ ! -f "$CONFIG_FILE" ]; then # Only show if config file also not found
     printf "${YELLOW} ${WARN_SYMBOL}No forwarding services found.${PLAIN}\n"
  fi
}

manage_forward_services() {
  while true; do
    printf "\n${CYAN}${INFO_SYMBOL}=== Manage Forwarding Services ===${PLAIN}\n"
    printf "${GREEN}1.${PLAIN} List all services\n"
    printf "${GREEN}2.${PLAIN} Delete forwarding service\n"
    printf "${GREEN}3.${PLAIN} Modify forwarding service\n"
    printf "${GREEN}4.${PLAIN} Add new forwarding service\n"
    printf "${GREEN}5.${PLAIN} Start service (apply config)\n"
    printf "${GREEN}6.${PLAIN} Stop service\n"
    printf "${GREEN}7.${PLAIN} Restart service\n"
    printf "${GREEN}8.${PLAIN} Check service status\n"
    printf "${GREEN}9.${PLAIN} Return to main menu\n"
    read -p "$(printf "${YELLOW}Please select [1-9]: ${PLAIN}")" choice

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
      printf "${CYAN}${INFO_SYMBOL}Select forwarding type:${PLAIN}\n"
      printf "${GREEN}1.${PLAIN} Single port forwarding\n"
      printf "${GREEN}2.${PLAIN} Port range forwarding\n"
      read -p "Select [1-2]: " forwarding_type
      case $forwarding_type in
      1) create_forward_service ;; 
      2) create_port_range_forward ;; 
      *) printf "${RED} ${ERROR_SYMBOL}Invalid selection.${PLAIN}\n" ;; 
      esac
      ;;
    5)
      printf "${CYAN}${INFO_SYMBOL}Starting GOST service (applying config)...${PLAIN}\n"
      apply_config
      ;;
    6)
      printf "${CYAN}${INFO_SYMBOL}Stopping GOST service...${PLAIN}\n"
      if systemctl is-active --quiet gost; then
        sudo systemctl stop gost
        printf "${GREEN} ${SUCCESS_SYMBOL}GOST service stopped.${PLAIN}\n"
      else
        printf "${YELLOW} ${WARN_SYMBOL}GOST service is not running.${PLAIN}\n"
      fi
      ;;
    7)
      printf "${CYAN}${INFO_SYMBOL}Restarting GOST service...${PLAIN}\n"
      if systemctl is-active --quiet gost; then
        sudo systemctl restart gost
        printf "${GREEN} ${SUCCESS_SYMBOL}GOST service restarted.${PLAIN}\n"
      else
        sudo systemctl start gost # Attempt to start if not active
        if systemctl is-active --quiet gost; then
            printf "${GREEN} ${SUCCESS_SYMBOL}GOST service started.${PLAIN}\n"
        else
            printf "${RED} ${ERROR_SYMBOL}Failed to start GOST service.${PLAIN}\n"
        fi
      fi
      ;;
    8)
      check_gost_status
      ;;
    9) return ;;
    *) printf "${RED} ${ERROR_SYMBOL}Invalid selection. Please try again.${PLAIN}\n" ;; 
    esac
    read -n1 -r -p "Press any key to continue..."
  done
}

config_file_management() {
  while true; do
    printf "\n${CYAN}${INFO_SYMBOL}=== Configuration File Management ===${PLAIN}\n"
    printf "${GREEN}1.${PLAIN} Initialize/reset config file\n"
    printf "${GREEN}2.${PLAIN} Apply current config file\n"
    printf "${GREEN}3.${PLAIN} View config file\n"
    printf "${GREEN}4.${PLAIN} Edit config file\n"
    printf "${GREEN}5.${PLAIN} Backup config file\n"
    printf "${GREEN}6.${PLAIN} Restore config from backup\n"
    printf "${GREEN}7.${PLAIN} Format config file (requires jq)\n"
    printf "${GREEN}8.${PLAIN} Return to main menu\n"
    read -p "$(printf "${YELLOW}Please select [1-8]: ${PLAIN}")" choice

    case $choice in
    1)
      read -p "This will reset your config. Are you sure? (y/N): " confirm
      if [[ $confirm == [Yy]* ]]; then
        rm -f "$CONFIG_FILE"
        ensure_config_dir
        printf "${GREEN} ${SUCCESS_SYMBOL}Config file reset to empty template.${PLAIN}\n"
      else
        printf "${YELLOW} ${WARN_SYMBOL}Operation cancelled.${PLAIN}\n"
      fi
      ;;
    2)
      if [ ! -f "$CONFIG_FILE" ]; then
        printf "${RED} ${ERROR_SYMBOL}Config file not found. Please initialize it first.${PLAIN}\n"
      else
        apply_config
      fi
      ;;
    3)
      if [ ! -f "$CONFIG_FILE" ]; then
        printf "${RED} ${ERROR_SYMBOL}Config file not found. Please initialize it first.${PLAIN}\n"
      else
        printf "${CYAN}${INFO_SYMBOL}Config file content:${PLAIN}\n"
        jq . "$CONFIG_FILE" | cat -n # jq is mandatory now
      fi
      ;;
    4)
      ensure_config_dir
      local editor=""
      for e in nano vim vi; do if command -v $e &>/dev/null; then editor=$e; break; fi; done
      if [ -z "$editor" ]; then
        printf "${RED} ${ERROR_SYMBOL}No suitable editor found (nano, vim, vi). Please install one.${PLAIN}\n"
      else
        $editor "$CONFIG_FILE"
        if jq empty "$CONFIG_FILE" > /dev/null 2>&1; then
          printf "${GREEN} ${SUCCESS_SYMBOL}Config file format is valid.${PLAIN}\n"
        else
          printf "${YELLOW} ${WARN_SYMBOL}WARNING: Config file format is invalid! This may cause issues when applying the config.${PLAIN}\n"
        fi
        read -p "Do you want to apply the edited config now? (y/N): " apply_now
        if [[ $apply_now == [Yy]* ]]; then apply_config; fi
      fi
      ;;
    5)
      if [ ! -f "$CONFIG_FILE" ]; then
        printf "${RED} ${ERROR_SYMBOL}Config file not found. Nothing to backup.${PLAIN}\n"
      else
        local backup_file="$CONFIG_DIR/config-$(date +%Y%m%d-%H%M%S).json.bak"
        cp "$CONFIG_FILE" "$backup_file"
        printf "${GREEN} ${SUCCESS_SYMBOL}Config file backed up to: %s${PLAIN}\n" "$backup_file"
      fi
      ;;
    6)
      local backups=($CONFIG_DIR/config-*.json.bak)
      if [ ${#backups[@]} -eq 0 ] || [ ! -f "${backups[0]}" ]; then # Check if array is empty or first element is not a file
        printf "${RED} ${ERROR_SYMBOL}No backup files found in %s${PLAIN}\n" "$CONFIG_DIR"
      else
        printf "${CYAN}${INFO_SYMBOL}Available backup files:${PLAIN}\n"
        local i=1
        for backup in "${backups[@]}"; do
          if [ -f "$backup" ]; then
            printf "${GREEN}%s.${PLAIN} %s (%s)${PLAIN}\n" "$i" "$(basename "$backup")" "$(date -r "$backup" '+%Y-%m-%d %H:%M:%S')"
            ((i++))
          fi
        done
        read -p "Select backup to restore [1-$((i-1))]: " backup_num
        if [[ "$backup_num" =~ ^[0-9]+$ ]] && [ "$backup_num" -ge 1 ] && [ "$backup_num" -le $((i-1)) ]; then
          selected=${backups[$((backup_num-1))]}
          read -p "Restore from $selected? This will overwrite your current config. (y/N): " confirm
          if [[ $confirm == [Yy]* ]]; then
            cp "$selected" "$CONFIG_FILE"
            printf "${GREEN} ${SUCCESS_SYMBOL}Config restored from: %s${PLAIN}\n" "$selected"
            read -p "Apply the restored config now? (Y/n): " apply_now
            if [[ $apply_now != [Nn]* ]]; then apply_config; fi
          else
            printf "${YELLOW} ${WARN_SYMBOL}Restore cancelled.${PLAIN}\n"
          fi
        else
          printf "${RED} ${ERROR_SYMBOL}Invalid selection.${PLAIN}\n"
        fi
      fi
      ;;
    7)
      if [ ! -f "$CONFIG_FILE" ]; then
        printf "${RED} ${ERROR_SYMBOL}Config file not found. Please initialize it first.${PLAIN}\n"
      else
        local temp_file=$(mktemp)
        if jq . "$CONFIG_FILE" > "$temp_file" 2>/dev/null; then
          mv "$temp_file" "$CONFIG_FILE"
          printf "${GREEN} ${SUCCESS_SYMBOL}Config file formatted successfully.${PLAIN}\n"
        else
          rm -f "$temp_file"
          printf "${RED} ${ERROR_SYMBOL}Failed to format config file. JSON format may be invalid.${PLAIN}\n"
        fi
      fi
      ;;
    8) return ;;
    *) printf "${RED} ${ERROR_SYMBOL}Invalid selection. Please try again.${PLAIN}\n" ;; 
    esac
    read -n1 -r -p "Press any key to continue..."
  done
}

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

parse_config_file() {
  if [ ! -f "$CONFIG_FILE" ]; then return 1; fi
  
  # 检测文件格式
  local file_ext="${CONFIG_FILE##*.}"
  if [ "$file_ext" = "json" ]; then
    # JSON格式解析
    jq -r '.services[] | select(.forwarder != null) | 
      .name + "|" + 
      .addr + "|" + 
      (.forwarder.nodes[0].addr // "") + "|" + 
      (.handler.type // "")' "$CONFIG_FILE" 2>/dev/null
  elif [ "$file_ext" = "yml" ] || [ "$file_ext" = "yaml" ]; then
    # YAML格式解析 (如果安装了yq)
    if command -v yq &>/dev/null; then
      yq -r '.services[] | select(.forwarder != null) | 
        .name + "|" + 
        .addr + "|" + 
        (.forwarder.nodes[0].addr // "") + "|" + 
        (.handler.type // "")' "$CONFIG_FILE" 2>/dev/null
    else
      printf "${RED} ${ERROR_SYMBOL}无法解析YAML格式，缺少yq工具${PLAIN}\n"
      return 1
    fi
  else
    # 假设是JSON格式
    jq -r '.services[] | select(.forwarder != null) | 
      .name + "|" + 
      .addr + "|" + 
      (.forwarder.nodes[0].addr // "") + "|" + 
      (.handler.type // "")' "$CONFIG_FILE" 2>/dev/null
  fi
}

delete_config_forward() {
  local entry_number=$1
  if [ -z "$entry_number" ] || ! [[ "$entry_number" =~ ^[0-9]+$ ]]; then
    printf "${RED} ${ERROR_SYMBOL}Invalid service number.${PLAIN}\n"; return 1;
  fi
  if [ ! -f "$CONFIG_FILE" ]; then
    printf "${RED} ${ERROR_SYMBOL}Config file not found.${PLAIN}\n"; return 1;
  fi

  local entries=()
  while IFS="|" read -r name _ _ _; do if [ ! -z "$name" ]; then entries+=("$name"); fi; done < <(parse_config_file)

  if [ $entry_number -lt 1 ] || [ $entry_number -gt ${#entries[@]} ]; then
    printf "${RED} ${ERROR_SYMBOL}Invalid entry number.${PLAIN}\n"; return 1;
  fi

  local target_name=${entries[$entry_number - 1]}
  printf "Are you sure you want to delete the forwarding entry ${BOLD}%s${PLAIN}? (${GREEN}Y${PLAIN}/${RED}N${PLAIN}): " "$target_name"
  read confirm
  if [[ $confirm != [Yy]* ]]; then
    printf "${YELLOW} ${WARN_SYMBOL}Deletion cancelled.${PLAIN}\n"; return 0;
  fi

  local temp_file=$(mktemp)
  if [[ "$target_name" == *-tcp ]] || [[ "$target_name" == *-udp ]]; then
    # 使用参数替换而不是sed来修正base_name提取
    local base_name=${target_name%-tcp}
    base_name=${base_name%-udp}
    jq --arg name_tcp "${base_name}-tcp" --arg name_udp "${base_name}-udp" \
      '.services = [.services[] | select(.name != $name_tcp and .name != $name_udp)]' "$CONFIG_FILE" > "$temp_file"
  else
    jq --arg name "$target_name" '.services = [.services[] | select(.name != $name)]' "$CONFIG_FILE" > "$temp_file"
  fi
    
  if [ $? -eq 0 ]; then
    mv "$temp_file" "$CONFIG_FILE"
  else
    printf "${RED} ${ERROR_SYMBOL}Error updating config file using jq.${PLAIN}\n"
    rm -f "$temp_file"; return 1;
  fi
  rm -f "$temp_file"
  printf "${GREEN} ${SUCCESS_SYMBOL}Entry deleted successfully.${PLAIN}\n"
  read -p "Apply config file now? (Y/n): " apply_now
  if [[ $apply_now != "n" && $apply_now != "N" ]]; then apply_config; fi
  return 0
}

edit_config_forward() {
  local entry_number=$1
  if [ -z "$entry_number" ] || ! [[ "$entry_number" =~ ^[0-9]+$ ]]; then printf "${RED} ${ERROR_SYMBOL}Invalid service number.${PLAIN}\n"; return 1; fi
  if [ ! -f "$CONFIG_FILE" ]; then printf "${RED} ${ERROR_SYMBOL}Config file not found.${PLAIN}\n"; return 1; fi

  local entries=() entry_details=()
  while IFS="|" read -r name listen_addr target_addr proto; do
    if [ ! -z "$name" ]; then entries+=("$name"); entry_details+=("$name|$listen_addr|$target_addr|$proto"); fi
  done < <(parse_config_file)

  if [ $entry_number -lt 1 ] || [ $entry_number -gt ${#entries[@]} ]; then printf "${RED} ${ERROR_SYMBOL}Invalid entry number.${PLAIN}\n"; return 1; fi

  IFS="|" read -r name listen_addr target_addr proto <<<"${entry_details[$entry_number - 1]}"
  local is_part_of_pair=0 base_name related_service
  if [[ "$name" == *-tcp ]] || [[ "$name" == *-udp ]]; then
    is_part_of_pair=1
    # 使用参数替换而不是sed处理base_name
    base_name=${name%-tcp}
    base_name=${base_name%-udp}
    if [[ "$name" == *-tcp ]]; then related_service="$base_name-udp"; else related_service="$base_name-tcp"; fi
    printf "${YELLOW} ${WARN_SYMBOL}This service is paired with %s. Both will be updated.${PLAIN}\n" "$related_service"
  fi

  printf "${CYAN}${INFO_SYMBOL}Editing forwarding entry: ${BOLD}%s${PLAIN}${CYAN}\n" "$name"
  local current_local_port=$(echo "$listen_addr" | grep -o ':[0-9]\+\(-[0-9]\+\)*' | sed 's/://')
  local current_target_ip=$(echo "$target_addr" | grep -o '[^:]*' | head -1)
  local current_target_port=$(echo "$target_addr" | grep -o ':[0-9]\+\(-[0-9]\+\)*' | sed 's/://')

  read -p "New local port (leave empty for $current_local_port): " new_local_port; [ -z "$new_local_port" ] && new_local_port=$current_local_port
  if ! validate_input "$new_local_port" "port"; then read -n1 -r -p "Press any key..." ; return 1; fi
  read -p "New target IP or hostname (leave empty for $current_target_ip): " new_target_ip; [ -z "$new_target_ip" ] && new_target_ip=$current_target_ip
  read -p "New target port (leave empty for $current_target_port): " new_target_port; [ -z "$new_target_port" ] && new_target_port=$current_target_port
  if ! validate_input "$new_target_port" "port"; then read -n1 -r -p "Press any key..." ; return 1; fi

  if [[ $new_target_ip == *:* ]] && [[ $new_target_ip != \\[*\] ]]; then new_target_ip="[$new_target_ip]"; fi
  local new_proto=$proto
  if [ $is_part_of_pair -eq 1 ]; then printf "${YELLOW} ${WARN_SYMBOL}Cannot change protocol for paired service. Delete and recreate to change protocol.${PLAIN}\n"; fi

  printf "\n${CYAN}${INFO_SYMBOL}New settings:${PLAIN}\n"
  printf "${GREEN}Local port:${PLAIN} %s\n" "$new_local_port"
  printf "${GREEN}Target:${PLAIN} %s:%s\n" "$new_target_ip" "$new_target_port"
  printf "${GREEN}Protocol:${PLAIN} %s\n" "$new_proto"

  read -p "Apply these changes? (Y/n): " confirm
  if [[ $confirm == "n" || $confirm == "N" ]]; then printf "${YELLOW} ${WARN_SYMBOL}Edit cancelled.${PLAIN}\n"; return 0; fi

  local temp_file=$(mktemp)
  if [ $is_part_of_pair -eq 1 ]; then
    local base_name=$(echo "$name" | sed 's/-tcp$\\|-udp$//') # Recalculate base_name here as $name might be from original loop
    local tcp_name="$base_name-tcp"
    local udp_name="$base_name-udp"
    jq --arg tcp_n "$tcp_name" --arg udp_n "$udp_name" \
        --arg addr_val ":$new_local_port" --arg target_val "$new_target_ip:$new_target_port" \
        '(.services[] | select(.name == $tcp_n or .name == $udp_n)) |= (.addr = $addr_val | .forwarder.nodes[0].addr = $target_val)' \
        "$CONFIG_FILE" > "$temp_file"
  else
    jq --arg name_val "$name" --arg addr_val ":$new_local_port" \
        --arg target_val "$new_target_ip:$new_target_port" \
        '(.services[] | select(.name == $name_val)) |= (.addr = $addr_val | .forwarder.nodes[0].addr = $target_val)' \
        "$CONFIG_FILE" > "$temp_file"
  fi
    
  if [ $? -eq 0 ]; then
    mv "$temp_file" "$CONFIG_FILE"
  else
    printf "${RED} ${ERROR_SYMBOL}Error updating config file using jq.${PLAIN}\n"; rm -f "$temp_file"; return 1;
  fi
  rm -f "$temp_file"
  printf "${GREEN} ${SUCCESS_SYMBOL}Entry updated successfully.${PLAIN}\n"
  read -p "Apply config file now? (Y/n): " apply_now
  if [[ $apply_now != "n" && $apply_now != "N" ]]; then apply_config; fi
  return 0
}

cleanup_old_services() {
  printf "${CYAN}${INFO_SYMBOL}=== Cleaning up old systemd services ===${PLAIN}\n"
  local found=0; local count=0
  printf "${BLUE}${INFO_SYMBOL}Found GOST related systemd services:${PLAIN}\n"
  for service_file in "$SERVICE_DIR"/gost-*.service; do
    if [ -e "$service_file" ]; then
      found=1; count=$((count + 1))
      service_name=$(basename "$service_file" .service)
      status=$(systemctl is-active "$service_name")
      printf "  ${GREEN}%s.${PLAIN} %s (Status: %s)${PLAIN}\n" "$count" "$service_name" "$status"
    fi
  done
  if [ $found -eq 0 ]; then printf "${YELLOW} ${WARN_SYMBOL}No old GOST systemd services found.${PLAIN}\n"; return; fi
  
  printf "${YELLOW} ${WARN_SYMBOL}Warning: This will disable and remove all individual GOST systemd services (except gost.service).${PLAIN}\n"
  printf "${YELLOW} ${WARN_SYMBOL}All port forwarding should be managed through the config file and the main gost.service.${PLAIN}\n"
  read -p "Are you sure you want to continue? (y/N): " confirm
  if [[ $confirm != [Yy]* ]]; then printf "${YELLOW} ${WARN_SYMBOL}Operation cancelled.${PLAIN}\n"; return; fi
  
  count=0 # Reset count for removed services
  for service_file in "$SERVICE_DIR"/gost-*.service; do
    if [ -e "$service_file" ]; then
      service_name=$(basename "$service_file" .service)
      if [ "$service_name" != "gost" ]; then # Do not remove the main gost.service itself
        printf "${CYAN} ${INFO_SYMBOL}Stopping, disabling and removing %s...${PLAIN}\n" "$service_name"
        sudo systemctl stop "$service_name" &>/dev/null
        sudo systemctl disable "$service_name" &>/dev/null
        sudo rm -f "$service_file"
        count=$((count + 1))
      fi
    fi
  done
  sudo systemctl daemon-reload
  printf "${GREEN} ${SUCCESS_SYMBOL}Successfully removed %s old GOST systemd services.${PLAIN}\n" "$count"
  read -p "Apply main config file now (restart gost.service)? (Y/n): " apply_now
  if [[ $apply_now != "n" && $apply_now != "N" ]]; then apply_config; fi
}

check_gost_status() {
  local status=$(systemctl is-active gost 2>/dev/null || echo "not found")
  if [ "$status" = "active" ]; then
    printf "${GREEN} ${SUCCESS_SYMBOL}GOST service is running.${PLAIN}\n"
    printf "${CYAN}${INFO_SYMBOL}GOST Process Information:${PLAIN}\n"
    ps aux | grep -v grep | grep gost || true
    printf "${CYAN}${INFO_SYMBOL}GOST Service Logs (last 10 lines):${PLAIN}\n"
    journalctl -u gost -n 10 --no-pager || true
  else
    printf "${RED} ${ERROR_SYMBOL}GOST service is not running (status: ${status}).${PLAIN}\n"
    printf "${CYAN} ${INFO_SYMBOL}Check service logs with: ${YELLOW}journalctl -u gost${PLAIN}\n" 
  fi
  read -n1 -r -p "Press any key to continue..."
}

main_menu() {
  while true; do
    clear
    get_ip_info
    printf "${BOLD}${BLUE}==================== Gost Port Forwarding Management ====================${PLAIN}\n"
    printf "  ${CYAN}IPv4: ${WHITE}%s ${YELLOW}(%s)${PLAIN}\n" "$IPV4" "$COUNTRY_V4"
    printf "  ${CYAN}IPv6: ${WHITE}%s ${YELLOW}(%s)${PLAIN}\n" "$IPV6" "$COUNTRY_V6"
    printf "${BOLD}${BLUE}=========================================================================${PLAIN}\n"
    printf "${GREEN}1.${PLAIN} Create Single Port Forwarding\n"
    printf "${GREEN}2.${PLAIN} Create Port Range Forwarding\n"
    printf "${GREEN}3.${PLAIN} Manage Forwarding Services\n"
    printf "${GREEN}4.${PLAIN} Configuration File Management\n"
    printf "${GREEN}5.${PLAIN} Clean Up Old Systemd Services\n"
    printf "${GREEN}6.${PLAIN} Exit\n"
    printf "${BOLD}${BLUE}=========================================================================${PLAIN}\n"
    read -p "$(printf "${YELLOW}Please select [1-6]: ${PLAIN}")" choice

    case $choice in
    1) create_forward_service ;; 
    2) create_port_range_forward ;; 
    3) manage_forward_services ;; 
    4) config_file_management ;; 
    5) cleanup_old_services ;; 
    6) printf "${GREEN}${SUCCESS_SYMBOL}Thank you for using. Goodbye!${PLAIN}\n"; exit 0 ;; 
    *) printf "${RED} ${ERROR_SYMBOL}Invalid selection. Please try again.${PLAIN}\n" ;; 
    esac
    read -n1 -r -p "Press any key to return to the main menu..."
  done
}

main_menu
