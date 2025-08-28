# Forward Manager (fwrd.sh)

A unified management tool for GOST, NFTables, and Realm forwarding tools.

## Features

- **Progressive Input**: Step-by-step IP and port entry with validation
- **Auto Error Correction**: Input sanitization and retry mechanisms
- **Tool Auto-selection**: Smart forwarding tool recommendation
- **Rule Management**: Add, list, modify, and delete forwarding rules
- **Service Control**: Unified start/stop/restart for all tools
- **Performance Testing**: Built-in connection testing

## Requirements

- Linux system with root privileges
- systemctl, curl, jq, lsof

## Quick Start

```bash
# Make executable
chmod +x fwrd.sh

# Run as root
sudo ./fwrd.sh
```

## Supported Tools

| Tool         | Performance | Description                                  |
| ------------ | ----------- | -------------------------------------------- |
| **NFTables** | ⭐⭐⭐⭐⭐  | Kernel-level forwarding, highest performance |
| **Realm**    | ⭐⭐⭐⭐⭐  | Rust proxy, supports TCP/UDP separation      |
| **GOST**     | ⭐⭐⭐⭐    | Feature-rich tunnel, supports port ranges    |

## Menu Navigation

### Main Menu

1. **Install tools** - Auto-install forwarding tools
2. **System status** - View tool status and system info
3. **Add rule** - Create new forwarding rule (progressive input)
4. **List rules** - Display all active rules
5. **Modify rule** - Update existing rule settings
6. **Delete rule** - Remove forwarding rule
7. **Service control** - Manage tool services
8. **Performance test** - Test connection performance

### Progressive Rule Creation

The script guides you through rule creation step by step:

1. **Listen Port**: Enter port or leave empty for auto-selection
2. **Target IP**: Enter destination IP (with validation)
3. **Target Port**: Enter destination port (with validation)
4. **Protocol**: Choose TCP, UDP, or both
5. **Tool**: Auto-select or choose specific tool
6. **Listen IP**: Default 0.0.0.0 or specify custom

### Input Validation

- **IP Address**: Validates IPv4, IPv6, and domain names
- **Port Range**: Checks 1-65535 range and port conflicts
- **Auto-correction**: Trims whitespace, handles common formats
- **Retry Logic**: Re-prompts for invalid input with examples

## Rule Management

### View Rules

```
#   TOOL     LISTEN_IP       PORT  TARGET_IP       PORT  PROTOCOL STATUS   CREATED
──────────────────────────────────────────────────────────────────────────────
1   gost     0.0.0.0         8080  192.168.1.100   80    tcp      running  2024-01-15
2   realm    0.0.0.0         9090  example.com     443   both     running  2024-01-15
```

### Modify Rules

- Select rule by number
- Enter new values or press Enter to keep current
- Confirms changes before applying

### Smart Tool Selection

- **High Performance**: NFTables > Realm > GOST
- **Feature Rich**: GOST > NFTables > Realm
- **Auto-selection**: Based on protocol and requirements

## Service Management

- **Start/Stop/Restart**: Control all services at once
- **Log Viewing**: Quick access to service logs
- **IP Forwarding**: Enable kernel IP forwarding
- **Status Monitoring**: Real-time service status

## Configuration

Configuration stored in `/etc/fwrd/`:

- `config.json` - Main configuration and rules
- `rules/` - Rule-specific configurations
- `backups/` - Automatic backups
- `logs/` - Operation logs

## Performance Testing

Built-in connection testing:

- Target IP/port validation
- Configurable test duration
- Success rate reporting
- Performance recommendations

## Security Features

- Dedicated system users for each tool
- Security hardening (NoNewPrivileges, ProtectSystem)
- Input validation and sanitization
- Service isolation with systemd

## Examples

### Basic Port Forward

```
Listen port: 8080
Target IP: 192.168.1.100
Target port: 80
Protocol: TCP
Result: 0.0.0.0:8080 -> 192.168.1.100:80
```

### Range Forward (GOST)

```
Listen port: 10000-10100
Target IP: remote.example.com
Target port: 3000-3100
Protocol: TCP + UDP
```

### High Performance (NFTables)

```
Listen port: 443
Target IP: backend.local
Target port: 8443
Protocol: TCP
Tool: nftables (auto-selected for performance)
```

## Troubleshooting

### Common Issues

1. **Permission Denied**: Run with `sudo`
2. **Port in Use**: Script detects and warns about conflicts
3. **Tool Not Found**: Use install menu to add tools
4. **Service Failed**: Check logs via service control menu

### Log Locations

- System logs: `journalctl -u <service_name>`
- Script logs: `/etc/fwrd/logs/`
- Service status: Built-in system status display

## Network Requirements

- Outbound internet for tool installation
- Required ports open for forwarding
- IP forwarding enabled (auto-configured)

---

_For advanced configuration and remote server testing, refer to the workspace rules in your environment._
