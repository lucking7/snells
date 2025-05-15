#!/bin/bash

# Colors for output
GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[0;33m"
BOLD="\033[1m"
NC="\033[0m" # No Color

# Configuration path variable
CONFIG_PATH="/root/.realm/config.toml"

# Function to deploy Realm
deploy_realm() {
    mkdir -p /root/realm && cd /root/realm
    
    # Get latest version from GitHub API
    _version=$(curl -s https://api.github.com/repos/zhboner/realm/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    
    if [ -z "$_version" ]; then
        echo -e "${RED}Failed to get version number. Please check if you can connect to GitHub API.${NC}"
        return 1
    else
        echo -e "Latest version: ${_version}"
    fi
    
    # Detect architecture
    arch=$(uname -m)
    os=$(uname -s | tr '[:upper:]' '[:lower:]')
    
    case "$arch-$os" in
        x86_64-linux)
            download_url="https://github.com/zhboner/realm/releases/download/${_version}/realm-x86_64-unknown-linux-gnu.tar.gz"
            ;;
        x86_64-darwin)
            download_url="https://github.com/zhboner/realm/releases/download/${_version}/realm-x86_64-apple-darwin.tar.gz"
            ;;
        aarch64-linux)
            download_url="https://github.com/zhboner/realm/releases/download/${_version}/realm-aarch64-unknown-linux-gnu.tar.gz"
            ;;
        aarch64-darwin)
            download_url="https://github.com/zhboner/realm/releases/download/${_version}/realm-aarch64-apple-darwin.tar.gz"
            ;;
        arm-linux)
            download_url="https://github.com/zhboner/realm/releases/download/${_version}/realm-arm-unknown-linux-gnueabi.tar.gz"
            ;;
        *)
            echo -e "${RED}Unsupported architecture: $arch-$os${NC}"
            return 1
            ;;
    esac
    
    wget -qO realm.tar.gz "$download_url"
    tar -xzf realm.tar.gz && chmod +x realm

    # Create directories for configs
    mkdir -p /root/.realm
    
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
WorkingDirectory=/root/realm
ExecStart=/root/realm/realm -c ${CONFIG_PATH}

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    # Initialize config.toml
    if [ ! -f "$CONFIG_PATH" ]; then
        cat <<EONET >${CONFIG_PATH}
[network]
no_tcp = false
use_udp = true
ipv6_only = false
EONET
        echo -e "${GREEN}[network] configuration added to config.toml.${NC}"
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
    rm -rf /root/realm
    if [ -f "/etc/crontab" ]; then
        sed -i '/realm/d' /etc/crontab
    else
        echo -e "${YELLOW}Warning: /etc/crontab not found. Skipping crontab cleanup.${NC}"
    fi
    
    read -e -p "Do you want to delete configuration files? (Y/N, default N): " delete_config
    delete_config=${delete_config:-N}

    if [[ $delete_config == "Y" || $delete_config == "y" ]]; then
        rm -rf /root/.realm
        echo -e "${RED}Configuration files deleted.${NC}"
    else
        echo -e "Configuration files preserved."
    fi
    
    realm_status="Not Installed"
    realm_status_color="$RED"
    echo -e "${RED}Realm has been uninstalled.${NC}"
}

# Function to check Realm installation
check_realm_installation() {
    if [ -f "/root/realm/realm" ]; then
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
    else
        echo -e "${RED}Inactive${NC}"
        echo "Attempting to fix Realm service..."

        # Check config file
        if [ ! -f "$CONFIG_PATH" ]; then
            echo -e "${RED}Error: config.toml not found${NC}"
            return 1
        fi

        # Remove duplicate lines in config
        awk '!seen[$0]++' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp"
        mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
        echo "Cleaned up duplicate lines in config.toml"

        # Ensure [network] section exists and is correct
        if ! grep -q '^\[network\]' "$CONFIG_PATH"; then
            echo "[network]" >> "$CONFIG_PATH"
            echo "no_tcp = false" >> "$CONFIG_PATH"
            echo "use_udp = true" >> "$CONFIG_PATH"
            echo "ipv6_only = false" >> "$CONFIG_PATH"
            echo "Added missing [network] section to config.toml"
        fi

        # Check for at least one valid endpoint
        if ! grep -q '^\[\[endpoints\]\]' "$CONFIG_PATH"; then
            echo -e "${YELLOW}Warning: No endpoints found in config.toml${NC}"
        fi

        # Check realm executable
        if [ ! -x "/root/realm/realm" ]; then
            echo -e "${RED}Error: realm executable not found or not executable${NC}"
            return 1
        fi

        # Attempt to restart the service
        echo "Attempting to restart Realm service..."
        systemctl restart realm
        sleep 2

        if systemctl is-active --quiet realm; then
            echo -e "${GREEN}Realm service successfully restarted${NC}"
        else
            echo -e "${RED}Failed to restart Realm service${NC}"
            echo "Checking logs for errors:"
            journalctl -u realm.service -n 20 --no-pager
            return 1
        fi
    fi
}

# Function to fetch server information
fetch_server_info() {
    # Fetch Cloudflare metadata
    meta_info=$(curl -s https://speed.cloudflare.com/meta)
    asOrganization=$(echo "$meta_info" | grep -oP '(?<="asOrganization":")[^"]+' || echo "N/A")
    colo=$(echo "$meta_info" | grep -oP '(?<="colo":")[^"]+' || echo "N/A")
    country=$(echo "$meta_info" | grep -oP '(?<="country":")[^"]+' || echo "N/A")
    
    # Fetch IP information using ip.sb
    ipv4=$(curl ipv4.ip.sb || echo "N/A")
    ipv6=$(curl ipv6.ip.sb || echo "N/A")
    
    # Check if IPv6 is available
    has_ipv6=false
    [ "$ipv6" != "N/A" ] && has_ipv6=true

    # Fallback to combined API if individual requests fail
    if [ "$ipv4" = "N/A" ] && [ "$ipv6" = "N/A" ]; then
        combined_ip=$(curl ip.sb || echo "N/A")
        [[ $combined_ip =~ .*:.* ]] && ipv6=$combined_ip && has_ipv6=true || ipv4=$combined_ip
    fi
}

# Functions for panel management
update_panel_status() {
    if [ -f "/root/realm/web/realm_web" ]; then
        panel_status="Installed"
        panel_status_color="$GREEN"
    else
        panel_status="Not Installed"
        panel_status_color="$RED"
    fi
}

check_panel_service_status() {
    if systemctl is-active --quiet realm-panel; then
        panel_service_status="Running"
        panel_service_status_color="$GREEN"
    else
        panel_service_status="Stopped"
        panel_service_status_color="$RED"
    fi
}

install_panel() {
    echo "Installing Realm Web Panel..."
    
    # Detect architecture
    arch=$(uname -m)
    case "$arch" in
        x86_64)
            panel_file="realm-panel-linux-amd64.zip"
            ;;
        aarch64|arm64)
            panel_file="realm-panel-linux-arm64.zip"
            ;;
        *)
            echo -e "${RED}Unsupported architecture: $arch${NC}"
            return 1
            ;;
    esac

    cd /root/realm 

    # Download panel files from GitHub
    echo "Downloading panel files from GitHub..."
    echo "Detected architecture: $arch, will download: $panel_file"
    
    # Download URL - adjust this to the correct location
    download_url="https://github.com/wcwq98/realm/releases/download/v2.1/${panel_file}"
    if ! wget -O "${panel_file}" "$download_url"; then
        echo -e "${RED}Download failed. Please check your network connection or try again later.${NC}"
        return 1
    fi
    
    mkdir -p web
    # Extract files
    unzip "${panel_file}" -d /root/realm/web

    cd web
    # Set permissions
    chmod +x realm_web
    
    # Create service file
    echo "[Unit]
Description=Realm Web Panel
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/root/realm/web
ExecStart=/root/realm/web/realm_web
Restart=on-failure

[Install]
WantedBy=multi-user.target" > /etc/systemd/system/realm-panel.service

    # Reload systemd and start service
    systemctl daemon-reload
    systemctl enable realm-panel
    systemctl start realm-panel

    update_panel_status
    echo -e "${GREEN}Realm panel installed successfully.${NC}"
}

start_panel() {
    systemctl start realm-panel
    echo -e "${GREEN}Panel service started.${NC}"
    check_panel_service_status
}

stop_panel() {
    systemctl stop realm-panel
    echo -e "${RED}Panel service stopped.${NC}"
    check_panel_service_status
}

uninstall_panel() {
    systemctl stop realm-panel
    systemctl disable realm-panel
    rm -f /etc/systemd/system/realm-panel.service
    systemctl daemon-reload

    rm -rf /root/realm/web
    echo -e "${RED}Panel has been uninstalled.${NC}"

    update_panel_status
}

panel_management() {
    clear
    echo -e "${BOLD}=== Realm Panel Management ===${NC}"
    echo "1. Install Panel"
    echo "2. Start Panel"
    echo "3. Stop Panel"
    echo "4. Uninstall Panel"
    echo "5. Return to Main Menu"
    read -rp "Select an option: " panel_choice
    case $panel_choice in
        1) install_panel ;;
        2) start_panel ;;
        3) stop_panel ;;
        4) uninstall_panel ;;
        5) return ;;
        *) echo -e "${RED}Invalid option${NC}" ;;
    esac
    read -n1 -r -p "Press any key to continue..."
}

# Function to display the menu
show_menu() {
    fetch_server_info
    update_panel_status
    check_panel_service_status
    clear
    echo -e "${BOLD}=== Realm Relay Management ===${NC}"
    echo "1. Add Realm Forward"
    echo "2. View Realm Forwards"
    echo "3. Delete Realm Forward"
    echo "4. Manage Realm Service"
    echo "5. Uninstall Realm"
    echo "6. Panel Management"
    echo "7. Exit"
    echo "------------------------------"
    echo -e "Realm Status: ${realm_status_color}${realm_status}${NC}"
    echo -n "Realm Service: "
    check_realm_service_status
    echo -e "Panel Status: ${panel_status_color}${panel_status}${NC}"
    echo -e "Panel Service: ${panel_service_status_color}${panel_service_status}${NC}"
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

    # Initialize random seed
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

# Function to create Realm service file
create_realm_service() {
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
WorkingDirectory=/root/realm
ExecStart=/root/realm/realm -c ${CONFIG_PATH}

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    echo -e "${GREEN}Realm service file created.${NC}"
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
    
    # Check server IPv6 capability
    fetch_server_info
    
    # Select IP version
    if [ "$has_ipv6" = true ]; then
        echo "Choose IP version:"
        echo "1. IPv4"
        echo "2. IPv6"
        echo "3. Both IPv4 and IPv6 (Default)"
        read -rp "Choice [3]: " ip_version_choice
        ip_version_choice=${ip_version_choice:-3}
        case $ip_version_choice in
            1) use_ipv4=true; use_ipv6=false; ipv6_only=false ;;
            2) use_ipv4=false; use_ipv6=true; ipv6_only=true ;;
            3) use_ipv4=true; use_ipv6=true; ipv6_only=false ;;
            *) echo "Invalid choice. Defaulting to Both."; use_ipv4=true; use_ipv6=true; ipv6_only=false ;;
        esac
    else
        echo "IPv6 is not available on this server. Using IPv4 only."
        use_ipv4=true; use_ipv6=false; ipv6_only=false
    fi

    # Select transport protocol
    echo "Choose Transport Protocol:"
    echo "1. TCP"
    echo "2. UDP"
    echo "3. Both TCP and UDP (Default)"
    read -rp "Choice [3]: " transport_choice
    transport_choice=${transport_choice:-3}
    case $transport_choice in
        1) use_tcp=true; use_udp=false; no_tcp=false ;;
        2) use_tcp=false; use_udp=true; no_tcp=true ;;
        3) use_tcp=true; use_udp=true; no_tcp=false ;;
        *) echo "Invalid choice. Defaulting to Both."; use_tcp=true; use_udp=true; no_tcp=false ;;
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
    read -rp "Enter remote IP or hostname: " ip
    read -rp "Enter remote port: " port
    read -rp "Enter remark: " remark

    # Validate inputs
    if ! [[ "$local_port" =~ ^[0-9]+$ ]] || [ "$local_port" -lt 1 ] || [ "$local_port" -gt 65535 ]; then
        echo -e "${RED}Invalid local port number.${NC}"
        return 1
    fi
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        echo -e "${RED}Invalid remote port number.${NC}"
        return 1
    fi

    # Check if [network] section exists, if not add it
    if ! grep -q '^\[network\]' "$CONFIG_PATH"; then
        cat <<EOF >> "$CONFIG_PATH"
[network]
no_tcp = $no_tcp
use_udp = $use_udp
ipv6_only = $ipv6_only
EOF
    else
        # Update the network section
        sed -i "s/^no_tcp = .*$/no_tcp = $no_tcp/" "$CONFIG_PATH"
        sed -i "s/^use_udp = .*$/use_udp = $use_udp/" "$CONFIG_PATH"
        sed -i "s/^ipv6_only = .*$/ipv6_only = $ipv6_only/" "$CONFIG_PATH"
    fi

    # Append new endpoint
    cat <<EOF >> "$CONFIG_PATH"

[[endpoints]]
# Remark: $remark
listen = "0.0.0.0:$local_port"
remote = "$ip:$port"
EOF

    # Restart and enable service
    systemctl enable realm
    systemctl restart realm
    echo -e "${GREEN}Forwarding rule added and Realm service restarted.${NC}"
}

# Function to add port range forwarding
add_port_range_forward() {
    echo -e "${BOLD}Add Port Range Forwarding${NC}"
    
    read -rp "Enter remote IP or hostname: " ip
    read -rp "Enter local start port: " start_port
    read -rp "Enter local end port: " end_port
    read -rp "Enter remote port: " remote_port
    read -rp "Enter remark prefix: " remark_prefix

    # Validate inputs
    if ! [[ "$start_port" =~ ^[0-9]+$ ]] || [ "$start_port" -lt 1 ] || [ "$start_port" -gt 65535 ]; then
        echo -e "${RED}Invalid start port number.${NC}"
        return 1
    fi
    if ! [[ "$end_port" =~ ^[0-9]+$ ]] || [ "$end_port" -lt 1 ] || [ "$end_port" -gt 65535 ]; then
        echo -e "${RED}Invalid end port number.${NC}"
        return 1
    fi
    if [ "$start_port" -gt "$end_port" ]; then
        echo -e "${RED}Start port cannot be greater than end port.${NC}"
        return 1
    fi
    if ! [[ "$remote_port" =~ ^[0-9]+$ ]] || [ "$remote_port" -lt 1 ] || [ "$remote_port" -gt 65535 ]; then
        echo -e "${RED}Invalid remote port number.${NC}"
        return 1
    fi

    # Add each port in the range
    for ((port=$start_port; port<=$end_port; port++)); do
        cat <<EOF >> "$CONFIG_PATH"

[[endpoints]]
# Remark: ${remark_prefix}_${port}
listen = "0.0.0.0:$port"
remote = "$ip:$remote_port"
EOF
    done

    # Restart and enable service
    systemctl enable realm
    systemctl restart realm
    echo -e "${GREEN}Port range forwarding added and Realm service restarted.${NC}"
    echo -e "Added ports from $start_port to $end_port forwarded to $ip:$remote_port"
}

# Function to view all forwarding rules
show_all_conf() {
    echo -e "${BOLD}Current Forwarding Rules:${NC}"
    IFS=$'\n' read -d '' -r -a lines < <(grep -n 'listen =' "$CONFIG_PATH" || true)
    if [ ${#lines[@]} -eq 0 ]; then
        echo "No forwarding rules found."
        return
    fi
    local index=1
    for line in "${lines[@]}"; do
        local line_number=$(echo "$line" | cut -d ':' -f1)
        local listen=$(sed -n "${line_number}p" "$CONFIG_PATH" | cut -d '"' -f2)
        local remote=$(sed -n "$((line_number + 1))p" "$CONFIG_PATH" | cut -d '"' -f2)
        local remark=$(sed -n "$((line_number - 1))p" "$CONFIG_PATH" | grep "^# Remark:" | cut -d ':' -f2 | xargs)
        echo "${index}. Remark: ${remark}"
        echo "   Listen: ${listen}, Remote: ${remote}"
        ((index++))
    done
}

# Function to delete a forwarding rule
delete_forward() {
    echo -e "${BOLD}Delete Forwarding Rule${NC}"
    IFS=$'\n' read -d '' -r -a lines < <(grep -n '^\[\[endpoints\]\]' "$CONFIG_PATH" || true)
    if [ ${#lines[@]} -eq 0 ]; then
        echo "No forwarding rules found."
        return
    fi
    local index=1
    declare -A rule_map
    for line in "${lines[@]}"; do
        local line_number=$(echo "$line" | cut -d ':' -f1)
        local remark=$(sed -n "$((line_number + 1))p" "$CONFIG_PATH" | grep "^# Remark:" | cut -d ':' -f2 | xargs)
        local listen=$(sed -n "$((line_number + 2))p" "$CONFIG_PATH" | cut -d '"' -f2)
        local remote=$(sed -n "$((line_number + 3))p" "$CONFIG_PATH" | cut -d '"' -f2)
        echo "${index}. Remark: ${remark}"
        echo "   Listen: ${listen}, Remote: ${remote}"
        rule_map[$index]="$line_number"
        ((index++))
    done
    read -rp "Enter the number to delete (Press Enter to return): " choice
    [ -z "$choice" ] && { echo "Returning to main menu."; return; }
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -ge "$index" ]; then
        echo "Invalid choice."
        return
    fi
    local chosen_line=${rule_map[$choice]}
    local next_line=$(awk "NR>$chosen_line && /^\[\[endpoints\]\]/{print NR; exit}" "$CONFIG_PATH")
    local end_line=${next_line:-$(wc -l < "$CONFIG_PATH")}
    end_line=$((end_line - 1))
    sed -i "${chosen_line},${end_line}d" "$CONFIG_PATH"
    sed -i '/^\s*$/d' "$CONFIG_PATH"
    echo "Forwarding rule deleted."
    # Manage service after deletion
    if ! grep -q '^\[\[endpoints\]\]' "$CONFIG_PATH"; then
        systemctl stop realm
        systemctl disable realm
        realm_status="Installed (No Forwards)"
        realm_status_color="$GREEN"
        echo -e "${RED}No forwarding rules left. Realm service has been stopped and disabled.${NC}"
    else
        systemctl restart realm
        echo -e "${GREEN}Realm service restarted.${NC}"
    fi
}

# Check Realm installation at startup
check_realm_installation

# Main Loop
while true; do
    show_menu
    read -rp "Select an option: " choice
    case $choice in
        1) add_forward ;;
        2) show_all_conf ;;
        3) delete_forward ;;
        4) manage_realm_service ;;
        5) uninstall_realm ;;
        6) panel_management ;;
        7) echo "Exiting script."; exit 0 ;;
        *) echo -e "${RED}Invalid option: $choice${NC}" ;;
    esac
    read -n1 -r -p "Press any key to continue..."
done
