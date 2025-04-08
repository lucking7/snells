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

# Check and install necessary components
check_and_install() {
  local packages=("gost" "lsof" "curl" "grep" "yq" "jq")
  local package_to_install
  for package in "${packages[@]}"; do
    if ! command -v $package &>/dev/null; then
      echo -e "${YELLOW}Package ${BOLD}$package${PLAIN}${YELLOW} not found. Installing...${PLAIN}"
      package_to_install=""
      case $package in
      "gost")
        (bash <(curl -fsSL https://github.com/go-gost/gost/raw/master/install.sh) --install) &
        ;;
      "yq")
        YQ_VERSION="latest"
        YQ_BINARY="yq_linux_amd64"
        YQ_URL=$(curl -s "https://api.github.com/repos/mikefarah/yq/releases/${YQ_VERSION}" | grep "browser_download_url.*${YQ_BINARY}" | cut -d '\"' -f 4 | head -n 1)
        if [ -z "$YQ_URL" ]; then
           echo -e "${RED}Could not find yq download URL. Trying apt...${PLAIN}"
           package_to_install="yq"
        else
           echo -e "${YELLOW}Downloading yq from $YQ_URL...${PLAIN}"
           (curl -L "$YQ_URL" -o /usr/local/bin/yq && chmod +x /usr/local/bin/yq) &
        fi
        ;;
      "jq")
        package_to_install="jq"
        ;;
      *)
        package_to_install=$package
        ;;
      esac

      if [ -n "$package_to_install" ]; then
        if ! sudo apt-get update -y; then
          echo -e "${RED}Failed to update package list.${PLAIN}"
          continue
        fi
        if ! sudo apt-get install $package_to_install -y; then
          echo -e "${RED}Failed to install $package_to_install via apt. Please install it manually.${PLAIN}"
          continue
        fi
        show_loading $!
      elif [[ "$package" == "yq" || "$package" == "gost" ]]; then
      show_loading $!
      fi

      if command -v $package &>/dev/null; then
        echo -e "${GREEN}$package installed successfully.${PLAIN}"
      else
        echo -e "${RED}Failed to install $package. Please install it manually.${PLAIN}"
      fi
    fi
  done

  # Ensure Gost config directory exists
  sudo mkdir -p /etc/gost
  # Create empty config if it doesn't exist
  if [ ! -f /etc/gost/config.yml ]; then
    echo -e "${YELLOW}Creating initial GOST config file: /etc/gost/config.yml${PLAIN}"
    sudo bash -c 'echo "services: []" > /etc/gost/config.yml'
    # Optionally set permissions
    # sudo chown <user>:<group> /etc/gost/config.yml
    # sudo chmod 640 /etc/gost/config.yml
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
ExecStart=/usr/local/bin/gost -C /etc/gost/config.yml
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

# Service files directory
SERVICE_DIR="/etc/systemd/system"

# Function to delete a service by number
delete_service_by_number() {
  local service_number=$1
  local counter=1
  for service_file in "$SERVICE_DIR"/gost-forward-*.service; do
    if [ -e "$service_file" ]; then
      if [ $counter -eq $service_number ]; then
        service_name=$(basename "$service_file" .service)
        echo -e -n "Are you sure you want to delete the service ${BOLD}$service_name${PLAIN}? (${GREEN}Y${PLAIN}/${RED}N${PLAIN}): "
        read confirm
        if [[ $confirm == [Yy]* ]]; then
          systemctl stop "$service_name"
          systemctl disable "$service_name"
          rm "$service_file"
          systemctl daemon-reload
          echo -e "${GREEN}Deleted service: $service_name${PLAIN}"
        else
          echo -e "${YELLOW}Deletion cancelled.${PLAIN}"
        fi
        return
      fi
      ((counter++))
    fi
  done
  echo -e "${RED}Service with the specified number not found.${PLAIN}"
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

# Function to create a forwarding service using config file
create_forward_service() {
  echo -e "${CYAN}=== Create new port forwarding rules (using /etc/gost/config.yml) ===${PLAIN}"

  # Get protocol type
  echo -e "${CYAN}Select protocol type:${PLAIN}"
  echo -e "${GREEN}1.${PLAIN} TCP ${YELLOW}(default)${PLAIN}"
  echo -e "${GREEN}2.${PLAIN} UDP"
  read -p "Select [1-2] (default: 1): " protocol_choice
  local protocol="tcp"
  local listener_type="tcp"
  local handler_type="tcp" # Simple forward handler
  local dialer_type="tcp"  # Connect to target via TCP
  if [ "$protocol_choice" == "2" ]; then
      protocol="udp"
      listener_type="udp"
      handler_type="udp" # Simple forward handler
      dialer_type="udp"  # Connect to target via UDP
  fi
  echo -e "${YELLOW}Selected protocol: ${BOLD}${protocol^^}${PLAIN}"

  # Get port information
  echo -e "${YELLOW}Enter local port(s). Examples: ${WHITE}8080${PLAIN}, ${WHITE}8080,8081${PLAIN}, ${WHITE}8080-8090${PLAIN}"
  read -p "Local port(s): " local_ports_input
  read -p "Target IP: " target_ip
  read -p "Target port: " target_port_input

  # --- Input Validation ---
  if ! validate_ip "$target_ip"; then
      echo -e "${RED}Invalid target IP address format: $target_ip${PLAIN}"
      return 1
  fi
  if ! validate_port "$target_port_input"; then
      echo -e "${RED}Invalid target port: $target_port_input. Must be between 1 and 65535.${PLAIN}"
      return 1
  fi
  local parsed_local_ports
  parsed_local_ports=$(parse_ports "$local_ports_input")
  if [ $? -ne 0 ]; then
      echo -e "${RED}Failed to parse local ports. Please check the format and values.${PLAIN}"
      return 1
  fi
   if [ -z "$parsed_local_ports" ]; then
    echo -e "${RED}No valid local ports specified.${PLAIN}"
    return 1
  fi
  # --- End Validation ---

  local target_address_config="$target_ip"
  # GOST config doesn't need brackets for IPv6 node addresses
  # if [[ $target_ip == *:* ]]; then target_address_config="$target_ip"; fi # No change needed

  local config_file="/etc/gost/config.yml"
  local changes_made=0
  local backup_file="${config_file}.bak.$(date +%Y%m%d%H%M%S)"

  echo -e "${YELLOW}Backing up current config to $backup_file...${PLAIN}"
  sudo cp "$config_file" "$backup_file" || { echo -e "${RED}Failed to create backup. Aborting.${PLAIN}"; return 1; }

  echo -e "${YELLOW}Adding services to $config_file...${PLAIN}"

  for local_port in $parsed_local_ports; do
      local safe_target_ip=${target_ip//[^a-zA-Z0-9.-]/_} # Sanitize for name
      local service_name="${protocol}-fwd-${local_port}-to-${safe_target_ip}-${target_port_input}"
      local listen_addr=":${local_port}" # Listen on all interfaces by default

      echo -e "  ${CYAN}Processing: ${protocol^^} Local ${WHITE}$listen_addr${PLAIN} -> Target ${WHITE}$target_ip:$target_port_input${PLAIN} (Service: ${BOLD}$service_name${PLAIN})"

      # Check if service with the same name OR same listener address/protocol already exists
      if sudo yq e ".services[] | select(.name == \"$service_name\")" "$config_file" | grep -q "name: $service_name"; then
          echo -e "  ${YELLOW}Skipping: Service name '$service_name' already exists.${PLAIN}"
          continue
      fi
      # Check for listener conflict (same addr and listener type)
      # Note: GOST might handle multiple services on the same UDP port, but good practice to check
      if sudo yq e ".services[] | select(.addr == \"$listen_addr\" and .listener.type == \"$listener_type\")" "$config_file" | grep -q "addr: $listen_addr"; then
          echo -e "  ${YELLOW}Warning: Another service might be listening on $protocol/$listen_addr. Skipping addition of '$service_name'. Check config manually.${PLAIN}"
          continue
      fi


      # Create the service YAML block as a string
      local service_yaml
      # Use explicit listener and dialer types matching the protocol
      service_yaml=$(cat <<EOF
- name: $service_name
  addr: "$listen_addr"
  listener:
    type: $listener_type
    # metadata: # Add listener specific options if needed
  handler:
    type: $handler_type # Use basic handler matching protocol
    retries: 0
  forwarder:
    nodes:
    - name: target-${protocol}-${local_port}-${target_port_input} # Node name
      addr: "$target_address_config:$target_port_input" # Target address
      connector: # Explicit connector needed for forwarding
         type: forward
      dialer: # Explicit dialer type
         type: $dialer_type
EOF
)
      # Use yq to add the service block
      if sudo yq eval ".services += [$(echo "$service_yaml" | yq eval -o=json - | sed 's/^- //')] | ... style=''" -i "$config_file"; then
          echo -e "  ${GREEN}Successfully added service '$service_name' to $config_file${PLAIN}"
          changes_made=1
      else
          echo -e "  ${RED}Error adding service '$service_name' using yq. Restoring backup.${PLAIN}"
          sudo mv "$backup_file" "$config_file" # Attempt to restore backup
          return 1 # Abort further additions on error
      fi
  done

  # Reload gost service if changes were made
  if [ $changes_made -eq 1 ]; then
    reload_gost_service
  else
    echo -e "${YELLOW}No new services were added (possibly due to existing names/listeners).${PLAIN}"
    # Remove unused backup if no changes made
    sudo rm "$backup_file"
  fi

  echo -e "${GREEN}Forwarding rule creation process finished.${PLAIN}"
}

# Function to list existing forwarding services from config file
list_forward_services() {
  echo -e "${CYAN}=== Forwarding Rules from /etc/gost/config.yml ===${PLAIN}"
  local config_file="/etc/gost/config.yml"
  # ... (status check remains the same) ...
  echo -e "Central GOST Service Status: ${central_service_status}"
  echo "----------------------------------------------------------------------------------------------------" # Adjusted width

  # Extract more info: name, addr, listener type (as protocol), target address
  local services_jsonl
  if ! services_jsonl=$(sudo yq e '.services[] | {"index": index, "name": .name, "addr": .addr, "protocol": (.listener.type // "tcp"), "target_addr": .forwarder.nodes[0].addr}' -o json "$config_file"); then
      echo -e "${RED}Error reading or parsing $config_file with yq.${PLAIN}"
      return 1
  fi

  if [ -z "$services_jsonl" ]; then
      echo -e "${YELLOW}No forwarding services found in $config_file.${PLAIN}"
      return 0
  fi

  # Print header - Added Protocol
  printf "%-5s %-35s %-10s %-15s %-20s %-15s\\n" "No." "Service Name" "Protocol" "Local Addr" "Target Addr" "Target Port"
  echo "----------------------------------------------------------------------------------------------------" # Adjusted width

  local counter=1
  while IFS= read -r line; do
    local service_name=$(echo "$line" | jq -r '.name')
    local local_addr=$(echo "$line" | jq -r '.addr')
    local protocol=$(echo "$line" | jq -r '.protocol | ascii_upcase') # Show protocol (uppercase)
    local target_full_addr=$(echo "$line" | jq -r '.target_addr')
    local target_address
    local target_port
    # ... (target address/port parsing remains the same) ...
    if [[ "$target_full_addr" == \[* ]]; then
        target_address=$(echo "$target_full_addr" | sed -E 's/\\[(.*)\\]:([0-9]+)/\\1/')
        target_port=$(echo "$target_full_addr" | sed -E 's/\\[(.*)\\]:([0-9]+)/\\2/')
    else
        target_address=$(echo "$target_full_addr" | cut -d: -f1)
        target_port=$(echo "$target_full_addr" | cut -d: -f2)
    fi

    # Adjusted printf format
    printf "%-5s %-35s %-10s %-15s %-20s %-15s\\n" \
      "$counter" \
      "$service_name" \
      "$protocol" \
      "$local_addr" \
      "$target_address" \
      "$target_port"

    ((counter++))
  done <<< "$services_jsonl"

  echo "----------------------------------------------------------------------------------------------------" # Adjusted width
  return $((counter - 1))
}

# Function to manage existing forwarding services
manage_forward_services() {
  while true; do
    echo -e "\\n${CYAN}=== Manage Forwarding Rules (/etc/gost/config.yml) ===${PLAIN}"
    echo -e "${GREEN}1.${PLAIN} List rules"
    echo -e "${GREEN}2.${PLAIN} Add new rule" # Renamed for clarity
    echo -e "${GREEN}3.${PLAIN} Edit rule (by number)"
    echo -e "${GREEN}4.${PLAIN} Delete rule (by number)"
    echo -e "${GREEN}5.${PLAIN} Return to main menu"
    read -p "$(echo -e ${YELLOW}"Please select [1-5]: "${PLAIN})" choice

    case $choice in
    1) list_forward_services ;;
    2) create_forward_service ;; # Direct call to add function
    3)
      # Edit Rule - Placeholder for now
      list_forward_services
      local service_count=$?
      if [ $service_count -gt 0 ]; then
        read -p "Enter the rule number to edit: " service_number_to_edit
        edit_forward_service "$service_number_to_edit" # Call edit function
      elif [ $service_count -eq 0 ]; then
          sleep 1
      else
          sleep 1
      fi
      ;;
    4)
      # Delete Rule
      list_forward_services
      local service_count=$?
      if [ $service_count -gt 0 ]; then
          read -p "Enter the rule number to delete: " service_number_to_delete
          delete_service_by_number "$service_number_to_delete"
      elif [ $service_count -eq 0 ]; then
          sleep 1
      else
          sleep 1
      fi
      ;;
    5) return ;;
    *) echo -e "${RED}Invalid selection. Please try again.${PLAIN}" ;;
    esac
  done
}

# Function to edit an existing forwarding service rule
edit_forward_service() {
    local service_number=$1
    local config_file="/etc/gost/config.yml"

    # Validate input number
    if ! [[ "$service_number" =~ ^[1-9][0-9]*$ ]]; then
        echo -e "${RED}Invalid number entered.${PLAIN}"
        return 1
    fi

    # Get the current service details using yq (index is 0-based)
    local service_index=$(($service_number - 1))
    local current_service_json
    if ! current_service_json=$(sudo yq e ".services[$service_index]" -o json "$config_file"); then
        echo -e "${RED}Service with number $service_number not found or error reading config.${PLAIN}"
        return 1
    fi

    # Extract current values using jq
    local service_name=$(echo "$current_service_json" | jq -r '.name')
    local current_local_addr=$(echo "$current_service_json" | jq -r '.addr')
    local current_protocol=$(echo "$current_service_json" | jq -r '.listener.type // "tcp"')
    local current_target_full_addr=$(echo "$current_service_json" | jq -r '.forwarder.nodes[0].addr')
    local current_target_ip
    local current_target_port

    # Parse current target address/port
    if [[ "$current_target_full_addr" == \\[.* ]]; then
        current_target_ip=$(echo "$current_target_full_addr" | sed -E 's/\\[(.*)\\]:([0-9]+)/\\1/')
        current_target_port=$(echo "$current_target_full_addr" | sed -E 's/\\[(.*)\\]:([0-9]+)/\\2/')
    else
        current_target_ip=$(echo "$current_target_full_addr" | cut -d: -f1)
        current_target_port=$(echo "$current_target_full_addr" | cut -d: -f2)
    fi

    echo -e "${CYAN}--- Editing Rule: $service_name ---${PLAIN}"
    echo -e "  Protocol: ${current_protocol^^}"
    echo -e "  Local Address: $current_local_addr"
    echo -e "  Current Target IP: $current_target_ip"
    echo -e "  Current Target Port: $current_target_port"
    echo -e "---------------------------------------"
    echo -e "${YELLOW}Enter new values (leave blank to keep current value):${PLAIN}"

    # Get new target IP
    read -p "New Target IP [$current_target_ip]: " new_target_ip
    if [ -z "$new_target_ip" ]; then
        new_target_ip=$current_target_ip
    elif ! validate_ip "$new_target_ip"; then
        echo -e "${RED}Invalid target IP address format: $new_target_ip${PLAIN}"
        return 1
    fi

    # Get new target port
    read -p "New Target Port [$current_target_port]: " new_target_port
    if [ -z "$new_target_port" ]; then
        new_target_port=$current_target_port
    elif ! validate_port "$new_target_port"; then
        echo -e "${RED}Invalid target port: $new_target_port. Must be 1-65535.${PLAIN}"
        return 1
    fi

    # Check if changes were actually made
    if [ "$new_target_ip" == "$current_target_ip" ] && [ "$new_target_port" == "$current_target_port" ]; then
        echo -e "${YELLOW}No changes detected. Edit cancelled.${PLAIN}"
        return 0
    fi

    # Prepare the new target address string
    local new_target_address_config="$new_target_ip"
    local new_target_full_addr="$new_target_ip:$new_target_port"

    echo -e -n "Apply changes? (Target: ${BOLD}$new_target_full_addr${PLAIN}) (${GREEN}Y${PLAIN}/${RED}N${PLAIN}): "
    read confirm
    if [[ $confirm == [Yy]* ]]; then
        local backup_file="${config_file}.bak.$(date +%Y%m%d%H%M%S)"
        echo -e "${YELLOW}Backing up current config to $backup_file...${PLAIN}"
        sudo cp "$config_file" "$backup_file" || { echo -e "${RED}Failed to create backup. Aborting.${PLAIN}"; return 1; }

        echo -e "${YELLOW}Updating rule '$service_name' in $config_file...${PLAIN}"
        # Use yq to update the specific node's address
        if sudo yq eval "(.services[$service_index].forwarder.nodes[0].addr) = \"$new_target_full_addr\"" -i "$config_file"; then
            echo -e "${GREEN}Successfully updated rule '$service_name'.${PLAIN}"
            # Reload the central service
            reload_gost_service
        else
            echo -e "${RED}Error updating rule '$service_name' using yq. Restoring backup.${PLAIN}"
            sudo mv "$backup_file" "$config_file"
            return 1
        fi
    else
        echo -e "${YELLOW}Edit cancelled.${PLAIN}"
    fi
}

# Main menu needs adjustment for the new manage menu options
main_menu() {
  while true; do
    clear
    get_ip_info
    echo -e "${BOLD}${BLUE}==================== Gost Port Forwarding Management ====================${PLAIN}"
    echo -e "  ${CYAN}IPv4: ${WHITE}$IPV4 ${YELLOW}($COUNTRY_V4)${PLAIN}"
    echo -e "  ${CYAN}IPv6: ${WHITE}$IPV6 ${YELLOW}($COUNTRY_V6)${PLAIN}"
    echo -e "${BOLD}${BLUE}=========================================================================${PLAIN}"
    echo -e "${GREEN}1.${PLAIN} Manage Forwarding Rules" # Simplified main menu
    echo -e "${GREEN}2.${PLAIN} Exit"
    echo -e "${BOLD}${BLUE}=========================================================================${PLAIN}"
    read -p "$(echo -e ${YELLOW}"Please select [1-2]: "${PLAIN})" choice

    case $choice in
    1) manage_forward_services ;; # Go to the management submenu
    2)
      echo -e "${GREEN}Thank you for using. Goodbye!${PLAIN}"
      exit 0
      ;;
    *) echo -e "${RED}Invalid selection. Please try again.${PLAIN}" ;;
    esac
    # Removed the pause here, handled within manage menu loop if needed
    # read -n1 -r -p "Press any key to return to the main menu..."
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

# Check and install necessary components
check_and_install

# Execute main menu
main_menu
