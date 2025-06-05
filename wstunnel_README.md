# wstunnel 管理脚本使用指南

## 简介

这是一个功能完善的 [wstunnel](https://github.com/erebe/wstunnel) 客户端管理脚本，提供了友好的菜单界面来管理 WebSocket 隧道转发规则。

## 功能特性

- 🚀 **一键安装** - 自动下载并安装最新版本的 wstunnel
- 📋 **菜单式操作** - 直观的交互式菜单，易于使用
- 🔀 **多协议支持** - 支持 TCP、UDP、SOCKS5 转发
- 🌐 **IP 智能识别** - 自动检测 IPv4/IPv6 支持，显示 IP、ASN、ORG 信息
- 🔧 **服务管理** - 集成 systemd 服务，支持开机自启
- 📝 **规则管理** - 添加、删除、启用/禁用转发规则
- 📊 **实时状态** - 显示服务运行状态和日志

## 安装使用

### 1. 下载脚本

```bash
wget https://raw.githubusercontent.com/your-repo/wstunnel.sh
chmod +x wstunnel.sh
```

### 2. 运行脚本

```bash
sudo ./wstunnel.sh
```

> ⚠️ **注意**：脚本需要 root 权限运行

## 使用说明

### 主菜单界面

运行脚本后会显示主菜单，包含以下信息：

- **IP 信息显示**：自动获取并显示本机的 IPv4/IPv6 地址、ASN、组织信息
- **服务状态**：显示 wstunnel 服务当前运行状态
- **服务器配置**：显示已配置的 wstunnel 服务器地址

### 功能菜单

#### 转发管理
1. **添加转发规则**
   - 选择协议类型（TCP/UDP/SOCKS5）
   - 选择监听地址（IPv4/IPv6/本地回环）
   - 设置端口和目标地址
   - 添加备注说明

2. **查看转发规则**
   - 列出所有已配置的转发规则
   - 显示规则状态（启用/禁用）

3. **删除转发规则**
   - 选择要删除的规则
   - 确认后删除

4. **启用/禁用规则**
   - 切换规则的启用状态

#### 服务管理
5. **配置服务器**
   - 设置 wstunnel 服务器 URL
   - 配置 HTTP 升级路径前缀密钥（可选）

6. **启动服务**
7. **停止服务**
8. **重启服务**
9. **查看日志**

#### 系统功能
10. **安装/更新 wstunnel**
11. **设置开机启动**
12. **取消开机启动**

## 配置示例

### 添加 TCP 转发

```
协议: TCP
监听地址: 0.0.0.0 (IPv4)
本地端口: 8080
远程地址: example.com
远程端口: 80
备注: Web服务转发
```

### 添加 UDP 转发（用于 WireGuard）

```
协议: UDP
监听地址: [::] (IPv6)
本地端口: 51820
远程地址: localhost
远程端口: 51820
UDP超时: 0 (不超时)
备注: WireGuard VPN
```

### 添加 SOCKS5 代理

```
协议: SOCKS5
监听地址: 127.0.0.1
本地端口: 1080
备注: 本地SOCKS5代理
```

## 配置文件

脚本使用 JSON 格式存储配置，位置：`/etc/wstunnel/config.json`

```json
{
  "tunnels": [
    {
      "id": "abc12345",
      "protocol": "tcp",
      "listen_addr": "0.0.0.0",
      "local_port": "8080",
      "remote_host": "example.com",
      "remote_port": "80",
      "config": "tcp://0.0.0.0:8080:example.com:80",
      "comment": "Web服务转发",
      "enabled": true
    }
  ],
  "server": {
    "url": "wss://my-server.com:443",
    "secret": "my-secret-key"
  }
}
```

## 系统要求

- Linux 系统（支持 systemd）
- 支持的架构：x86_64、aarch64、armv7
- 依赖软件：jq、curl、wget（脚本会自动安装）

## 故障排查

### 服务无法启动

1. 检查服务器配置是否正确
2. 查看服务日志：选择菜单选项 9
3. 确保防火墙允许相应端口

### 转发不工作

1. 确认规则已启用
2. 检查本地端口是否被占用
3. 验证远程服务器可访问

### 日志查看

```bash
# 查看详细日志
journalctl -u wstunnel-client -f

# 查看启动脚本
cat /usr/local/bin/wstunnel-start.sh
```

## 安全建议

1. **使用 HTTPS/WSS**：始终使用加密连接
2. **设置密钥**：配置 HTTP 升级路径前缀密钥
3. **限制访问**：仅监听必要的地址和端口
4. **定期更新**：保持 wstunnel 版本最新

## 相关链接

- [wstunnel 官方仓库](https://github.com/erebe/wstunnel)
- [wstunnel 文档](https://github.com/erebe/wstunnel#readme)

## 许可证

本脚本遵循 MIT 许可证