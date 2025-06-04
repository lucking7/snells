# NFTables 转发管理脚本

一个功能完整的 nftables 转发管理脚本，专为 Debian/Ubuntu 系统设计，提供简单易用的网络转发规则管理功能。

## 🚀 特性

- ✅ **一键安装** - 自动安装和配置 nftables
- ✅ **智能转发** - 支持 TCP/UDP/双协议转发
- ✅ **高级转发** - 同端口不同协议转发到不同地址
- ✅ **源IP限制** - 支持按源IP过滤转发规则
- ✅ **批量管理** - 导入/导出规则配置
- ✅ **实时测试** - 内置连通性测试功能
- ✅ **安全可靠** - 自动备份和恢复机制

## 📦 文件说明

| 文件名 | 描述 |
|--------|------|
| `nftables_forward.sh` | 主脚本文件 |
| `nftables_forward_使用说明.md` | 详细使用手册 |
| `示例规则配置.txt` | 批量导入规则示例 |
| `README.md` | 项目概述（本文件） |

## ⚡ 快速开始

### 1. 下载并安装
```bash
# 下载脚本
wget https://github.com/your-repo/nftables-forward/raw/main/nftables_forward.sh

# 添加执行权限
chmod +x nftables_forward.sh

# 安装 nftables
sudo ./nftables_forward.sh install

# 初始化配置
sudo ./nftables_forward.sh init
```

### 2. 添加转发规则
```bash
# HTTP转发：外部80端口 -> 内网192.168.1.100:8080
sudo ./nftables_forward.sh add tcp 80 192.168.1.100 8080

# HTTPS转发：外部443端口 -> 内网192.168.1.100:8443
sudo ./nftables_forward.sh add tcp 443 192.168.1.100 8443

# SSH转发（限制源IP）：外部2222端口 -> 内网192.168.1.50:22
sudo ./nftables_forward.sh add tcp 2222 192.168.1.50 22 10.0.0.100
```

### 3. 高级功能
```bash
# 同端口不同协议转发（DNS为例）
sudo ./nftables_forward.sh advanced 53 192.168.1.10:53 192.168.1.11:53

# 查看所有转发规则
sudo ./nftables_forward.sh list

# 测试转发规则
sudo ./nftables_forward.sh test 80

# 批量导入规则
sudo ./nftables_forward.sh import 示例规则配置.txt
```

## 📋 主要命令

| 命令 | 功能 | 示例 |
|------|------|------|
| `install` | 安装/更新 nftables | `./script.sh install` |
| `init` | 初始化配置 | `./script.sh init` |
| `add` | 添加转发规则 | `./script.sh add tcp 80 192.168.1.100 8080` |
| `advanced` | 高级转发 | `./script.sh advanced 53 192.168.1.10:53 192.168.1.11:53` |
| `delete` | 删除规则 | `./script.sh delete web_server` |
| `list` | 列出所有规则 | `./script.sh list` |
| `flush` | 清空所有规则 | `./script.sh flush` |
| `test` | 测试转发规则 | `./script.sh test 80` |
| `import` | 批量导入 | `./script.sh import rules.txt` |
| `export` | 导出规则 | `./script.sh export` |

## 🎯 使用场景

### Web服务器负载均衡
```bash
# 将外部访问分发到多个内网服务器
sudo ./nftables_forward.sh add tcp 80 192.168.1.100 80 any web1
sudo ./nftables_forward.sh add tcp 8080 192.168.1.101 80 any web2
```

### 游戏服务器端口转发
```bash
# Minecraft服务器
sudo ./nftables_forward.sh add tcp 25565 192.168.1.200 25565 any minecraft
# TeamSpeak语音服务器
sudo ./nftables_forward.sh add udp 9987 192.168.1.201 9987 any teamspeak
```

### 数据库服务访问
```bash
# MySQL数据库（限制内网访问）
sudo ./nftables_forward.sh add tcp 3306 192.168.1.150 3306 192.168.1.0/24 mysql
```

## 🔧 系统要求

- **操作系统**: Debian 9+ / Ubuntu 18.04+
- **权限**: root 或 sudo 权限
- **内核**: 支持 nftables (Linux 3.13+)
- **依赖**: nftables 包（脚本会自动安装）

## 🛡️ 安全特性

- **自动备份**: 每次修改都自动备份配置
- **参数验证**: 严格的输入参数验证
- **源IP限制**: 支持基于源IP的访问控制
- **恢复机制**: 配置错误时自动恢复备份

## 🔍 故障排除

### 转发不工作？
```bash
# 检查IP转发是否启用
sysctl net.ipv4.ip_forward

# 启用IP转发
echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
sysctl -p
```

### 规则不生效？
```bash
# 检查服务状态
sudo ./nftables_forward.sh status

# 重新加载配置
sudo ./nftables_forward.sh reload
```

## 📚 文档

- 📖 [详细使用手册](nftables_forward_使用说明.md) - 完整的功能说明和配置指南
- 📝 [示例配置](示例规则配置.txt) - 各种场景的转发规则示例
- 🆘 [故障排除](nftables_forward_使用说明.md#故障排除) - 常见问题解决方案

## 🤝 贡献

欢迎提交 Issue 和 Pull Request！

## 📄 许可证

MIT License - 自由使用和修改

---

**⚠️ 注意**: 在生产环境使用前，请务必在测试环境中充分验证所有功能。

```bash
bash <(curl -Ls https://raw.githubusercontent.com/ilychi/snells/main/snells.sh)
```

### gost

```bash
bash <(curl -Ls https://raw.githubusercontent.com/ilychi/snells/main/gost.sh)
```

### realm

```bash
bash <(curl -Ls https://raw.githubusercontent.com/ilychi/snells/main/realm.sh)
```

### brook

```bash
bash <(curl -Ls https://raw.githubusercontent.com/ilychi/snells/main/brook.sh)
```
