#!/bin/bash

# ==========================================
# NFTables 转发管理脚本
# 适用于 Debian/Ubuntu 系统
# 功能：安装、管理转发规则、协议控制等
# ==========================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 配置文件路径
NFTABLES_CONF="/etc/nftables.conf"
FORWARD_RULES_FILE="/etc/nftables_forward_rules.txt"
SCRIPT_VERSION="1.0.0"

# 日志函数
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_debug() {
    echo -e "${BLUE}[DEBUG]${NC} $1"
}

# 检查是否为root用户
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本需要root权限运行"
        exit 1
    fi
}

# 检查系统是否为Debian/Ubuntu
check_system() {
    if [[ -f /etc/debian_version ]]; then
        log_info "检测到 Debian/Ubuntu 系统"
        return 0
    else
        log_error "此脚本仅支持 Debian/Ubuntu 系统"
        exit 1
    fi
}

# 安装或更新nftables
install_nftables() {
    log_info "正在安装/更新 nftables..."
    
    # 更新包索引
    apt update -qq
    
    # 安装nftables
    if apt install -y nftables > /dev/null 2>&1; then
        log_info "nftables 安装/更新成功"
    else
        log_error "nftables 安装失败"
        exit 1
    fi
    
    # 启用并启动服务
    systemctl enable nftables.service > /dev/null 2>&1
    systemctl start nftables.service > /dev/null 2>&1
    
    log_info "nftables 服务已启用并启动"
}

# 检查nftables是否已安装
check_nftables() {
    if ! command -v nft &> /dev/null; then
        log_warn "nftables 未安装，正在安装..."
        install_nftables
    else
        log_info "nftables 已安装，版本: $(nft --version | head -n1)"
    fi
}

# 初始化nftables配置
init_nftables() {
    log_info "初始化 nftables 配置..."
    
    # 创建基础配置
    cat > "${NFTABLES_CONF}" << 'EOF'
#!/usr/sbin/nft -f

flush ruleset

# 定义变量
define WAN_IF = "eth0"  # 请根据实际情况修改外网接口
define LAN_IF = "eth1"  # 请根据实际情况修改内网接口

# 主过滤表
table inet filter {
    chain input {
        type filter hook input priority 0; policy accept;
        # 允许本地回环
        iifname "lo" accept
        # 允许已建立和相关的连接
        ct state established,related accept
    }
    
    chain forward {
        type filter hook forward priority 0; policy accept;
        # 允许已建立和相关的连接
        ct state established,related accept
    }
    
    chain output {
        type filter hook output priority 0; policy accept;
    }
}

# NAT表用于转发
table ip nat {
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
        # 转发规则将在这里添加
    }
    
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        # SNAT规则将在这里添加
    }
}

# IPv6 NAT表（如需要）
table ip6 nat {
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
    }
    
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
    }
}
EOF

    # 加载配置
    if nft -f "${NFTABLES_CONF}"; then
        log_info "nftables 基础配置加载成功"
    else
        log_error "nftables 基础配置加载失败"
        exit 1
    fi
    
    # 创建转发规则记录文件
    touch "${FORWARD_RULES_FILE}"
}

# 添加转发规则
add_forward_rule() {
    local protocol="$1"
    local external_port="$2"
    local internal_ip="$3"
    local internal_port="$4"
    local external_ip="${5:-any}"
    local rule_name="${6:-rule_$(date +%s)}"
    
    # 参数验证
    if [[ -z "$protocol" || -z "$external_port" || -z "$internal_ip" || -z "$internal_port" ]]; then
        log_error "参数不完整。用法: add_forward_rule <protocol> <external_port> <internal_ip> <internal_port> [external_ip] [rule_name]"
        return 1
    fi
    
    # 协议验证
    if [[ "$protocol" != "tcp" && "$protocol" != "udp" && "$protocol" != "both" ]]; then
        log_error "协议必须是 tcp、udp 或 both"
        return 1
    fi
    
    # IP地址验证
    if ! [[ "$internal_ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        log_error "内网IP地址格式无效: $internal_ip"
        return 1
    fi
    
    # 端口验证
    if ! [[ "$external_port" =~ ^[0-9]+$ ]] || ! [[ "$internal_port" =~ ^[0-9]+$ ]]; then
        log_error "端口号必须是数字"
        return 1
    fi
    
    if [[ "$external_port" -lt 1 || "$external_port" -gt 65535 ]] || [[ "$internal_port" -lt 1 || "$internal_port" -gt 65535 ]]; then
        log_error "端口号必须在 1-65535 范围内"
        return 1
    fi
    
    log_info "添加转发规则: $rule_name"
    log_debug "协议: $protocol, 外部端口: $external_port, 内部地址: $internal_ip:$internal_port"
    
    # 构建规则
    local src_condition=""
    if [[ "$external_ip" != "any" ]]; then
        src_condition="ip saddr $external_ip "
    fi
    
    # 添加转发规则到nftables
    if [[ "$protocol" == "tcp" || "$protocol" == "both" ]]; then
        local tcp_rule="${src_condition}tcp dport $external_port dnat to $internal_ip:$internal_port"
        if nft add rule ip nat prerouting $tcp_rule; then
            log_info "TCP转发规则添加成功"
            # 记录规则
            echo "tcp|$external_port|$internal_ip|$internal_port|$external_ip|$rule_name|$(date)" >> "${FORWARD_RULES_FILE}"
        else
            log_error "TCP转发规则添加失败"
            return 1
        fi
    fi
    
    if [[ "$protocol" == "udp" || "$protocol" == "both" ]]; then
        local udp_rule="${src_condition}udp dport $external_port dnat to $internal_ip:$internal_port"
        if nft add rule ip nat prerouting $udp_rule; then
            log_info "UDP转发规则添加成功"
            # 记录规则
            echo "udp|$external_port|$internal_ip|$internal_port|$external_ip|$rule_name|$(date)" >> "${FORWARD_RULES_FILE}"
        else
            log_error "UDP转发规则添加失败"
            return 1
        fi
    fi
    
    # 保存当前规则集
    save_rules
}

# 删除转发规则
delete_forward_rule() {
    local rule_identifier="$1"
    
    if [[ -z "$rule_identifier" ]]; then
        log_error "请指定规则标识符（规则名称、端口号或序号）"
        return 1
    fi
    
    log_info "删除转发规则: $rule_identifier"
    
    # 获取规则句柄并删除
    local deleted=false
    
    # 通过规则名称查找
    if grep -q "|$rule_identifier|" "${FORWARD_RULES_FILE}" 2>/dev/null; then
        local rule_info=$(grep "|$rule_identifier|" "${FORWARD_RULES_FILE}")
        local protocol=$(echo "$rule_info" | cut -d'|' -f1)
        local external_port=$(echo "$rule_info" | cut -d'|' -f2)
        
        # 删除对应的nftables规则
        nft list ruleset -a | grep "dport $external_port" | grep "$protocol" | while read -r line; do
            local handle=$(echo "$line" | grep -o 'handle [0-9]*' | awk '{print $2}')
            if [[ -n "$handle" ]]; then
                nft delete rule ip nat prerouting handle "$handle"
                log_info "删除了句柄为 $handle 的规则"
            fi
        done
        
        # 从记录文件中删除
        sed -i "/$rule_identifier/d" "${FORWARD_RULES_FILE}"
        deleted=true
    fi
    
    # 通过端口号查找
    if grep -q "|$rule_identifier|" "${FORWARD_RULES_FILE}" 2>/dev/null || [[ "$rule_identifier" =~ ^[0-9]+$ ]]; then
        nft list ruleset -a | grep "dport $rule_identifier" | while read -r line; do
            local handle=$(echo "$line" | grep -o 'handle [0-9]*' | awk '{print $2}')
            if [[ -n "$handle" ]]; then
                nft delete rule ip nat prerouting handle "$handle"
                log_info "删除了端口 $rule_identifier 的转发规则"
                deleted=true
            fi
        done
        
        # 从记录文件中删除相关记录
        sed -i "/|$rule_identifier|/d" "${FORWARD_RULES_FILE}"
    fi
    
    if [[ "$deleted" == "true" ]]; then
        log_info "转发规则删除成功"
        save_rules
    else
        log_warn "未找到匹配的转发规则"
    fi
}

# 列出所有转发规则
list_forward_rules() {
    log_info "当前转发规则列表:"
    echo
    printf "%-4s %-8s %-6s %-15s %-6s %-15s %-20s %-20s\n" "序号" "协议" "外端口" "内网IP" "内端口" "源IP限制" "规则名称" "创建时间"
    echo "--------------------------------------------------------------------------------------------------------"
    
    local counter=1
    if [[ -f "${FORWARD_RULES_FILE}" ]]; then
        while IFS='|' read -r protocol external_port internal_ip internal_port external_ip rule_name create_time; do
            [[ -z "$protocol" ]] && continue
            
            local src_display="any"
            [[ "$external_ip" != "any" ]] && src_display="$external_ip"
            
            printf "%-4s %-8s %-6s %-15s %-6s %-15s %-20s %-20s\n" \
                "$counter" "$protocol" "$external_port" "$internal_ip" "$internal_port" \
                "$src_display" "$rule_name" "$create_time"
            
            ((counter++))
        done < "${FORWARD_RULES_FILE}"
    fi
    
    if [[ $counter -eq 1 ]]; then
        echo "暂无转发规则"
    fi
    echo
    
    # 显示当前活动的nftables规则
    log_info "当前活动的NAT规则:"
    nft list table ip nat 2>/dev/null || log_warn "无法获取NAT规则"
}

# 清空所有转发规则
flush_all_rules() {
    log_warn "这将清空所有转发规则，是否继续？(y/N)"
    read -r confirm
    
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        log_info "清空所有转发规则..."
        
        # 清空NAT表
        nft flush table ip nat 2>/dev/null
        nft flush table ip6 nat 2>/dev/null
        
        # 重新创建链
        nft add chain ip nat prerouting { type nat hook prerouting priority dstnat\; policy accept\; } 2>/dev/null
        nft add chain ip nat postrouting { type nat hook postrouting priority srcnat\; policy accept\; } 2>/dev/null
        
        # 清空记录文件
        > "${FORWARD_RULES_FILE}"
        
        log_info "所有转发规则已清空"
        save_rules
    else
        log_info "操作已取消"
    fi
}

# 保存规则到配置文件
save_rules() {
    log_info "保存规则到配置文件..."
    
    # 备份原配置
    cp "${NFTABLES_CONF}" "${NFTABLES_CONF}.bak.$(date +%Y%m%d_%H%M%S)"
    
    # 导出当前规则集
    nft list ruleset > "${NFTABLES_CONF}"
    
    # 在文件开头添加shebang
    sed -i '1i#!/usr/sbin/nft -f' "${NFTABLES_CONF}"
    
    log_info "规则已保存到 $NFTABLES_CONF"
}

# 重新加载规则
reload_rules() {
    log_info "重新加载nftables规则..."
    
    if nft -f "${NFTABLES_CONF}"; then
        log_info "规则重新加载成功"
    else
        log_error "规则重新加载失败"
        # 尝试恢复备份
        local backup_file=$(ls -t "${NFTABLES_CONF}.bak."* 2>/dev/null | head -n1)
        if [[ -n "$backup_file" ]]; then
            log_warn "尝试恢复最近的备份: $backup_file"
            cp "$backup_file" "${NFTABLES_CONF}"
            nft -f "${NFTABLES_CONF}"
        fi
    fi
}

# 显示系统状态
show_status() {
    log_info "nftables 系统状态:"
    echo
    
    # 服务状态
    echo "服务状态:"
    systemctl status nftables.service --no-pager -l
    echo
    
    # 规则统计
    echo "规则统计:"
    local rule_count=$(wc -l < "${FORWARD_RULES_FILE}" 2>/dev/null || echo "0")
    echo "总转发规则数: $rule_count"
    
    # 内核模块
    echo
    echo "相关内核模块:"
    lsmod | grep -E "(nf_tables|nf_nat|nf_conntrack)" || echo "未加载相关模块"
}

# 测试转发规则
test_forward_rule() {
    local external_port="$1"
    local test_ip="${2:-127.0.0.1}"
    
    if [[ -z "$external_port" ]]; then
        log_error "请指定要测试的端口号"
        return 1
    fi
    
    log_info "测试端口 $external_port 的转发规则..."
    
    # 检查端口是否有转发规则
    if nft list ruleset | grep -q "dport $external_port"; then
        log_info "找到端口 $external_port 的转发规则"
        nft list ruleset | grep "dport $external_port"
    else
        log_warn "未找到端口 $external_port 的转发规则"
    fi
    
    # 尝试连接测试（需要安装nc或netcat）
    if command -v nc &> /dev/null; then
        log_info "测试连接到 $test_ip:$external_port..."
        timeout 3 nc -zv "$test_ip" "$external_port" 2>&1 || log_warn "连接测试失败或超时"
    else
        log_warn "未安装nc工具，无法进行连接测试"
    fi
}

# 批量导入规则
import_rules() {
    local import_file="$1"
    
    if [[ -z "$import_file" ]]; then
        log_error "请指定导入文件路径"
        return 1
    fi
    
    if [[ ! -f "$import_file" ]]; then
        log_error "导入文件不存在: $import_file"
        return 1
    fi
    
    log_info "从文件导入转发规则: $import_file"
    
    # 文件格式: protocol|external_port|internal_ip|internal_port|external_ip|rule_name
    local imported=0
    local failed=0
    
    while IFS='|' read -r protocol external_port internal_ip internal_port external_ip rule_name; do
        # 跳过空行和注释行
        [[ -z "$protocol" || "$protocol" =~ ^# ]] && continue
        
        if add_forward_rule "$protocol" "$external_port" "$internal_ip" "$internal_port" "$external_ip" "$rule_name"; then
            ((imported++))
        else
            ((failed++))
        fi
    done < "$import_file"
    
    log_info "导入完成 - 成功: $imported, 失败: $failed"
}

# 导出规则
export_rules() {
    local export_file="$1"
    
    if [[ -z "$export_file" ]]; then
        export_file="nftables_forward_rules_$(date +%Y%m%d_%H%M%S).txt"
    fi
    
    log_info "导出转发规则到: $export_file"
    
    # 添加头部注释
    cat > "$export_file" << EOF
# nftables转发规则导出文件
# 生成时间: $(date)
# 格式: protocol|external_port|internal_ip|internal_port|external_ip|rule_name
# 协议: tcp, udp, both
# external_ip: any 表示不限制源IP
EOF
    
    # 复制规则
    if [[ -f "${FORWARD_RULES_FILE}" ]]; then
        cat "${FORWARD_RULES_FILE}" >> "$export_file"
        local rule_count=$(wc -l < "${FORWARD_RULES_FILE}")
        log_info "已导出 $rule_count 条规则到 $export_file"
    else
        log_warn "无规则可导出"
    fi
}

# 显示帮助信息
show_help() {
    echo "nftables转发管理脚本 v$SCRIPT_VERSION"
    echo "适用于 Debian/Ubuntu 系统"
    echo
    echo "用法: $0 [选项]"
    echo
    echo "选项:"
    echo "  install                    安装/更新 nftables"
    echo "  init                       初始化 nftables 配置"
    echo "  add <proto> <ext_port> <int_ip> <int_port> [src_ip] [name]"
    echo "                            添加转发规则"
    echo "                            proto: tcp|udp|both"
    echo "                            src_ip: 源IP限制(可选,默认any)"
    echo "  delete <rule_id>          删除转发规则(规则名称、端口号或序号)"
    echo "  list                      列出所有转发规则"
    echo "  flush                     清空所有转发规则"
    echo "  save                      保存当前规则到配置文件"
    echo "  reload                    重新加载配置文件"
    echo "  status                    显示系统状态"
    echo "  test <port> [ip]          测试转发规则"
    echo "  import <file>             从文件批量导入规则"
    echo "  export [file]             导出规则到文件"
    echo "  help                      显示此帮助信息"
    echo
    echo "示例:"
    echo "  $0 add tcp 80 192.168.1.100 8080           # TCP端口转发"
    echo "  $0 add udp 53 192.168.1.10 53              # UDP端口转发"  
    echo "  $0 add both 22 192.168.1.50 22 10.0.0.1    # 双协议转发，限制源IP"
    echo "  $0 delete web_server                        # 删除名为web_server的规则"
    echo "  $0 delete 80                                # 删除端口80的转发规则"
    echo "  $0 test 80 192.168.1.1                     # 测试端口80转发"
    echo
}

# 高级端口转发函数 - 支持同一端口的TCP/UDP分别转发到不同地址
add_advanced_forward() {
    local external_port="$1"
    local tcp_target="$2"  # 格式: ip:port
    local udp_target="$3"  # 格式: ip:port
    local rule_name="${4:-advanced_$(date +%s)}"
    
    if [[ -z "$external_port" || -z "$tcp_target" || -z "$udp_target" ]]; then
        log_error "参数不完整。用法: add_advanced_forward <external_port> <tcp_target_ip:port> <udp_target_ip:port> [rule_name]"
        return 1
    fi
    
    # 解析TCP目标
    local tcp_ip=$(echo "$tcp_target" | cut -d':' -f1)
    local tcp_port=$(echo "$tcp_target" | cut -d':' -f2)
    
    # 解析UDP目标
    local udp_ip=$(echo "$udp_target" | cut -d':' -f1)
    local udp_port=$(echo "$udp_target" | cut -d':' -f2)
    
    log_info "添加高级转发规则: $rule_name"
    log_debug "端口 $external_port: TCP -> $tcp_ip:$tcp_port, UDP -> $udp_ip:$udp_port"
    
    # 添加TCP转发规则
    if nft add rule ip nat prerouting tcp dport "$external_port" dnat to "$tcp_ip:$tcp_port"; then
        log_info "TCP转发规则添加成功: $external_port -> $tcp_ip:$tcp_port"
        echo "tcp|$external_port|$tcp_ip|$tcp_port|any|${rule_name}_tcp|$(date)" >> "${FORWARD_RULES_FILE}"
    else
        log_error "TCP转发规则添加失败"
        return 1
    fi
    
    # 添加UDP转发规则
    if nft add rule ip nat prerouting udp dport "$external_port" dnat to "$udp_ip:$udp_port"; then
        log_info "UDP转发规则添加成功: $external_port -> $udp_ip:$udp_port"
        echo "udp|$external_port|$udp_ip|$udp_port|any|${rule_name}_udp|$(date)" >> "${FORWARD_RULES_FILE}"
    else
        log_error "UDP转发规则添加失败"
        return 1
    fi
    
    save_rules
    log_info "高级转发规则 '$rule_name' 添加完成"
}

# 主函数
main() {
    check_root
    check_system
    check_nftables
    
    case "${1:-help}" in
        "install")
            install_nftables
            ;;
        "init")
            init_nftables
            ;;
        "add")
            if [[ "$#" -lt 5 ]]; then
                log_error "参数不足。用法: add <protocol> <external_port> <internal_ip> <internal_port> [external_ip] [rule_name]"
                exit 1
            fi
            add_forward_rule "$2" "$3" "$4" "$5" "$6" "$7"
            ;;
        "advanced")
            if [[ "$#" -lt 4 ]]; then
                log_error "参数不足。用法: advanced <external_port> <tcp_target_ip:port> <udp_target_ip:port> [rule_name]"
                exit 1
            fi
            add_advanced_forward "$2" "$3" "$4" "$5"
            ;;
        "delete"|"del"|"remove")
            if [[ "$#" -lt 2 ]]; then
                log_error "请指定要删除的规则标识符"
                exit 1
            fi
            delete_forward_rule "$2"
            ;;
        "list"|"ls")
            list_forward_rules
            ;;
        "flush"|"clear")
            flush_all_rules
            ;;
        "save")
            save_rules
            ;;
        "reload")
            reload_rules
            ;;
        "status")
            show_status
            ;;
        "test")
            if [[ "$#" -lt 2 ]]; then
                log_error "请指定要测试的端口号"
                exit 1
            fi
            test_forward_rule "$2" "$3"
            ;;
        "import")
            if [[ "$#" -lt 2 ]]; then
                log_error "请指定导入文件路径"
                exit 1
            fi
            import_rules "$2"
            ;;
        "export")
            export_rules "$2"
            ;;
        "help"|"-h"|"--help")
            show_help
            ;;
        *)
            log_error "未知选项: $1"
            show_help
            exit 1
            ;;
    esac
}

# 运行主函数
main "$@"