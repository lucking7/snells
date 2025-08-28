# Forward Manager (fwrd.sh)

A unified management tool for GOST, NFTables, and Realm forwarding tools.

## Features

- **Quick Setup Mode**: Press Enter through all prompts for instant deployment with optimal defaults
- **Progressive Input**: Step-by-step IP and port entry with validation and smart defaults
- **Auto Error Correction**: Input sanitization and retry mechanisms
- **Tool Auto-selection**: Smart forwarding tool recommendation based on performance
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
3. **Add rule (standard)** - Create standard forwarding rule (progressive input)
4. **Add rule (advanced)** - Create separate TCP/UDP forwarding rules
5. **Add rule (templates)** 🚀 - Quick setup with pre-configured templates
6. **List rules** - Display all active rules
7. **Modify rule** - Update existing rule settings
8. **Delete rule** - Remove forwarding rule
9. **Service control** - Manage tool services
10. **Performance test** - Test connection performance
11. **Health check** - Complete system diagnostics

### Progressive Rule Creation

The script guides you through rule creation step by step with smart defaults:

1. **Listen Port**: Enter port or **press Enter** for auto-selected random port
2. **Target IP**: Enter destination IP (with validation)
3. **Target Port**: Enter destination port (with validation)
4. **Protocol**: Choose TCP, UDP, or **press Enter** for TCP+UDP (recommended)
5. **Tool**: Auto-select or **press Enter** for smart tool selection
6. **Listen IP**: Specify custom IP or **press Enter** for 0.0.0.0 (all interfaces)
7. **Confirmation**: **Press Enter** to create rule or type 'n' to cancel

#### Quick Setup Mode

For rapid deployment, simply **press Enter** through all prompts to use optimal defaults:

- Random available port
- TCP+UDP protocol
- Auto-selected best tool
- Listen on all interfaces

### New Enhanced Interface Preview

🚀 **The redesigned interface provides a clean, step-by-step experience:**

```
🚀 Add Forward Rule - Quick Setup
Press Enter for defaults or enter custom values

Step 1: Listen Port
Listen port (Enter for random): [Enter]
  ✓ Auto-selected port: 12345

Step 4: Protocol
1) TCP only  2) UDP only  3) TCP+UDP
Protocol (Enter for TCP+UDP): [Enter]
  ✓ Protocol: TCP + UDP (default)

══════════════════════════════════════
📋 RULE SUMMARY
══════════════════════════════════════
  🎯 Forward: 0.0.0.0:12345 → 23.249.27.109:43475
  🔗 Protocol: both
  🛠️  Tool: auto-select
══════════════════════════════════════

✅ SUCCESS! Rule created successfully!
```

**Key improvements over the old interface:**

- ✅ No complex nested menus that could hang
- ✅ Simple one-line inputs for everything
- ✅ Visual ✓ confirmation after each step
- ✅ Beautiful colored output with emojis
- ✅ All defaults work with just Enter key
- ✅ Clear step numbering and progression

### 🔧 Advanced Separate TCP/UDP Rules

**NEW FEATURE** - Configure different targets for TCP and UDP traffic on the same port:

```
🔧 Advanced Rule - Separate TCP/UDP Targets

Step 1: Listen Port: 8080
Step 2: TCP Target: web.example.com:80
Step 3: UDP Target: dns.example.com:53

Result:
📡 TCP traffic to port 8080 → web.example.com:80
📡 UDP traffic to port 8080 → dns.example.com:53
```

**Use Cases:**

- **Port 53**: TCP → DNS-over-TCP, UDP → Regular DNS
- **Port 443**: TCP → HTTPS, UDP → QUIC/HTTP3
- **Port 80**: TCP → Web Server, UDP → Game Server
- **Port 514**: TCP → Syslog-TCP, UDP → Syslog-UDP

**Supported Tools**: GOST, NFTables, Realm (all tools support separate targets)

### 🚀 Quick Templates (New Feature!)

**One-click deployment for common scenarios:**

#### Available Templates:

1. **🌐 HTTP Proxy** - Forward HTTP traffic (port 80 → target server)
2. **🔒 HTTPS Proxy** - Forward HTTPS traffic (port 443 → target server)
3. **🔐 SSH Forward** - Secure SSH tunneling (port 2222 → port 22)
4. **🔍 DNS Split** - Separate DNS servers for TCP/UDP traffic
5. **💻 Dev Server** - Development server forwarding (3000/8080)
6. **🎮 Game Server** - Gaming traffic forwarding (UDP optimized)
7. **🗃️ Database Proxy** - MySQL/DB connection proxy (33306 → 3306)

#### Template Benefits:

- ⚡ **Instant Setup**: Pre-configured with optimal settings
- 🎯 **Best Practices**: Industry-standard port recommendations
- 💡 **Guided Input**: Smart defaults with helpful examples
- 🔧 **Auto-Configuration**: Automatic tool selection and optimization

#### Example Usage:

```bash
🚀 Quick Templates - Choose a scenario:
1. HTTP Proxy
Target Server IP: example.com
✅ HTTP Proxy created successfully!
🔗 Access: http://localhost:8080 → http://example.com:80
```

### Enhanced User Experience

#### 🛠️ Interactive Help System:

- Type **`?`** in any input field for context-sensitive help
- **IP Help**: IPv4, IPv6, and domain format examples
- **Port Help**: Range guidance, common ports, system reserved ports

#### 🚨 Smart Validation:

```bash
❌ 无效端口号，必须在 1-65535 范围内
💡 端口号帮助：
   • 范围: 1-65535
   • 常用: 80(HTTP), 443(HTTPS), 8080(代理)
   • 避免: 22(SSH), 53(DNS), 25(SMTP) (系统保留)
   • 推荐: 10000-65000 (用户端口)
```

#### ⚠️ Port Conflict Detection:

- Automatic detection of ports in use
- Warning prompts before overwriting
- Smart recommendations for alternative ports

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
