#!/bin/bash

# Colors for output
GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[0;33m"
BOLD="\033[1m"
NC="\033[0m" # No Color

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

# jq为可选依赖，如果不存在则采用grep方式
use_jq=false
if command -v jq &> /dev/null; then
    use_jq=true
fi

# Function to deploy Realm
deploy_realm() {
    mkdir -p /root/realm && cd /root/realm || { echo -e "${RED}Failed to access /root/realm directory.${NC}"; exit 1; }
    wget -qO realm.tar.gz https://github.com/zhboner/realm/releases/download/v2.6.2/realm-x86_64-unknown-linux-gnu.tar.gz
    if [ ! -f realm.tar.gz ]; then
        echo -e "${RED}Download realm.tar.gz failed. Please check network or URL.${NC}"
        exit 1
    fi
    tar -xzf realm.tar.gz && chmod +x realm
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
ExecStart=/root/realm/realm -c /root/realm/config.toml

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    # Initialize config.toml
    if [ ! -f /root/realm/config.toml ]; then
        cat <<EONET >/root/realm/config.toml
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
        return 0
    fi

    # Check if there are any endpoints configured
    if ! grep -q '^\[\[endpoints\]\]' /root/realm/config.toml; then
        echo -e "${RED}Inactive${NC}"
        echo -e "${YELLOW}No forwarding rules configured. Add rules before starting the service.${NC}"
        return 0
    fi

    echo -e "${RED}Inactive${NC}"
    echo "Attempting to fix Realm service..."

    # Check config file
    if [ ! -f "/root/realm/config.toml" ]; then
        echo -e "${RED}Error: config.toml not found${NC}"
        return 1
    fi

    # Remove duplicate lines in config
    awk '!seen[$0]++' /root/realm/config.toml > /root/realm/config.toml.tmp
    mv /root/realm/config.toml.tmp /root/realm/config.toml
    echo "Cleaned up duplicate lines in config.toml"

    # Ensure [network] section exists and is correct
    if ! grep -q '^\[network\]' /root/realm/config.toml; then
        cat <<EOF >>/root/realm/config.toml
[network]
no_tcp = false
use_udp = true
ipv6_only = false
EOF
        echo "Added missing [network] section to config.toml"
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
}

# Function to fetch server information
fetch_server_info() {
    meta_info=$(curl -s https://speed.cloudflare.com/meta)

    # 尝试使用 jq 解析
    if $use_jq && [ -n "$meta_info" ]; then
        asOrganization=$(echo "$meta_info" | jq -r '.asOrganization // "N/A"')
        colo=$(echo "$meta_info" | jq -r '.colo // "N/A"')
        country=$(echo "$meta_info" | jq -r '.country // "N/A"')
    else
        # 后备方案，无 jq 时使用 grep 提取
        # 去除 -P 使用：使用普通 grep 来简化
        # 假设 JSON 中字段顺序稳定。如果不稳定建议安装 jq
        asOrganization=$(echo "$meta_info" | grep '"asOrganization":"' | sed 's/.*"asOrganization":"\([^"]*\)".*/\1/' || echo "N/A")
        colo=$(echo "$meta_info" | grep '"colo":"' | sed 's/.*"colo":"\([^"]*\)".*/\1/' || echo "N/A")
        country=$(echo "$meta_info" | grep '"country":"' | sed 's/.*"country":"\([^"]*\)".*/\1/' || echo "N/A")
    fi

    # Fetch IP information using ip.sb
    ipv4=$(curl -s ipv4.ip.sb || echo "N/A")
    ipv6=$(curl -s ipv6.ip.sb || echo "N/A")

    # Check if IPv6 is available
    has_ipv6=false
    if [ "$ipv6" != "N/A" ] && [[ "$ipv6" =~ ":" ]]; then
        has_ipv6=true
    fi

    # Fallback to combined API if individual requests fail
    if [ "$ipv4" = "N/A" ] && [ "$ipv6" = "N/A" ]; then
        combined_ip=$(curl -s ip.sb || echo "N/A")
        if [[ $combined_ip =~ .*:.* ]]; then
            ipv6=$combined_ip
            has_ipv6=true
        else
            ipv4=$combined_ip
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

# Function to create Realm service file (已在 deploy_realm 中创建，不重复调用)
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
ExecStart=/root/realm/realm -c /root/realm/config.toml

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
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        echo -e "${RED}Invalid remote port number.${NC}"
        return 1
    fi
    # 简单IP校验(IPv4/IPv6略简化)
    if [[ ! "$ip" =~ ^[0-9a-fA-F:.]+$ ]]; then
        echo -e "${RED}Invalid IP address format.${NC}"
        return 1
    fi

    # Check if [network] section exists, if not add it
    if ! grep -q '^\[network\]' /root/realm/config.toml; then
        cat <<EOF >> /root/realm/config.toml
[network]
no_tcp = false
use_udp = true
ipv6_only = false
EOF
    fi

    # Append new endpoint
    cat <<EOF >> /root/realm/config.toml

[[endpoints]]
# Remark: $remark
listen = "0.0.0.0:$local_port"
remote = "$ip:$port"
use_udp = $use_udp
use_tcp = $use_tcp
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
    IFS=$'\n' read -d '' -r -a lines < <(grep -n 'listen =' /root/realm/config.toml || true)
    if [ ${#lines[@]} -eq 0 ]; then
        echo "No forwarding rules found."
        return
    fi
    local index=1
    for line in "${lines[@]}"; do
        local line_number=$(echo "$line" | cut -d ':' -f1)
        local listen=$(sed -n "${line_number}p" /root/realm/config.toml | cut -d '"' -f2)
        local remote=$(sed -n "$((line_number + 1))p" /root/realm/config.toml | cut -d '"' -f2)
        local remark=$(sed -n "$((line_number - 1))p" /root/realm/config.toml | grep "^# Remark:" | cut -d ':' -f2 | xargs)
        echo "${index}. Remark: ${remark:-None}"
        echo "   Listen: ${listen}, Remote: ${remote}"
        ((index++))
    done
}

# Function to delete a forwarding rule
delete_forward() {
    echo -e "${BOLD}Delete Forwarding Rule${NC}"
    IFS=$'\n' read -d '' -r -a lines < <(grep -n '^\[\[endpoints\]\]' /root/realm/config.toml || true)
    if [ ${#lines[@]} -eq 0 ]; then
        echo "No forwarding rules found."
        return
    fi
    local index=1
    declare -A rule_map
    for line in "${lines[@]}"; do
        local line_number=$(echo "$line" | cut -d ':' -f1)
        local remark=$(sed -n "$((line_number + 1))p" /root/realm/config.toml | grep "^# Remark:" | cut -d ':' -f2 | xargs)
        local listen=$(sed -n "$((line_number + 2))p" /root/realm/config.toml | cut -d '"' -f2)
        local remote=$(sed -n "$((line_number + 3))p" /root/realm/config.toml | cut -d '"' -f2)
        echo "${index}. Remark: ${remark:-None}"
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
    local next_line=$(awk "NR>$chosen_line && /^\[\[endpoints\]\]/{print NR; exit}" /root/realm/config.toml)
    local end_line=${next_line:-$(wc -l < /root/realm/config.toml)}
    end_line=$((end_line - 1))
    sed -i "${chosen_line},${end_line}d" /root/realm/config.toml
    sed -i '/^\s*$/d' /root/realm/config.toml
    echo "Forwarding rule deleted."
    # Manage service after deletion
    if ! grep -q '^\[\[endpoints\]\]' /root/realm/config.toml; then
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
        6) echo "Exiting script."; exit 0 ;;
        *) echo -e "${RED}Invalid option: $choice${NC}" ;;
    esac
    read -n1 -r -p "Press any key to continue..."
done
