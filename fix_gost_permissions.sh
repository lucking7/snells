#!/bin/bash

# GOST 权限修复脚本
# 解决 nobody 用户无法读取配置文件的问题

echo "=== GOST 权限问题修复脚本 ==="

# 检查配置文件是否存在
if [ -f "/etc/gost/config.json" ]; then
    echo "[信息] 发现配置文件: /etc/gost/config.json"
    
    # 显示当前权限
    echo "[当前权限]:"
    ls -la /etc/gost/config.json
    
    # 修复权限
    echo "[修复中] 设置正确的文件权限..."
    sudo chown root:root /etc/gost/config.json
    sudo chmod 644 /etc/gost/config.json
    
    # 确保目录权限正确
    echo "[修复中] 设置目录权限..."
    sudo chown root:root /etc/gost/
    sudo chmod 755 /etc/gost/
    
    echo "[修复后权限]:"
    ls -la /etc/gost/config.json
    ls -ld /etc/gost/
    
else
    echo "[错误] 配置文件不存在: /etc/gost/config.json"
    echo "[建议] 重新运行 gost.sh 脚本创建配置文件"
fi

# 检查 nobody 用户是否可以读取文件
echo "[测试] 检查 nobody 用户是否可以读取配置文件..."
if sudo -u nobody test -r /etc/gost/config.json; then
    echo "[成功] nobody 用户可以读取配置文件"
else
    echo "[失败] nobody 用户仍无法读取配置文件"
    echo "[建议] 考虑以下替代方案:"
    echo "1. 将配置文件移动到 /home/gost/ 目录"
    echo "2. 修改systemd服务使用不同用户"
    echo "3. 使用完整路径权限"
fi

# 停止并重启服务
echo "[服务] 重启 GOST 服务..."
sudo systemctl stop gost
sudo systemctl start gost

echo "[状态] 检查服务状态..."
sudo systemctl status gost --no-pager -l

echo "=== 修复完成 ==="
echo "如果问题仍然存在，请运行: journalctl -u gost -f" 
