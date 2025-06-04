#!/bin/bash

# ==========================================
# NFTables 转发管理脚本 v2.0
# 适用于 Debian/Ubuntu 系统
# 功能：IPv4/IPv6支持、端口转发管理
# ==========================================

# 三色方案 - 60-30-10 原则
# 60% 主色调 - 蓝色系
PRIMARY='\033[38;5;33m'           # 主蓝色
PRIMARY_BOLD='\033[1;38;5;33m'    # 主蓝色加粗

# 30% 辅助色 - 灰色系  
SECONDARY='\033[38;5;243m'        # 中灰色
SECONDARY_LIGHT='\033[38;5;250m'  # 浅灰色

# 10% 强调色 - 状态色
ACCENT_SUCCESS='\033[38;5;34m'    # 成功绿色
ACCENT_ERROR='\033[38;5;196m'     # 错误红色
ACCENT_WARNING='\033[38;5;220m'   # 警告黄色

# 重置和特殊效果
NC='\033[0m'                      # 重置颜色
BOLD='\033[1m'                    # 粗体

# 配置文件路径
NFTABLES_CONF="/etc/nftables.conf"
FORWARD_RULES_FILE="/etc/nftables_forward_rules.txt"
CONFIG_FILE="/etc/nftables_forward_config.conf"
SCRIPT_VERSION="2.0.0"

# 默认配置
DEFAULT_IP_MODE="mix"
DEFAULT_INTERFACE_WAN="eth0"
DEFAULT_INTERFACE_LAN="eth1"

# 载入配置文件
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
    else
        create_default_config
    fi
}

# 创建默认配置
create_default_config() {
    cat > "$CONFIG_FILE" << EOF
# NFTables转发脚本配置文件
IP_MODE="$DEFAULT_IP_MODE"
WAN_INTERFACE="$DEFAULT_INTERFACE_WAN"
LAN_INTERFACE="$DEFAULT_INTERFACE_LAN"
AUTO_SAVE="true"
LOG_LEVEL="info"
EOF
}

# 保存配置
save_config() {
    cat > "$CONFIG_FILE" << EOF
# NFTables转发脚本配置文件
IP_MODE="$IP_MODE"
WAN_INTERFACE="$WAN_INTERFACE"
LAN_INTERFACE="$LAN_INTERFACE"
AUTO_SAVE="$AUTO_SAVE"
LOG_LEVEL="$LOG_LEVEL"
EOF
}

# 日志函数
print_header() {
    clear
    echo -e "${PRIMARY_BOLD}NFTables 转发管理系统 v${SCRIPT_VERSION}${NC}"
    echo -e "${SECONDARY}Enhanced Multi-Protocol Support${NC}"
    echo

    # 获取IPv4信息
    local ipv4_info="IPv4: Not Available"
    local public_ipv4=$(curl -s -4 https://ipapi.co/ip 2>/dev/null)
    if [[ -n "$public_ipv4" ]]; then
        local ipv4_data=$(curl -s -4 "https://ipapi.co/${public_ipv4}/json" 2>/dev/null)
        if [[ -n "$ipv4_data" ]] && echo "$ipv4_data" | jq -e . >/dev/null 2>&1; then
            local country=$(echo "$ipv4_data" | jq -r '.country_name // "N/A"')
            local city=$(echo "$ipv4_data" | jq -r '.city // "N/A"')
            ipv4_info="IPv4: ${public_ipv4} (${country}/${city})"
        else
            ipv4_info="IPv4: ${public_ipv4}"
        fi
    fi
    echo -e "${SECONDARY}${ipv4_info}${NC}"

    # 获取IPv6信息
    local ipv6_info="IPv6: Not Available"
    local public_ipv6=$(curl -s -6 https://ipapi.co/ip 2>/dev/null)
    if [[ -n "$public_ipv6" ]]; then
        ipv6_info="IPv6: ${public_ipv6}"
    fi
    echo -e "${SECONDARY}${ipv6_info}${NC}"
    
    echo -e "${SECONDARY}模式: ${IP_MODE^^} | 系统: $(lsb_release -si 2>/dev/null || echo 'Linux') | 时间: $(date '+%Y-%m-%d %H:%M:%S')${NC}"
    echo
}

print_section() {
    echo -e "${PRIMARY}> $1${NC}"
    [[ -n "$2" ]] && echo -e "${SECONDARY}$2${NC}"
}

print_success() {
    echo -e "${ACCENT_SUCCESS}[成功] $1${NC}"
}

print_error() {
    echo -e "${ACCENT_ERROR}[错误] $1${NC}"
}

print_warning() {
    echo -e "${ACCENT_WARNING}[警告] $1${NC}"
}

print_info() {
    echo -e "${PRIMARY}[信息] $1${NC}"
}

print_debug() {
    [[ "$LOG_LEVEL" == "debug" ]] && echo -e "${SECONDARY}[调试] $1${NC}"
}

# 绘制分隔线
draw_line() {
    local length=${1:-60}
    echo -e "${SECONDARY}$(printf "%*s" $length | tr ' ' "-")${NC}"
}

# 绘制菜单项
draw_menu_item() {
    local number="$1"
    local title="$2"
    local desc="$3"
    local status="$4"
    
    printf "${PRIMARY}%2s${NC} ${BOLD}%-20s${NC} ${SECONDARY}%-30s${NC}" "$number" "$title" "$desc"
    [[ -n "$status" ]] && printf " ${ACCENT_SUCCESS}[%s]${NC}" "$status"
    echo
}

# 等待用户输入
wait_enter() {
    echo
    echo -e "${SECONDARY}按 Enter 键继续...${NC}"
    read -r
}

# 检查系统权限和兼容性
check_system() {
    if [[ $EUID -ne 0 ]]; then
        print_error "此脚本需要root权限运行"
        exit 1
    fi
    
    if [[ ! -f /etc/debian_version ]]; then
        print_error "此脚本仅支持 Debian/Ubuntu 系统"
        exit 1
    fi
    
    print_success "系统检查通过 - $(lsb_release -ds 2>/dev/null || cat /etc/debian_version)"
}

# 检查和安装nftables
install_nftables() {
    print_section "检查 nftables 安装状态"
    
    if ! command -v nft &> /dev/null; then
        print_warning "nftables 未安装，正在安装..."
        
        apt update -qq
        if apt install -y nftables > /dev/null 2>&1; then
            print_success "nftables 安装成功"
        else
            print_error "nftables 安装失败"
            exit 1
        fi
    else
        local version=$(nft --version | head -n1)
        print_success "nftables 已安装 - $version"
    fi
    
    # 启用服务
    systemctl enable nftables.service > /dev/null 2>&1
    systemctl start nftables.service > /dev/null 2>&1
    print_success "nftables 服务已启用"
}

# 初始化nftables配置
init_nftables() {
    print_section "初始化 nftables 配置" "IP模式: $IP_MODE"
    
    # 创建配置文件
    cat > "${NFTABLES_CONF}" << EOF
#!/usr/sbin/nft -f

flush ruleset

# 定义变量
define WAN_IF = "$WAN_INTERFACE"
define LAN_IF = "$LAN_INTERFACE"

EOF

    # 根据IP模式创建不同的表结构
    case "$IP_MODE" in
        "ipv4")
            create_ipv4_tables
            ;;
        "ipv6")
            create_ipv6_tables
            ;;
        "mix")
            create_mixed_tables
            ;;
    esac
    
    # 加载配置
    if nft -f "${NFTABLES_CONF}"; then
        print_success "nftables 配置初始化成功 (模式: $IP_MODE)"
    else
        print_error "nftables 配置初始化失败"
        return 1
    fi
    
    # 创建规则记录文件
    touch "${FORWARD_RULES_FILE}"
    print_success "转发规则记录文件已创建"
}

create_ipv4_tables() {
    cat >> "${NFTABLES_CONF}" << 'EOF'
# IPv4专用表结构
table ip filter {
    chain input {
        type filter hook input priority 0; policy accept;
        iifname "lo" accept
        ct state established,related accept
    }
    
    chain forward {
        type filter hook forward priority 0; policy accept;
        ct state established,related accept
    }
    
    chain output {
        type filter hook output priority 0; policy accept;
    }
}

table ip nat {
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
    }
    
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
    }
}
EOF
}

create_ipv6_tables() {
    cat >> "${NFTABLES_CONF}" << 'EOF'
# IPv6专用表结构
table ip6 filter {
    chain input {
        type filter hook input priority 0; policy accept;
        iifname "lo" accept
        ct state established,related accept
    }
    
    chain forward {
        type filter hook forward priority 0; policy accept;
        ct state established,related accept
    }
    
    chain output {
        type filter hook output priority 0; policy accept;
    }
}

table ip6 nat {
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
    }
    
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
    }
}
EOF
}

create_mixed_tables() {
    cat >> "${NFTABLES_CONF}" << 'EOF'
# 混合IPv4/IPv6表结构
table inet filter {
    chain input {
        type filter hook input priority 0; policy accept;
        iifname "lo" accept
        ct state established,related accept
    }
    
    chain forward {
        type filter hook forward priority 0; policy accept;
        ct state established,related accept
    }
    
    chain output {
        type filter hook output priority 0; policy accept;
    }
}

table ip nat {
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
    }
    
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
    }
}

table ip6 nat {
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
    }
    
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
    }
}
EOF
}

# 主菜单
show_main_menu() {
    print_header
    
    echo -e "${PRIMARY_BOLD}主菜单${NC}"
    draw_line 60
    
    draw_menu_item "1" "转发规则管理" "添加、删除、查看转发规则"
    draw_menu_item "2" "系统配置" "IP模式、接口配置等"
    draw_menu_item "3" "系统状态" "查看服务状态和统计"
    draw_menu_item "4" "批量管理" "导入导出规则配置"
    draw_menu_item "5" "高级功能" "高级转发、测试等"
    draw_menu_item "0" "退出程序" "安全退出脚本"
    
    draw_line 60
    echo -ne "${PRIMARY}请选择功能 [0-5]: ${NC}"
    
    read -r choice
    handle_main_menu "$choice"
}

handle_main_menu() {
    case "$1" in
        1) show_forward_menu ;;
        2) show_config_menu ;;
        3) show_status_menu ;;
        4) show_batch_menu ;;
        5) show_advanced_menu ;;
        0) exit_program ;;
        *) 
            print_error "无效选择，请重新输入"
            wait_enter
            show_main_menu
            ;;
    esac
}

# 转发规则管理菜单
show_forward_menu() {
    print_header
    print_section "转发规则管理"
    
    draw_menu_item "1" "添加转发规则" "创建新的端口转发规则"
    draw_menu_item "2" "删除转发规则" "删除现有转发规则"
    draw_menu_item "3" "查看转发规则" "列出所有转发规则"
    draw_menu_item "4" "清空所有规则" "删除所有转发规则"
    draw_menu_item "9" "返回主菜单" ""
    
    draw_line 40
    echo -ne "${PRIMARY}请选择操作 [1-4,9]: ${NC}"
    
    read -r choice
    case "$choice" in
        1) add_forward_rule_interactive ;;
        2) delete_forward_rule_interactive ;;
        3) list_forward_rules_interactive ;;
        4) flush_all_rules_interactive ;;
        9) show_main_menu ;;
        *) 
            print_error "无效选择"
            wait_enter
            show_forward_menu
            ;;
    esac
}

# 交互式添加转发规则
add_forward_rule_interactive() {
    print_header
    print_section "添加转发规则"
    
    # 协议选择
    echo -e "${PRIMARY}选择协议类型:${NC}"
    echo -e "${PRIMARY}1${NC} TCP"
    echo -e "${PRIMARY}2${NC} UDP"
    echo -e "${PRIMARY}3${NC} TCP + UDP"
    echo -ne "${PRIMARY}请选择 [1-3]: ${NC}"
    read -r proto_choice
    
    local protocol=""
    case "$proto_choice" in
        1) protocol="tcp" ;;
        2) protocol="udp" ;;
        3) protocol="both" ;;
        *) 
            print_error "无效选择"
            wait_enter
            show_forward_menu
            return
            ;;
    esac
    
    # 外部端口
    echo -ne "${PRIMARY}外部端口 (1-65535): ${NC}"
    read -r external_port
    
    if ! [[ "$external_port" =~ ^[0-9]+$ ]] || [[ "$external_port" -lt 1 || "$external_port" -gt 65535 ]]; then
        print_error "端口号无效"
        wait_enter
        show_forward_menu
        return
    fi
    
    # 内网IP
    echo -ne "${PRIMARY}内网IP地址: ${NC}"
    read -r internal_ip
    
    # 内网端口
    echo -ne "${PRIMARY}内网端口 (默认: $external_port): ${NC}"
    read -r internal_port
    [[ -z "$internal_port" ]] && internal_port="$external_port"
    
    # 源IP限制
    echo -ne "${PRIMARY}源IP限制 (留空表示不限制): ${NC}"
    read -r source_ip
    [[ -z "$source_ip" ]] && source_ip="any"
    
    # 规则名称
    echo -ne "${PRIMARY}规则名称 (可选): ${NC}"
    read -r rule_name
    [[ -z "$rule_name" ]] && rule_name="rule_$(date +%s)"
    
    # 确认添加
    echo
    print_section "规则确认"
    echo -e "${SECONDARY_LIGHT}协议: $protocol${NC}"
    echo -e "${SECONDARY_LIGHT}外部端口: $external_port${NC}"
    echo -e "${SECONDARY_LIGHT}内网地址: $internal_ip:$internal_port${NC}"
    echo -e "${SECONDARY_LIGHT}源IP限制: $source_ip${NC}"
    echo -e "${SECONDARY_LIGHT}规则名称: $rule_name${NC}"
    echo
    echo -ne "${ACCENT_WARNING}确认添加此规则? [y/N]: ${NC}"
    read -r confirm
    
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        if add_forward_rule_core "$protocol" "$external_port" "$internal_ip" "$internal_port" "$source_ip" "$rule_name"; then
            print_success "转发规则添加成功！"
        else
            print_error "转发规则添加失败！"
        fi
    else
        print_info "操作已取消"
    fi
    
    wait_enter
    show_forward_menu
}

# 核心转发规则添加函数
add_forward_rule_core() {
    local protocol="$1"
    local external_port="$2"
    local internal_ip="$3"
    local internal_port="$4"
    local external_ip="${5:-any}"
    local rule_name="${6:-rule_$(date +%s)}"
    
    print_debug "添加规则: $protocol $external_port -> $internal_ip:$internal_port"
    
    # 根据IP模式选择表
    local table_family=""
    case "$IP_MODE" in
        "ipv4") table_family="ip" ;;
        "ipv6") table_family="ip6" ;;
        "mix") table_family="ip" ;;
    esac
    
    # 构建规则
    local src_condition=""
    if [[ "$external_ip" != "any" ]]; then
        src_condition="ip saddr $external_ip "
    fi
    
    # 添加转发规则到nftables
    local success=true
    
    if [[ "$protocol" == "tcp" || "$protocol" == "both" ]]; then
        local tcp_rule="${src_condition}tcp dport $external_port dnat to $internal_ip:$internal_port"
        if ! nft add rule $table_family nat prerouting $tcp_rule 2>/dev/null; then
            print_error "TCP转发规则添加失败"
            success=false
        else
            print_success "TCP转发规则添加成功"
            echo "tcp|$external_port|$internal_ip|$internal_port|$external_ip|$rule_name|$(date)" >> "${FORWARD_RULES_FILE}"
        fi
    fi
    
    if [[ "$protocol" == "udp" || "$protocol" == "both" ]]; then
        local udp_rule="${src_condition}udp dport $external_port dnat to $internal_ip:$internal_port"
        if ! nft add rule $table_family nat prerouting $udp_rule 2>/dev/null; then
            print_error "UDP转发规则添加失败"
            success=false
        else
            print_success "UDP转发规则添加成功"
            echo "udp|$external_port|$internal_ip|$internal_port|$external_ip|$rule_name|$(date)" >> "${FORWARD_RULES_FILE}"
        fi
    fi
    
    # 自动保存
    if [[ "$AUTO_SAVE" == "true" && "$success" == "true" ]]; then
        save_rules_core
    fi
    
    [[ "$success" == "true" ]]
}

# 其他菜单函数继续...
show_config_menu() {
    print_header
    print_section "系统配置"
    
    draw_menu_item "1" "IP协议模式" "当前: $IP_MODE"
    draw_menu_item "2" "网络接口配置" "WAN: $WAN_INTERFACE | LAN: $LAN_INTERFACE"
    draw_menu_item "3" "其他设置" "自动保存等"
    draw_menu_item "9" "返回主菜单" ""
    
    draw_line 40
    echo -ne "${PRIMARY}请选择配置项 [1-3,9]: ${NC}"
    
    read -r choice
    case "$choice" in
        1) config_ip_mode ;;
        2) config_interfaces ;;
        3) config_other_settings ;;
        9) show_main_menu ;;
        *) 
            print_error "无效选择"
            wait_enter
            show_config_menu
            ;;
    esac
}

config_ip_mode() {
    print_header
    print_section "IP协议模式配置"
    
    echo -e "${PRIMARY}当前模式: ${BOLD}$IP_MODE${NC}"
    echo
    echo -e "${PRIMARY}可选模式:${NC}"
    echo -e "${PRIMARY}1${NC} IPv4 Only - 仅支持IPv4转发"
    echo -e "${PRIMARY}2${NC} IPv6 Only - 仅支持IPv6转发"
    echo -e "${PRIMARY}3${NC} Mixed Mode - 同时支持IPv4和IPv6"
    echo
    echo -ne "${PRIMARY}请选择新模式 [1-3]: ${NC}"
    
    read -r mode_choice
    local new_mode=""
    
    case "$mode_choice" in
        1) new_mode="ipv4" ;;
        2) new_mode="ipv6" ;;
        3) new_mode="mix" ;;
        *) 
            print_error "无效选择"
            wait_enter
            show_config_menu
            return
            ;;
    esac
    
    if [[ "$new_mode" != "$IP_MODE" ]]; then
        IP_MODE="$new_mode"
        save_config
        print_success "IP模式已更改为: $IP_MODE"
        print_warning "请重新初始化nftables配置以应用更改"
    else
        print_info "模式未更改"
    fi
    
    wait_enter
    show_config_menu
}

# 配置网络接口
config_interfaces() {
    print_header
    print_section "网络接口配置"
    
    echo -e "${PRIMARY}当前配置:${NC}"
    echo -e "${SECONDARY_LIGHT}WAN接口: $WAN_INTERFACE${NC}"
    echo -e "${SECONDARY_LIGHT}LAN接口: $LAN_INTERFACE${NC}"
    echo
    
    # 显示可用接口
    echo -e "${PRIMARY}可用网络接口:${NC}"
    ip link show | grep -E "^[0-9]+:" | while read -r line; do
        local interface=$(echo "$line" | sed 's/.*: \([^:]*\):.*/\1/')
        echo -e "${SECONDARY_LIGHT}  - $interface${NC}"
    done
    echo
    
    echo -ne "${PRIMARY}WAN接口 (外网接口，当前: $WAN_INTERFACE): ${NC}"
    read -r new_wan
    [[ -n "$new_wan" ]] && WAN_INTERFACE="$new_wan"
    
    echo -ne "${PRIMARY}LAN接口 (内网接口，当前: $LAN_INTERFACE): ${NC}"
    read -r new_lan
    [[ -n "$new_lan" ]] && LAN_INTERFACE="$new_lan"
    
    save_config
    print_success "网络接口配置已更新"
    print_warning "请重新初始化nftables配置以应用更改"
    
    wait_enter
    show_config_menu
}

# 其他设置
config_other_settings() {
    print_header
    print_section "其他设置"
    
    echo -e "${PRIMARY}当前设置:${NC}"
    echo -e "${SECONDARY_LIGHT}自动保存: $AUTO_SAVE${NC}"
    echo -e "${SECONDARY_LIGHT}日志级别: $LOG_LEVEL${NC}"
    echo
    
    # 自动保存设置
    echo -e "${PRIMARY}自动保存设置:${NC}"
    echo -e "${PRIMARY}1${NC} 启用自动保存"
    echo -e "${PRIMARY}2${NC} 禁用自动保存"
    echo -ne "${PRIMARY}请选择 [1-2]: ${NC}"
    read -r auto_save_choice
    
    case "$auto_save_choice" in
        1) AUTO_SAVE="true" ;;
        2) AUTO_SAVE="false" ;;
    esac
    
    # 日志级别设置
    echo
    echo -e "${PRIMARY}日志级别设置:${NC}"
    echo -e "${PRIMARY}1${NC} info - 基本信息"
    echo -e "${PRIMARY}2${NC} debug - 详细调试信息"
    echo -ne "${PRIMARY}请选择 [1-2]: ${NC}"
    read -r log_level_choice
    
    case "$log_level_choice" in
        1) LOG_LEVEL="info" ;;
        2) LOG_LEVEL="debug" ;;
    esac
    
    save_config
    print_success "设置已更新"
    
    wait_enter
    show_config_menu
}

# 系统状态菜单
show_status_menu() {
    print_header
    print_section "系统状态"
    
    # 服务状态
    echo -e "${PRIMARY}服务状态:${NC}"
    systemctl status nftables.service --no-pager -l
    echo
    
    # 规则统计
    print_section "规则统计"
    local rule_count=$(wc -l < "${FORWARD_RULES_FILE}" 2>/dev/null || echo "0")
    echo -e "${SECONDARY_LIGHT}总转发规则数: $rule_count${NC}"
    echo -e "${SECONDARY_LIGHT}当前IP模式: $IP_MODE${NC}"
    echo -e "${SECONDARY_LIGHT}WAN接口: $WAN_INTERFACE${NC}"
    echo -e "${SECONDARY_LIGHT}LAN接口: $LAN_INTERFACE${NC}"
    echo
    
    # 内核模块
    print_section "相关内核模块"
    lsmod | grep -E "(nf_tables|nf_nat|nf_conntrack)" || echo -e "${ACCENT_WARNING}未加载相关模块${NC}"
    echo
    
    # 网络接口状态
    print_section "网络接口状态"
    ip addr show | grep -E "(inet |inet6 )" | grep -v "127.0.0.1"
    
    wait_enter
    show_main_menu
}

# 批量管理菜单
show_batch_menu() {
    print_header
    print_section "批量管理"
    
    draw_menu_item "1" "导出规则" "导出当前所有转发规则"
    draw_menu_item "2" "导入规则" "从文件批量导入规则"
    draw_menu_item "3" "备份配置" "备份当前完整配置"
    draw_menu_item "4" "恢复配置" "从备份恢复配置"
    draw_menu_item "9" "返回主菜单" ""
    
    draw_line 40
    echo -ne "${PRIMARY}请选择操作 [1-4,9]: ${NC}"
    
    read -r choice
    case "$choice" in
        1) export_rules_interactive ;;
        2) import_rules_interactive ;;
        3) backup_config_interactive ;;
        4) restore_config_interactive ;;
        9) show_main_menu ;;
        *) 
            print_error "无效选择"
            wait_enter
            show_batch_menu
            ;;
    esac
}

# 高级功能菜单
show_advanced_menu() {
    print_header
    print_section "高级功能"
    
    draw_menu_item "1" "高级端口转发" "同端口不同协议转发"
    draw_menu_item "2" "测试转发规则" "测试端口连通性"
    draw_menu_item "3" "初始化配置" "重新初始化nftables"
    draw_menu_item "4" "保存当前规则" "手动保存规则"
    draw_menu_item "5" "重新加载规则" "从配置文件重新加载"
    draw_menu_item "9" "返回主菜单" ""
    
    draw_line 40
    echo -ne "${PRIMARY}请选择功能 [1-5,9]: ${NC}"
    
    read -r choice
    case "$choice" in
        1) add_advanced_forward_interactive ;;
        2) test_forward_rule_interactive ;;
        3) init_nftables_interactive ;;
        4) save_rules_interactive ;;
        5) reload_rules_interactive ;;
        9) show_main_menu ;;
        *) 
            print_error "无效选择"
            wait_enter
            show_advanced_menu
            ;;
    esac
}

# 删除转发规则交互函数
delete_forward_rule_interactive() {
    print_header
    print_section "删除转发规则"
    
    if [[ ! -f "${FORWARD_RULES_FILE}" || ! -s "${FORWARD_RULES_FILE}" ]]; then
        print_warning "没有可删除的规则"
        wait_enter
        show_forward_menu
        return
    fi
    
    list_forward_rules_core
    echo
    echo -ne "${PRIMARY}请输入要删除的规则编号: ${NC}"
    read -r rule_number
    
    if delete_forward_rule_core "$rule_number"; then
        print_success "规则删除成功"
    else
        print_error "规则删除失败"
    fi
    
    wait_enter
    show_forward_menu
}

# 查看转发规则交互函数
list_forward_rules_interactive() {
    print_header
    print_section "转发规则列表"
    
    list_forward_rules_core
    
    wait_enter
    show_forward_menu
}

# 核心规则列表函数
list_forward_rules_core() {
    if [[ ! -f "${FORWARD_RULES_FILE}" || ! -s "${FORWARD_RULES_FILE}" ]]; then
        print_info "当前没有转发规则"
        return
    fi
    
    local count=1
    while IFS='|' read -r protocol external_port internal_ip internal_port external_ip rule_name timestamp; do
        echo -e "${PRIMARY}[$count]${NC} ${SECONDARY_LIGHT}$protocol $external_port -> $internal_ip:$internal_port ($rule_name)${NC}"
        ((count++))
    done < "${FORWARD_RULES_FILE}"
}

# 核心删除规则函数
delete_forward_rule_core() {
    local rule_number="$1"
    
    if ! [[ "$rule_number" =~ ^[0-9]+$ ]]; then
        print_error "无效的规则编号"
        return 1
    fi
    
    local total_rules=$(wc -l < "${FORWARD_RULES_FILE}" 2>/dev/null || echo "0")
    if [[ "$rule_number" -lt 1 || "$rule_number" -gt "$total_rules" ]]; then
        print_error "规则编号超出范围"
        return 1
    fi
    
    # 获取要删除的规则信息
    local rule_line=$(sed -n "${rule_number}p" "${FORWARD_RULES_FILE}")
    IFS='|' read -r protocol external_port internal_ip internal_port external_ip rule_name timestamp <<< "$rule_line"
    
    # 从nftables中删除规则（这里需要更复杂的逻辑来匹配和删除具体规则）
    print_warning "从NFTables中删除规则需要重新加载配置"
    
    # 从文件中删除规则
    sed -i "${rule_number}d" "${FORWARD_RULES_FILE}"
    
    print_success "规则已从记录中删除: $protocol $external_port -> $internal_ip:$internal_port"
    return 0
}

# 清空所有规则交互函数
flush_all_rules_interactive() {
    print_header
    print_section "清空所有规则"
    
    echo -ne "${ACCENT_WARNING}确定要删除所有转发规则吗? [y/N]: ${NC}"
    read -r confirm
    
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        if flush_all_rules_core; then
            print_success "所有规则已清空"
        else
            print_error "清空规则失败"
        fi
    else
        print_info "操作已取消"
    fi
    
    wait_enter
    show_forward_menu
}

# 核心清空规则函数
flush_all_rules_core() {
    # 清空NFTables规则
    case "$IP_MODE" in
        "ipv4") nft flush table ip nat ;;
        "ipv6") nft flush table ip6 nat ;;
        "mix") 
            nft flush table ip nat
            nft flush table ip6 nat
            ;;
    esac
    
    # 清空规则文件
    > "${FORWARD_RULES_FILE}"
    
    return 0
}

# 导出规则交互函数
export_rules_interactive() {
    print_header
    print_section "导出转发规则"
    
    local default_filename="nftables_forward_rules_$(date +%Y%m%d_%H%M%S).txt"
    echo -ne "${PRIMARY}导出文件名 (默认: $default_filename): ${NC}"
    read -r export_file
    [[ -z "$export_file" ]] && export_file="$default_filename"
    
    if export_rules_core "$export_file"; then
        print_success "规则已导出到: $export_file"
    else
        print_error "导出失败"
    fi
    
    wait_enter
    show_batch_menu
}

# 核心导出函数
export_rules_core() {
    local export_file="$1"
    
    cat > "$export_file" << EOF
# nftables转发规则导出文件
# 生成时间: $(date)
# 格式: protocol|external_port|internal_ip|internal_port|external_ip|rule_name
EOF
    
    if [[ -f "${FORWARD_RULES_FILE}" && -s "${FORWARD_RULES_FILE}" ]]; then
        cat "${FORWARD_RULES_FILE}" >> "$export_file"
        local rule_count=$(wc -l < "${FORWARD_RULES_FILE}")
        print_debug "已导出 $rule_count 条规则到 $export_file"
        return 0
    else
        print_warning "无规则可导出"
        return 1
    fi
}

# 导入规则交互函数
import_rules_interactive() {
    print_header
    print_section "导入转发规则"
    
    echo -ne "${PRIMARY}导入文件路径: ${NC}"
    read -r import_file
    
    if [[ ! -f "$import_file" ]]; then
        print_error "文件不存在: $import_file"
        wait_enter
        show_batch_menu
        return
    fi
    
    if import_rules_core "$import_file"; then
        print_success "规则导入成功"
    else
        print_error "导入失败"
    fi
    
    wait_enter
    show_batch_menu
}

# 核心导入函数
import_rules_core() {
    local import_file="$1"
    local imported=0
    
    while IFS='|' read -r protocol external_port internal_ip internal_port external_ip rule_name timestamp; do
        # 跳过注释行
        [[ "$protocol" =~ ^#.*$ ]] && continue
        [[ -z "$protocol" ]] && continue
        
        if add_forward_rule_core "$protocol" "$external_port" "$internal_ip" "$internal_port" "$external_ip" "$rule_name"; then
            ((imported++))
        fi
    done < "$import_file"
    
    print_info "成功导入 $imported 条规则"
    return 0
}

# 备份配置函数
backup_config_interactive() {
    print_header
    print_section "备份配置"
    
    local backup_dir="/etc/nftables_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    
    cp "${NFTABLES_CONF}" "$backup_dir/" 2>/dev/null
    cp "${FORWARD_RULES_FILE}" "$backup_dir/" 2>/dev/null
    cp "${CONFIG_FILE}" "$backup_dir/" 2>/dev/null
    
    print_success "配置已备份到: $backup_dir"
    
    wait_enter
    show_batch_menu
}

# 恢复配置函数
restore_config_interactive() {
    print_header
    print_section "恢复配置"
    
    echo -ne "${PRIMARY}备份目录路径: ${NC}"
    read -r backup_dir
    
    if [[ ! -d "$backup_dir" ]]; then
        print_error "备份目录不存在"
        wait_enter
        show_batch_menu
        return
    fi
    
    cp "$backup_dir/nftables.conf" "${NFTABLES_CONF}" 2>/dev/null
    cp "$backup_dir/nftables_forward_rules.txt" "${FORWARD_RULES_FILE}" 2>/dev/null
    cp "$backup_dir/nftables_forward_config.conf" "${CONFIG_FILE}" 2>/dev/null
    
    load_config
    nft -f "${NFTABLES_CONF}"
    
    print_success "配置已恢复"
    
    wait_enter
    show_batch_menu
}

# 高级功能占位函数
add_advanced_forward_interactive() {
    print_info "高级端口转发功能开发中..."
    wait_enter
    show_advanced_menu
}

test_forward_rule_interactive() {
    print_info "转发规则测试功能开发中..."
    wait_enter
    show_advanced_menu
}

init_nftables_interactive() {
    print_header
    print_section "初始化NFTables配置"
    
    echo -ne "${ACCENT_WARNING}确定要重新初始化配置吗? [y/N]: ${NC}"
    read -r confirm
    
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        if init_nftables; then
            print_success "NFTables配置初始化成功"
        else
            print_error "初始化失败"
        fi
    else
        print_info "操作已取消"
    fi
    
    wait_enter
    show_advanced_menu
}

save_rules_interactive() {
    print_header
    print_section "保存当前规则"
    
    if save_rules_core; then
        print_success "规则保存成功"
    else
        print_error "保存失败"
    fi
    
    wait_enter
    show_advanced_menu
}

# 核心保存函数
save_rules_core() {
    print_debug "保存规则到配置文件..."
    
    if [[ -f "${NFTABLES_CONF}" ]]; then
        cp "${NFTABLES_CONF}" "${NFTABLES_CONF}.bak.$(date +%Y%m%d_%H%M%S)"
    fi
    
    nft list ruleset > "${NFTABLES_CONF}"
    sed -i '1i#!/usr/sbin/nft -f' "${NFTABLES_CONF}"
    
    print_debug "规则已保存到 $NFTABLES_CONF"
    return 0
}

reload_rules_interactive() {
    print_header
    print_section "重新加载规则"
    
    if nft -f "${NFTABLES_CONF}"; then
        print_success "规则重新加载成功"
    else
        print_error "加载失败"
    fi
    
    wait_enter
    show_advanced_menu
}

# 安全退出
exit_program() {
    print_header
    print_section "退出程序"
    
    echo -ne "${ACCENT_WARNING}确定要退出程序吗? [y/N]: ${NC}"
    read -r confirm
    
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        print_success "感谢使用 NFTables 转发管理系统！"
        echo -e "${SECONDARY_LIGHT}再见！${NC}"
        exit 0
    else
        show_main_menu
    fi
}

# 主程序入口
main() {
    # 系统检查
    check_system
    
    # 安装nftables
    install_nftables
    
    # 载入配置
    load_config
    
    # 启动主菜单
    show_main_menu
}

# 运行主程序
main "$@"
