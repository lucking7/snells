# NFTables 转发管理脚本使用说明

## 概述

这是一个专为 Debian/Ubuntu 系统设计的 nftables 转发管理脚本，提供了完整的网络转发规则管理功能。

## 主要功能

- ✅ **自动安装和更新** nftables
- ✅ **智能初始化** 配置文件
- ✅ **灵活转发规则** 支持 TCP/UDP/双协议
- ✅ **高级转发** 同一端口的 TCP/UDP 可分别转发到不同地址
- ✅ **源IP限制** 可指定特定源IP的转发
- ✅ **规则管理** 添加、删除、列表、清空
- ✅ **批量操作** 导入/导出规则
- ✅ **实时测试** 转发规则连通性测试
- ✅ **备份恢复** 自动备份配置文件
- ✅ **日志管理** 彩色输出和详细日志

## 系统要求

- **操作系统**: Debian 9+ 或 Ubuntu 18.04+
- **权限**: root 用户或具有 sudo 权限
- **内核**: 支持 nftables (Linux 3.13+)

## 快速开始

### 1. 脚本安装

```bash
# 下载脚本
wget https://your-server.com/nftables_forward.sh
# 或者直接复制脚本内容到本地文件

# 添加可执行权限
chmod +x nftables_forward.sh

# 移动到系统路径（可选）
sudo mv nftables_forward.sh /usr/local/bin/nftables-forward
```

### 2. 初始化系统

```bash
# 安装 nftables（如果未安装）
sudo ./nftables_forward.sh install

# 初始化配置
sudo ./nftables_forward.sh init
```

### 3. 添加第一个转发规则

```bash
# 将外部80端口的TCP流量转发到内网192.168.1.100:8080
sudo ./nftables_forward.sh add tcp 80 192.168.1.100 8080 any web_server
```

## 详细用法

### 命令语法

```bash
./nftables_forward.sh [命令] [参数...]
```

### 可用命令

| 命令 | 参数 | 描述 | 示例 |
|------|------|------|------|
| `install` | 无 | 安装/更新 nftables | `./script.sh install` |
| `init` | 无 | 初始化基础配置 | `./script.sh init` |
| `add` | `<proto> <ext_port> <int_ip> <int_port> [src_ip] [name]` | 添加转发规则 | `./script.sh add tcp 80 192.168.1.100 8080` |
| `advanced` | `<ext_port> <tcp_target> <udp_target> [name]` | 高级转发（同端口不同协议） | `./script.sh advanced 53 192.168.1.10:53 192.168.1.11:53` |
| `delete` | `<rule_id>` | 删除转发规则 | `./script.sh delete web_server` |
| `list` | 无 | 列出所有规则 | `./script.sh list` |
| `flush` | 无 | 清空所有规则 | `./script.sh flush` |
| `save` | 无 | 保存当前规则 | `./script.sh save` |
| `reload` | 无 | 重新加载配置 | `./script.sh reload` |
| `status` | 无 | 显示系统状态 | `./script.sh status` |
| `test` | `<port> [ip]` | 测试转发规则 | `./script.sh test 80` |
| `import` | `<file>` | 批量导入规则 | `./script.sh import rules.txt` |
| `export` | `[file]` | 导出规则到文件 | `./script.sh export backup.txt` |
| `help` | 无 | 显示帮助信息 | `./script.sh help` |

## 使用示例

### 基础转发示例

#### 1. Web服务器转发
```bash
# 将外部80端口转发到内网Web服务器
sudo ./nftables_forward.sh add tcp 80 192.168.1.100 8080 any web_server

# 将外部443端口转发到内网HTTPS服务器
sudo ./nftables_forward.sh add tcp 443 192.168.1.100 8443 any https_server
```

#### 2. SSH转发
```bash
# 将外部2222端口转发到内网SSH服务器
sudo ./nftables_forward.sh add tcp 2222 192.168.1.50 22 any ssh_server
```

#### 3. DNS服务器转发
```bash
# 将DNS请求转发到内网DNS服务器（TCP和UDP）
sudo ./nftables_forward.sh add both 53 192.168.1.10 53 any dns_server
```

### 高级转发示例

#### 1. 同端口不同协议转发
```bash
# 53端口：TCP转发到192.168.1.10:53，UDP转发到192.168.1.11:53
sudo ./nftables_forward.sh advanced 53 192.168.1.10:53 192.168.1.11:53 dns_split
```

#### 2. 游戏服务器转发
```bash
# 游戏端口：TCP转发到游戏服务器，UDP转发到语音服务器
sudo ./nftables_forward.sh advanced 25565 192.168.1.20:25565 192.168.1.21:25565 minecraft
```

### 源IP限制示例

#### 1. 限制管理访问
```bash
# 只允许特定IP访问SSH转发
sudo ./nftables_forward.sh add tcp 2222 192.168.1.50 22 10.0.0.100 admin_ssh
```

#### 2. 内网专用服务
```bash
# 只允许内网访问数据库
sudo ./nftables_forward.sh add tcp 3306 192.168.1.200 3306 192.168.1.0/24 mysql_server
```

### 批量管理示例

#### 1. 导出当前规则
```bash
# 导出所有规则到文件
sudo ./nftables_forward.sh export my_rules_backup.txt
```

#### 2. 批量导入规则
首先创建规则文件 `bulk_rules.txt`：
```
# 格式: protocol|external_port|internal_ip|internal_port|external_ip|rule_name
tcp|80|192.168.1.100|8080|any|web_server
tcp|443|192.168.1.100|8443|any|https_server
udp|53|192.168.1.10|53|any|dns_server
tcp|22|192.168.1.50|22|10.0.0.100|admin_ssh
```

然后导入：
```bash
sudo ./nftables_forward.sh import bulk_rules.txt
```

## 高级配置

### 网络接口配置

编辑 `/etc/nftables.conf`，修改网络接口定义：

```bash
# 根据实际网络环境修改
define WAN_IF = "enp0s3"    # 外网接口
define LAN_IF = "enp0s8"    # 内网接口
```

### 防火墙集成

脚本默认创建开放的转发策略。如需要更严格的安全控制，可以：

1. **修改默认策略为 drop**：
```bash
# 编辑 /etc/nftables.conf
# 将 policy accept 改为 policy drop
```

2. **添加特定允许规则**：
```bash
# 在 input 链中添加允许规则
nft add rule inet filter input tcp dport 22 accept
nft add rule inet filter input tcp dport 80 accept
```

### 日志监控

启用转发日志记录：

```bash
# 添加日志规则
nft add rule ip nat prerouting log prefix "NAT-Forward: " level info
```

查看日志：
```bash
# 查看实时日志
journalctl -f | grep "NAT-Forward"

# 查看历史日志
journalctl | grep "NAT-Forward"
```

## 故障排除

### 常见问题

#### 1. 转发不工作
```bash
# 检查IP转发是否启用
sysctl net.ipv4.ip_forward

# 启用IP转发
echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
sysctl -p
```

#### 2. 规则不生效
```bash
# 检查 nftables 服务状态
sudo ./nftables_forward.sh status

# 重新加载规则
sudo ./nftables_forward.sh reload
```

#### 3. 端口无法访问
```bash
# 测试特定端口
sudo ./nftables_forward.sh test 80

# 检查目标服务器是否可达
ping 192.168.1.100
telnet 192.168.1.100 8080
```

### 调试模式

启用详细输出：
```bash
# 在脚本中添加调试信息
set -x  # 在脚本开头添加此行
```

### 规则验证

```bash
# 列出当前所有规则
sudo nft list ruleset

# 检查特定表
sudo nft list table ip nat

# 显示规则统计
sudo nft list ruleset -s
```

## 性能优化

### 1. 规则顺序优化
将常用规则放在前面，减少匹配时间。

### 2. 连接跟踪优化
```bash
# 增加连接跟踪表大小
echo 'net.netfilter.nf_conntrack_max = 131072' >> /etc/sysctl.conf
```

### 3. 内存优化
```bash
# 调整哈希表大小
echo 'net.netfilter.nf_conntrack_buckets = 16384' >> /etc/sysctl.conf
```

## 安全建议

### 1. 最小权限原则
- 只开放必要的端口
- 使用源IP限制减少攻击面
- 定期审查转发规则

### 2. 监控和日志
- 启用连接日志
- 监控异常流量
- 定期备份配置

### 3. 防护措施
```bash
# 启用SYN flood保护
echo 'net.ipv4.tcp_syncookies = 1' >> /etc/sysctl.conf

# 限制并发连接
nft add rule inet filter input ct count over 100 drop
```

## 配置文件说明

### 主配置文件
- `/etc/nftables.conf` - nftables主配置文件
- `/etc/nftables_forward_rules.txt` - 转发规则记录文件

### 备份文件
脚本会自动创建备份文件：
- `/etc/nftables.conf.bak.YYYYMMDD_HHMMSS`

### 服务管理
```bash
# 启用开机自启动
sudo systemctl enable nftables.service

# 启动服务
sudo systemctl start nftables.service

# 查看服务状态
sudo systemctl status nftables.service
```

## 脚本更新

定期检查和更新脚本：

1. **检查版本**：
```bash
./nftables_forward.sh help | head -1
```

2. **备份当前配置**：
```bash
sudo ./nftables_forward.sh export update_backup.txt
```

3. **更新脚本后恢复配置**：
```bash
sudo ./nftables_forward.sh import update_backup.txt
```

## 贡献和支持

如果您发现bug或有功能建议，请：

1. 检查现有的issue
2. 提供详细的错误信息
3. 包含系统环境信息
4. 提供复现步骤

## 许可证

本脚本基于MIT许可证发布，允许自由使用和修改。

---

**注意**: 在生产环境中使用前，请务必在测试环境中充分验证所有功能。