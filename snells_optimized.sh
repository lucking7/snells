#!/bin/bash

# Script version
current_version="1.3.0"

# Define color codes
red='\e[31m'
green='\e[92m' 
yellow='\e[33m'  
reset='\e[0m'
underline='\e[4m'
blink='\e[5m'  
cyan='\e[96m'
purple='\e[35m'
BOLD='\e[1m'
BG_BLUE='\e[44m'

# Color print functions
_red() { echo -e "${red}$@${reset}"; }
_green() { echo -e "${green}$@${reset}"; }
_yellow() { echo -e "${yellow}$@${reset}"; }  
_cyan() { echo -e "${cyan}$@${reset}"; }
_magenta() { echo -e "${purple}$@${reset}"; }  
_red_bg() { echo -e "\e[41m$@${reset}"; }
_blue_bg() { echo -e "${BG_BLUE}$@${reset}"; }
_bold() { echo -e "${BOLD}$@${reset}"; }

is_err=$(_red_bg "ERROR!")
is_warn=$(_red_bg "WARNING!")

err() {  
    echo -e "\n$is_err $@\n" && return 1
}

warn() {
    echo -e "\n$is_warn $@\n"  
}

# Function to display log messages
msg() {
    case $1 in
        err) echo -e "${red}[ERROR] $2${reset}" ;;
        warn) echo -e "${yellow}[WARN] $2${reset}" ;;
        ok) echo -e "${green}[OK] $2${reset}" ;;
        info) echo -e "[INFO] $2" ;;
        *) echo -e "[LOG] $2" ;;
    esac
}

# Check Snell service status
check_snell_status() {
    echo -e "${cyan}═════════════════════════════════════${reset}"
    echo -e "${cyan}            Service Status Check      ${reset}"
    echo -e "${cyan}═════════════════════════════════════${reset}"
    
    if systemctl is-active --quiet snell; then
        echo -e "Snell Service: ${green}Running${reset}"
    else
        echo -e "Snell Service: ${red}Stopped${reset}"
    fi
    
    if systemctl is-active --quiet shadow-tls; then
        echo -e "Shadow-TLS Service: ${green}Running${reset}"
    else
        echo -e "Shadow-TLS Service: ${red}Stopped${reset} or ${yellow}Not installed${reset}"
    fi
    
    # Check port usage
    if [[ -f "${snell_workspace}/snell-server.conf" ]]; then
        local snell_port=$(grep -oP 'listen = .*?:(\d+)' "${snell_workspace}/snell-server.conf" | grep -oP '\d+$')
        if [[ -n "$snell_port" ]]; then
            if ss -tuln | grep -q ":${snell_port} "; then
                echo -e "Snell Port ${snell_port}: ${green}Open${reset}"
            else
                echo -e "Snell Port ${snell_port}: ${red}Closed${reset}"
            fi
        fi
    fi
    
    echo
}

# Function to check server IP (supports both IPv4 and IPv6)
get_ip() {
    # Add timeout for IPv4
    trace_info_v4=$(curl -s4 --connect-timeout 5 https://cloudflare.com/cdn-cgi/trace)
    # Add timeout for IPv6: --connect-timeout 5s connection timeout, --max-time 10s total timeout
    trace_info_v6=$(curl -s6 --connect-timeout 5 --max-time 10 https://cloudflare.com/cdn-cgi/trace)
    ipv4=$(echo "$trace_info_v4" | grep -oP '(?<=ip=)[^\n]*')
    ipv6=$(echo "$trace_info_v6" | grep -oP '(?<=ip=)[^\n]*')
    colo=$(echo "$trace_info_v4" | grep -oP '(?<=colo=)[^\n]*')

    if [[ -n $ipv4 && -n $ipv6 ]]; then
        ip_type="both"
    elif [[ -n $ipv4 ]]; then
        ip_type="ipv4"
        msg info "IPv6 unavailable or detection timeout."
    elif [[ -n $ipv6 ]]; then
        ip_type="ipv6"
    else
        msg err "Unable to get server IP address." && exit 1
    fi

    server_ip=${ipv4:-$ipv6}

    if [[ -z $colo ]]; then
        # Try to get colo from IPv6 info
        colo=$(echo "$trace_info_v6" | grep -oP '(?<=colo=)[^\n]*')
        if [[ -z $colo ]]; then
            msg warn "Unable to get datacenter location, using default settings."
            colo="unknown"
        else
            msg ok "Datacenter location: ${colo}"
        fi
    else
        msg ok "Datacenter location: ${colo}"
    fi
}

# Check prerequisites
check_preconditions() {
    # Check for root privileges
    [[ $EUID -ne 0 ]] && err "Root privileges are required to run this script."

    # Detect package manager
    if ! command -v apt-get >/dev/null 2>&1 && ! command -v yum >/dev/null 2>&1; then
        err "This script only supports Ubuntu or Debian."
    fi

    # Check for systemd
    if ! command -v systemctl >/dev/null 2>&1; then
        err "This script requires systemd support."
    fi
}

# Call the function early in the script
check_preconditions

# Initialization  
snell_workspace="/etc/snell-server"
snell_service="/etc/systemd/system/snell.service"
shadow_tls_workspace="/etc/shadow-tls"  
shadow_tls_service="/etc/systemd/system/shadow-tls.service"
dependencies="wget unzip jq net-tools curl cron"

# Simplified installation of missing packages  
install_pkg() {
    apt-get update -qq
    apt-get install -y $dependencies
}

# Function to generate a random PSK
generate_random_psk() {
    echo "$(openssl rand -base64 32)"
}

# Function to generate a random password  
generate_random_password() {
    echo "$(openssl rand -base64 16)"
}

# Function to find an unused port  
find_unused_port() {
    local port
    while true; do
        port=$(shuf -i 10000-65535 -n 1)
        if ! ss -tuln | grep -q ":$port "; then
            echo "$port"
            break
        fi
    done
}

# Start services
run() {
    systemctl start snell  
    systemctl start shadow-tls
    sleep 2
    if systemctl is-active --quiet snell && systemctl is-active --quiet shadow-tls; then  
        msg ok "Snell and Shadow-TLS are now running."
    else
        msg err "Failed to start Snell or Shadow-TLS, please check logs."  
    fi
}

# Stop services
stop() {  
    systemctl stop snell
    systemctl stop shadow-tls
    msg ok "Snell and Shadow-TLS have been stopped."  
}

# Restart services
restart() {
    systemctl restart snell
    systemctl restart shadow-tls
    sleep 2
    if systemctl is-active --quiet snell && systemctl is-active --quiet shadow-tls; then
        msg ok "Snell and Shadow-TLS have been restarted successfully."
    else
        msg err "Failed to restart services, please check logs."
    fi
}

# Install options
install() {
    clear
    _blue_bg "┌─────────────────────────────────────────┐"
    _blue_bg "│  $(printf '%-36s' "Installation Options")  │"
    _blue_bg "└─────────────────────────────────────────┘"
    echo ""
    
    _green "1) Install Snell and Shadow-TLS"
    _yellow "2) Install Snell Only"
    _cyan "3) Install Shadow-TLS Only"
    _red "0) Back to Main Menu"
    echo ""
    
    read -p "Please select an option [0-3]: " option

    case $option in
        1) install_all ;;
        2) install_snell ;;
        3) install_shadow_tls ;;
        0) menu ;;
        *) err "Invalid option" && sleep 2 && install ;;
    esac
}

# Uninstall options
uninstall() {
    clear
    _blue_bg "┌─────────────────────────────────────────┐"
    _blue_bg "│  $(printf '%-36s' "Uninstall Options")  │"
    _blue_bg "└─────────────────────────────────────────┘"
    echo ""
    
    _red "1) Uninstall Snell and Shadow-TLS"
    _yellow "2) Uninstall Snell Only"
    _cyan "3) Uninstall Shadow-TLS Only"
    _green "0) Back to Main Menu"
    echo ""
    
    read -p "Please select an option [0-3]: " option

    case $option in
        1) uninstall_all ;;
        2) uninstall_snell ;;
        3) uninstall_shadow_tls ;;
        0) menu ;;
        *) err "Invalid option" && sleep 2 && uninstall ;;
    esac
}

# Service management menu
manage() {
    clear
    _blue_bg "┌─────────────────────────────────────────┐"
    _blue_bg "│  $(printf '%-36s' "Service Management")  │"
    _blue_bg "└─────────────────────────────────────────┘"
    echo ""
    
    # Display service status
    check_snell_status
    
    _cyan "═════════════════════════════════════"
    _bold "$(_yellow "Management Options")"
    _cyan "═════════════════════════════════════"
    
    _green "1) Start Services" 
    _red "2) Stop Services"
    _yellow "3) Restart Services"
    _cyan "4) View Detailed Service Status"
    _magenta "5) View Service Logs"
    _blue_bg "6) Modify Configuration"
    _red "0) Back to Main Menu"
    echo ""
    
    read -p "Please select an option [0-6]: " operation
    
    case $operation in
        1) run && sleep 2 && manage ;;  
        2) stop && sleep 2 && manage ;;
        3) restart && sleep 2 && manage ;;
        4) check_service ;; 
        5) show_logs && manage ;;
        6) modify && manage ;; 
        0) menu ;;
        *) err "Invalid selection" && sleep 2 && manage ;;
    esac  
}

# Configuration modification menu
modify() {
    clear
    _blue_bg "┌─────────────────────────────────────────┐"
    _blue_bg "│  $(printf '%-36s' "Configuration Editor")  │"
    _blue_bg "└─────────────────────────────────────────┘"
    echo ""
    
    _green "1) Modify Snell Configuration"
    _yellow "2) Modify Shadow-TLS Configuration"
    _red "0) Back to Main Menu"
    echo ""
    
    read -p "Please select an option [0-2]: " operation
    
    case $operation in  
        1) nano "${snell_workspace}/snell-server.conf" ;;
        2) nano "${shadow_tls_service}" ;;
        0) menu ;;  
        *) err "Invalid operation" && sleep 2 && modify ;;
    esac

    msg info "Don't forget to restart services to apply changes!"
    read -p "Press any key to continue..." _
}

# Main menu
menu() {  
    clear
    _blue_bg "┌─────────────────────────────────────────┐"
    _blue_bg "│  $(printf '%-36s' "ShadowTLS + Snell Management v${current_version}")  │"
    _blue_bg "└─────────────────────────────────────────┘"
    echo ""
    
    # Display service status
    check_snell_status
    
    _cyan "═════════════════════════════════════"
    _bold "$(_yellow "MAIN MENU")"
    _cyan "═════════════════════════════════════"
    
    _green "1) Install Services"
    _red "2) Uninstall Services"
    _yellow "3) Manage Services"
    _cyan "4) Modify Configuration"
    _magenta "5) Display Configuration"
    _blue_bg "6) Update Snell"
    _red "0) Exit"
    echo ""
    
    echo -e "───────────────────────────────────────"
    
    read -p "Please select an option [0-6]: " operation

    case $operation in  
        1) install ;;
        2) uninstall ;;
        3) manage ;;
        4) modify ;;
        5) display_config ;;
        6) update_snell && menu ;;
        0) echo -e "${green}Thank you for using this script! Goodbye!${reset}" && exit 0 ;;
        *) err "Invalid selection" && sleep 2 && menu ;;
    esac
}

# Placeholder functions (you'll need to implement these based on your original script)
install_all() {
    msg info "Installing Snell and Shadow-TLS..."
    # Implementation needed
    menu
}

install_snell() {
    msg info "Installing Snell only..."
    # Implementation needed
    menu
}

install_shadow_tls() {
    msg info "Installing Shadow-TLS only..."
    # Implementation needed
    menu
}

uninstall_all() {
    msg info "Uninstalling Snell and Shadow-TLS..."
    # Implementation needed
    menu
}

uninstall_snell() {
    msg info "Uninstalling Snell only..."
    # Implementation needed
    menu
}

uninstall_shadow_tls() {
    msg info "Uninstalling Shadow-TLS only..."
    # Implementation needed
    menu
}

check_service() {
    clear
    _blue_bg "┌─────────────────────────────────────────┐"
    _blue_bg "│  $(printf '%-36s' "Detailed Service Status")  │"
    _blue_bg "└─────────────────────────────────────────┘"
    echo ""
    
    echo -e "${cyan}Snell Service Status:${reset}"
    systemctl status snell --no-pager
    echo ""
    
    echo -e "${cyan}Shadow-TLS Service Status:${reset}"
    systemctl status shadow-tls --no-pager
    echo ""
    
    read -p "Press any key to return to management menu..." _
    manage
}

show_logs() {
    clear
    _blue_bg "┌─────────────────────────────────────────┐"
    _blue_bg "│  $(printf '%-36s' "Service Logs")  │"
    _blue_bg "└─────────────────────────────────────────┘"
    echo ""
    
    echo -e "${cyan}Recent Snell Logs:${reset}"
    journalctl -u snell --no-pager -n 20
    echo ""
    
    echo -e "${cyan}Recent Shadow-TLS Logs:${reset}"
    journalctl -u shadow-tls --no-pager -n 20
    echo ""
    
    read -p "Press any key to return..." _
}

display_config() {
    clear
    _blue_bg "┌─────────────────────────────────────────┐"
    _blue_bg "│  $(printf '%-36s' "Configuration Display")  │"
    _blue_bg "└─────────────────────────────────────────┘"
    echo ""
    
    if [[ -f "${snell_workspace}/snell-server.conf" ]]; then
        echo -e "${cyan}Snell Configuration:${reset}"
        cat "${snell_workspace}/snell-server.conf"
        echo ""
    else
        echo -e "${red}Snell configuration file not found${reset}"
    fi
    
    read -p "Press any key to return to main menu..." _
    menu
}

update_snell() {
    msg info "Checking for Snell updates..."
    # Implementation needed based on your original update function
    sleep 2
}

# Script starts here  
menu
