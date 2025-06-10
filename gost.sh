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

# Check for root privileges and define SUDO command
SUDO=""
if [ "$(id -u)" -ne 0 ]; then
    SUDO="sudo"
    if ! command -v sudo &>/dev/null; then
        printf "${RED} ${ERROR_SYMBOL}This script requires sudo to run as a non-root user, but sudo is not found.${PLAIN}\n"
        exit 1
    fi
fi

# Function to run a command as a specific user
run_as() {
  local user="$1"
  shift
  if [ "$(id -u)" -eq 0 ]; then
    if command -v sudo &>/dev/null; then
      sudo -u "$user" "$@"
    elif command -v su &>/dev/null; then
      # su needs a single command string
      local cmd_str
      printf -v cmd_str '%q ' "$@"
      su -s /bin/sh -c "$cmd_str" "$user"
    else
      return 1
    fi
  else
    # SUDO must be "sudo" here because of the check at the top
    $SUDO -u "$user" "$@"
  fi
}

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
        $SUDO apt-get update -y || printf "${RED} ${ERROR_SYMBOL}Failed to update package lists.${PLAIN}\n"
      fi
      if $SUDO $pkg_manager_detected install -y "${pkgs_to_install[@]}"; then
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
  if [ -d "/etc/gost" ] || ($SUDO mkdir -p /etc/gost && $SUDO chmod 755 /etc/gost 2>/dev/null); then
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
      $SUDO mkdir -p "$CONFIG_DIR" 2>/dev/null
    else
      mkdir -p "$CONFIG_DIR" 2>/dev/null
    fi
    printf "${GREEN} ${SUCCESS_SYMBOL}Created config directory: %s${PLAIN}\n" "$CONFIG_DIR"
  fi

  if [ ! -f "$CONFIG_FILE" ]; then
    json_content='{"services":[]}' # Ensure simplest valid JSON for initialization
    if [[ "$CONFIG_DIR" == "/etc/"* ]]; then
      echo "$json_content" | $SUDO tee "$CONFIG_FILE" > /dev/null # No -e needed for this simple JSON
      $SUDO chown root:root "$CONFIG_FILE"  
      $SUDO chmod 644 "$CONFIG_FILE"       
      $SUDO chmod 755 "$CONFIG_DIR"        
      printf "${GREEN} ${SUCCESS_SYMBOL}Created base config file (with sudo): %s${PLAIN}\n" "$CONFIG_FILE"
    else
      echo "$json_content" > "$CONFIG_FILE" # No -e needed for this simple JSON
      chmod 644 "$CONFIG_FILE"
      printf "${GREEN} ${SUCCESS_SYMBOL}Created base config file: %s${PLAIN}\n" "$CONFIG_FILE"
    fi
  else
    if [[ "$CONFIG_DIR" == "/etc/"* ]]; then
      $SUDO chown root:root "$CONFIG_FILE"
      $SUDO chmod 644 "$CONFIG_FILE"
      $SUDO chmod 755 "$CONFIG_DIR"
      # Check if permissions were actually changed or already correct
      # No direct output here unless it's a fix, to reduce noise.
      # A dedicated check function could provide this if needed.
    else
      chmod 644 "$CONFIG_FILE"
    fi
  fi
  
  # Validate config file can be read by relevant user (gost or nobody)
  local target_user="gost"
  if ! id "$target_user" &>/dev/null; then
    target_user="nobody"
  fi

  if [[ "$CONFIG_DIR" == "/etc/"* ]]; then
    if ! run_as "$target_user" test -r "$CONFIG_FILE" 2>/dev/null; then
      printf "${RED} ${ERROR_SYMBOL}Warning: user ${target_user} cannot read config file. Attempting to fix...${PLAIN}\n"
      # Permissions were set above, this re-evaluates if they are sufficient
      # If the above chown/chmod was to a different group than what target_user is in, it might fail.
      # For /etc/gost, gost user (if exists) should ideally own or be in group of config, or config be world-readable.
      # Current setup makes it root:root 644, which IS world-readable.
      # Directory /etc/gost is root:root 755, which is world-executable/traversable.
      # So, a simple `sudo chmod 644 "$CONFIG_FILE"` and `sudo chmod 755 "$CONFIG_DIR"` should suffice.
      # The commands are already there; this check is more for complex scenarios or if they were altered.
      # Re-applying them explicitly if test fails might be redundant but harmless.
      $SUDO chmod 644 "$CONFIG_FILE"
      $SUDO chmod 755 "$CONFIG_DIR"
      if ! run_as "$target_user" test -r "$CONFIG_FILE" 2>/dev/null; then
        printf "${RED} ${ERROR_SYMBOL}Failed to fix permissions for ${target_user}. Consider config location or manual check.${PLAIN}\n"
        # return 1 # Decided not to make this fatal for now, but it's a serious warning.
      else
        printf "${GREEN} ${SUCCESS_SYMBOL}Fixed permissions - ${target_user} user can now read config file.${PLAIN}\n"
      fi
    fi
  fi
}

add_forward_to_config() {
  local name_arg=$1          # For proto="tcp" or "udp", this is the final service name (e.g., ...-tcp).
                             # For proto="tcp-udp", this is a base name (e.g., forward-local-to-target).
  local listen_addr=$2
  local node0_addr_str=$3 # Raw address string, e.g., "hkt-01.hkg.rere.ws:45036"
  local proto=$4          # Expected to be "tcp", "udp", or "tcp-udp" (for option 3).

  ensure_config_dir
  local temp_file=$(mktemp)

  if [ "$proto" = "tcp-udp" ]; then # This case is for option 3 (Both TCP & UDP to SAME single target)
    # name_arg is base name like "forward-localport-to-targetport"
    local tcp_service_name="${name_arg}-tcp"
    local udp_service_name="${name_arg}-udp"

    jq --arg tcp_name "$tcp_service_name" \
       --arg udp_name "$udp_service_name" \
       --arg common_addr "$listen_addr" \
       --arg node0_addr "$node0_addr_str" \
       '.services += [
         {name: $tcp_name, addr: $common_addr, handler: {type: "tcp"}, listener: {type: "tcp"}, forwarder: {nodes: [{name: "target-0", addr: $node0_addr}] }},
         {name: $udp_name, addr: $common_addr, handler: {type: "udp"}, listener: {type: "udp"}, forwarder: {nodes: [{name: "target-0", addr: $node0_addr}] }}
       ]' "$CONFIG_FILE" > "$temp_file"
  else 
    # This path is for single protocol services (proto is "tcp" or "udp").
    # This includes Option 1, Option 2, and each leg of Option 4 (Split TCP/UDP).
    # name_arg is already the final, suffixed service name (e.g., "forward-...-tcp").
    jq --arg service_name "$name_arg" \
       --arg service_addr "$listen_addr" \
       --arg service_proto "$proto" \
       --arg node0_addr "$node0_addr_str" \
       '.services += [{name: $service_name, addr: $service_addr, handler: {type: $service_proto}, listener: {type: $service_proto}, forwarder: {nodes: [{name: "target-0", addr: $node0_addr}] }}]' \
       "$CONFIG_FILE" > "$temp_file"
  fi
  
  local jq_exit_code=$?
  if [ $jq_exit_code -eq 0 ]; then
    if ! jq empty "$temp_file" >/dev/null 2>&1; then
      printf "${RED} ${ERROR_SYMBOL}Error: jq produced an invalid JSON in temp file. Config not updated.${PLAIN}\n"
      cat "$temp_file" 
      rm -f "$temp_file"
      return 1
    fi

    if [[ "$CONFIG_FILE" == "/etc/gost/"* ]]; then
        $SUDO mv "$temp_file" "$CONFIG_FILE"
        $SUDO chown root:root "$CONFIG_FILE"
        $SUDO chmod 644 "$CONFIG_FILE"
    else
        mv "$temp_file" "$CONFIG_FILE"
        chmod 644 "$CONFIG_FILE"
    fi
  else
    printf "${RED} ${ERROR_SYMBOL}Error (jq exit code: %s) adding service(s) to config file using jq.${PLAIN}\n" "$jq_exit_code"
    if [ -s "$temp_file" ]; then 
        printf "${YELLOW} ${WARN_SYMBOL}jq failed. Content of temporary file (may be incomplete or invalid):${PLAIN}\n"
        cat "$temp_file"
    fi
    rm -f "$temp_file"
    return 1
  fi
  printf "${GREEN} ${SUCCESS_SYMBOL}Added forwarding to config file.${PLAIN}\n"
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
  
  printf "${YELLOW} ${WARN_SYMBOL}WARNING: The gost service might run as User=gost or User=nobody.${PLAIN}\n"
  printf "${YELLOW} ${WARN_SYMBOL}Please ensure the config file '$(realpath "$CONFIG_FILE")' is readable by this user.${PLAIN}\n"
  # ensure_config_dir attempts to set permissions for root:root 644 for /etc/gost/config.json

  printf "${CYAN} ${INFO_SYMBOL}Stopping existing gost service (if any)...${PLAIN}\n"
  if systemctl is-active --quiet gost; then
    $SUDO systemctl stop gost
    printf "${GREEN} ${SUCCESS_SYMBOL}GOST service stopped.${PLAIN}\n"
  else
    printf "${YELLOW} ${WARN_SYMBOL}GOST service is not running.${PLAIN}\n"
  fi

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
  $SUDO useradd --system --no-create-home --shell /bin/false gost 2>/dev/null || {
    printf "${YELLOW} ${WARN_SYMBOL}Failed to create gost user, using nobody instead${PLAIN}\n"
    GOST_USER="nobody"
    GOST_GROUP="nogroup"
  }
  if [ -z "$GOST_USER" ]; then
    GOST_USER="gost"
    GOST_GROUP="gost"
    # 确保gost用户可以读取配置文件
    if [[ "$CONFIG_DIR" == "/etc/"* ]]; then
      $SUDO chown -R root:gost "$CONFIG_DIR"
      $SUDO chmod -R 750 "$CONFIG_DIR"
      $SUDO chmod 640 "$CONFIG_FILE"
    fi
  fi
else
  GOST_USER="gost"
  GOST_GROUP="gost"
  # 确保gost用户可以读取配置文件
  if [[ "$CONFIG_DIR" == "/etc/"* ]]; then
    $SUDO chown -R root:gost "$CONFIG_DIR"
    $SUDO chmod -R 750 "$CONFIG_DIR"
    $SUDO chmod 640 "$CONFIG_FILE"
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

  echo "$SERVICE_FILE_CONTENT" | $SUDO tee "$SERVICE_DIR/gost.service" > /dev/null
  if [ $? -ne 0 ]; then
    printf "${RED} ${ERROR_SYMBOL}Failed to write gost.service file. Check sudo permissions or if '%s' is writable.${PLAIN}\n" "$SERVICE_DIR"
    return 1
  fi

  $SUDO systemctl daemon-reload
  $SUDO systemctl enable gost

  printf "${CYAN} ${INFO_SYMBOL}Starting gost service...${PLAIN}\n"
  if ! $SUDO systemctl start gost; then
    printf "${RED} ${ERROR_SYMBOL}Failed to start gost service. Checking for errors...${PLAIN}\n"
    $SUDO journalctl -u gost --no-pager -n 20
    return 1
  fi

  if $SUDO systemctl is-active --quiet gost; then
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
    $SUDO journalctl -u gost --no-pager -n 20
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
  printf "${CYAN}${INFO_SYMBOL}=== Create a new port forwarding ===${PLAIN}\n"
  read -p "Local port (default: random available port): " local_port
  if [ -n "$local_port" ]; then
    if ! validate_input "$local_port" "port"; then
      read -n1 -r -p "Press any key to try again..."
      return
    fi
  else
    local_port=$(find_free_port)
    printf "${YELLOW} ${INFO_SYMBOL}Selected available local port: ${BOLD}%s${PLAIN}${YELLOW}\n" "$local_port"
  fi

  printf "${CYAN}${INFO_SYMBOL}Select protocol:${PLAIN}\n"
  printf "${GREEN}1.${PLAIN} TCP (to a single target)\n"
  printf "${GREEN}2.${PLAIN} UDP (to a single target)\n"
  printf "${GREEN}3.${PLAIN} Both TCP & UDP (to the SAME single target) ${YELLOW}(default)${PLAIN}\n"
  printf "${GREEN}4.${PLAIN} Split: TCP to one target, UDP to a DIFFERENT target (same local port)\n"
  read -p "Select [1-4] (default: 3): " protocol_choice

  local what_to_do_next 

  case $protocol_choice in
  1) what_to_do_next="tcp_leg" ;;
  2) what_to_do_next="udp_leg" ;;
  4) what_to_do_next="split_tcp_first" ;;
  *) what_to_do_next="tcp_udp_same_target_leg" ;; 
  esac

  if [ "$what_to_do_next" = "split_tcp_first" ]; then
    printf "\n${CYAN}${INFO_SYMBOL}Configuring TCP forwarding leg:${PLAIN}\n"
    local tcp_target_ip tcp_target_port
    while true; do read -p "TCP Target IP or hostname: " tcp_target_ip; if [ -n "$tcp_target_ip" ]; then break; else printf "${RED} ${ERROR_SYMBOL}TCP Target IP cannot be empty.${PLAIN}\n"; fi; done
    while true; do read -p "TCP Target port: " tcp_target_port; if validate_input "$tcp_target_port" "port"; then break; fi; done
    if [[ $tcp_target_ip == *:* ]] && [[ $tcp_target_ip != \[\]* ]]; then tcp_target_ip="[$tcp_target_ip]"; fi # Corrected IPv6 bracketing for single IP
    local tcp_addr_val="${tcp_target_ip}:${tcp_target_port}"
    local tcp_service_name="forward-$local_port-to-$tcp_target_port-tcp" 

    printf "\n${CYAN}${INFO_SYMBOL}Configuring UDP forwarding leg:${PLAIN}\n"
    local udp_target_ip udp_target_port
    while true; do read -p "UDP Target IP or hostname: " udp_target_ip; if [ -n "$udp_target_ip" ]; then break; else printf "${RED} ${ERROR_SYMBOL}UDP Target IP cannot be empty.${PLAIN}\n"; fi; done
    while true; do read -p "UDP Target port: " udp_target_port; if validate_input "$udp_target_port" "port"; then break; fi; done
    if [[ $udp_target_ip == *:* ]] && [[ $udp_target_ip != \[\]* ]]; then udp_target_ip="[$udp_target_ip]"; fi # Corrected IPv6 bracketing for single IP
    local udp_addr_val="${udp_target_ip}:${udp_target_port}"
    local udp_service_name="forward-$local_port-to-$udp_target_port-udp" 

    add_forward_to_config "$tcp_service_name" ":$local_port" "$tcp_addr_val" "tcp" 
    local add_tcp_rc=$?
    add_forward_to_config "$udp_service_name" ":$local_port" "$udp_addr_val" "udp" 
    local add_udp_rc=$?

    if [ $add_tcp_rc -ne 0 ] || [ $add_udp_rc -ne 0 ]; then
      printf "${RED} ${ERROR_SYMBOL}Failed to add one or both forwarding legs for split configuration.${PLAIN}\n"
    fi
  else
    local target_ip target_port
    local descriptive_proto_for_prompt
    local proto_for_add_func 

    if [ "$what_to_do_next" = "tcp_leg" ]; then
        descriptive_proto_for_prompt="TCP"
        proto_for_add_func="tcp"
    elif [ "$what_to_do_next" = "udp_leg" ]; then
        descriptive_proto_for_prompt="UDP"
        proto_for_add_func="udp"
    else 
        descriptive_proto_for_prompt="TCP & UDP (same target)"
        proto_for_add_func="tcp-udp" 
    fi
    
    printf "\n${CYAN}${INFO_SYMBOL}Enter details for the Target (for %s traffic):${PLAIN}\n" "$descriptive_proto_for_prompt"
    while true; do read -p "Target IP or hostname: " target_ip; if [ -n "$target_ip" ]; then break; else printf "${RED} ${ERROR_SYMBOL}Target IP cannot be empty.${PLAIN}\n"; fi; done
    while true; do read -p "Target port: " target_port; if validate_input "$target_port" "port"; then break; fi; done
    if [[ $target_ip == *:* ]] && [[ $target_ip != \[\]* ]]; then target_ip="[$target_ip]"; fi # Corrected IPv6 bracketing for single IP
    local target_addr_val="${target_ip}:${target_port}"
    
    local service_name_to_pass
    if [ "$proto_for_add_func" = "tcp" ]; then
        service_name_to_pass="forward-$local_port-to-$target_port-tcp"
    elif [ "$proto_for_add_func" = "udp" ]; then
        service_name_to_pass="forward-$local_port-to-$target_port-udp"
    else 
        service_name_to_pass="forward-$local_port-to-$target_port" 
    fi
            
    add_forward_to_config "$service_name_to_pass" ":$local_port" "$target_addr_val" "$proto_for_add_func"
  fi
  
  read -p "Apply config file now? (Y/n): " apply_now
  if [[ $apply_now != "n" && $apply_now != "N" ]]; then
      apply_config
  fi
}

create_port_range_forward() {
  printf "${CYAN}${INFO_SYMBOL}=== Create Port Range Forwarding ===${PLAIN}\n"
  printf "${GREEN}1.${PLAIN} Many-to-One (Multiple local ports to one target port)\n"
  printf "${GREEN}2.${PLAIN} Many-to-Many (Each local port maps to corresponding target port)\n"
  read -p "Select forwarding type [1-2]: " range_type

  read -p "Local port range start: " local_start
  if ! validate_input "$local_start" "port"; then read -n1 -r -p "Press any key..." ; return; fi
  read -p "Local port range end: " local_end
  if ! validate_input "$local_end" "port"; then read -n1 -r -p "Press any key..." ; return; fi

  if [ "$local_start" -gt "$local_end" ]; then
    printf "${RED} ${ERROR_SYMBOL}Start port cannot be greater than end port.${PLAIN}\n"
    read -n1 -r -p "Press any key to try again..."
    return
  fi

  read -p "Target IP or hostname: " target_ip
  if [ -z "$target_ip" ]; then printf "${RED} ${ERROR_SYMBOL}Target IP or hostname cannot be empty.${PLAIN}\n"; read -n1 -r -p "Press any key..." ; return; fi

  if [[ $target_ip == *:* ]] && [[ $target_ip != \[\]* ]]; then target_ip="[$target_ip]"; fi # Corrected IPv6 bracketing for single IP

  printf "${CYAN}${INFO_SYMBOL}Select protocol:${PLAIN}\n"
  printf "${GREEN}1.${PLAIN} TCP\n"
  printf "${GREEN}2.${PLAIN} UDP\n"
  printf "${GREEN}3.${PLAIN} Both TCP & UDP ${YELLOW}(default)${PLAIN}\n"
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
        printf "${RED} ${ERROR_SYMBOL}Calculated target end port (%s) exceeds 65535.${PLAIN}\n" "$target_end"
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
  
  printf "${GREEN} ${SUCCESS_SYMBOL}Port range forwarding added to config file.${PLAIN}\n"
  printf "  ${CYAN}${INFO_SYMBOL}- Name: %s${PLAIN}\n" "$service_name"
  printf "  ${CYAN}${INFO_SYMBOL}- Local Ports: %s-%s${PLAIN}\n" "$local_start" "$local_end"
  printf "  ${CYAN}${INFO_SYMBOL}- Target Address: %s${PLAIN}\n" "$target_addr" # Display the target_addr string
  printf "  ${CYAN}${INFO_SYMBOL}- Protocol: %s${PLAIN}\n" "$proto"
  
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
        $SUDO systemctl stop gost
        printf "${GREEN} ${SUCCESS_SYMBOL}GOST service stopped.${PLAIN}\n"
      else
        printf "${YELLOW} ${WARN_SYMBOL}GOST service is not running.${PLAIN}\n"
      fi
      ;;
    7)
      printf "${CYAN}${INFO_SYMBOL}Restarting GOST service...${PLAIN}\n"
      if systemctl is-active --quiet gost; then
        $SUDO systemctl restart gost
        printf "${GREEN} ${SUCCESS_SYMBOL}GOST service restarted.${PLAIN}\n"
      else
        $SUDO systemctl start gost 
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
        # Before removing, ensure it's not a directory or something unexpected
        if [ -f "$CONFIG_FILE" ] || [ -L "$CONFIG_FILE" ]; then # If it's a file or symlink
            if [[ "$CONFIG_FILE" == "/etc/gost/"* ]]; then
                $SUDO rm -f "$CONFIG_FILE"
            else
                rm -f "$CONFIG_FILE"
            fi
        elif [ -d "$CONFIG_FILE" ]; then # Should not happen if CONFIG_FILE points to a file
            printf "${RED} ${ERROR_SYMBOL}Error: Config path %s is a directory. Cannot reset.${PLAIN}\n" "$CONFIG_FILE"
            # Potentially offer to remove directory content or skip
            read -n1 -r -p "Press any key to continue..."
            continue # Skip to next iteration of the loop
        fi
        # ensure_config_dir will recreate the file with default content
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
        if command -v jq &>/dev/null; then
          jq . "$CONFIG_FILE" | cat -n 
        else
          cat -n "$CONFIG_FILE"
          printf "${YELLOW}\n ${WARN_SYMBOL}jq not found. Displaying raw content. Install jq for formatted view.${PLAIN}\n"
        fi
      fi
      ;;
    4)
      ensure_config_dir
      local editor=""
      for e in nano vim vi; do if command -v $e &>/dev/null; then editor=$e; break; fi; done
      if [ -z "$editor" ]; then
        printf "${RED} ${ERROR_SYMBOL}No suitable editor found (nano, vim, vi). Please install one.${PLAIN}\n"
      else
        # Use sudo if editing /etc/gost/config.json
        if [[ "$CONFIG_FILE" == "/etc/gost/"* ]]; then
            $SUDO "$editor" "$CONFIG_FILE"
        else
            "$editor" "$CONFIG_FILE"
        fi
        if command -v jq &>/dev/null && jq empty "$CONFIG_FILE" > /dev/null 2>&1; then
          printf "${GREEN} ${SUCCESS_SYMBOL}Config file format is valid JSON.${PLAIN}\n"
        elif command -v jq &>/dev/null; then # jq is present but format is invalid
          printf "${YELLOW} ${WARN_SYMBOL}WARNING: Config file format is invalid JSON! This may cause issues.${PLAIN}\n"
        else # jq not present, cannot validate
          printf "${YELLOW} ${WARN_SYMBOL}jq not found. Cannot validate JSON format.${PLAIN}\n"
        fi
        read -p "Do you want to apply the edited config now? (y/N): " apply_now
        if [[ $apply_now == [Yy]* ]]; then apply_config; fi
      fi
      ;;
    5)
      if [ ! -f "$CONFIG_FILE" ]; then
        printf "${RED} ${ERROR_SYMBOL}Config file not found. Nothing to backup.${PLAIN}\n"
      else
        local backup_file
        # Ensure backup directory exists, handle potential sudo for /etc/gost/
        local backup_dir="$CONFIG_DIR"
        if [[ "$backup_dir" == "/etc/gost" && ! -w "$backup_dir" ]]; then 
            # If /etc/gost is not writable by current user, try to place backup in $HOME/gost_backups
            # Or, one could attempt sudo to write into /etc/gost if preferred, but that adds complexity here.
            # For simplicity, redirecting non-sudo-writable /etc/gost backups to user's home.
            local user_backup_dir="$HOME/gost_backups"
            mkdir -p "$user_backup_dir"
            backup_dir="$user_backup_dir"
            printf "${YELLOW} ${WARN_SYMBOL}Config directory %s not writable, saving backup to %s ${PLAIN}\n" "$CONFIG_DIR" "$backup_dir"
        fi
        backup_file="$backup_dir/config-$(date +%Y%m%d-%H%M%S).json.bak"
        
        if [[ "$CONFIG_FILE" == "/etc/gost/"* ]]; then
            $SUDO cp "$CONFIG_FILE" "$backup_file"
            # If backup_dir was changed to user's home, chown might be needed if sudo cp was used.
            if [[ "$backup_dir" == "$HOME/"* ]]; then $SUDO chown "$(id -u)":"$(id -g)" "$backup_file"; fi
        else
            cp "$CONFIG_FILE" "$backup_file"
        fi

        if [ $? -eq 0 ]; then
          printf "${GREEN} ${SUCCESS_SYMBOL}Config file backed up to: %s${PLAIN}\n" "$backup_file"
        else
          printf "${RED} ${ERROR_SYMBOL}Failed to backup config file to %s${PLAIN}\n" "$backup_file"
        fi
      fi
      ;;
    6)
      # Consider looking in both $CONFIG_DIR and $HOME/gost_backups if used
      local search_dirs=()
      search_dirs+=("$CONFIG_DIR")
      if [ -d "$HOME/gost_backups" ]; then search_dirs+=("$HOME/gost_backups"); fi
      
      local all_backups=()
      for dir_to_search in "${search_dirs[@]}"; do
          # Use find to get files, then read into array. Handles spaces in filenames if any.
          while IFS= read -r -d $'\0' file; do
              all_backups+=("$file")
          done < <(find "$dir_to_search" -maxdepth 1 -name 'config-*.json.bak' -print0)
      done

      if [ ${#all_backups[@]} -eq 0 ]; then
        printf "${RED} ${ERROR_SYMBOL}No backup files found in searched locations.${PLAIN}\n"
      else
        printf "${CYAN}${INFO_SYMBOL}Available backup files:${PLAIN}\n"
        local i=1
        # Create a temporary array for display to handle potential duplicates if search_dirs overlap or for sorting
        # For now, just list them. Sorting could be added.
        declare -A displayed_backups # Associative array to avoid duplicates in listing if paths are same
        local distinct_backups=()
        for backup in "${all_backups[@]}"; do
            if [ -f "$backup" ] && [[ -z "${displayed_backups["$backup"]}" ]]; then
                distinct_backups+=("$backup")
                displayed_backups["$backup"]=1
            fi
        done

        if [ ${#distinct_backups[@]} -eq 0 ]; then # Should not happen if all_backups was not empty
             printf "${RED} ${ERROR_SYMBOL}No valid backup files found after filtering.${PLAIN}\n"
        else
            for backup in "${distinct_backups[@]}"; do
              printf "${GREEN}%s.${PLAIN} %s (%s) - %s${PLAIN}\n" "$i" "$(basename "$backup")" "$(date -r "$backup" '+%Y-%m-%d %H:%M:%S')" "$backup"
              ((i++))
            done
            read -p "Select backup to restore [1-$((i-1))]: " backup_num
            if [[ "$backup_num" =~ ^[0-9]+$ ]] && [ "$backup_num" -ge 1 ] && [ "$backup_num" -le $((i-1)) ]; then
              selected_backup_path=${distinct_backups[$((backup_num-1))]}
              printf "Restoring from ${BOLD}%s${PLAIN}\n" "$selected_backup_path"
              read -p "This will overwrite your current config ($CONFIG_FILE). Are you sure? (y/N): " confirm_restore
              if [[ $confirm_restore == [Yy]* ]]; then
                if [[ "$CONFIG_FILE" == "/etc/gost/"* ]]; then
                    $SUDO cp "$selected_backup_path" "$CONFIG_FILE"
                    $SUDO chown root:root "$CONFIG_FILE" # Ensure correct ownership after restore
                    $SUDO chmod 644 "$CONFIG_FILE"
                else
                    cp "$selected_backup_path" "$CONFIG_FILE"
                fi
                if [ $? -eq 0 ]; then
                  printf "${GREEN} ${SUCCESS_SYMBOL}Config restored from: %s${PLAIN}\n" "$selected_backup_path"
                  read -p "Apply the restored config now? (Y/n): " apply_now_restore
                  if [[ $apply_now_restore != [Nn]* ]]; then apply_config; fi
                else
                  printf "${RED} ${ERROR_SYMBOL}Failed to restore config from %s${PLAIN}\n" "$selected_backup_path"
                fi
              else
                printf "${YELLOW} ${WARN_SYMBOL}Restore cancelled.${PLAIN}\n"
              fi
            else
              printf "${RED} ${ERROR_SYMBOL}Invalid selection.${PLAIN}\n"
            fi
        fi
      fi
      ;;
    7)
      if [ ! -f "$CONFIG_FILE" ]; then
        printf "${RED} ${ERROR_SYMBOL}Config file not found. Please initialize it first.${PLAIN}\n"
      elif ! command -v jq &>/dev/null; then
        printf "${RED} ${ERROR_SYMBOL}jq command not found. Cannot format config file.${PLAIN}\n"
      else
        local temp_format_file=$(mktemp)
        # Format and write to temp file
        if jq . "$CONFIG_FILE" > "$temp_format_file" 2>/dev/null; then
          # Check if original needs sudo to write
          if [[ "$CONFIG_FILE" == "/etc/gost/"* ]]; then
            $SUDO mv "$temp_format_file" "$CONFIG_FILE"
            $SUDO chown root:root "$CONFIG_FILE"
            $SUDO chmod 644 "$CONFIG_FILE"
          else
            mv "$temp_format_file" "$CONFIG_FILE"
          fi
          if [ $? -eq 0 ]; then
            printf "${GREEN} ${SUCCESS_SYMBOL}Config file formatted successfully.${PLAIN}\n"
          else
            printf "${RED} ${ERROR_SYMBOL}Failed to move formatted config file into place.${PLAIN}\n"
            rm -f "$temp_format_file" # Clean up temp file on move failure
          fi
        else
          rm -f "$temp_format_file"
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
  # For services created by "tcp-udp" (Option 3) or "tcp-udp-split" (Option 4),
  # target_name will already have -tcp or -udp. Deleting one will leave the other.
  # If a user wants to delete a "pair" from Option 3, they must delete both -tcp and -udp entries separately.
  # This is consistent with how they are listed.
  jq --arg name "$target_name" '.services = [.services[] | select(.name != $name)]' "$CONFIG_FILE" > "$temp_file"
    
  if [ $? -eq 0 ]; then
    if [[ "$CONFIG_FILE" == "/etc/gost/"* ]]; then
        $SUDO mv "$temp_file" "$CONFIG_FILE"
    else
        mv "$temp_file" "$CONFIG_FILE"
    fi
  else
    printf "${RED} ${ERROR_SYMBOL}Error updating config file using jq.${PLAIN}\n"
    rm -f "$temp_file"; return 1;
  fi
  # rm -f "$temp_file" # No, mv removes it.
  printf "${GREEN} ${SUCCESS_SYMBOL}Entry deleted successfully.${PLAIN}\n"
  read -p "Apply config file now? (Y/n): " apply_now
  if [[ $apply_now != "n" && $apply_now != "N" ]]; then apply_config; fi
  return 0
}

edit_config_forward() {
  local entry_number=$1
  if [ -z "$entry_number" ] || ! [[ "$entry_number" =~ ^[0-9]+$ ]]; then printf "${RED} ${ERROR_SYMBOL}Invalid service number.${PLAIN}\n"; return 1; fi
  if [ ! -f "$CONFIG_FILE" ]; then printf "${RED} ${ERROR_SYMBOL}Config file not found.${PLAIN}\n"; return 1; fi

  local entries=() entry_details=() # entry_details will store full line from parse_config_file
  local current_line_num=0
  while IFS='|' read -r name listen_addr target_addr proto; do
    current_line_num=$((current_line_num + 1))
    if [ ! -z "$name" ]; then 
      entries+=("$name") # Used for count and selecting by name
      # Store all details for the selected entry number
      if [ "$current_line_num" -eq "$entry_number" ]; then
          entry_details=("$name" "$listen_addr" "$target_addr" "$proto")
      fi
    fi
  done < <(parse_config_file)

  if [ $entry_number -lt 1 ] || [ $entry_number -gt ${#entries[@]} ]; then printf "${RED} ${ERROR_SYMBOL}Invalid entry number.${PLAIN}\n"; return 1; fi

  local original_name="${entry_details[0]}"
  local original_listen_addr="${entry_details[1]}"
  local original_target_node0_addr="${entry_details[2]}" # This is nodes[0].addr
  local original_proto="${entry_details[3]}"

  # Editing a service that was part of a tcp-udp pair (from Option 3) or split (Option 4)
  # will only edit that specific leg (-tcp or -udp). This is consistent.
  # The service name itself (-tcp/-udp suffix) should generally not be changed by editing.
  # Protocol type of an existing single leg service also cannot be changed here.

  printf "${CYAN}${INFO_SYMBOL}Editing forwarding entry: ${BOLD}%s${PLAIN}${CYAN}\n" "$original_name"
  printf "  ${YELLOW}Current Local Listen Address:${PLAIN} %s\n" "$original_listen_addr"
  printf "  ${YELLOW}Current Target Node[0] Address:${PLAIN} %s\n" "$original_target_node0_addr"
  printf "  ${YELLOW}Current Protocol:${PLAIN} %s\n" "$original_proto"
  printf "  ${YELLOW}Note: Service name and protocol type cannot be changed here.${PLAIN}\n"

  local current_local_port=$(echo "$original_listen_addr" | grep -o ':[0-9]\+\(-\[0-9]\+\)*' | sed 's/://')
  local current_target_ip=$(echo "$original_target_node0_addr" | grep -o '[^:]*' | head -1) # Handles IPv6 in brackets too
  local current_target_port=$(echo "$original_target_node0_addr" | sed -n 's/.*:\([0-9]\+\(-[0-9]\+\)*\)$/\1/p')

  read -p "New local port/range (leave empty for '$current_local_port'): " new_local_port
  [ -z "$new_local_port" ] && new_local_port=$current_local_port
  if ! validate_input "$new_local_port" "port"; then # Simplified validation, assumes single port for now
      if ! [[ "$new_local_port" =~ ^[0-9]+-[0-9]+$ ]]; then # Basic range check if not single port
          read -n1 -r -p "Invalid port/range. Press any key..." ; return 1;
      fi
  fi
  
  read -p "New target IP or hostname (leave empty for '$current_target_ip'): " new_target_ip
  [ -z "$new_target_ip" ] && new_target_ip=$current_target_ip
  # No direct validation for IP/hostname here to allow flexibility, but could be added

  read -p "New target port/range (leave empty for '$current_target_port'): " new_target_port
  [ -z "$new_target_port" ] && new_target_port=$current_target_port
  # Basic validation for port/range
  if ! validate_input "$new_target_port" "port"; then 
      if ! [[ "$new_target_port" =~ ^[0-9]+(-[0-9]+)?$ ]]; then # Allows single port or port-port
        read -n1 -r -p "Invalid target port/range. Press any key..." ; return 1;
      fi
  fi

  if [[ $new_target_ip == *:* ]] && [[ $new_target_ip != \[\]* ]]; then new_target_ip="[$new_target_ip]"; fi # Corrected IPv6 bracketing
  
  local new_listen_addr=":$new_local_port"
  local new_target_node0_addr="${new_target_ip}:${new_target_port}"

  printf "\n${CYAN}${INFO_SYMBOL}New settings to be applied for ${BOLD}%s${PLAIN}:${PLAIN}\n" "$original_name"
  printf "${GREEN}Local Listen Address:${PLAIN} %s\n" "$new_listen_addr"
  printf "${GREEN}Target Node[0] Address:${PLAIN} %s\n" "$new_target_node0_addr"
  printf "${GREEN}Protocol:${PLAIN} %s (cannot be changed)\n" "$original_proto"

  read -p "Apply these changes? (Y/n): " confirm
  if [[ $confirm == "n" || $confirm == "N" ]]; then printf "${YELLOW} ${WARN_SYMBOL}Edit cancelled.${PLAIN}\n"; return 0; fi

  local temp_file=$(mktemp)
  # Update the specific service entry identified by original_name
  # We are only changing addr (listen) and forwarder.nodes[0].addr (target)
  jq --arg name_val "$original_name" \
     --arg new_addr_val "$new_listen_addr" \
     --arg new_target_val "$new_target_node0_addr" \
    '(.services[] | select(.name == $name_val)) |= (.addr = $new_addr_val | .forwarder.nodes[0].addr = $new_target_val)' \
    "$CONFIG_FILE" > "$temp_file"
    
  if [ $? -eq 0 ]; then
    if [[ "$CONFIG_FILE" == "/etc/gost/"* ]]; then
        $SUDO mv "$temp_file" "$CONFIG_FILE"
    else
        mv "$temp_file" "$CONFIG_FILE"
    fi
  else
    printf "${RED} ${ERROR_SYMBOL}Error updating config file using jq.${PLAIN}\n"; rm -f "$temp_file"; return 1;
  fi
  printf "${GREEN} ${SUCCESS_SYMBOL}Entry updated successfully.${PLAIN}\n"
  read -p "Apply config file now? (Y/n): " apply_now
  if [[ $apply_now != "n" && $apply_now != "N" ]]; then apply_config; fi
  return 0
}

cleanup_old_services() {
  printf "${CYAN}${INFO_SYMBOL}=== Cleaning up old systemd services ===${PLAIN}\n"
  local found=0; local count=0
  printf "${BLUE}${INFO_SYMBOL}Searching for old GOST related systemd services (gost-*.service)...${PLAIN}\n"
  # Ensure SERVICE_DIR is defined and accessible
  if [ -z "$SERVICE_DIR" ] || [ ! -d "$SERVICE_DIR" ]; then
      printf "${RED} ${ERROR_SYMBOL}Systemd service directory ($SERVICE_DIR) not found or not accessible.${PLAIN}\n"
      return 1
  fi

  # Use find to robustly get service files, handling spaces or funny characters if any.
  # However, systemd service names are quite restricted, so direct globbing is usually fine.
  local old_services_found=()
  while IFS= read -r -d $'\0' f; do old_services_found+=("$f"); done < <(find "$SERVICE_DIR" -maxdepth 1 -name 'gost-*.service' -print0)

  if [ ${#old_services_found[@]} -eq 0 ]; then 
      printf "${YELLOW} ${WARN_SYMBOL}No old GOST systemd services (gost-*.service) found.${PLAIN}\n"; return;
  fi

  printf "${BLUE}${INFO_SYMBOL}Found the following old GOST related systemd services:${PLAIN}\n"
  count=0
  for service_file_path in "${old_services_found[@]}"; do
    count=$((count + 1))
    service_name=$(basename "$service_file_path" .service)
    status=$(systemctl is-active "$service_name" 2>/dev/null || echo "inactive/not-found")
    printf "  ${GREEN}%s.${PLAIN} %s (Path: %s, Status: %s)${PLAIN}\n" "$count" "$service_name" "$service_file_path" "$status"
  done
  
  printf "${YELLOW} ${WARN_SYMBOL}Warning: This will disable and remove all listed individual GOST systemd services (except gost.service).${PLAIN}\n"
  printf "${YELLOW} ${WARN_SYMBOL}All port forwarding should be managed through the config file and the main gost.service.${PLAIN}\n"
  read -p "Are you sure you want to continue? (y/N): " confirm
  if [[ $confirm != [Yy]* ]]; then printf "${YELLOW} ${WARN_SYMBOL}Operation cancelled.${PLAIN}\n"; return; fi
  
  local removed_count=0
  for service_file_path in "${old_services_found[@]}"; do
    service_name=$(basename "$service_file_path" .service)
    # Ensure we are not touching the main gost.service, though the find pattern should prevent this.
    if [ "$service_name" != "gost" ]; then 
      printf "${CYAN} ${INFO_SYMBOL}Stopping, disabling and removing %s...${PLAIN}\n" "$service_name"
      $SUDO systemctl stop "$service_name" &>/dev/null
      $SUDO systemctl disable "$service_name" &>/dev/null
      $SUDO rm -f "$service_file_path"
      if [ $? -eq 0 ]; then
        removed_count=$((removed_count + 1))
      else
        printf "${RED} ${ERROR_SYMBOL}Failed to remove %s${PLAIN}\n" "$service_file_path"
      fi
    fi
  done

  if [ $removed_count -gt 0 ]; then
    $SUDO systemctl daemon-reload
    printf "${GREEN} ${SUCCESS_SYMBOL}Successfully removed %s old GOST systemd services.${PLAIN}\n" "$removed_count"
  else
    printf "${YELLOW} ${WARN_SYMBOL}No old services were actually removed (perhaps only gost.service was found or removal failed).${PLAIN}\n"
  fi
  
  read -p "Apply main config file now (restart gost.service)? (Y/n): " apply_now
  if [[ $apply_now != "n" && $apply_now != "N" ]]; then apply_config; fi
}

check_gost_status() {
  local status
  if systemctl is-active --quiet gost; then
    status="active"
  elif systemctl is-failed --quiet gost; then
    status="failed"
  elif systemctl list-units --full -all | grep -q 'gost.service.*not-found'; then
    status="not-found"
  else 
    status=$(systemctl is-system-running &>/dev/null && systemctl show -p SubState gost 2>/dev/null | sed 's/SubState=//' || echo "unknown")
    [ -z "$status" ] && status="inactive/unknown" # Fallback if SubState is empty
  fi 

  if [ "$status" = "active" ]; then
    printf "${GREEN} ${SUCCESS_SYMBOL}GOST service is running.${PLAIN}\n"
    printf "${CYAN}${INFO_SYMBOL}GOST Process Information:${PLAIN}\n"
    ps aux | grep -v grep | grep gost || printf "  ${YELLOW}(No gost process found, but service is active - check service logs)${PLAIN}\n"
    printf "${CYAN}${INFO_SYMBOL}GOST Service Logs (last 10 lines):${PLAIN}\n"
    journalctl -u gost -n 10 --no-pager || printf "  ${YELLOW}(Failed to retrieve service logs)${PLAIN}\n"
  elif [ "$status" = "failed" ]; then
    printf "${RED} ${ERROR_SYMBOL}GOST service is in a failed state.${PLAIN}\n"
    printf "${CYAN} ${INFO_SYMBOL}Check service logs with: ${YELLOW}sudo journalctl -u gost -n 50 --no-pager${PLAIN}\n" 
    printf "${CYAN} ${INFO_SYMBOL}Attempt to reset failed state: ${YELLOW}sudo systemctl reset-failed gost${PLAIN}\n" 
  elif [ "$status" = "not-found" ]; then
    printf "${RED} ${ERROR_SYMBOL}GOST service (gost.service) is not found. It may not be installed or configured correctly as a systemd service.${PLAIN}\n"
  else
    printf "${RED} ${ERROR_SYMBOL}GOST service is not active (status: ${status}).${PLAIN}\n"
    printf "${CYAN} ${INFO_SYMBOL}Check service logs with: ${YELLOW}sudo journalctl -u gost -n 50 --no-pager${PLAIN}\n" 
    printf "${CYAN} ${INFO_SYMBOL}Try starting it with menu option 5 (Start service).${PLAIN}\n"
  fi
  read -n1 -r -p "Press any key to continue..."
}

main_menu() {
  while true; do
    # clear # Consider making clear optional or less frequent
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

# Perform initial checks and setup before showing the main menu
check_and_install_dependencies_and_gost
setup_config_dir # Sets CONFIG_DIR and CONFIG_FILE
ensure_config_dir  # Ensures the directory and a base config file exist

main_menu
