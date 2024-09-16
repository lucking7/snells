#!/bin/bash

# ================================
#       Enhanced Realm Manager
# ================================

# Enhanced Realm Manager Script with Colored Output, Conditional Sudo,
# and Interactive Menu for Managing Forwarding Endpoints.
# Provides installation, uninstallation, and advanced forwarding management for Realm.

# ================================
#         Color Definitions
# ================================

# Reset
RESET="\e[0m"

# Regular Colors
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
MAGENTA="\e[35m"
CYAN="\e[36m"

# Bold
BOLD="\e[1m"

# ================================
#        Sudo Configuration
# ================================

# Determine if the script is run as root
if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
else
    SUDO="sudo"
fi

# ================================
#           Configuration
# ================================

REALM_VERSION="v2.6.2"
REALM_BINARY_NAME="realm-x86_64-unknown-linux-gnu.tar.gz"
REALM_BINARY_URL="https://github.com/zhboner/realm/releases/download/${REALM_VERSION}/${REALM_BINARY_NAME}"
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/realm"
CONFIG_FILE="${CONFIG_DIR}/config.toml"
SERVICE_FILE="/etc/systemd/system/realm.service"

# ================================
#             Functions
# ================================

# Print in GREEN
print_success() {
    echo -e "${GREEN}$1${RESET}"
}

# Print in RED
print_error() {
    echo -e "${RED}$1${RESET}"
}

# Print in YELLOW
print_warning() {
    echo -e "${YELLOW}$1${RESET}"
}

# Print in BLUE
print_info() {
    echo -e "${BLUE}$1${RESET}"
}

# Display Menu
show_menu() {
    echo -e "${BOLD}${CYAN}Realm Manager Menu${RESET}"
    echo "1. Install Realm"
    echo "2. Uninstall Realm"
    echo "3. Add New Forward"
    echo "4. List All Forwards"
    echo "5. Delete a Forward"
    echo "6. Exit"
    echo -n "Please enter your choice [1-6]: "
}

# Install Realm
install_realm() {
    print_info "Installing Realm ${REALM_VERSION}..."

    # Create configuration directory
    ${SUDO} mkdir -p "${CONFIG_DIR}" && print_success "Created configuration directory at ${CONFIG_DIR}."

    # Download and extract Realm
    print_info "Downloading Realm binary from ${REALM_BINARY_URL}..."
    wget "${REALM_BINARY_URL}" -O /tmp/realm.tar.gz
    if [[ $? -ne 0 ]]; then
        print_error "Failed to download Realm binary."
        exit 1
    fi

    print_info "Extracting Realm binary..."
    tar -xzf /tmp/realm.tar.gz -C /tmp
    if [[ $? -ne 0 ]]; then
        print_error "Failed to extract Realm binary."
        exit 1
    fi

    ${SUDO} mv /tmp/realm "${INSTALL_DIR}/realm" && print_success "Moved Realm binary to ${INSTALL_DIR}."
    ${SUDO} chmod +x "${INSTALL_DIR}/realm" && print_success "Set executable permissions for Realm."

    # Create a default config file if it doesn't exist
    if [[ ! -f "${CONFIG_FILE}" ]]; then
        print_info "Creating default configuration at ${CONFIG_FILE}..."
        ${SUDO} bash -c "cat > ${CONFIG_FILE}" <<EOL
[[endpoints]]
listen = "0.0.0.0:5000"
remote = "1.1.1.1:443"
protocol = "both"    # Options: udp, tcp, both
ip_version = "both"  # Options: ipv4, ipv6, both
EOL
        print_success "Default configuration created."
    else
        print_warning "Configuration file already exists at ${CONFIG_FILE}."
    fi

    # Create systemd service
    print_info "Setting up systemd service for Realm..."
    ${SUDO} bash -c "cat > ${SERVICE_FILE}" <<EOL
[Unit]
Description=Realm Relay Service
After=network.target

[Service]
ExecStart=${INSTALL_DIR}/realm -c ${CONFIG_FILE}
Restart=always
User=nobody
Group=nogroup

[Install]
WantedBy=multi-user.target
EOL
    print_success "Systemd service file created at ${SERVICE_FILE}."

    # Reload systemd, enable and start Realm service
    print_info "Reloading systemd daemon..."
    ${SUDO} systemctl daemon-reload

    print_info "Enabling Realm service to start on boot..."
    ${SUDO} systemctl enable realm

    print_info "Starting Realm service..."
    ${SUDO} systemctl start realm

    print_success "Realm installed and service started successfully."
}

# Uninstall Realm
uninstall_realm() {
    print_info "Uninstalling Realm..."

    # Stop and disable service
    print_info "Stopping Realm service..."
    ${SUDO} systemctl stop realm

    print_info "Disabling Realm service..."
    ${SUDO} systemctl disable realm

    # Remove service file
    print_info "Removing systemd service file..."
    ${SUDO} rm -f "${SERVICE_FILE}" && print_success "Removed service file."

    # Remove binary
    print_info "Removing Realm binary from ${INSTALL_DIR}..."
    ${SUDO} rm -f "${INSTALL_DIR}/realm" && print_success "Removed Realm binary."

    # Remove configuration
    print_info "Removing configuration directory at ${CONFIG_DIR}..."
    ${SUDO} rm -rf "${CONFIG_DIR}" && print_success "Removed configuration directory."

    # Reload systemd
    print_info "Reloading systemd daemon..."
    ${SUDO} systemctl daemon-reload

    print_success "Realm uninstalled successfully."
}

# Add a new forward
add_forward() {
    echo -e "${BOLD}${CYAN}Add New Forward${RESET}"

    # Prompt for listening address type
    echo "Select Listening Address Type:"
    echo "1. IPv4 (e.g., 0.0.0.0)"
    echo "2. IPv6 (e.g., [::])"
    echo "3. Both"
    read -p "Enter choice [1-3]: " addr_type

    case "$addr_type" in
        1)
            LISTEN_ADDR="0.0.0.0"
            IP_VERSION="ipv4"
            ;;
        2)
            LISTEN_ADDR="[::]"
            IP_VERSION="ipv6"
            ;;
        3)
            LISTEN_ADDR="0.0.0.0,[::]"
            IP_VERSION="both"
            ;;
        *)
            print_error "Invalid choice. Defaulting to both."
            LISTEN_ADDR="0.0.0.0,[::]"
            IP_VERSION="both"
            ;;
    esac

    # Prompt for listening port
    read -p "Enter Listening Port (e.g., 5000): " LISTEN_PORT
    if [[ -z "$LISTEN_PORT" ]]; then
        print_error "Listening port cannot be empty."
        return
    fi

    # Prompt for remote address
    read -p "Enter Remote Address (e.g., 1.1.1.1 or [2001:db8::1]): " REMOTE_ADDR
    if [[ -z "$REMOTE_ADDR" ]]; then
        print_error "Remote address cannot be empty."
        return
    fi

    # Add square brackets for IPv6 remote addresses if not present
    if [[ "$REMOTE_ADDR" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+ ]]; then
        REMOTE_FORMATTED="$REMOTE_ADDR"
    elif [[ "$REMOTE_ADDR" =~ ^\[[0-9a-fA-F:]+\]$ ]]; then
        REMOTE_FORMATTED="$REMOTE_ADDR"
    else
        # Assume IPv6 and add brackets
        REMOTE_FORMATTED="[$REMOTE_ADDR]"
    fi

    # Prompt for remote port
    read -p "Enter Remote Port (e.g., 443): " REMOTE_PORT
    if [[ -z "$REMOTE_PORT" ]]; then
        print_error "Remote port cannot be empty."
        return
    fi

    # Prompt for protocol
    echo "Select Forwarding Protocol:"
    echo "1. TCP"
    echo "2. UDP"
    echo "3. Both"
    read -p "Enter choice [1-3]: " protocol_choice

    case "$protocol_choice" in
        1)
            PROTOCOL="tcp"
            ;;
        2)
            PROTOCOL="udp"
            ;;
        3)
            PROTOCOL="both"
            ;;
        *)
            print_error "Invalid choice. Defaulting to both."
            PROTOCOL="both"
            ;;
    esac

    # Construct listen and remote addresses
    IFS=',' read -ra ADDR_ARRAY <<< "$LISTEN_ADDR"
    for addr in "${ADDR_ARRAY[@]}"; do
        echo "Adding forward: Listen=${addr}:${LISTEN_PORT} | Remote=${REMOTE_FORMATTED}:${REMOTE_PORT} | Protocol=${PROTOCOL} | IP Version=${IP_VERSION}"
        ${SUDO} bash -c "cat >> ${CONFIG_FILE}" <<EOL

[[endpoints]]
listen = "${addr}:${LISTEN_PORT}"
remote = "${REMOTE_FORMATTED}:${REMOTE_PORT}"
protocol = "${PROTOCOL}"
ip_version = "${IP_VERSION}"
EOL
    done

    print_success "New forward(s) added successfully."

    # Restart Realm service to apply changes
    print_info "Restarting Realm service to apply changes..."
    ${SUDO} systemctl restart realm

    print_success "Realm service restarted."
}

# List all forwards
list_forwards() {
    echo -e "${BOLD}${CYAN}Current Forwards:${RESET}"
    echo "----------------------------------------"

    if [[ ! -f "${CONFIG_FILE}" ]]; then
        print_warning "Configuration file does not exist."
        return
    fi

    local COUNT=0
    local TEMP_LIST=$(grep -E '^\[\[endpoints\]\]$|^listen =|^remote =|^protocol =|^ip_version =' "${CONFIG_FILE}" 2>/dev/null)

    while IFS= read -r line; do
        if [[ "$line" == "[[endpoints]]" ]]; then
            ((COUNT++))
            echo -e "${YELLOW}Forward #${COUNT}:${RESET}"
        elif [[ "$line" =~ listen\ =\ \"(.+)\" ]]; then
            echo -e "  ${GREEN}Listen:${RESET} ${BASH_REMATCH[1]}"
        elif [[ "$line" =~ remote\ =\ \"(.+)\" ]]; then
            echo -e "  ${GREEN}Remote:${RESET} ${BASH_REMATCH[1]}"
        elif [[ "$line" =~ protocol\ =\ \"(.+)\" ]]; then
            echo -e "  ${GREEN}Protocol:${RESET} ${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ip_version\ =\ \"(.+)\" ]]; then
            echo -e "  ${GREEN}IP Version:${RESET} ${BASH_REMATCH[1]}"
            echo "----------------------------------------"
        fi
    done <<< "${TEMP_LIST}"

    if [[ ${COUNT} -eq 0 ]]; then
        print_warning "No forwards found in the configuration."
    else
        echo -e "${BOLD}Total Forwards: ${COUNT}${RESET}"
    fi
}

# Delete a forward
delete_forward() {
    list_forwards
    if [[ $? -ne 0 ]]; then
        return
    fi

    read -p "Enter the Forward Number to Delete: " INDEX

    if ! [[ "$INDEX" =~ ^[0-9]+$ ]]; then
        print_error "Invalid input. Please enter a valid number."
        return
    fi

    # Extract the total number of endpoints
    local TOTAL
    TOTAL=$(grep -c '^\[\[endpoints\]\]$' "${CONFIG_FILE}" 2>/dev/null)

    if (( INDEX < 1 || INDEX > TOTAL )); then
        print_error "Invalid forward number. Use list command to see valid numbers."
        return
    fi

    # Use awk to delete the specified forward
    print_info "Deleting forward number ${INDEX}..."

    awk -v idx="$INDEX" '
    BEGIN { count=0; }
    /^\[\[endpoints\]\]$/ {
        count++;
        if (count == idx) {
            skip=1;
            next
        }
    }
    {
        if (skip && /^listen =/) {
            skip=2
            next
        }
        if (skip == 2 && (/^remote =/ || /^protocol =/ || /^ip_version =/)) {
            next
        }
        if (skip == 2 && !(/^(remote|protocol|ip_version)/)) {
            skip=0
        }
        print
    }
    ' "${CONFIG_FILE}" | ${SUDO} tee "${CONFIG_FILE}" > /dev/null

    print_success "Deleted forward number ${INDEX}."

    # Restart Realm service to apply changes
    print_info "Restarting Realm service to apply changes..."
    ${SUDO} systemctl restart realm

    print_success "Realm service restarted."
}

# Show Help
show_help() {
    echo -e "${BOLD}${CYAN}Enhanced Realm Manager Script${RESET}"
    echo "Usage: $0"
    echo ""
    echo "Provides an interactive menu to manage Realm forwards."
    echo ""
    echo "Commands:"
    echo "  Run the script without arguments to display the menu."
}

# ================================
#             Main
# ================================

# If script is called with arguments, show help
if [[ $# -gt 0 ]]; then
    show_help
    exit 0
fi

# Show menu in a loop
while true; do
    show_menu
    read choice
    case "$choice" in
        1)
            install_realm
            ;;
        2)
            uninstall_realm
            ;;
        3)
            add_forward
            ;;
        4)
            list_forwards
            ;;
        5)
            delete_forward
            ;;
        6)
            print_info "Exiting Realm Manager. Goodbye!"
            exit 0
            ;;
        *)
            print_error "Invalid choice. Please select between 1-6."
            ;;
    esac
    echo ""
done