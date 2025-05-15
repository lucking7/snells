#!/bin/bash

# GOST端口转发统一管理脚本
# 该脚本使用GOST配置文件管理所有端口转发，通过单一systemd服务运行
# 版本: 2.2
# 支持功能: 单端口转发、端口范围转发、配置文件管理
# 注意: 该脚本默认使用配置文件方式管理所有转发

# Color definitions
RED='\\033[0;31m'
GREEN='\\033[0;32m'
YELLOW='\\033[1;33m'
BLUE='\\033[1;34m'
PURPLE='\\033[1;35m'
CYAN='\\033[1;36m'
WHITE='\\033[1;37m'
BOLD='\\033[1m'
UNDERLINE='\\033[4m'
PLAIN='\\033[0m'

# Symbols for messages
SUCCESS_SYMBOL="[✔]"
ERROR_SYMBOL="[✘]"
INFO_SYMBOL="[ℹ]"
WARN_SYMBOL="[!]"

# Service files directory - Standard systemd path
SERVICE_DIR="/etc/systemd/system"

# Config directory and file (user-level, for easier management without sudo for config edits)
CONFIG_DIR="./gost_config"
CONFIG_FILE="$CONFIG_DIR/config.json"

# Function to check and install essential dependencies and gost
check_and_install_dependencies_and_gost() {
  printf "%b %sPerforming initial setup and dependency check...%b\\n" "$BLUE" "$INFO_SYMBOL" "$PLAIN"
  
  local essential_pkgs=("lsof" "jq" "realpath") # realpath is needed for absolute config path
  local utility_pkgs=("curl" "grep") 
  local pkgs_to_install=()
  local pkg_manager_detected=""

  if command -v apt-get &>/dev/null; then
    pkg_manager_detected="apt-get"
  elif command -v yum &>/dev/null; then
    pkg_manager_detected="yum"
  elif command -v dnf &>/dev/null; then
    pkg_manager_detected="dnf"
  else
    printf "%b %sNo supported package manager (apt-get, yum, dnf) found. Please install dependencies manually.%b\\n" "$RED" "$ERROR_SYMBOL" "$PLAIN"
    for pkg in "${essential_pkgs[@]}"; do
        if ! command -v $pkg &>/dev/null; then
            printf "%b %sCRITICAL: Essential package '$pkg' is missing. Script cannot continue.%b\\n" "$RED" "$ERROR_SYMBOL" "$PLAIN"
            exit 1
        fi
    done
    printf "%b %sAssuming essential dependencies are present as no package manager was found for installation.%b\\n" "$YELLOW" "$WARN_SYMBOL" "$PLAIN"
  fi

  if [ -n "$pkg_manager_detected" ]; then
    for pkg in "${essential_pkgs[@]}" "${utility_pkgs[@]}"; do # Combined check
      if ! command -v $pkg &>/dev/null; then
        pkgs_to_install+=($pkg)
      fi
    done

    if [ ${#pkgs_to_install[@]} -gt 0 ]; then
      printf "%b %sThe following packages are missing or not found: %s.%b\\n" "$YELLOW" "$INFO_SYMBOL" "${pkgs_to_install[*]}" "$PLAIN"
      printf "%b %sAttempting to install them using %s (requires sudo)...%b\\n" "$YELLOW" "$INFO_SYMBOL" "$pkg_manager_detected" "$PLAIN"
      if [ "$pkg_manager_detected" == "apt-get" ]; then
        sudo apt-get update -y || printf "%b %sFailed to update package lists.%b\\n" "$RED" "$ERROR_SYMBOL" "$PLAIN"
      fi
      if sudo $pkg_manager_detected install -y "${pkgs_to_install[@]}"; then
        printf "%b %sSuccessfully attempted installation of: %s.%b\\n" "$GREEN" "$SUCCESS_SYMBOL" "${pkgs_to_install[*]}" "$PLAIN"
      else
        printf "%b %sFailed to install some packages. Please check errors and install them manually.%b\\n" "$RED" "$ERROR_SYMBOL" "$PLAIN"
      fi
    fi
  fi

  for pkg in "${essential_pkgs[@]}"; do
    if ! command -v $pkg &>/dev/null; then
      printf "%b %sCRITICAL: Essential package '$pkg' is still missing after installation attempt.%b\\n" "$RED" "$ERROR_SYMBOL" "$PLAIN"
      printf "%b %sPlease install '$pkg' manually and re-run the script. Exiting.%b\\n" "$RED" "$ERROR_SYMBOL" "$PLAIN"
      exit 1
    fi
  done
  printf "%b %sEssential dependencies (lsof, jq, realpath) are installed.%b\\n" "$GREEN" "$SUCCESS_SYMBOL" "$PLAIN"

  if ! command -v gost &>/dev/null; then
    printf "%b %sgost not found. Attempting to install gost...%b\\n" "$YELLOW" "$INFO_SYMBOL" "$PLAIN"
    if command -v curl &>/dev/null; then
      (bash <(curl -fsSL https://github.com/go-gost/gost/raw/master/install.sh) --install) &
      show_loading $! 
      if command -v gost &>/dev/null; then
        printf "%b %sgost installed successfully.%b\\n" "$GREEN" "$SUCCESS_SYMBOL" "$PLAIN"
      else
        printf "%b %sFailed to install gost. Please install it manually from https://github.com/go-gost/gost %b\\n" "$RED" "$ERROR_SYMBOL" "$PLAIN"
      fi
    else
      printf "%b %scurl is not installed. Cannot download gost install script. Please install curl and gost manually.%b\\n" "$RED" "$ERROR_SYMBOL" "$PLAIN"
    fi
  else
    printf "%b %sgost is already installed.%b\\n" "$GREEN" "$SUCCESS_SYMBOL" "$PLAIN"
  fi
  printf "%b %sInitial setup and dependency check complete.%b\\n" "$BLUE" "$INFO_SYMBOL" "$PLAIN"
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
  printf "%b%s%b\\n" "$GREEN" "[OK]" "$PLAIN"
}

check_and_install_dependencies_and_gost

validate_input() {
  local input=$1
  local input_type=$2

  case $input_type in
  "port")
    if ! [[ "$input" =~ ^[0-9]+$ ]] || [ "$input" -lt 1 ] || [ "$input" -gt 65535 ]; then
      printf "%b %sInvalid port number. Must be between 1-65535.%b\\n" "$RED" "$ERROR_SYMBOL" "$PLAIN"
      return 1
    fi
    ;;
  "ip")
    if [[ "$input" =~ ^([0-9]{1,3}\\.){3}[0-9]{1,3}$ ]]; then
      IFS='.' read -r -a octets <<<"$input"
      for octet in "${octets[@]}"; do
        if [ "$octet" -gt 255 ]; then
          printf "%b %sInvalid IPv4 address. Each octet must be <= 255.%b\\n" "$RED" "$ERROR_SYMBOL" "$PLAIN"
          return 1
        fi
      done
      return 0
    fi
    if [[ "$input" =~ ^[0-9a-fA-F:]+$ ]]; then # Simplified IPv6 check
      return 0
    fi
    printf "%b %sInvalid IP address format.%b\\n" "$RED" "$ERROR_SYMBOL" "$PLAIN"
    return 1
    ;;
  "hostname")
    if [[ "$input" =~ ^[a-zA-Z0-9]([-a-zA-Z0-9\\.]{0,61}[a-zA-Z0-9])?$ ]]; then
      return 0
    fi
    printf "%b %sInvalid hostname format.%b\\n" "$RED" "$ERROR_SYMBOL" "$PLAIN"
    return 1
    ;;
  esac
  return 0
}

ensure_config_dir() {
  if [ ! -d "$CONFIG_DIR" ]; then
    mkdir -p "$CONFIG_DIR"
    printf "%b %sCreated config directory: %s%b\\n" "$GREEN" "$SUCCESS_SYMBOL" "$CONFIG_DIR" "$PLAIN"
  fi
  if [ ! -f "$CONFIG_FILE" ]; then
    cat <<EOF >"$CONFIG_FILE"
{
  "services": []
}
EOF
    printf "%b %sCreated base config file: %s%b\\n" "$GREEN" "$SUCCESS_SYMBOL" "$CONFIG_FILE" "$PLAIN"
  fi
}

add_forward_to_config() {
  local name=$1
  local listen_addr=$2
  local target_addr=$3
  local proto=$4

  ensure_config_dir
  local temp_file=$(mktemp)
  
  if [ "$proto" = "tcp-udp" ]; then
    local tcp_service='{
      "name": "'$name'-tcp",
      "addr": "'$listen_addr'",
      "handler": { "type": "tcp" },
      "listener": { "type": "tcp" },
      "forwarder": { "nodes": [ { "name": "target-0", "addr": "'$target_addr'" } ] }
    }'
    local udp_service='{
      "name": "'$name'-udp",
      "addr": "'$listen_addr'",
      "handler": { "type": "udp" },
      "listener": { "type": "udp" },
      "forwarder": { "nodes": [ { "name": "target-0", "addr": "'$target_addr'" } ] }
    }'
    jq ".services += [${tcp_service}, ${udp_service}]" "$CONFIG_FILE" > "$temp_file"
    if [ $? -eq 0 ]; then
      mv "$temp_file" "$CONFIG_FILE"
    else
      printf "%b %sError adding services to config file using jq.%b\\n" "$RED" "$ERROR_SYMBOL" "$PLAIN"
      rm -f "$temp_file"
      return 1
    fi
  else 
    local service='{
      "name": "'$name'",
      "addr": "'$listen_addr'",
      "handler": { "type": "'$proto'" },
      "listener": { "type": "'$proto'" },
      "forwarder": { "nodes": [ { "name": "target-0", "addr": "'$target_addr'" } ] }
    }'
    jq ".services += [${service}]" "$CONFIG_FILE" > "$temp_file"
    if [ $? -eq 0 ]; then
      mv "$temp_file" "$CONFIG_FILE"
    else
      printf "%b %sError adding service to config file using jq.%b\\n" "$RED" "$ERROR_SYMBOL" "$PLAIN"
      rm -f "$temp_file"
      return 1
    fi
  fi
  printf "%b %sAdded forwarding to config file.%b\\n" "$GREEN" "$SUCCESS_SYMBOL" "$PLAIN"
}

apply_config() {
  if [ ! -f "$CONFIG_FILE" ]; then
    printf "%b %sConfig file not found at: %s%b\\n" "$RED" "$ERROR_SYMBOL" "$CONFIG_FILE" "$PLAIN"
    ensure_config_dir
    printf "%b %sBase config file created. Please add forwarding entries and try again.%b\\n" "$YELLOW" "$WARN_SYMBOL" "$PLAIN"
    return 1
  fi

  if ! command -v gost &>/dev/null; then
    printf "%b %sgost command not found. Please install it first.%b\\n" "$RED" "$ERROR_SYMBOL" "$PLAIN"
    return 1
  fi

  if ! jq empty "$CONFIG_FILE" >/dev/null 2>&1; then
      printf "%b %sInvalid JSON format in %s. Please fix it manually.%b\\n" "$RED" "$ERROR_SYMBOL" "$CONFIG_FILE" "$PLAIN"
      return 1
  fi
  
  printf "%b %sWARNING: The gost service will run as User=nobody, Group=nogroup.%b\\n" "$YELLOW" "$WARN_SYMBOL" "$PLAIN"
  printf "%b %sPlease ensure the config file '$CONFIG_FILE' (absolute path: $(realpath "$CONFIG_FILE")) is readable by this user/group.%b\\n" "$YELLOW" "$WARN_SYMBOL" "$PLAIN"
  printf "%b %sYou might need to adjust permissions (e.g., sudo chmod 644 $(realpath "$CONFIG_FILE")).%b\\n" "$YELLOW" "$WARN_SYMBOL" "$PLAIN"

  printf "%b %sStopping existing gost service (if any)...%b\\n" "$CYAN" "$INFO_SYMBOL" "$PLAIN"
  if systemctl is-active --quiet gost; then
    sudo systemctl stop gost
  fi
  for old_service_file in "$SERVICE_DIR"/gost-*.service; do
    if [ -f "$old_service_file" ]; then
      service_name=$(basename "$old_service_file" .service)
      if [ "$service_name" != "gost" ]; then 
        printf "%b %sStopping and disabling old service %s...%b\\n" "$YELLOW" "$INFO_SYMBOL" "$service_name" "$PLAIN"
        sudo systemctl stop "$service_name" &>/dev/null
        sudo systemctl disable "$service_name" &>/dev/null
        sudo rm -f "$old_service_file"
      fi
    fi
  done

  printf "%b %sCreating and configuring gost systemd service...%b\\n" "$CYAN" "$INFO_SYMBOL" "$PLAIN"
  
  local abs_config_file
  if ! abs_config_file=$(realpath "$CONFIG_FILE"); then
    printf "%b %sFailed to get absolute path for %s. Make sure 'realpath' is installed.%b\\n" "$RED" "$ERROR_SYMBOL" "$CONFIG_FILE" "$PLAIN"
    return 1
  fi

  SERVICE_FILE_CONTENT=$(cat <<EOF
[Unit]
Description=GOST Proxy Service
After=network.target
Wants=network.target

[Service]
ExecStart=/usr/local/bin/gost -C "$abs_config_file"
Restart=always
RestartSec=5
User=nobody
Group=nogroup

[Install]
WantedBy=multi-user.target
EOF
)

  echo "$SERVICE_FILE_CONTENT" | sudo tee "$SERVICE_DIR/gost.service" > /dev/null
  if [ $? -ne 0 ]; then
    printf "%b %sFailed to write gost.service file. Check sudo permissions or if '%s' is writable.%b\\n" "$RED" "$ERROR_SYMBOL" "$SERVICE_DIR" "$PLAIN"
    return 1
  fi

  sudo systemctl daemon-reload
  sudo systemctl enable gost

  printf "%b %sStarting gost service...%b\\n" "$CYAN" "$INFO_SYMBOL" "$PLAIN"
  if ! sudo systemctl start gost; then
    printf "%b %sFailed to start gost service. Checking for errors...%b\\n" "$RED" "$ERROR_SYMBOL" "$PLAIN"
    sudo journalctl -u gost --no-pager -n 20
    return 1
  fi

  if sudo systemctl is-active --quiet gost; then
    printf "%b %sGost service is running successfully!%b\\n" "$GREEN" "$SUCCESS_SYMBOL" "$PLAIN"
    printf "%b %sConfigured forwarding services from %s:%b\\n" "$CYAN" "$INFO_SYMBOL" "$CONFIG_FILE" "$PLAIN"
    local counter=1
    while IFS="|" read -r name listen_addr target_addr proto; do
      if [ ! -z "$name" ]; then
        local local_port=$(echo "$listen_addr" | grep -o ':[0-9]\+\(-[0-9]\+\)*' | sed 's/://')
        target_ip=$(echo "$target_addr" | grep -o '[^:]*' | head -1)
        target_port=$(echo "$target_addr" | grep -o ':[0-9]\+\(-[0-9]\+\)*' | sed 's/://')
        printf "  %b%s.%b Port %s (%s) -> %s:%s [%s]\\n" "$GREEN" "$counter" "$PLAIN" "$local_port" "$proto" "$target_ip" "$target_port" "$name"
        ((counter++))
      fi
    done < <(parse_config_file)
    if [ $counter -eq 1 ]; then
      printf "%b %sNo forwarding entries found in config file.%b\\n" "$YELLOW" "$WARN_SYMBOL" "$PLAIN"
    fi
  else
    printf "%b %sFailed to start gost service. Service status is inactive.%b\\n" "$RED" "$ERROR_SYMBOL" "$PLAIN"
    sudo journalctl -u gost --no-pager -n 20
    return 1
  fi
  printf "%b %sSuccessfully applied configuration from: %s%b\\n" "$GREEN" "$SUCCESS_SYMBOL" "$CONFIG_FILE" "$PLAIN"
  return 0
}

find_free_port() {
  local port
  while true; do
    port=$(shuf -i 10000-65000 -n 1) # Requires shuf from coreutils
    if ! lsof -iTCP:"$port" -sTCP:LISTEN -P -n > /dev/null 2>&1; then
      echo $port
      return
    fi
  done
}

create_forward_service() {
  printf "%b%s=== Create a new port forwarding ===%b\\n" "$CYAN" "$INFO_SYMBOL" "$PLAIN"
  read -p "Local port (default: random available port): " local_port
  if [ -n "$local_port" ]; then
    if ! validate_input "$local_port" "port"; then
      read -n1 -r -p "Press any key to try again..."
      return
    fi
  else
    local_port=$(find_free_port)
    printf "%b %sSelected available local port: %b%s%b%b\\n" "$YELLOW" "$INFO_SYMBOL" "$BOLD" "$local_port" "$PLAIN" "$YELLOW" # Ensure PLAIN is reset
  fi

  read -p "Target IP or hostname: " target_ip
  if [ -z "$target_ip" ]; then
    printf "%b %sTarget IP or hostname cannot be empty.%b\\n" "$RED" "$ERROR_SYMBOL" "$PLAIN"
    read -n1 -r -p "Press any key to try again..."
    return
  fi

  read -p "Target port: " target_port
  if ! validate_input "$target_port" "port"; then
    read -n1 -r -p "Press any key to try again..."
    return
  fi

  if [[ $target_ip == *:* ]] && [[ $target_ip != \\[*\] ]]; then
    target_ip="[$target_ip]"
  fi

  printf "%b%sSelect protocol:%b\\n" "$CYAN" "$INFO_SYMBOL" "$PLAIN"
  printf "%b1.%b TCP\\n" "$GREEN" "$PLAIN"
  printf "%b2.%b UDP\\n" "$GREEN" "$PLAIN"
  printf "%b3.%b Both TCP & UDP %b(default)%b\\n" "$GREEN" "$PLAIN" "$YELLOW" "$PLAIN"
  read -p "Select [1-3] (default: 3): " protocol_type

  case $protocol_type in
  1) proto="tcp" ;; 
  2) proto="udp" ;; 
  *) proto="tcp-udp" ;; 
  esac

  service_name="forward-$local_port-to-$target_port"
  add_forward_to_config "$service_name" ":$local_port" "$target_ip:$target_port" "$proto"
  
  read -p "Apply config file now? (Y/n): " apply_now
  if [[ $apply_now != "n" && $apply_now != "N" ]]; then
      apply_config
  fi
}

create_port_range_forward() {
  printf "%b%s=== Create Port Range Forwarding ===%b\\n" "$CYAN" "$INFO_SYMBOL" "$PLAIN"
  printf "%b1.%b Many-to-One (Multiple local ports to one target port)\\n" "$GREEN" "$PLAIN"
  printf "%b2.%b Many-to-Many (Each local port maps to corresponding target port)\\n" "$GREEN" "$PLAIN"
  read -p "Select forwarding type [1-2]: " range_type

  read -p "Local port range start: " local_start
  if ! validate_input "$local_start" "port"; then read -n1 -r -p "Press any key..." ; return; fi
  read -p "Local port range end: " local_end
  if ! validate_input "$local_end" "port"; then read -n1 -r -p "Press any key..." ; return; fi

  if [ "$local_start" -gt "$local_end" ]; then
    printf "%b %sStart port cannot be greater than end port.%b\\n" "$RED" "$ERROR_SYMBOL" "$PLAIN"
    read -n1 -r -p "Press any key to try again..."
    return
  fi

  read -p "Target IP or hostname: " target_ip
  if [ -z "$target_ip" ]; then printf "%b %sTarget IP or hostname cannot be empty.%b\\n" "$RED" "$ERROR_SYMBOL" "$PLAIN"; read -n1 -r -p "Press any key..." ; return; fi

  if [[ $target_ip == *:* ]] && [[ $target_ip != \\[*\] ]]; then target_ip="[$target_ip]"; fi

  printf "%b%sSelect protocol:%b\\n" "$CYAN" "$INFO_SYMBOL" "$PLAIN"
  printf "%b1.%b TCP\\n" "$GREEN" "$PLAIN"
  printf "%b2.%b UDP\\n" "$GREEN" "$PLAIN"
  printf "%b3.%b Both TCP & UDP %b(default)%b\\n" "$GREEN" "$PLAIN" "$YELLOW" "$PLAIN"
  read -p "Select [1-3] (default: 3): " protocol_type
  case $protocol_type in 1) proto="tcp";; 2) proto="udp";; *) proto="tcp-udp";; esac

  local temp_file=$(mktemp)
  local service_name target_addr tcp_service udp_service service

  if [ "$range_type" = "1" ]; then
    read -p "Target port: " target_port
    if ! validate_input "$target_port" "port"; then read -n1 -r -p "Press any key..." ; rm -f "$temp_file"; return; fi
    service_name="range-${local_start}-${local_end}-to-${target_port}"
    target_addr="${target_ip}:${target_port}"
  else
    read -p "Target port range start: " target_start
    if ! validate_input "$target_start" "port"; then read -n1 -r -p "Press any key..." ; rm -f "$temp_file"; return; fi
    local port_count=$((local_end - local_start + 1))
    local target_end=$((target_start + port_count - 1))
    service_name="range-${local_start}-${local_end}-to-${target_start}-${target_end}"
    target_addr="${target_ip}:${target_start}-${target_end}"
  fi
  
  ensure_config_dir
  if [ "$proto" = "tcp-udp" ]; then
    tcp_service='{"name":"'$service_name'-tcp","addr":":${local_start}-${local_end}","handler":{"type":"tcp"},"listener":{"type":"tcp"},"forwarder":{"nodes":[{"name":"target-0","addr":"'$target_addr'"}]}}'
    udp_service='{"name":"'$service_name'-udp","addr":":${local_start}-${local_end}","handler":{"type":"udp"},"listener":{"type":"udp"},"forwarder":{"nodes":[{"name":"target-0","addr":"'$target_addr'"}]}}'
    jq ".services += [${tcp_service}, ${udp_service}]" "$CONFIG_FILE" > "$temp_file"
  else
    service='{"name":"'$service_name'","addr":":${local_start}-${local_end}","handler":{"type":"'$proto'"},"listener":{"type":"'$proto'"},"forwarder":{"nodes":[{"name":"target-0","addr":"'$target_addr'"}]}}'
    jq ".services += [${service}]" "$CONFIG_FILE" > "$temp_file"
  fi
    
  if [ $? -eq 0 ]; then
    mv "$temp_file" "$CONFIG_FILE"
  else
    printf "%b %sError adding service to config file using jq.%b\\n" "$RED" "$ERROR_SYMBOL" "$PLAIN"
    rm -f "$temp_file"
    return 1
  fi
  rm -f "$temp_file"
  
  printf "%b %sPort range forwarding added to config file.%b\\n" "$GREEN" "$SUCCESS_SYMBOL" "$PLAIN"
  printf "%b  %s- Name: %s%b\\n" "$CYAN" "$INFO_SYMBOL" "$service_name" "$PLAIN"
  printf "%b  %s- Ports: %s-%s%b\\n" "$CYAN" "$INFO_SYMBOL" "$local_start" "$local_end" "$PLAIN"
  printf "%b  %s- Protocol: %s%b\\n" "$CYAN" "$INFO_SYMBOL" "$proto" "$PLAIN"
  
  read -p "Apply config file now? (Y/n): " apply_now
  if [[ $apply_now != "n" && $apply_now != "N" ]]; then
    apply_config
  fi
}

list_forward_services() {
  printf "%b%s=== Forwarding Services List ===%b\\n" "$CYAN" "$INFO_SYMBOL" "$PLAIN"
  local counter=1
  local config_found=0

  printf "%bConfig File Forwarding Services:%b\\n" "$BLUE" "$PLAIN"
  printf "%-5s %-35s %-20s %-20s %-15s %-10s\\n" "No." "Service Name" "Local Port/Range" "Target Address" "Target Port" "Type"
  printf "%s\\n" "-----------------------------------------------------------------------------------------------------"

  if [ -f "$CONFIG_FILE" ]; then
    local gost_status=$(systemctl is-active gost 2>/dev/null)
    [ -z "$gost_status" ] && gost_status="inactive"

    while IFS="|" read -r name listen_addr target_addr proto; do
      if [ ! -z "$name" ]; then
        config_found=1
        local local_port=$(echo "$listen_addr" | grep -o ':[0-9]\+\(-[0-9]\+\)*' | sed 's/://')
        target_ip=$(echo "$target_addr" | grep -o '[^:]*' | head -1)
        target_port=$(echo "$target_addr" | grep -o ':[0-9]\+\(-[0-9]\+\)*' | sed 's/://')

        printf "%-5s %-35s %-20s %-20s %-15s %-10s\\n" \
          "$counter" "$name" "$local_port" "$target_ip" "$target_port" "$proto"
        ((counter++))
      fi
    done < <(parse_config_file)

    if [ $config_found -eq 0 ]; then
      printf "%b %sNo forwarding services found in config file.%b\\n" "$YELLOW" "$WARN_SYMBOL" "$PLAIN"
    else
      printf "\\n%bService Status:%b %s\\n" "$BLUE" "$PLAIN" "$gost_status"
    fi
  else
    printf "%b %sConfig file not found at: %s%b\\n" "$YELLOW" "$WARN_SYMBOL" "$CONFIG_FILE" "$PLAIN"
  fi

  if [ $config_found -eq 0 ] && [ ! -f "$CONFIG_FILE" ]; then # Only show if config file also not found
     printf "%b %sNo forwarding services found.%b\\n" "$YELLOW" "$WARN_SYMBOL" "$PLAIN"
  fi
}

manage_forward_services() {
  while true; do
    printf "\\n%b%s=== Manage Forwarding Services ===%b\\n" "$CYAN" "$INFO_SYMBOL" "$PLAIN"
    printf "%b1.%b List all services\\n" "$GREEN" "$PLAIN"
    printf "%b2.%b Delete forwarding service\\n" "$GREEN" "$PLAIN"
    printf "%b3.%b Modify forwarding service\\n" "$GREEN" "$PLAIN"
    printf "%b4.%b Add new forwarding service\\n" "$GREEN" "$PLAIN"
    printf "%b5.%b Start service (apply config)\\n" "$GREEN" "$PLAIN"
    printf "%b6.%b Stop service\\n" "$GREEN" "$PLAIN"
    printf "%b7.%b Restart service\\n" "$GREEN" "$PLAIN"
    printf "%b8.%b Check service status\\n" "$GREEN" "$PLAIN"
    printf "%b9.%b Return to main menu\\n" "$GREEN" "$PLAIN"
    read -p "$(printf "%bPlease select [1-9]: %b" "$YELLOW" "$PLAIN")" choice

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
      printf "%b%sSelect forwarding type:%b\\n" "$CYAN" "$INFO_SYMBOL" "$PLAIN"
      printf "%b1.%b Single port forwarding\\n" "$GREEN" "$PLAIN"
      printf "%b2.%b Port range forwarding\\n" "$GREEN" "$PLAIN"
      read -p "Select [1-2]: " forwarding_type
      case $forwarding_type in
      1) create_forward_service ;; 
      2) create_port_range_forward ;; 
      *) printf "%b %sInvalid selection.%b\\n" "$RED" "$ERROR_SYMBOL" "$PLAIN" ;; 
      esac
      ;;
    5)
      printf "%b %sStarting GOST service (applying config)...%b\\n" "$CYAN" "$INFO_SYMBOL" "$PLAIN"
      apply_config
      ;;
    6)
      printf "%b %sStopping GOST service...%b\\n" "$CYAN" "$INFO_SYMBOL" "$PLAIN"
      if systemctl is-active --quiet gost; then
        sudo systemctl stop gost
        printf "%b %sGOST service stopped.%b\\n" "$GREEN" "$SUCCESS_SYMBOL" "$PLAIN"
      else
        printf "%b %sGOST service is not running.%b\\n" "$YELLOW" "$WARN_SYMBOL" "$PLAIN"
      fi
      ;;
    7)
      printf "%b %sRestarting GOST service...%b\\n" "$CYAN" "$INFO_SYMBOL" "$PLAIN"
      if systemctl is-active --quiet gost; then
        sudo systemctl restart gost
        printf "%b %sGOST service restarted.%b\\n" "$GREEN" "$SUCCESS_SYMBOL" "$PLAIN"
      else
        sudo systemctl start gost # Attempt to start if not active
        if systemctl is-active --quiet gost; then
            printf "%b %sGOST service started.%b\\n" "$GREEN" "$SUCCESS_SYMBOL" "$PLAIN"
        else
            printf "%b %sFailed to start GOST service.%b\\n" "$RED" "$ERROR_SYMBOL" "$PLAIN"
        fi
      fi
      ;;
    8)
      local status=$(systemctl is-active gost)
      if [ "$status" = "active" ]; then
        printf "%b %sGOST service is running.%b\\n" "$GREEN" "$SUCCESS_SYMBOL" "$PLAIN"
        printf "%b%sGOST Process Information:%b\\n" "$CYAN" "$INFO_SYMBOL" "$PLAIN"
        ps aux | grep "/usr/local/bin/gost -C" | grep -v grep
        printf "%b%sGOST Service Logs (last 10 lines):%b\\n" "$CYAN" "$INFO_SYMBOL" "$PLAIN"
        sudo journalctl -u gost --no-pager -n 10
      else
        printf "%b %sGOST service is not running (status: %s).%b\\n" "$RED" "$ERROR_SYMBOL" "$status" "$PLAIN"
        printf "%b %sCheck service logs with: %bjournalctl -u gost%b%b\\n" "$CYAN" "$INFO_SYMBOL" "$YELLOW" "$PLAIN" "$CYAN" # Fixed color reset
      fi
      ;;
    9) return ;;
    *) printf "%b %sInvalid selection. Please try again.%b\\n" "$RED" "$ERROR_SYMBOL" "$PLAIN" ;; 
    esac
    read -n1 -r -p "Press any key to continue..."
  done
}

config_file_management() {
  while true; do
    printf "\\n%b%s=== Configuration File Management ===%b\\n" "$CYAN" "$INFO_SYMBOL" "$PLAIN"
    printf "%b1.%b Initialize/reset config file\\n" "$GREEN" "$PLAIN"
    printf "%b2.%b Apply current config file\\n" "$GREEN" "$PLAIN"
    printf "%b3.%b View config file\\n" "$GREEN" "$PLAIN"
    printf "%b4.%b Edit config file\\n" "$GREEN" "$PLAIN"
    printf "%b5.%b Backup config file\\n" "$GREEN" "$PLAIN"
    printf "%b6.%b Restore config from backup\\n" "$GREEN" "$PLAIN"
    printf "%b7.%b Format config file (requires jq)\\n" "$GREEN" "$PLAIN"
    printf "%b8.%b Return to main menu\\n" "$GREEN" "$PLAIN"
    read -p "$(printf "%bPlease select [1-8]: %b" "$YELLOW" "$PLAIN")" choice

    case $choice in
    1)
      read -p "This will reset your config. Are you sure? (y/N): " confirm
      if [[ $confirm == [Yy]* ]]; then
        rm -f "$CONFIG_FILE"
        ensure_config_dir
        printf "%b %sConfig file reset to empty template.%b\\n" "$GREEN" "$SUCCESS_SYMBOL" "$PLAIN"
      else
        printf "%b %sOperation cancelled.%b\\n" "$YELLOW" "$WARN_SYMBOL" "$PLAIN"
      fi
      ;;
    2)
      if [ ! -f "$CONFIG_FILE" ]; then
        printf "%b %sConfig file not found. Please initialize it first.%b\\n" "$RED" "$ERROR_SYMBOL" "$PLAIN"
      else
        apply_config
      fi
      ;;
    3)
      if [ ! -f "$CONFIG_FILE" ]; then
        printf "%b %sConfig file not found. Please initialize it first.%b\\n" "$RED" "$ERROR_SYMBOL" "$PLAIN"
      else
        printf "%b%sConfig file content:%b\\n" "$CYAN" "$INFO_SYMBOL" "$PLAIN"
        jq . "$CONFIG_FILE" | cat -n # jq is mandatory now
      fi
      ;;
    4)
      ensure_config_dir
      local editor=""
      for e in nano vim vi; do if command -v $e &>/dev/null; then editor=$e; break; fi; done
      if [ -z "$editor" ]; then
        printf "%b %sNo suitable editor found (nano, vim, vi). Please install one.%b\\n" "$RED" "$ERROR_SYMBOL" "$PLAIN"
      else
        $editor "$CONFIG_FILE"
        if jq empty "$CONFIG_FILE" > /dev/null 2>&1; then
          printf "%b %sConfig file format is valid.%b\\n" "$GREEN" "$SUCCESS_SYMBOL" "$PLAIN"
        else
          printf "%b %sWARNING: Config file format is invalid! This may cause issues when applying the config.%b\\n" "$RED" "$WARN_SYMBOL" "$PLAIN"
        fi
        read -p "Do you want to apply the edited config now? (y/N): " apply_now
        if [[ $apply_now == [Yy]* ]]; then apply_config; fi
      fi
      ;;
    5)
      if [ ! -f "$CONFIG_FILE" ]; then
        printf "%b %sConfig file not found. Nothing to backup.%b\\n" "$RED" "$ERROR_SYMBOL" "$PLAIN"
      else
        local backup_file="$CONFIG_DIR/config-$(date +%Y%m%d-%H%M%S).json.bak"
        cp "$CONFIG_FILE" "$backup_file"
        printf "%b %sConfig file backed up to: %s%b\\n" "$GREEN" "$SUCCESS_SYMBOL" "$backup_file" "$PLAIN"
      fi
      ;;
    6)
      local backups=($CONFIG_DIR/config-*.json.bak)
      if [ ${#backups[@]} -eq 0 ] || [ ! -f "${backups[0]}" ]; then # Check if array is empty or first element is not a file
        printf "%b %sNo backup files found in %s%b\\n" "$RED" "$ERROR_SYMBOL" "$CONFIG_DIR" "$PLAIN"
      else
        printf "%b%sAvailable backup files:%b\\n" "$CYAN" "$INFO_SYMBOL" "$PLAIN"
        local i=1
        for backup in "${backups[@]}"; do
          if [ -f "$backup" ]; then
            printf "%b%s.%b %s (%s)\\n" "$GREEN" "$i" "$PLAIN" "$(basename "$backup")" "$(date -r "$backup" '+%Y-%m-%d %H:%M:%S')"
            ((i++))
          fi
        done
        read -p "Select backup to restore [1-$((i-1))]: " backup_num
        if [[ "$backup_num" =~ ^[0-9]+$ ]] && [ "$backup_num" -ge 1 ] && [ "$backup_num" -le $((i-1)) ]; then
          selected=${backups[$((backup_num-1))]}
          read -p "Restore from $selected? This will overwrite your current config. (y/N): " confirm
          if [[ $confirm == [Yy]* ]]; then
            cp "$selected" "$CONFIG_FILE"
            printf "%b %sConfig restored from: %s%b\\n" "$GREEN" "$SUCCESS_SYMBOL" "$selected" "$PLAIN"
            read -p "Apply the restored config now? (Y/n): " apply_now
            if [[ $apply_now != [Nn]* ]]; then apply_config; fi
          else
            printf "%b %sRestore cancelled.%b\\n" "$YELLOW" "$WARN_SYMBOL" "$PLAIN"
          fi
        else
          printf "%b %sInvalid selection.%b\\n" "$RED" "$ERROR_SYMBOL" "$PLAIN"
        fi
      fi
      ;;
    7)
      if [ ! -f "$CONFIG_FILE" ]; then
        printf "%b %sConfig file not found. Please initialize it first.%b\\n" "$RED" "$ERROR_SYMBOL" "$PLAIN"
      else
        local temp_file=$(mktemp)
        if jq . "$CONFIG_FILE" > "$temp_file" 2>/dev/null; then
          mv "$temp_file" "$CONFIG_FILE"
          printf "%b %sConfig file formatted successfully.%b\\n" "$GREEN" "$SUCCESS_SYMBOL" "$PLAIN"
        else
          rm -f "$temp_file"
          printf "%b %sFailed to format config file. JSON format may be invalid.%b\\n" "$RED" "$ERROR_SYMBOL" "$PLAIN"
        fi
      fi
      ;;
    8) return ;;
    *) printf "%b %sInvalid selection. Please try again.%b\\n" "$RED" "$ERROR_SYMBOL" "$PLAIN" ;; 
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
  jq -r '.services[] | select(.forwarder != null) | 
    .name + "|" + 
    .addr + "|" + 
    (.forwarder.nodes[0].addr // "") + "|" + 
    (.handler.type // "")' "$CONFIG_FILE" 2>/dev/null
}

delete_config_forward() {
  local entry_number=$1
  if [ -z "$entry_number" ] || ! [[ "$entry_number" =~ ^[0-9]+$ ]]; then
    printf "%b %sInvalid service number.%b\\n" "$RED" "$ERROR_SYMBOL" "$PLAIN"; return 1;
  fi
  if [ ! -f "$CONFIG_FILE" ]; then
    printf "%b %sConfig file not found.%b\\n" "$RED" "$ERROR_SYMBOL" "$PLAIN"; return 1;
  fi

  local entries=()
  while IFS="|" read -r name _ _ _; do if [ ! -z "$name" ]; then entries+=("$name"); fi; done < <(parse_config_file)

  if [ $entry_number -lt 1 ] || [ $entry_number -gt ${#entries[@]} ]; then
    printf "%b %sInvalid entry number.%b\\n" "$RED" "$ERROR_SYMBOL" "$PLAIN"; return 1;
  fi

  local target_name=${entries[$entry_number - 1]}
  read -p "Are you sure you want to delete the forwarding entry ${BOLD}${target_name}${PLAIN}? (${GREEN}Y${PLAIN}/${RED}N${PLAIN}): " confirm
  if [[ $confirm != [Yy]* ]]; then
    printf "%b %sDeletion cancelled.%b\\n" "$YELLOW" "$WARN_SYMBOL" "$PLAIN"; return 0;
  fi

  local temp_file=$(mktemp)
  if [[ "$target_name" == *-tcp ]] || [[ "$target_name" == *-udp ]]; then
    local base_name=$(echo "$target_name" | sed 's/-tcp$\\|-udp$//')
    jq --arg name_tcp "${base_name}-tcp" --arg name_udp "${base_name}-udp" \
      '.services = [.services[] | select(.name != $name_tcp and .name != $name_udp)]' "$CONFIG_FILE" > "$temp_file"
  else
    jq --arg name "$target_name" '.services = [.services[] | select(.name != $name)]' "$CONFIG_FILE" > "$temp_file"
  fi
    
  if [ $? -eq 0 ]; then
    mv "$temp_file" "$CONFIG_FILE"
  else
    printf "%b %sError updating config file using jq.%b\\n" "$RED" "$ERROR_SYMBOL" "$PLAIN"
    rm -f "$temp_file"; return 1;
  fi
  rm -f "$temp_file"
  printf "%b %sEntry deleted successfully.%b\\n" "$GREEN" "$SUCCESS_SYMBOL" "$PLAIN"
  read -p "Apply config file now? (Y/n): " apply_now
  if [[ $apply_now != "n" && $apply_now != "N" ]]; then apply_config; fi
  return 0
}

edit_config_forward() {
  local entry_number=$1
  if [ -z "$entry_number" ] || ! [[ "$entry_number" =~ ^[0-9]+$ ]]; then printf "%b %sInvalid service number.%b\\n" "$RED" "$ERROR_SYMBOL" "$PLAIN"; return 1; fi
  if [ ! -f "$CONFIG_FILE" ]; then printf "%b %sConfig file not found.%b\\n" "$RED" "$ERROR_SYMBOL" "$PLAIN"; return 1; fi

  local entries=() entry_details=()
  while IFS="|" read -r name listen_addr target_addr proto; do
    if [ ! -z "$name" ]; then entries+=("$name"); entry_details+=("$name|$listen_addr|$target_addr|$proto"); fi
  done < <(parse_config_file)

  if [ $entry_number -lt 1 ] || [ $entry_number -gt ${#entries[@]} ]; then printf "%b %sInvalid entry number.%b\\n" "$RED" "$ERROR_SYMBOL" "$PLAIN"; return 1; fi

  IFS="|" read -r name listen_addr target_addr proto <<<"${entry_details[$entry_number - 1]}"
  local is_part_of_pair=0 base_name related_service
  if [[ "$name" == *-tcp ]] || [[ "$name" == *-udp ]]; then
    is_part_of_pair=1
    base_name=$(echo "$name" | sed 's/-tcp$\\|-udp$//')
    if [[ "$name" == *-tcp ]]; then related_service="$base_name-udp"; else related_service="$base_name-tcp"; fi
    printf "%b %sThis service is paired with %s. Both will be updated.%b\\n" "$YELLOW" "$WARN_SYMBOL" "$related_service" "$PLAIN"
  fi

  printf "%b%sEditing forwarding entry: %b%s%b%b\\n" "$CYAN" "$INFO_SYMBOL" "$BOLD" "$name" "$PLAIN" "$CYAN"
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
  if [ $is_part_of_pair -eq 1 ]; then printf "%b %sCannot change protocol for paired service. Delete and recreate to change protocol.%b\\n" "$YELLOW" "$WARN_SYMBOL" "$PLAIN"; fi

  printf "\\n%b%sNew settings:%b\\n" "$CYAN" "$INFO_SYMBOL" "$PLAIN"
  printf "%bLocal port:%b %s\\n" "$GREEN" "$PLAIN" "$new_local_port"
  printf "%bTarget:%b %s:%s\\n" "$GREEN" "$PLAIN" "$new_target_ip" "$new_target_port"
  printf "%bProtocol:%b %s\\n" "$GREEN" "$PLAIN" "$new_proto"

  read -p "Apply these changes? (Y/n): " confirm
  if [[ $confirm == "n" || $confirm == "N" ]]; then printf "%b %sEdit cancelled.%b\\n" "$YELLOW" "$WARN_SYMBOL" "$PLAIN"; return 0; fi

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
    printf "%b %sError updating config file using jq.%b\\n" "$RED" "$ERROR_SYMBOL" "$PLAIN"; rm -f "$temp_file"; return 1;
  fi
  rm -f "$temp_file"
  printf "%b %sEntry updated successfully.%b\\n" "$GREEN" "$SUCCESS_SYMBOL" "$PLAIN"
  read -p "Apply config file now? (Y/n): " apply_now
  if [[ $apply_now != "n" && $apply_now != "N" ]]; then apply_config; fi
  return 0
}

cleanup_old_services() {
  printf "%b%s=== Cleaning up old systemd services ===%b\\n" "$CYAN" "$INFO_SYMBOL" "$PLAIN"
  local found=0; local count=0
  printf "%b%sFound GOST related systemd services:%b\\n" "$BLUE" "$INFO_SYMBOL" "$PLAIN"
  for service_file in "$SERVICE_DIR"/gost-*.service; do
    if [ -e "$service_file" ]; then
      found=1; count=$((count + 1))
      service_name=$(basename "$service_file" .service)
      status=$(systemctl is-active "$service_name")
      printf "  %b%s.%b %s (Status: %s)\\n" "$GREEN" "$count" "$PLAIN" "$service_name" "$status"
    fi
  done
  if [ $found -eq 0 ]; then printf "%b %sNo old GOST systemd services found.%b\\n" "$YELLOW" "$WARN_SYMBOL" "$PLAIN"; return; fi
  
  printf "%b %sWarning: This will disable and remove all individual GOST systemd services (except gost.service).%b\\n" "$YELLOW" "$WARN_SYMBOL" "$PLAIN"
  printf "%b %sAll port forwarding should be managed through the config file and the main gost.service.%b\\n" "$YELLOW" "$WARN_SYMBOL" "$PLAIN"
  read -p "Are you sure you want to continue? (y/N): " confirm
  if [[ $confirm != [Yy]* ]]; then printf "%b %sOperation cancelled.%b\\n" "$YELLOW" "$WARN_SYMBOL" "$PLAIN"; return; fi
  
  count=0 # Reset count for removed services
  for service_file in "$SERVICE_DIR"/gost-*.service; do
    if [ -e "$service_file" ]; then
      service_name=$(basename "$service_file" .service)
      if [ "$service_name" != "gost" ]; then # Do not remove the main gost.service itself
        printf "%b %sStopping, disabling and removing %s...%b\\n" "$CYAN" "$INFO_SYMBOL" "$service_name" "$PLAIN"
        sudo systemctl stop "$service_name" &>/dev/null
        sudo systemctl disable "$service_name" &>/dev/null
        sudo rm -f "$service_file"
        count=$((count + 1))
      fi
    fi
  done
  sudo systemctl daemon-reload
  printf "%b %sSuccessfully removed %s old GOST systemd services.%b\\n" "$GREEN" "$SUCCESS_SYMBOL" "$count" "$PLAIN"
  read -p "Apply main config file now (restart gost.service)? (Y/n): " apply_now
  if [[ $apply_now != "n" && $apply_now != "N" ]]; then apply_config; fi
}

main_menu() {
  while true; do
    clear
    get_ip_info
    printf "%b%s==================== Gost Port Forwarding Management ====================%b\\n" "$BOLD" "$BLUE" "$PLAIN"
    printf "  %bIPv4: %b%s %b(%s)%b\\n" "$CYAN" "$WHITE" "$IPV4" "$YELLOW" "$COUNTRY_V4" "$PLAIN"
    printf "  %bIPv6: %b%s %b(%s)%b\\n" "$CYAN" "$WHITE" "$IPV6" "$YELLOW" "$COUNTRY_V6" "$PLAIN"
    printf "%b%s=========================================================================%b\\n" "$BOLD" "$BLUE" "$PLAIN"
    printf "%b1.%b Create Single Port Forwarding\\n" "$GREEN" "$PLAIN"
    printf "%b2.%b Create Port Range Forwarding\\n" "$GREEN" "$PLAIN"
    printf "%b3.%b Manage Forwarding Services\\n" "$GREEN" "$PLAIN"
    printf "%b4.%b Configuration File Management\\n" "$GREEN" "$PLAIN"
    printf "%b5.%b Clean Up Old Systemd Services\\n" "$GREEN" "$PLAIN"
    printf "%b6.%b Exit\\n" "$GREEN" "$PLAIN"
    printf "%b%s=========================================================================%b\\n" "$BOLD" "$BLUE" "$PLAIN"
    read -p "$(printf "%bPlease select [1-6]: %b" "$YELLOW" "$PLAIN")" choice

    case $choice in
    1) create_forward_service ;; 
    2) create_port_range_forward ;; 
    3) manage_forward_services ;; 
    4) config_file_management ;; 
    5) cleanup_old_services ;; 
    6) printf "%b%sThank you for using. Goodbye!%b\\n" "$GREEN" "$SUCCESS_SYMBOL" "$PLAIN"; exit 0 ;; 
    *) printf "%b %sInvalid selection. Please try again.%b\\n" "$RED" "$ERROR_SYMBOL" "$PLAIN" ;; 
    esac
    read -n1 -r -p "Press any key to return to the main menu..."
  done
}

main_menu
