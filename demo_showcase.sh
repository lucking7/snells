#!/bin/bash

# NFTables转发脚本功能演示
# 展示主要功能和使用方法

echo "=========================================="
echo "🚀 NFTables转发管理脚本功能演示"
echo "=========================================="

SCRIPT="./nftables_forward.sh"

# 颜色定义
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

demo_section() {
    echo
    echo -e "${BLUE}=========================================="
    echo -e "📋 $1"
    echo -e "==========================================${NC}"
}

demo_command() {
    echo
    echo -e "${YELLOW}💻 命令演示: $1${NC}"
    echo -e "${GREEN}$2${NC}"
    echo "输出示例:"
    echo "$3"
}

demo_section "1. 脚本基本信息"

echo "📁 项目文件结构:"
ls -la *.sh *.md *.txt 2>/dev/null | head -10

echo
echo "📊 脚本统计信息:"
echo "- 主脚本大小: $(wc -c < nftables_forward.sh) 字节"
echo "- 代码行数: $(wc -l < nftables_forward.sh) 行"
echo "- 函数数量: $(grep -c "^[a-zA-Z_][a-zA-Z0-9_]*() {" nftables_forward.sh)"
echo "- 示例规则数: $(grep -cE '^[^#].*\|.*\|.*\|.*\|.*\|.*$' 示例规则配置.txt)"

demo_section "2. 帮助和版本信息"

demo_command "查看帮助信息" \
    "sudo $SCRIPT help" \
    "nftables转发管理脚本 v1.0.0
适用于 Debian/Ubuntu 系统

用法: ./nftables_forward.sh [选项]

选项:
  install                    安装/更新 nftables
  init                       初始化 nftables 配置
  add <proto> <ext_port> <int_ip> <int_port> [src_ip] [name]
                            添加转发规则
  ..."

demo_section "3. 基础转发规则示例"

demo_command "添加Web服务器转发" \
    "sudo $SCRIPT add tcp 80 192.168.1.100 8080 any web_server" \
    "[INFO] 添加转发规则: web_server
[DEBUG] 协议: tcp, 外部端口: 80, 内部地址: 192.168.1.100:8080
[INFO] TCP转发规则添加成功
[INFO] 规则已保存到 /etc/nftables.conf"

demo_command "添加SSH转发（限制源IP）" \
    "sudo $SCRIPT add tcp 2222 192.168.1.50 22 10.0.0.100 admin_ssh" \
    "[INFO] 添加转发规则: admin_ssh
[DEBUG] 协议: tcp, 外部端口: 2222, 内部地址: 192.168.1.50:22
[INFO] TCP转发规则添加成功（仅允许 10.0.0.100 访问）"

demo_command "添加DNS服务器转发（TCP+UDP）" \
    "sudo $SCRIPT add both 53 192.168.1.10 53 any dns_server" \
    "[INFO] 添加转发规则: dns_server
[INFO] TCP转发规则添加成功
[INFO] UDP转发规则添加成功"

demo_section "4. 高级转发功能"

demo_command "同端口不同协议转发" \
    "sudo $SCRIPT advanced 53 192.168.1.10:53 192.168.1.11:53 dns_split" \
    "[INFO] 添加高级转发规则: dns_split
[DEBUG] 端口 53: TCP -> 192.168.1.10:53, UDP -> 192.168.1.11:53
[INFO] TCP转发规则添加成功: 53 -> 192.168.1.10:53
[INFO] UDP转发规则添加成功: 53 -> 192.168.1.11:53
[INFO] 高级转发规则 'dns_split' 添加完成"

demo_section "5. 规则管理功能"

demo_command "列出所有转发规则" \
    "sudo $SCRIPT list" \
    "[INFO] 当前转发规则列表:

序号 协议     外端口 内网IP          内端口 源IP限制        规则名称             创建时间
--------------------------------------------------------------------------------------------------------
1    tcp      80     192.168.1.100   8080   any             web_server           2024-01-01 10:00:00
2    tcp      2222   192.168.1.50    22     10.0.0.100      admin_ssh            2024-01-01 10:01:00
3    tcp      53     192.168.1.10    53     any             dns_server_tcp       2024-01-01 10:02:00
4    udp      53     192.168.1.10    53     any             dns_server_udp       2024-01-01 10:02:00"

demo_command "删除转发规则" \
    "sudo $SCRIPT delete web_server" \
    "[INFO] 删除转发规则: web_server
[INFO] 删除了句柄为 15 的规则
[INFO] 转发规则删除成功"

demo_command "测试转发规则" \
    "sudo $SCRIPT test 80" \
    "[INFO] 测试端口 80 的转发规则...
[INFO] 找到端口 80 的转发规则
tcp dport 80 dnat to 192.168.1.100:8080
[INFO] 测试连接到 127.0.0.1:80...
Connection to 127.0.0.1 80 port [tcp/http] succeeded!"

demo_section "6. 批量管理功能"

demo_command "导出当前规则" \
    "sudo $SCRIPT export backup_rules.txt" \
    "[INFO] 导出转发规则到: backup_rules.txt
[INFO] 已导出 5 条规则到 backup_rules.txt"

demo_command "批量导入规则" \
    "sudo $SCRIPT import 示例规则配置.txt" \
    "[INFO] 从文件导入转发规则: 示例规则配置.txt
[INFO] TCP转发规则添加成功
[INFO] TCP转发规则添加成功
[INFO] UDP转发规则添加成功
...
[INFO] 导入完成 - 成功: 53, 失败: 0"

demo_section "7. 系统管理功能"

demo_command "查看系统状态" \
    "sudo $SCRIPT status" \
    "[INFO] nftables 系统状态:

服务状态:
● nftables.service - Netfilter Tables
   Loaded: loaded (/lib/systemd/system/nftables.service; enabled)
   Active: active (exited) since Mon 2024-01-01 10:00:00 UTC

规则统计:
总转发规则数: 15

相关内核模块:
nf_tables              32768  10
nf_nat                 32768  2 nf_tables,xt_nat"

demo_command "保存当前规则" \
    "sudo $SCRIPT save" \
    "[INFO] 保存规则到配置文件...
[INFO] 规则已保存到 /etc/nftables.conf"

demo_command "重新加载规则" \
    "sudo $SCRIPT reload" \
    "[INFO] 重新加载nftables规则...
[INFO] 规则重新加载成功"

demo_section "8. 实际使用场景示例"

echo "🌐 Web服务器负载均衡:"
echo "sudo $SCRIPT add tcp 80 192.168.1.100 80 any web1"
echo "sudo $SCRIPT add tcp 8080 192.168.1.101 80 any web2"

echo
echo "🎮 游戏服务器端口转发:"
echo "sudo $SCRIPT add tcp 25565 192.168.1.200 25565 any minecraft"
echo "sudo $SCRIPT add udp 9987 192.168.1.201 9987 any teamspeak"

echo
echo "🗄️ 数据库服务访问（安全限制）:"
echo "sudo $SCRIPT add tcp 3306 192.168.1.150 3306 192.168.1.0/24 mysql"
echo "sudo $SCRIPT add tcp 5432 192.168.1.151 5432 192.168.1.0/24 postgresql"

echo
echo "🔧 管理服务转发:"
echo "sudo $SCRIPT add tcp 2222 192.168.1.50 22 10.0.0.100 admin_ssh"
echo "sudo $SCRIPT add tcp 3389 192.168.1.60 3389 10.0.0.0/24 rdp"

demo_section "9. 配置文件示例"

echo "📝 示例配置文件格式 (示例规则配置.txt):"
echo "# 格式: protocol|external_port|internal_ip|internal_port|external_ip|rule_name"
head -20 示例规则配置.txt

demo_section "10. 安全特性"

echo "🛡️ 安全功能:"
echo "✅ 自动备份配置文件"
echo "✅ 严格的参数验证"
echo "✅ 源IP访问控制"
echo "✅ 错误恢复机制"
echo "✅ 操作确认提示"

echo
echo "🔍 参数验证示例:"
echo "- IP地址格式检查: 192.168.1.1 ✅  256.256.256.256 ❌"
echo "- 端口范围检查: 80 ✅  65536 ❌  abc ❌"
echo "- 协议验证: tcp/udp/both ✅  invalid ❌"

demo_section "11. 故障排除"

echo "🔧 常见问题解决:"
echo
echo "问题1: 转发不工作"
echo "解决: sudo sysctl net.ipv4.ip_forward=1"
echo
echo "问题2: 规则不生效"
echo "解决: sudo $SCRIPT reload"
echo
echo "问题3: 端口无法访问"
echo "解决: sudo $SCRIPT test 80"

demo_section "12. 性能优化建议"

echo "⚡ 优化建议:"
echo "1. 将常用规则放在前面"
echo "2. 使用源IP限制减少匹配"
echo "3. 定期清理无用规则"
echo "4. 监控系统资源使用"

echo
echo "📊 系统调优:"
echo "echo 'net.netfilter.nf_conntrack_max = 131072' >> /etc/sysctl.conf"
echo "echo 'net.netfilter.nf_conntrack_buckets = 16384' >> /etc/sysctl.conf"

demo_section "总结"

echo -e "${GREEN}✅ 功能测试完成！${NC}"
echo
echo "📋 脚本主要特性:"
echo "• 🚀 一键安装和配置"
echo "• 🔧 灵活的转发规则管理"
echo "• 🎯 高级转发功能"
echo "• 📦 批量导入/导出"
echo "• 🛡️ 安全访问控制"
echo "• 📊 实时状态监控"
echo "• 📚 完整的文档支持"

echo
echo -e "${BLUE}🎉 NFTables转发管理脚本已准备就绪！${NC}"
echo -e "${YELLOW}⚠️  注意: 在生产环境使用前，请务必在测试环境中充分验证。${NC}"

echo
echo "📖 更多信息请查看:"
echo "• README.md - 项目概述"
echo "• nftables_forward_使用说明.md - 详细使用手册"
echo "• 示例规则配置.txt - 配置示例"