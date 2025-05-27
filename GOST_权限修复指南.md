# GOST 权限问题修复指南

## 问题描述

GOST 服务启动失败，错误信息：`open /etc/gost/config.json: permission denied`

## 快速解决方案

### 方案一：使用权限修复脚本

在 Linux 服务器上运行：

```bash
chmod +x fix_gost_permissions.sh
./fix_gost_permissions.sh
```

### 方案二：手动修复权限

```bash
# 1. 停止服务
sudo systemctl stop gost

# 2. 修复配置文件权限
sudo chown root:root /etc/gost/config.json
sudo chmod 644 /etc/gost/config.json

# 3. 修复目录权限
sudo chown root:root /etc/gost/
sudo chmod 755 /etc/gost/

# 4. 验证nobody用户可以读取
sudo -u nobody test -r /etc/gost/config.json && echo "权限正确" || echo "权限仍有问题"

# 5. 重启服务
sudo systemctl start gost
sudo systemctl status gost
```

### 方案三：使用改进的脚本

使用更新后的 `gost.sh` 脚本重新部署：

```bash
# 备份现有配置
sudo cp /etc/gost/config.json /etc/gost/config.json.backup

# 运行改进的脚本
./gost.sh
# 选择 "4. Configuration File Management" -> "2. Apply current config file"
```

## 改进的功能

### 新的用户管理

- 创建专门的 `gost` 系统用户
- 回退机制：如果创建失败，使用 `nobody` 用户
- 更安全的权限设置

### 增强的安全性

- `NoNewPrivileges=true` - 防止权限提升
- `PrivateTmp=true` - 私有临时目录
- `ProtectSystem=strict` - 保护系统文件
- `ProtectHome=true` - 保护用户目录

### 自动权限验证

- 自动检测和修复权限问题
- 验证用户是否可以读取配置文件
- 详细的错误提示和解决建议

## 故障排除

### 检查服务状态

```bash
sudo systemctl status gost
journalctl -u gost -f
```

### 检查配置文件权限

```bash
ls -la /etc/gost/config.json
ls -ld /etc/gost/
```

### 测试用户权限

```bash
# 测试gost用户（如果存在）
sudo -u gost test -r /etc/gost/config.json && echo "gost用户可以读取" || echo "gost用户无法读取"

# 测试nobody用户
sudo -u nobody test -r /etc/gost/config.json && echo "nobody用户可以读取" || echo "nobody用户无法读取"
```

## 替代方案

如果仍有权限问题，可考虑：

1. **使用用户目录**：将配置移到 `$HOME/gost/`
2. **使用其他用户**：修改 systemd 服务使用当前用户
3. **检查 SELinux**：如果启用，可能需要配置 SELinux 规则

## 联系支持

如果问题仍然存在，请提供以下信息：

- `ls -la /etc/gost/`
- `sudo systemctl status gost`
- `journalctl -u gost -n 20`
