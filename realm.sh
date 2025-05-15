#!/bin/bash

# Colors for output
GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[0;33m"
BOLD="\033[1m"
NC="\033[0m" # No Color

# Configuration path variable
CONFIG_PATH="/root/.realm/config.toml"
REALM_DIR="/root/realm"
REALM_CONFIG_DIR="/root/.realm"

# 检查依赖函数
require_command() {
    if ! command -v "$1" &> /dev/null; then
        echo -e "${RED}Error: '$1' command not found. Please install it and rerun the script.${NC}"
        exit 1
    fi
}

# 必要依赖检查
require_command curl
require_command lsof
require_command systemctl
require_command tar
require_command wget

# jq为可选依赖，如果不存在则采用grep方式
use_jq=false
if command -v jq &> /dev/null; then
    use_jq=true
fi

# Function to deploy Realm
deploy_realm() {
    mkdir -p "$REALM_DIR" && cd "$REALM_DIR" || { echo -e "${RED}Failed to access $REALM_DIR directory.${NC}"; exit 1; }
    
    # Get latest version from GitHub API
    _version=$(curl -s https://api.github.com/repos/zhboner/realm/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\\1/')
    
    if [ -z "$_version" ]; then
        echo -e "${RED}Failed to get version number. Please check if you can connect to GitHub API.${NC}"
        echo -e "${YELLOW}Falling back to a default known version v2.6.2 for download.${NC}"
        _version="v2.6.2" # Fallback version
    else
        echo -e "${GREEN}Latest version: ${_version}${NC}"
    fi
    
    # Detect architecture
    arch=$(uname -m)
    os_type=$(uname -s | tr '[:upper:]' '[:lower:]') # Renamed to os_type to avoid conflict
    
    download_url=""
    case "$arch-$os_type" in
        x86_64-linux)
            download_url="https://github.com/zhboner/realm/releases/download/${_version}/realm-x86_64-unknown-linux-gnu.tar.gz"
            ;;
        # realm.sh seems to focus on linux-gnu, keeping it simple. Add more if user explicitly asks.
        # x86_64-darwin)
        #     download_url="https://github.com/zhboner/realm/releases/download/${_version}/realm-x86_64-apple-darwin.tar.gz"
        #     ;;
        aarch64-linux)
            download_url="https://github.com/zhboner/realm/releases/download/${_version}/realm-aarch64-unknown-linux-gnu.tar.gz"
            ;;
        # aarch64-darwin)
        #     download_url="https://github.com/zhboner/realm/releases/download/${_version}/realm-aarch64-apple-darwin.tar.gz"
        #     ;;
        armv7l-linux | arm-linux) # armv7l is a common output for arm 32-bit
            download_url="https://github.com/zhboner/realm/releases/download/${_version}/realm-arm-unknown-linux-gnueabi.tar.gz"
            ;;
        *)
            echo -e "${RED}Unsupported architecture or OS: $arch-$os_type. Attempting x86_64-linux-gnu as a default.${NC}"
            download_url="https://github.com/zhboner/realm/releases/download/${_version}/realm-x86_64-unknown-linux-gnu.tar.gz"
            ;;
    esac
    
    echo -e "${YELLOW}Downloading Realm from: $download_url ${NC}"
    wget -qO realm.tar.gz "$download_url"
    if [ ! -f realm.tar.gz ] || [ ! -s realm.tar.gz ]; then # Check if file exists and is not empty
        echo -e "${RED}Download realm.tar.gz failed. Please check network or URL: $download_url ${NC}"
        # Attempt to cleanup before exiting
        rm -f realm.tar.gz
        cd .. && rm -rf "$REALM_DIR"
        exit 1
    fi
    tar -xzf realm.tar.gz && chmod +x realm
    rm realm.tar.gz # Clean up downloaded archive

    # Create directories for configs
    mkdir -p "$REALM_CONFIG_DIR"
    
    # Create service file
    cat <<EOF >/etc/systemd/system/realm.service
[Unit]
Description=Realm Service
After=network-online.target
Wants=network-online.target systemd-networkd-wait-online.service

[Service]
Type=simple
User=root
Restart=on-failure
RestartSec=5s
WorkingDirectory=${REALM_DIR}
ExecStart=${REALM_DIR}/realm -c ${CONFIG_PATH}

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    # Initialize config.toml
    if [ ! -f "$CONFIG_PATH" ]; then
        cat <<EONET >"$CONFIG_PATH"
# Global network settings
# These settings can be overridden by individual endpoint configurations where applicable.
[network]
# Default to TCP enabled and UDP enabled if not specified per endpoint.
# 'no_tcp = true' means TCP is disabled globally unless an endpoint explicitly enables it.
# 'use_udp = true' means UDP is enabled globally unless an endpoint explicitly disables it.
no_tcp = false 
use_udp = true
ipv6_only = false 
EONET
        echo -e "${GREEN}[network] configuration added to ${CONFIG_PATH}.${NC}"
    fi
    realm_status="Installed"
    realm_status_color="$GREEN"
    echo -e "${GREEN}Deployment completed.${NC}"
}

# Function to uninstall Realm
uninstall_realm() {
    systemctl stop realm &>/dev/null
    systemctl disable realm &>/dev/null
    rm -f /etc/systemd/system/realm.service
    systemctl daemon-reload
    echo -e "${YELLOW}Removing Realm directories...${NC}"
    rm -rf "$REALM_DIR"
    rm -rf "$REALM_CONFIG_DIR" # Thoroughly remove config directory
    if [ -f "/etc/crontab" ]; then
        # Check if crontab is writable and sed is available
        if [ -w "/etc/crontab" ] && command -v sed &> /dev/null; then
            sed -i '/realm/d' /etc/crontab
            echo -e "${YELLOW}Realm cron jobs removed from /etc/crontab.${NC}"
        else
            echo -e "${YELLOW}Warning: /etc/crontab not writable or sed not found. Skipping crontab cleanup.${NC}"
        fi
    else
        echo -e "${YELLOW}Warning: /etc/crontab not found. Skipping crontab cleanup.${NC}"
    fi
    realm_status="Not Installed"
    realm_status_color="$RED"
    echo -e "${RED}Realm has been uninstalled.${NC}"
}

# Function to check Realm installation
check_realm_installation() {
    if [ -f "${REALM_DIR}/realm" ]; then
        realm_status="Installed"
        realm_status_color="$GREEN"
    else
        realm_status="Not Installed"
        realm_status_color="$RED"
        echo -e "${RED}Realm is not installed. Installing now...${NC}"
        deploy_realm
    fi
}

# Function to check and fix Realm service status
check_realm_service_status() {
    if systemctl is-active --quiet realm; then
        echo -e "${GREEN}Active${NC}"
        return 0 # Service is active, nothing to do
    fi

    # Service is not active, check if config exists
    if [ ! -f "$CONFIG_PATH" ]; then
        echo -e "${RED}Inactive${NC}"
        echo -e "${YELLOW}Realm configuration file (${CONFIG_PATH}) not found. Cannot start service.${NC}"
        return 1 # Config missing, cannot proceed
    fi
    
    # Check if there are any endpoints configured
    if ! grep -q '^\\[\\[endpoints\\]\\]' "$CONFIG_PATH"; then
        echo -e "${RED}Inactive${NC}"
        echo -e "${YELLOW}No forwarding rules configured in ${CONFIG_PATH}. Add rules before starting the service.${NC}"
        return 0 # No endpoints, do not attempt to start/fix
    fi

    echo -e "${RED}Inactive${NC}"
    echo "Attempting to fix Realm service..."

    # Remove duplicate lines in config (optional, but good practice)
    # Using a temporary file for awk is safer
    awk '!seen[$0]++' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
    echo "Cleaned up duplicate lines in ${CONFIG_PATH}"

    # Ensure [network] section exists and is correct (already handled in deploy_realm, but check again)
    if ! grep -q '^\\[network\\]' "$CONFIG_PATH"; then
        cat <<EOF >>"$CONFIG_PATH"
[network]
no_tcp = false
use_udp = true
ipv6_only = false
EOF
        echo "Added missing [network] section to ${CONFIG_PATH}"
    fi

    # Check realm executable
    if [ ! -x "${REALM_DIR}/realm" ]; then
        echo -e "${RED}Error: realm executable not found or not executable at ${REALM_DIR}/realm${NC}"
        return 1
    fi

    # Attempt to restart the service
    echo "Attempting to restart Realm service..."
    systemctl restart realm
    sleep 2 # Give service time to start

    if systemctl is-active --quiet realm; then
        echo -e "${GREEN}Realm service successfully restarted${NC}"
    else
        echo -e "${RED}Failed to restart Realm service${NC}"
        echo "Checking logs for errors:"
        journalctl -u realm.service -n 20 --no-pager
        return 1
    fi
    return 0
}

# Function to fetch server information
fetch_server_info() {
    meta_info=$(curl -s https://speed.cloudflare.com/meta)

    # 尝试使用 jq 解析
    if $use_jq && [ -n "$meta_info" ]; then
        # Ensure jq processes the string content correctly
        asOrganization=$(echo "$meta_info" | jq -r '.asOrganization // "N/A"')
        colo=$(echo "$meta_info" | jq -r '.colo // "N/A"')
        country=$(echo "$meta_info" | jq -r '.country // "N/A"')
    else
        # 后备方案，无 jq 时使用 grep 提取
        asOrganization=$(echo "$meta_info" | grep -oP '(?<="asOrganization":")[^"]*' || echo "N/A")
        colo=$(echo "$meta_info" | grep -oP '(?<="colo":")[^"]*' || echo "N/A")
        country=$(echo "$meta_info" | grep -oP '(?<="country":")[^"]*' || echo "N/A")
        # Fallback to simpler grep if grep -P is not available
        if [ "$asOrganization" = "N/A" ] && command -v grep &>/dev/null && command -v sed &>/dev/null; then
             asOrganization=$(echo "$meta_info" | grep '"asOrganization":"' | sed 's/.*"asOrganization":"\\([^"]*\\)".*/\\1/' || echo "N/A")
             colo=$(echo "$meta_info" | grep '"colo":"' | sed 's/.*"colo":"\\([^"]*\\)".*/\\1/' || echo "N/A")
             country=$(echo "$meta_info" | grep '"country":"' | sed 's/.*"country":"\\([^"]*\\)".*/\\1/' || echo "N/A")
        fi
    fi
    
    # Sanitize N/A values if fields are empty
    [ -z "$asOrganization" ] && asOrganization="N/A"
    [ -z "$colo" ] && colo="N/A"
    [ -z "$country" ] && country="N/A"


    # Fetch IP information using ip.sb
    ipv4=$(curl -s ipv4.ip.sb || echo "N/A")
    ipv6=$(curl -s ipv6.ip.sb || echo "N/A")

    # Check if IPv6 is available
    has_ipv6=false
    if [ "$ipv6" != "N/A" ] && [[ "$ipv6" =~ ":" ]]; then # Basic check for colon in IPv6
        has_ipv6=true
    fi

    # Fallback to combined API if individual requests fail or return invalid-looking data
    if { [ "$ipv4" = "N/A" ] || ! [[ "$ipv4" =~ ^[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}$ ]]; } && \
       { [ "$ipv6" = "N/A" ] || ! [[ "$ipv6" =~ ":" ]]; }; then
        combined_ip=$(curl -s ip.sb || echo "N/A")
        if [[ $combined_ip =~ .*:.* ]]; then # If it contains a colon, assume IPv6
            ipv6=$combined_ip
            has_ipv6=true
            ipv4="N/A" # Reset IPv4 if we got a valid IPv6 from combined
        elif [[ $combined_ip =~ ^[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}$ ]]; then # Else if it looks like IPv4
            ipv4=$combined_ip
            # ipv6 remains N/A or its previous value
        fi
    fi
}

# Function to display the menu
show_menu() {
    fetch_server_info
    clear
    echo -e "${BOLD}=== Realm Relay Management ===${NC}"
    echo "1. Add Realm Forward"
    echo "2. View Realm Forwards"
    echo "3. Delete Realm Forward"
    echo "4. Manage Realm Service"
    echo "5. Uninstall Realm"
    echo "6. Exit"
    echo "------------------------------"
    echo -e "Realm Status: ${realm_status_color}${realm_status}${NC}"
    echo -n "Realm Service: "
    check_realm_service_status
    echo "------------------------------"
    echo "Server Information:"
    echo "IPv4: $ipv4 | IPv6: $ipv6"
    echo "COLO: $colo | AS Organization: $asOrganization | Country: $country"
    echo "=================================="
}

# Function to find an available port
find_available_port() {
    local start_port=${1:-10000}
    local end_port=${2:-65535}
    local range=$((end_port - start_port + 1))
    local max_attempts=100

    RANDOM=$$$(date +%s)

    for ((i=1; i<=max_attempts; i++)); do
        local port=$((RANDOM % range + start_port))
        if ! lsof -i :$port > /dev/null 2>&1; then
            echo $port
            return 0
        fi
    done

    echo "No available ports found after $max_attempts attempts in the range $start_port-$end_port" >&2
    return 1
}

# Function to manage Realm service
manage_realm_service() {
    while true; do
        clear
        echo -e "${BOLD}Manage Realm Service${NC}"
        echo "1. Start Realm Service"
        echo "2. Stop Realm Service"
        echo "3. Restart Realm Service"
        echo "4. View Realm Service Status"
        echo "5. Return to Main Menu"
        read -rp "Select an option: " service_choice
        case $service_choice in
            1) systemctl start realm; echo "Realm service started." ;;
            2) systemctl stop realm; echo "Realm service stopped." ;;
            3) systemctl restart realm; echo "Realm service restarted." ;;
            4) systemctl status realm ;;
            5) return ;;
            *) echo -e "${RED}Invalid option${NC}" ;;
        esac
        read -n1 -r -p "Press any key to continue..."
    done
}

# Function to add a forwarding rule
add_forward() {
    echo -e "${BOLD}Add New Forwarding Rule${NC}"

    fetch_server_info

    # Select IP version for listening address of the endpoint (not global ipv6_only)
    local listen_ipv6_only_for_endpoint=false
    if [ "$has_ipv6" = true ]; then
        echo "Choose IP version for this listening endpoint:"
        echo "1. IPv4 (0.0.0.0)"
        echo "2. IPv6 ([::])"
        echo "3. Both IPv4 and IPv6 (Not directly supported by realm listen, typically handled by OS or specific config)"
        echo "   If you need separate IPv4 and IPv6 listeners for the same remote, create two rules."
        read -rp "Choice for listening [1 for IPv4, 2 for IPv6]: " ip_version_choice
        
        case $ip_version_choice in
            1) listen_addr="0.0.0.0";;
            2) listen_addr="[::]"; listen_ipv6_only_for_endpoint=true;; # Realm might interpret [::] as v6 only
            # 3) echo "To listen on both, you might need two rules or rely on OS behavior for 0.0.0.0"; listen_addr="0.0.0.0";;
            *) echo "Invalid choice. Defaulting to IPv4 (0.0.0.0)."; listen_addr="0.0.0.0";;
        esac
    else
        echo "IPv6 is not available or detected on this server. Endpoint will listen on IPv4 (0.0.0.0)."
        listen_addr="0.0.0.0"
    fi
    
    # Global ipv6_only setting in [network] - this is different
    # The user might want realm to ONLY use IPv6 for outgoing connections if multiple interfaces, etc.
    # For now, we keep the previous logic for global ipv6_only, but it seems less relevant if listen_addr is specific
    # This part may need clarification on how 'realm' uses global ipv6_only vs endpoint listen_on_ipv6
    # For this iteration, we will remove the prompt for global ipv6_only to simplify,
    # and assume the default in config.toml ([network] ipv6_only = false) is sufficient unless user has specific needs.


    # Select transport protocol for this endpoint
    echo "Choose Transport Protocol:"
    echo "1. TCP"
    echo "2. UDP"
    echo "3. Both TCP and UDP (Default)"
    read -rp "Choice [3]: " transport_choice
    transport_choice=${transport_choice:-3}
    case $transport_choice in
        1) use_tcp=true; use_udp=false ;;
        2) use_tcp=false; use_udp=true ;;
        3) use_tcp=true; use_udp=true ;;
        *) echo "Invalid choice. Defaulting to Both."; use_tcp=true; use_udp=true ;;
    esac

    # Get forwarding details
    read -rp "Enter local listening port (leave blank for auto-selection): " local_port
    if [ -z "$local_port" ]; then
        local_port=$(find_available_port)
        if [ $? -ne 0 ]; then
            echo -e "${RED}Failed to find an available port. Please specify one manually.${NC}"
            return 1
        fi
        echo -e "${GREEN}Automatically selected available port: $local_port${NC}"
    fi
    read -rp "Enter remote IP: " ip
    read -rp "Enter remote port: " port
    read -rp "Enter remark: " remark

    # Validate inputs
    if ! [[ "$local_port" =~ ^[0-9]+$ ]] || [ "$local_port" -lt 1 ] || [ "$local_port" -gt 65535 ]; then
        echo -e "${RED}Invalid local port number.${NC}"
        return 1
    fi
    # Remote IP validation
    # A more robust regex might be needed for all valid IP/hostname cases
    # This is a basic check
    if [[ -z "$ip" ]]; then # Check if remote IP is empty
        echo -e "${RED}Remote IP cannot be empty.${NC}"
        return 1
    fi
    # if ! [[ "$ip" =~ ^([0-9]{1,3}\\.){3}[0-9]{1,3}$ || "$ip" =~ ^([0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}$ || "$ip" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*[a-zA-Z0-9]$ ]]; then
    #    echo -e "${RED}Invalid remote IP or hostname format.${NC}"
    #    return 1
    # fi

    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        echo -e "${RED}Invalid remote port number.${NC}"
        return 1
    fi
    # 简单IP校验(IPv4/IPv6略简化) - old comment
    # if [[ ! "$ip" =~ ^[0-9a-fA-F:.]+$ ]]; then
    #     echo -e "${RED}Invalid IP address format.${NC}"
    #     return 1
    # fi

    # Check if [network] section exists, if not add it (should be created by deploy_realm)
    if ! grep -q '^\\[network\\]' "$CONFIG_PATH"; then
        cat <<EOF >> "$CONFIG_PATH"
[network]
no_tcp = false 
use_udp = true
ipv6_only = false 
EOF
        echo -e "${YELLOW}Warning: [network] section was missing and has been added to ${CONFIG_PATH}.${NC}"
    fi
    
    # Update global ipv6_only setting based on endpoint choice if desired, or keep it separate.
    # For now, we'll set the global ipv6_only if the endpoint is set to listen on IPv6 only.
    # This might not be what the user intends if they want global IPv6 preference for outbound connections
    # but still listen on IPv4. This needs clarification from Realm's behavior.
    # A safer approach is to let the listen_addr handle listening behavior and keep global ipv6_only for other purposes.
    # Let's comment out changing global ipv6_only here for now.
    # if [ "$listen_ipv6_only_for_endpoint" = true ]; then
    #    sed -i "s/^ipv6_only = .*$/ipv6_only = true/" "$CONFIG_PATH"
    # else
    #    sed -i "s/^ipv6_only = .*$/ipv6_only = false/" "$CONFIG_PATH"
    # fi


    # Append new endpoint
    cat <<EOF >> "$CONFIG_PATH"

[[endpoints]]
# Remark: $remark
listen = "${listen_addr}:$local_port"
remote = "$ip:$port"
# Per-endpoint protocol settings
use_tcp = $use_tcp 
use_udp = $use_udp
# Add other per-endpoint flags if supported by realm and needed, e.g., endpoint_ipv6_only = $listen_ipv6_only_for_endpoint
EOF

    realm_status="Installed"
    realm_status_color="$GREEN"

    # Enable and restart service
    systemctl enable realm
    systemctl restart realm
    echo -e "${GREEN}Forwarding rule added and Realm service restarted.${NC}"
}

# Function to view all forwarding rules
show_all_conf() {
    echo -e "${BOLD}Current Forwarding Rules:${NC}"
    if [ ! -f "$CONFIG_PATH" ]; then
        echo -e "${RED}Configuration file ${CONFIG_PATH} not found.${NC}"
        return
    fi
    # Use awk for more robust parsing of endpoints
    awk '
    BEGIN { endpoint_idx = 0; in_endpoint = 0; }
    /^# Remark: / { if (in_endpoint) remark = substr($0, index($0, ":") + 2); }
    /listen = "/ { if (in_endpoint) listen = substr($0, index($0, "=") + 2); }
    /remote = "/ { if (in_endpoint) remote = substr($0, index($0, "=") + 2); }
    /use_tcp =/ { if (in_endpoint) use_tcp = substr($0, index($0, "=") + 2); }
    /use_udp =/ { 
        if (in_endpoint) {
            use_udp = substr($0, index($0, "=") + 2);
            endpoint_idx++;
            printf "%d. Remark: %s\\n", endpoint_idx, remark;
            printf "   Listen: %s, Remote: %s\\n", listen, remote;
            printf "   TCP: %s, UDP: %s\\n", use_tcp, use_udp;
            # Reset for next endpoint
            remark="None"; listen="N/A"; remote="N/A"; use_tcp="N/A"; use_udp="N/A";
        }
    }
    /^\\[\\[endpoints\\]\\]/ { in_endpoint = 1; remark="None"; listen="N/A"; remote="N/A"; use_tcp="N/A"; use_udp="N/A"; }
    END { if (endpoint_idx == 0) print "No forwarding rules found."; }
    ' "$CONFIG_PATH"
}

# Function to delete a forwarding rule
delete_forward() {
    echo -e "${BOLD}Delete Forwarding Rule${NC}"
    if [ ! -f "$CONFIG_PATH" ]; then
        echo -e "${RED}Configuration file ${CONFIG_PATH} not found.${NC}"
        return
    fi

    # Temp file for processing
    local temp_config_file="${CONFIG_PATH}.tmp_delete"
    cp "$CONFIG_PATH" "$temp_config_file"

    declare -a rules_starts
    declare -a rules_ends
    declare -a rules_descs

    local rule_count=0
    local current_rule_start_line=0
    local line_num=0
    local in_endpoint_block=0

    # Read the temp config file to identify rule blocks
    while IFS= read -r line; do
        ((line_num++))
        if [[ "$line" == *"[[endpoints]]"* ]]; then
            if [ "$in_endpoint_block" -ne 0 ] && [ "$current_rule_start_line" -ne 0 ]; then
                # End of previous rule block (implicit)
                rules_ends[$rule_count]=$((line_num - 1))
            fi
            in_endpoint_block=1
            ((rule_count++))
            rules_starts[$rule_count]=$line_num
            current_rule_start_line=$line_num
            
            # Extract description for the current rule
            local remark_line=$(sed -n "$((current_rule_start_line + 1))p" "$temp_config_file" | grep "^# Remark:")
            local listen_line=$(sed -n "$((current_rule_start_line + 2))p" "$temp_config_file") # Assuming listen is 2 lines after [[endpoints]]
            local remote_line=$(sed -n "$((current_rule_start_line + 3))p" "$temp_config_file") # Assuming remote is 3 lines after [[endpoints]]
            local remark="None"
            if [[ "$remark_line" =~ #\ Remark:\ (.*) ]]; then
                remark="${BASH_REMATCH[1]}"
            fi
            local listen_val="N/A"
            if [[ "$listen_line" =~ listen\ =\ \"(.*)\" ]]; then
                listen_val="${BASH_REMATCH[1]}"
            fi
            local remote_val="N/A"
            if [[ "$remote_line" =~ remote\ =\ \"(.*)\" ]]; then
                remote_val="${BASH_REMATCH[1]}"
            fi
            rules_descs[$rule_count]="${rule_count}. Remark: ${remark} (Listen: ${listen_val}, Remote: ${remote_val})"
            echo "${rules_descs[$rule_count]}"
        elif [[ "$line" =~ ^\[[a-zA-Z_]+\]$ ]] && [ "$in_endpoint_block" -ne 0 ] && [ "$current_rule_start_line" -ne 0 ]; then
             # New section starts, signifies end of current endpoints block if we were in one
             rules_ends[$rule_count]=$((line_num - 1))
             in_endpoint_block=0 # reset
             current_rule_start_line=0
        fi
    done < "$temp_config_file"

    # Handle the last rule block if file ends before a new section
    if [ "$in_endpoint_block" -ne 0 ] && [ "$current_rule_start_line" -ne 0 ]; then
        rules_ends[$rule_count]=$line_num
    fi
    
    if [ "$rule_count" -eq 0 ]; then
        echo "No forwarding rules found."
        rm -f "$temp_config_file"
        return
    fi

    read -rp "Enter the number to delete (Press Enter to return): " choice
    rm -f "$temp_config_file" # Clean up temp file

    [ -z "$choice" ] && { echo "Returning to main menu."; return; }
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "$rule_count" ]; then
        echo "Invalid choice."
        return
    fi

    local chosen_start_line=${rules_starts[$choice]}
    local chosen_end_line=${rules_ends[$choice]}

    # Delete the block. Add 1 to chosen_end_line if it's the last block and no newline after.
    # A safer sed is to delete from start to end.
    # Ensure chosen_end_line is valid
    if [ "$chosen_end_line" -lt "$chosen_start_line" ]; then # Should not happen with current logic but good check
        echo "Error calculating rule block for deletion."
        return
    fi

    # Create a backup
    cp "$CONFIG_PATH" "${CONFIG_PATH}.bak"
    echo "Original config backed up to ${CONFIG_PATH}.bak"

    # Use sed to delete the lines.
    sed -i "${chosen_start_line},${chosen_end_line}d" "$CONFIG_PATH"
    
    # Remove potentially multiple blank lines left after deletion into a single one or none if at EOF
    # This awk command removes all blank lines.
    awk 'NF > 0' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp_clean" && mv "${CONFIG_PATH}.tmp_clean" "$CONFIG_PATH"
    
    echo "Forwarding rule $choice deleted."

    # Manage service after deletion
    if ! grep -q '^\\[\\[endpoints\\]\\]' "$CONFIG_PATH"; then
        systemctl stop realm &>/dev/null # stop first
        systemctl disable realm &>/dev/null
        realm_status="Installed (No Forwards)"
        realm_status_color="$YELLOW" # Changed color to yellow
        echo -e "${YELLOW}No forwarding rules left. Realm service has been stopped and disabled.${NC}"
    else
        echo "Restarting Realm service due to configuration change..."
        systemctl restart realm
        # Brief pause and check status
        sleep 1
        if systemctl is-active --quiet realm; then
            echo -e "${GREEN}Realm service restarted successfully.${NC}"
        else
            echo -e "${RED}Realm service failed to restart after rule deletion. Check logs.${NC}"
            journalctl -u realm.service -n 10 --no-pager
        fi
    fi
}

# Check Realm installation at startup
check_realm_installation

# Main Loop
while true; do
    show_menu
    read -rp "Select an option (1-6): " choice
    case $choice in
        1) add_forward ;;
        2) show_all_conf ;;
        3) delete_forward ;;
        4) manage_realm_service ;;
        5) uninstall_realm ;;
        6) echo "Exiting script."; exit 0 ;;
        *) echo -e "${RED}Invalid option: $choice${NC}" ;;
    esac
    read -n1 -r -p "Press any key to continue..."
done
