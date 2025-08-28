#!/bin/bash

# Socat Forward Manager - Professional Network Traffic Manager
# Author: Advanced Network Tools
# Version: 2.0

# Color codes for better UI
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Configuration file path
CONFIG_FILE="$HOME/.socat_manager.conf"
PID_DIR="$HOME/.socat_pids"
LOG_DIR="$HOME/.socat_logs"
SYSTEMD_DIR="/etc/systemd/system"

# Ensure directories exist
mkdir -p "$PID_DIR" "$LOG_DIR"

# Global variables
SCRIPT_VERSION="2.0"

# Function to print banner
print_banner() {
    clear
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                    ${BOLD}SOCAT FORWARD MANAGER${NC}${CYAN}                    ║${NC}"
    echo -e "${CYAN}║                Professional Network Traffic Manager           ║${NC}"
    echo -e "${CYAN}║                        Version ${SCRIPT_VERSION}                           ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo
}

# Function to get IP information
get_ip_info() {
    echo -e "${BOLD}${BLUE}Network Information:${NC}"
    echo -e "${CYAN}─────────────────────────────────────────${NC}"
    
    # Get IPv4 information
    echo -e "${YELLOW}IPv4 Information:${NC}"
    local ipv4=$(curl -s -4 ifconfig.me 2>/dev/null || echo "N/A")
    if [ "$ipv4" != "N/A" ]; then
        echo -e "  ${GREEN}Public IPv4:${NC} $ipv4"
        
        # Get geolocation and ASN info
        local ip_info=$(curl -s "http://ip-api.com/json/$ipv4?fields=country,regionName,city,isp,as,org" 2>/dev/null)
        if [ $? -eq 0 ] && [ "$ip_info" != "" ]; then
            local country=$(echo "$ip_info" | grep -o '"country":"[^"]*"' | cut -d'"' -f4)
            local region=$(echo "$ip_info" | grep -o '"regionName":"[^"]*"' | cut -d'"' -f4)
            local city=$(echo "$ip_info" | grep -o '"city":"[^"]*"' | cut -d'"' -f4)
            local isp=$(echo "$ip_info" | grep -o '"isp":"[^"]*"' | cut -d'"' -f4)
            local asn=$(echo "$ip_info" | grep -o '"as":"[^"]*"' | cut -d'"' -f4)
            
            echo -e "  ${GREEN}Location:${NC} $city, $region, $country"
            echo -e "  ${GREEN}ISP:${NC} $isp"
            echo -e "  ${GREEN}ASN:${NC} $asn"
        fi
    else
        echo -e "  ${RED}Public IPv4: Not available${NC}"
    fi
    
    # Get IPv6 information
    echo -e "${YELLOW}IPv6 Information:${NC}"
    local ipv6=$(curl -s -6 ifconfig.me 2>/dev/null || echo "N/A")
    if [ "$ipv6" != "N/A" ]; then
        echo -e "  ${GREEN}Public IPv6:${NC} $ipv6"
    else
        echo -e "  ${RED}Public IPv6: Not available${NC}"
    fi
    
    # Get local interfaces
    echo -e "${YELLOW}Local Interfaces:${NC}"
    local interfaces=$(ip addr show 2>/dev/null | grep -E "inet[6]?" | grep -v "127.0.0.1\|::1" | awk '{print $2}' | head -5)
    if [ "$interfaces" != "" ]; then
        echo "$interfaces" | while read -r line; do
            echo -e "  ${GREEN}Local:${NC} $line"
        done
    else
        # Fallback for macOS
        ifconfig 2>/dev/null | grep -E "inet[6]?" | grep -v "127.0.0.1\|::1" | head -5 | while read -r line; do
            echo -e "  ${GREEN}Local:${NC} $(echo $line | awk '{print $2}')"
        done
    fi
    
    echo -e "${CYAN}─────────────────────────────────────────${NC}"
    echo
}

# Function to load configuration
load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "# Socat Manager Configuration" > "$CONFIG_FILE"
        echo "# Format: ID|NAME|PROTOCOL|IP_VERSION|LISTEN_PORT|TARGET_HOST|TARGET_PORT|STATUS|SYSTEMD" >> "$CONFIG_FILE"
    fi
}

# Function to save rule
save_rule() {
    local id="$1"
    local name="$2"
    local protocol="$3"
    local ip_version="$4"
    local listen_port="$5"
    local target_host="$6"
    local target_port="$7"
    local status="$8"
    local systemd="$9"
    
    echo "${id}|${name}|${protocol}|${ip_version}|${listen_port}|${target_host}|${target_port}|${status}|${systemd}" >> "$CONFIG_FILE"
}

# Function to get next available ID
get_next_id() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "1"
        return
    fi
    
    local max_id=$(grep -v "^#" "$CONFIG_FILE" | cut -d'|' -f1 | sort -n | tail -1)
    if [ "$max_id" = "" ]; then
        echo "1"
    else
        echo $((max_id + 1))
    fi
}

# Function to create systemd service
create_systemd_service() {
    local id="$1"
    local name="$2"
    local protocol="$3"
    local ip_version="$4"
    local listen_port="$5"
    local target_host="$6"
    local target_port="$7"
    
    local service_name="socat-forward-${id}"
    local service_file="${SYSTEMD_DIR}/${service_name}.service"
    local log_file="${LOG_DIR}/socat_${id}.log"
    
    # Build socat commands based on protocol
    local commands=""
    
    if [ "$protocol" = "TCP" ] || [ "$protocol" = "BOTH" ]; then
        local listen_addr="TCP-LISTEN"
        local target_addr="TCP"
        
        case "$ip_version" in
            "4") listen_addr="TCP4-LISTEN"; target_addr="TCP4" ;;
            "6") listen_addr="TCP6-LISTEN"; target_addr="TCP6" ;;
        esac
        
        commands="ExecStart=/usr/bin/socat ${listen_addr}:${listen_port},reuseaddr,fork ${target_addr}:${target_host}:${target_port}"
    fi
    
    if [ "$protocol" = "UDP" ] || [ "$protocol" = "BOTH" ]; then
        local listen_addr="UDP-LISTEN"
        local target_addr="UDP"
        
        case "$ip_version" in
            "4") listen_addr="UDP4-LISTEN"; target_addr="UDP4" ;;
            "6") listen_addr="UDP6-LISTEN"; target_addr="UDP6" ;;
        esac
        
        if [ "$protocol" = "BOTH" ]; then
            # For BOTH protocol, we need a separate service for UDP
            local udp_service_name="socat-forward-${id}-udp"
            local udp_service_file="${SYSTEMD_DIR}/${udp_service_name}.service"
            
            cat > "$udp_service_file" << EOF
[Unit]
Description=Socat UDP Forward ${name} (ID: ${id})
After=network.target
Wants=network.target

[Service]
Type=simple
User=socat
Group=socat
ExecStart=/usr/bin/socat ${listen_addr}:${listen_port},reuseaddr,fork ${target_addr}:${target_host}:${target_port}
Restart=always
RestartSec=3
StandardOutput=append:${log_file}
StandardError=append:${log_file}
LimitNOFILE=infinity
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
        else
            commands="ExecStart=/usr/bin/socat ${listen_addr}:${listen_port},reuseaddr,fork ${target_addr}:${target_host}:${target_port}"
        fi
    fi
    
    # Create main service file
    cat > "$service_file" << EOF
[Unit]
Description=Socat ${protocol} Forward ${name} (ID: ${id})
After=network.target
Wants=network.target

[Service]
Type=simple
User=socat
Group=socat
${commands}
Restart=always
RestartSec=3
StandardOutput=append:${log_file}
StandardError=append:${log_file}
LimitNOFILE=infinity
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF

    echo "$service_name"
}

# Function to ensure socat user exists
ensure_socat_user() {
    if ! id "socat" &>/dev/null; then
        echo -e "${YELLOW}Creating socat system user...${NC}"
        useradd --system --no-create-home --shell /bin/false socat
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✓ Socat user created successfully${NC}"
        else
            echo -e "${RED}✗ Failed to create socat user${NC}"
            return 1
        fi
    fi
}

# Function to start forwarding rule
start_forward() {
    local id="$1"
    local protocol="$2"
    local ip_version="$3"
    local listen_port="$4"
    local target_host="$5"
    local target_port="$6"
    local use_systemd="$7"
    local name="$8"
    
    if [ "$use_systemd" = "true" ]; then
        # Use systemd
        ensure_socat_user
        local service_name=$(create_systemd_service "$id" "$name" "$protocol" "$ip_version" "$listen_port" "$target_host" "$target_port")
        
        systemctl daemon-reload
        systemctl enable "$service_name"
        systemctl start "$service_name"
        
        # For BOTH protocol, also start UDP service
        if [ "$protocol" = "BOTH" ]; then
            systemctl enable "socat-forward-${id}-udp"
            systemctl start "socat-forward-${id}-udp"
        fi
        
        if systemctl is-active --quiet "$service_name"; then
            echo -e "${GREEN}✓ Forward rule started successfully with systemd${NC}"
        else
            echo -e "${RED}✗ Failed to start systemd service${NC}"
            return 1
        fi
    else
        # Use traditional method
        local pid_file="${PID_DIR}/socat_${id}.pid"
        local log_file="${LOG_DIR}/socat_${id}.log"
        
        # Build socat command based on protocol and IP version
        local listen_addr=""
        local target_addr=""
        
        case "$ip_version" in
            "4")
                listen_addr="TCP4-LISTEN"
                target_addr="TCP4"
                ;;
            "6")
                listen_addr="TCP6-LISTEN"
                target_addr="TCP6"
                ;;
            "46")
                listen_addr="TCP-LISTEN"
                target_addr="TCP"
                ;;
        esac
        
        if [ "$protocol" = "UDP" ]; then
            case "$ip_version" in
                "4")
                    listen_addr="UDP4-LISTEN"
                    target_addr="UDP4"
                    ;;
                "6")
                    listen_addr="UDP6-LISTEN"
                    target_addr="UDP6"
                    ;;
                "46")
                    listen_addr="UDP-LISTEN"
                    target_addr="UDP"
                    ;;
            esac
        elif [ "$protocol" = "BOTH" ]; then
            # Start TCP first
            local tcp_cmd="socat ${listen_addr}:${listen_port},reuseaddr,fork ${target_addr}:${target_host}:${target_port}"
            echo "Executing TCP: $tcp_cmd" > "$log_file"
            nohup $tcp_cmd >> "$log_file" 2>&1 &
            local tcp_pid=$!
            
            # Start UDP
            case "$ip_version" in
                "4")
                    listen_addr="UDP4-LISTEN"
                    target_addr="UDP4"
                    ;;
                "6")
                    listen_addr="UDP6-LISTEN"
                    target_addr="UDP6"
                    ;;
                "46")
                    listen_addr="UDP-LISTEN"
                    target_addr="UDP"
                    ;;
            esac
            
            local udp_cmd="socat ${listen_addr}:${listen_port},reuseaddr,fork ${target_addr}:${target_host}:${target_port}"
            echo "Executing UDP: $udp_cmd" >> "$log_file"
            nohup $udp_cmd >> "$log_file" 2>&1 &
            local udp_pid=$!
            
            # Save both PIDs
            echo "$tcp_pid,$udp_pid" > "$pid_file"
            echo -e "${GREEN}✓ Forward rule started successfully (TCP PID: $tcp_pid, UDP PID: $udp_pid)${NC}"
        else
            # Single protocol
            local cmd="socat ${listen_addr}:${listen_port},reuseaddr,fork ${target_addr}:${target_host}:${target_port}"
            
            echo "Executing: $cmd" > "$log_file"
            nohup $cmd >> "$log_file" 2>&1 &
            local socat_pid=$!
            
            # Save PID
            echo "$socat_pid" > "$pid_file"
            echo -e "${GREEN}✓ Forward rule started successfully (PID: $socat_pid)${NC}"
        fi
    fi
    
    # Update status in config
    sed -i.bak "s/^${id}|.*|STOPPED|/${id}|$(grep "^${id}|" "$CONFIG_FILE" | cut -d'|' -f2-7)|RUNNING|/" "$CONFIG_FILE"
}

# Function to stop forwarding rule
stop_forward() {
    local id="$1"
    local rule_info=$(grep "^${id}|" "$CONFIG_FILE")
    local use_systemd=$(echo "$rule_info" | cut -d'|' -f9)
    local protocol=$(echo "$rule_info" | cut -d'|' -f3)
    
    if [ "$use_systemd" = "true" ]; then
        # Stop systemd service
        local service_name="socat-forward-${id}"
        systemctl stop "$service_name"
        systemctl disable "$service_name"
        rm -f "${SYSTEMD_DIR}/${service_name}.service"
        
        # For BOTH protocol, also stop UDP service
        if [ "$protocol" = "BOTH" ]; then
            systemctl stop "socat-forward-${id}-udp"
            systemctl disable "socat-forward-${id}-udp"
            rm -f "${SYSTEMD_DIR}/socat-forward-${id}-udp.service"
        fi
        
        systemctl daemon-reload
        echo -e "${GREEN}✓ Forward rule stopped and systemd service removed${NC}"
    else
        # Stop traditional method
        local pid_file="${PID_DIR}/socat_${id}.pid"
        
        if [ -f "$pid_file" ]; then
            local pids=$(cat "$pid_file")
            if [[ "$pids" == *","* ]]; then
                # Multiple PIDs (BOTH protocol)
                IFS=',' read -ra PID_ARRAY <<< "$pids"
                for pid in "${PID_ARRAY[@]}"; do
                    if kill -0 "$pid" 2>/dev/null; then
                        kill "$pid"
                    fi
                done
            else
                # Single PID
                if kill -0 "$pids" 2>/dev/null; then
                    kill "$pids"
                fi
            fi
            rm -f "$pid_file"
            echo -e "${GREEN}✓ Forward rule stopped successfully${NC}"
        else
            echo -e "${YELLOW}⚠ PID file not found${NC}"
        fi
    fi
    
    # Update status in config
    sed -i.bak "s/^${id}|.*|RUNNING|/${id}|$(grep "^${id}|" "$CONFIG_FILE" | cut -d'|' -f2-7)|STOPPED|/" "$CONFIG_FILE"
}

# Function to check if rule is actually running
check_rule_status() {
    local id="$1"
    local rule_info=$(grep "^${id}|" "$CONFIG_FILE")
    local use_systemd=$(echo "$rule_info" | cut -d'|' -f9)
    local protocol=$(echo "$rule_info" | cut -d'|' -f3)
    
    if [ "$use_systemd" = "true" ]; then
        local service_name="socat-forward-${id}"
        if systemctl is-active --quiet "$service_name"; then
            if [ "$protocol" = "BOTH" ]; then
                if systemctl is-active --quiet "socat-forward-${id}-udp"; then
                    echo "RUNNING"
                else
                    echo "PARTIAL"
                fi
            else
                echo "RUNNING"
            fi
        else
            echo "STOPPED"
        fi
    else
        local pid_file="${PID_DIR}/socat_${id}.pid"
        if [ -f "$pid_file" ]; then
            local pids=$(cat "$pid_file")
            if [[ "$pids" == *","* ]]; then
                # Multiple PIDs (BOTH protocol)
                IFS=',' read -ra PID_ARRAY <<< "$pids"
                local running_count=0
                for pid in "${PID_ARRAY[@]}"; do
                    if kill -0 "$pid" 2>/dev/null; then
                        ((running_count++))
                    fi
                done
                if [ $running_count -eq ${#PID_ARRAY[@]} ]; then
                    echo "RUNNING"
                elif [ $running_count -gt 0 ]; then
                    echo "PARTIAL"
                else
                    echo "STOPPED"
                fi
            else
                # Single PID
                if kill -0 "$pids" 2>/dev/null; then
                    echo "RUNNING"
                else
                    echo "STOPPED"
                fi
            fi
        else
            echo "STOPPED"
        fi
    fi
}

# Function to show all rules
show_rules() {
    echo -e "${BOLD}${BLUE}Current Forwarding Rules:${NC}"
    echo -e "${CYAN}─────────────────────────────────────────────────────────────────────────────────${NC}"
    
    if [ ! -f "$CONFIG_FILE" ] || [ $(grep -v "^#" "$CONFIG_FILE" | wc -l) -eq 0 ]; then
        echo -e "${YELLOW}No forwarding rules configured.${NC}"
        return
    fi
    
    printf "${BOLD}%-3s %-15s %-8s %-3s %-6s %-20s %-6s %-8s %-8s${NC}\n" "ID" "NAME" "PROTOCOL" "IP" "L.PORT" "TARGET HOST" "T.PORT" "STATUS" "SYSTEMD"
    echo -e "${CYAN}─────────────────────────────────────────────────────────────────────────────────${NC}"
    
    while IFS='|' read -r id name protocol ip_version listen_port target_host target_port status systemd; do
        if [[ ! "$id" =~ ^# ]]; then
            # Check actual status
            local actual_status=$(check_rule_status "$id")
            
            # Update status if different
            if [ "$status" != "$actual_status" ]; then
                sed -i.bak "s/^${id}|.*/${id}|${name}|${protocol}|${ip_version}|${listen_port}|${target_host}|${target_port}|${actual_status}|${systemd}/" "$CONFIG_FILE"
                status="$actual_status"
            fi
            
            # Set systemd column display
            local systemd_display="NO"
            if [ "$systemd" = "true" ]; then
                systemd_display="YES"
            fi
            
            case "$status" in
                "RUNNING")
                    printf "%-3s %-15s %-8s %-3s %-6s %-20s %-6s ${GREEN}%-8s${NC} %-8s\n" "$id" "$name" "$protocol" "$ip_version" "$listen_port" "$target_host" "$target_port" "$status" "$systemd_display"
                    ;;
                "PARTIAL")
                    printf "%-3s %-15s %-8s %-3s %-6s %-20s %-6s ${YELLOW}%-8s${NC} %-8s\n" "$id" "$name" "$protocol" "$ip_version" "$listen_port" "$target_host" "$target_port" "$status" "$systemd_display"
                    ;;
                *)
                    printf "%-3s %-15s %-8s %-3s %-6s %-20s %-6s ${RED}%-8s${NC} %-8s\n" "$id" "$name" "$protocol" "$ip_version" "$listen_port" "$target_host" "$target_port" "$status" "$systemd_display"
                    ;;
            esac
        fi
    done < "$CONFIG_FILE"
    
    echo -e "${CYAN}─────────────────────────────────────────────────────────────────────────────────${NC}"
    echo
}

# Function to add new rule
add_rule() {
    echo -e "${BOLD}${GREEN}Add New Forwarding Rule${NC}"
    echo -e "${CYAN}─────────────────────────────────────────${NC}"
    
    # Get rule name
    echo -n -e "${YELLOW}Enter rule name: ${NC}"
    read -r rule_name
    if [ "$rule_name" = "" ]; then
        echo -e "${RED}✗ Rule name cannot be empty${NC}"
        return
    fi
    
    # Get protocol
    echo -e "${YELLOW}Select protocol:${NC}"
    echo "1) TCP"
    echo "2) UDP"
    echo "3) TCP + UDP (Both)"
    echo -n "Choice [1-3]: "
    read -r protocol_choice
    
    local protocol=""
    case "$protocol_choice" in
        1) protocol="TCP" ;;
        2) protocol="UDP" ;;
        3) protocol="BOTH" ;;
        *) echo -e "${RED}✗ Invalid choice${NC}"; return ;;
    esac
    
    # Get IP version
    echo -e "${YELLOW}Select IP version:${NC}"
    echo "1) IPv4 only"
    echo "2) IPv6 only"
    echo "3) IPv4 + IPv6"
    echo -n "Choice [1-3]: "
    read -r ip_choice
    
    local ip_version=""
    case "$ip_choice" in
        1) ip_version="4" ;;
        2) ip_version="6" ;;
        3) ip_version="46" ;;
        *) echo -e "${RED}✗ Invalid choice${NC}"; return ;;
    esac
    
    # Get listen port
    echo -n -e "${YELLOW}Enter listen port: ${NC}"
    read -r listen_port
    if ! [[ "$listen_port" =~ ^[0-9]+$ ]] || [ "$listen_port" -lt 1 ] || [ "$listen_port" -gt 65535 ]; then
        echo -e "${RED}✗ Invalid port number${NC}"
        return
    fi
    
    # Get target host
    echo -n -e "${YELLOW}Enter target host/IP: ${NC}"
    read -r target_host
    if [ "$target_host" = "" ]; then
        echo -e "${RED}✗ Target host cannot be empty${NC}"
        return
    fi
    
    # Get target port
    echo -n -e "${YELLOW}Enter target port: ${NC}"
    read -r target_port
    if ! [[ "$target_port" =~ ^[0-9]+$ ]] || [ "$target_port" -lt 1 ] || [ "$target_port" -gt 65535 ]; then
        echo -e "${RED}✗ Invalid port number${NC}"
        return
    fi
    
    # Get systemd preference
    echo -n -e "${YELLOW}Use systemd for persistence? [Y/n]: ${NC}"
    read -r use_systemd_input
    local use_systemd="true"
    if [[ "$use_systemd_input" =~ ^[Nn]$ ]]; then
        use_systemd="false"
    fi
    
    # Get auto-start preference
    echo -n -e "${YELLOW}Start rule immediately? [y/N]: ${NC}"
    read -r auto_start
    
    local id=$(get_next_id)
    local status="STOPPED"
    
    # Save rule
    save_rule "$id" "$rule_name" "$protocol" "$ip_version" "$listen_port" "$target_host" "$target_port" "$status" "$use_systemd"
    
    echo -e "${GREEN}✓ Rule added successfully (ID: $id)${NC}"
    
    # Start if requested
    if [[ "$auto_start" =~ ^[Yy]$ ]]; then
        start_forward "$id" "$protocol" "$ip_version" "$listen_port" "$target_host" "$target_port" "$use_systemd" "$rule_name"
    fi
}

# Function to delete rule
delete_rule() {
    show_rules
    
    echo -n -e "${YELLOW}Enter rule ID to delete: ${NC}"
    read -r rule_id
    
    if ! grep -q "^${rule_id}|" "$CONFIG_FILE"; then
        echo -e "${RED}✗ Rule ID not found${NC}"
        return
    fi
    
    # Stop the rule if running
    stop_forward "$rule_id"
    
    # Remove from config
    sed -i.bak "/^${rule_id}|/d" "$CONFIG_FILE"
    
    # Remove log file
    rm -f "${LOG_DIR}/socat_${rule_id}.log"
    
    echo -e "${GREEN}✓ Rule deleted successfully${NC}"
}

# Function to manage rule (start/stop)
manage_rule() {
    show_rules
    
    echo -n -e "${YELLOW}Enter rule ID to manage: ${NC}"
    read -r rule_id
    
    if ! grep -q "^${rule_id}|" "$CONFIG_FILE"; then
        echo -e "${RED}✗ Rule ID not found${NC}"
        return
    fi
    
    local rule_info=$(grep "^${rule_id}|" "$CONFIG_FILE")
    local name=$(echo "$rule_info" | cut -d'|' -f2)
    local protocol=$(echo "$rule_info" | cut -d'|' -f3)
    local ip_version=$(echo "$rule_info" | cut -d'|' -f4)
    local listen_port=$(echo "$rule_info" | cut -d'|' -f5)
    local target_host=$(echo "$rule_info" | cut -d'|' -f6)
    local target_port=$(echo "$rule_info" | cut -d'|' -f7)
    local status=$(echo "$rule_info" | cut -d'|' -f8)
    local use_systemd=$(echo "$rule_info" | cut -d'|' -f9)
    
    local actual_status=$(check_rule_status "$rule_id")
    
    if [ "$actual_status" = "RUNNING" ]; then
        echo -n -e "${YELLOW}Rule is running. Stop it? [y/N]: ${NC}"
        read -r confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            stop_forward "$rule_id"
        fi
    else
        echo -n -e "${YELLOW}Rule is stopped. Start it? [y/N]: ${NC}"
        read -r confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            start_forward "$rule_id" "$protocol" "$ip_version" "$listen_port" "$target_host" "$target_port" "$use_systemd" "$name"
        fi
    fi
}

# Function to show logs
show_logs() {
    show_rules
    
    echo -n -e "${YELLOW}Enter rule ID to view logs: ${NC}"
    read -r rule_id
    
    if ! grep -q "^${rule_id}|" "$CONFIG_FILE"; then
        echo -e "${RED}✗ Rule ID not found${NC}"
        return
    fi
    
    local log_file="${LOG_DIR}/socat_${rule_id}.log"
    if [ -f "$log_file" ]; then
        echo -e "${BOLD}${BLUE}Logs for Rule ID $rule_id:${NC}"
        echo -e "${CYAN}─────────────────────────────────────────${NC}"
        tail -50 "$log_file"
        echo -e "${CYAN}─────────────────────────────────────────${NC}"
    else
        echo -e "${YELLOW}⚠ Log file not found${NC}"
    fi
}

# Function to show main menu
show_menu() {
    print_banner
    get_ip_info
    show_rules
    
    echo -e "${BOLD}${WHITE}Main Menu:${NC}"
    echo -e "${GREEN}1)${NC} Add new forwarding rule"
    echo -e "${GREEN}2)${NC} Delete forwarding rule"
    echo -e "${GREEN}3)${NC} Start/Stop forwarding rule"
    echo -e "${GREEN}4)${NC} View rule logs"
    echo -e "${GREEN}5)${NC} Refresh display"
    echo -e "${GREEN}6)${NC} Show system info"
    echo -e "${RED}0)${NC} Exit"
    echo
    echo -n -e "${BOLD}Select option [0-6]: ${NC}"
}

# Function to show system info
show_system_info() {
    echo -e "${BOLD}${BLUE}System Information:${NC}"
    echo -e "${CYAN}─────────────────────────────────────────${NC}"
    echo -e "${GREEN}Script Version:${NC} $SCRIPT_VERSION"
    echo -e "${GREEN}Config File:${NC} $CONFIG_FILE"
    echo -e "${GREEN}PID Directory:${NC} $PID_DIR"
    echo -e "${GREEN}Log Directory:${NC} $LOG_DIR"
    echo -e "${GREEN}Socat Version:${NC} $(socat -V 2>/dev/null | head -1 || echo "Not installed")"
    echo -e "${GREEN}Total Rules:${NC} $(grep -v "^#" "$CONFIG_FILE" 2>/dev/null | wc -l | tr -d ' ')"
    echo -e "${GREEN}Running Rules:${NC} $(grep "|RUNNING|" "$CONFIG_FILE" 2>/dev/null | wc -l | tr -d ' ')"
    echo -e "${GREEN}Systemd Services:${NC} $(systemctl list-units --type=service --state=active | grep "socat-forward" | wc -l | tr -d ' ')"
    
    echo -e "\n${YELLOW}Active socat processes:${NC}"
    ps aux | grep socat | grep -v grep || echo "None"
    
    echo -e "\n${YELLOW}Listening ports (socat):${NC}"
    lsof -i -n | grep socat || echo "None"
    
    echo -e "${CYAN}─────────────────────────────────────────${NC}"
    echo
    echo -e "${YELLOW}Press Enter to continue...${NC}"
    read -r
}

# Main function
main() {
    # Check if socat is installed
    if ! command -v socat &> /dev/null; then
        echo -e "${RED}Error: socat is not installed.${NC}"
        echo -e "${YELLOW}Please install socat first:${NC}"
        echo -e "  Ubuntu/Debian: ${GREEN}sudo apt-get install socat${NC}"
        echo -e "  CentOS/RHEL:   ${GREEN}sudo yum install socat${NC}"
        echo -e "  macOS:         ${GREEN}brew install socat${NC}"
        exit 1
    fi
    
    # Load configuration
    load_config
    
    # Main loop
    while true; do
        show_menu
        read -r choice
        
        case "$choice" in
            1)
                add_rule
                echo -e "\n${YELLOW}Press Enter to continue...${NC}"
                read -r
                ;;
            2)
                delete_rule
                echo -e "\n${YELLOW}Press Enter to continue...${NC}"
                read -r
                ;;
            3)
                manage_rule
                echo -e "\n${YELLOW}Press Enter to continue...${NC}"
                read -r
                ;;
            4)
                show_logs
                echo -e "\n${YELLOW}Press Enter to continue...${NC}"
                read -r
                ;;
            5)
                # Just refresh by continuing the loop
                ;;
            6)
                show_system_info
                ;;
            0)
                echo -e "${GREEN}Thank you for using Socat Forward Manager!${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}✗ Invalid option. Please try again.${NC}"
                echo -e "\n${YELLOW}Press Enter to continue...${NC}"
                read -r
                ;;
        esac
    done
}

# Run main function
main "$@"
