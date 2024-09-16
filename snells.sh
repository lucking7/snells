#!/bin/bash

# SCP Foundation - Snell with Shadow-TLS Deployment Protocol Simplified

# Define color codes
red='\e[31m'
green='\e[92m' 
yellow='\e[33m'  
reset='\e[0m'
underline='\e[4m'
blink='\e[5m'  
cyan='\e[96m'
purple='\e[35m'

# Color print functions
_red() { echo -e "${red}$@${reset}"; }
_green() { echo -e "${green}$@${reset}"; }
_yellow() { echo -e "${yellow}$@${reset}"; }  
_cyan() { echo -e "${cyan}$@${reset}"; }
_magenta() { echo -e "${purple}$@${reset}"; }  
_red_bg() { echo -e "\e[41m$@${reset}"; }

is_err=$(_red_bg "ERROR!")
is_warn=$(_red_bg "WARNING!")

err() {  
    echo -e "\n$is_err $@\n" && return 1
}

warn() {
    echo -e "\n$is_warn $@\n"  
}

# Log message function
msg() {
    case $1 in
        err) echo -e "${red}[ERROR] $2${reset}" ;;
        warn) echo -e "${yellow}[WARN] $2${reset}" ;;
        ok) echo -e "${green}[OK] $2${reset}" ;;
        info) echo -e "[INFO] $2" ;;
        *) echo -e "[LOG] $2" ;;
    esac
}

# Initialize variables
snell_workspace="/etc/snell-server"
snell_service="/etc/systemd/system/snell.service"
shadow_tls_workspace="/etc/shadow-tls"  
shadow_tls_service="/etc/systemd/system/shadow-tls.service"

# Define required packages for Debian/Ubuntu
REQUIRED_PACKAGES="wget unzip jq net-tools curl cron dnsutils"

# Enhanced dependency installation
install_dependencies() {
    if ! command -v apt-get >/dev/null 2>&1; then
        err "This script only supports Debian/Ubuntu systems"
        exit 1
    }

    msg info "Updating package lists..."
    apt-get update -y >/dev/null 2>&1

    msg info "Checking required packages..."
    local missing_pkgs=()
    for pkg in $REQUIRED_PACKAGES; do
        if ! command -v "$pkg" >/dev/null 2>&1; then
            missing_pkgs+=("$pkg")
        fi
    done

    if [ ${#missing_pkgs[@]} -ne 0 ]; then
        msg info "Installing missing packages: ${missing_pkgs[*]}"
        apt-get install -y "${missing_pkgs[@]}"
        if [ $? -ne 0 ]; then
            err "Failed to install required packages"
            exit 1
        fi
    fi
}

# Basic system check
check_system() {
    # Check CPU architecture
    local arch=$(uname -m)
    case $arch in
        x86_64|aarch64|armv7l|i386) 
            msg ok "CPU architecture $arch is supported"
            ;;
        *)
            err "Unsupported CPU architecture: $arch"
            exit 1
            ;;
    esac

    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        err "This script must be run as root"
        exit 1
    fi

    # Check systemd
    if ! command -v systemctl >/dev/null 2>&1; then
        err "Systemd is required but not found"
        exit 1
    fi
}

# Comprehensive pre-installation check
pre_install_check() {
    msg info "Starting pre-installation checks..."
    
    # Run basic checks
    check_system || exit 1
    install_dependencies || exit 1
    
    # Check for existing installations
    if [[ -e "${snell_workspace}/snell-server" ]] || [[ -e "/usr/local/bin/shadow-tls" ]]; then
        warn "Existing installation detected"
        read -rp "Do you want to proceed with reinstallation? (y/n): " response
        if [[ ! $response =~ ^[Yy]$ ]]; then
            msg info "Installation cancelled by user"
            exit 0
        fi
    fi
    
    msg ok "All pre-installation checks passed"
}

# Main script execution
main() {
    # Set error handling
    set -eo pipefail
    trap 'err "An error occurred. Exiting..."' ERR
    
    # Run pre-installation checks
    pre_install_check
    
    # Continue with menu/installation
    menu
}

# Main menu
menu() {  
    _cyan "${cyan}${underline}${blink}Snell and Shadow-TLS: Double the speed, double the fun!${reset}\n"
    _green "1. Install"
    _red "2. Uninstall"
    _yellow "3. Manage"
    echo "4. Exit"  
    read -p "Choose an action (1-4): " operation

    case $operation in  
        1) install ;;
        2) uninstall ;;
        3) manage ;;
        4) exit 0 ;;  
        *) msg err "Invalid action." ;;
    esac
}

# Script entry
main