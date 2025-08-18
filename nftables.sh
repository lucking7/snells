#!/bin/bash

# ==========================================
# NFTables 转发管理脚本 Enhanced v2.0
# 适用于 Debian/Ubuntu 系统
# 功能：IPv4/IPv6支持、双栈协议转发、自动SNAT配置
# ==========================================

# 颜色定义 - 60 30 10 原则
# 60% 主色调 - 蓝色系
PRIMARY_BLUE='\033[38;5;32m'      # 深蓝色
LIGHT_BLUE='\033[38;5;39m'        # 浅蓝色
ACCENT_BLUE='\033[38;5;33m'       # 强调蓝色

# 30% 次色调 - 灰色系
SECONDARY_GRAY='\033[38;5;242m'   # 中灰色
LIGHT_GRAY='\033[38;5;248m'       # 浅灰色
DARK_GRAY='\033[38;5;236m'        # 深灰色

# 10% 强调色 - 状态色
SUCCESS_GREEN='\033[38;5;34m'     # 成功绿色
ERROR_RED='\033[38;5;196m'        # 错误红色
WARNING_YELLOW='\033[38;5;220m'   # 警告黄色

# 重置和特殊效果
NC='\033[0m'                      # 重置颜色
BOLD='\033[1m'                    # 粗体
DIM='\033[2m'                     # 暗色
UNDERLINE='\033[4m'               # 下划线

# 统一信息符号（与其他脚本一致）
SUCCESS_SYMBOL="${BOLD}${SUCCESS_GREEN}[+]${NC}"
ERROR_SYMBOL="${BOLD}${ERROR_RED}[x]${NC}"
INFO_SYMBOL="${BOLD}${LIGHT_BLUE}[i]${NC}"
WARN_SYMBOL="${BOLD}${WARNING_YELLOW}[!]${NC}"

# 配置文件路径
NFTABLES_CONF="/etc/nftables.conf"
FORWARD_RULES_FILE="/etc/nftables_forward_rules.txt"
CONFIG_FILE="/etc/nftables_forward_config.conf"
SCRIPT_VERSION="2.0.0"

# 默认配置
DEFAULT_IP_MODE="mix"  # ipv4, ipv6, mix
DEFAULT_INTERFACE_WAN="eth0"
DEFAULT_INTERFACE_LAN="eth1"

# 全局变量初始化
IP_MODE="$DEFAULT_IP_MODE"
WAN_INTERFACE="$DEFAULT_INTERFACE_WAN"
LAN_INTERFACE="$DEFAULT_INTERFACE_LAN"
AUTO_SAVE="true"
LOG_LEVEL="info"

# API配置
IPAPI_URL="https://ipapi.co/json"

# IP信息缓存
CACHED_IPV4=""
CACHED_IPV6=""
CACHED_IPV4_INFO=""
CACHED_IPV6_INFO=""

# 载入配置文件
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
        # 确保变量不为空，使用默认值
        [[ -z "$IP_MODE" ]] && IP_MODE="$DEFAULT_IP_MODE"
        [[ -z "$WAN_INTERFACE" ]] && WAN_INTERFACE="$DEFAULT_INTERFACE_WAN"
        [[ -z "$LAN_INTERFACE" ]] && LAN_INTERFACE="$DEFAULT_INTERFACE_LAN"
        [[ -z "$AUTO_SAVE" ]] && AUTO_SAVE="true"
        [[ -z "$LOG_LEVEL" ]] && LOG_LEVEL="info"
    else
        create_default_config
    fi
}

# 创建默认配置
create_default_config() {
    cat > "$CONFIG_FILE" << EOF
# NFTables转发脚本配置文件
IP_MODE="$IP_MODE"
WAN_INTERFACE="$WAN_INTERFACE"
LAN_INTERFACE="$LAN_INTERFACE"
AUTO_SAVE="$AUTO_SAVE"
LOG_LEVEL="$LOG_LEVEL"
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

# 获取本机IP信息
get_local_ip_info() {
    # 获取IPv4
    if [[ -z "$CACHED_IPV4" ]]; then
        CACHED_IPV4=$(timeout 5 curl -s -4 ifconfig.me 2>/dev/null || timeout 5 curl -s -4 ipinfo.io/ip 2>/dev/null || echo "")
        if [[ -n "$CACHED_IPV4" ]]; then
            local ipv4_data=$(timeout 5 curl -s "${IPAPI_URL}?ip=${CACHED_IPV4}" 2>/dev/null)
            if [[ -n "$ipv4_data" ]] && echo "$ipv4_data" | jq -e . >/dev/null 2>&1; then
                local country=$(echo "$ipv4_data" | jq -r '.country_name // .country // "未知"' 2>/dev/null)
                local city=$(echo "$ipv4_data" | jq -r '.city // "未知"' 2>/dev/null)
                local org=$(echo "$ipv4_data" | jq -r '.org // .organization // "未知"' 2>/dev/null)
                CACHED_IPV4_INFO="$country/$city"
            else
                CACHED_IPV4_INFO="位置未知"
            fi
        fi
    fi
    
    # 获取IPv6
    if [[ -z "$CACHED_IPV6" ]]; then
        CACHED_IPV6=$(timeout 5 curl -s -6 ifconfig.me 2>/dev/null || timeout 5 curl -s -6 ipinfo.io/ip 2>/dev/null || echo "")
        if [[ -n "$CACHED_IPV6" ]]; then
            local ipv6_data=$(timeout 5 curl -s "${IPAPI_URL}?ip=${CACHED_IPV6}" 2>/dev/null)
            if [[ -n "$ipv6_data" ]] && echo "$ipv6_data" | jq -e . >/dev/null 2>&1; then
                local country=$(echo "$ipv6_data" | jq -r '.country_name // .country // "未知"' 2>/dev/null)
                local city=$(echo "$ipv6_data" | jq -r '.city // "未知"' 2>/dev/null)
                local org=$(echo "$ipv6_data" | jq -r '.org // .organization // "未知"' 2>/dev/null)
                CACHED_IPV6_INFO="$country/$city"
            else
                CACHED_IPV6_INFO="位置未知"
            fi
        fi
    fi
}

# 美化日志函数
print_header() {
    clear
    
    # 获取IP信息
    get_local_ip_info
    
    echo -e "${PRIMARY_BLUE}${BOLD}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║              🚀 NFTables 转发管理系统 v${SCRIPT_VERSION}              ║"
    echo "║                   双栈协议转发 | 自动SNAT配置                  ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    # 显示IP信息
    local ipv4_display="${CACHED_IPV4:-未检测到}"
    local ipv6_display="${CACHED_IPV6:-未检测到}"
    local ipv4_info_display="${CACHED_IPV4_INFO:-}"
    local ipv6_info_display="${CACHED_IPV6_INFO:-}"
    
    if [[ "$CACHED_IPV4" != "" ]]; then
        echo -e "${INFO_SYMBOL} IPv4: ${BOLD}$ipv4_display${NC} ${LIGHT_GRAY}($ipv4_info_display)${NC}"
    else
        echo -e "${WARN_SYMBOL} IPv4: 未检测到${NC}"
    fi
    
    if [[ "$CACHED_IPV6" != "" ]]; then
        echo -e "${INFO_SYMBOL} IPv6: ${BOLD}$ipv6_display${NC} ${LIGHT_GRAY}($ipv6_info_display)${NC}"
    else
        echo -e "${WARN_SYMBOL} IPv6: 未检测到${NC}"
    fi
    
    echo -e "${LIGHT_GRAY}${DIM}系统: $(lsb_release -si 2>/dev/null || echo 'Linux') | 时间: $(date '+%Y-%m-%d %H:%M:%S')${NC}"
    echo
}

print_section() {
    echo -e "${ACCENT_BLUE}${BOLD}▶ $1${NC}"
    echo -e "${SECONDARY_GRAY}$([[ -n "$2" ]] && echo "$2")${NC}"
}

print_success() {
    echo -e "${SUCCESS_GREEN}✅ $1${NC}"
}

print_error() {
    echo -e "${ERROR_RED}❌ $1${NC}"
}

print_warning() {
    echo -e "${WARNING_YELLOW}⚠️  $1${NC}"
}

print_info() {
    echo -e "${LIGHT_BLUE}ℹ️  $1${NC}"
}

print_debug() {
    [[ "$LOG_LEVEL" == "debug" ]] && echo -e "${DARK_GRAY}🔍 DEBUG: $1${NC}"
}

# 绘制分隔线
draw_line() {
    local length=${1:-60}
    local char=${2:-"─"}
    echo -e "${SECONDARY_GRAY}$(printf "%*s" $length | tr ' ' "$char")${NC}"
}

# 绘制菜单项
draw_menu_item() {
    local number="$1"
    local title="$2"
    local desc="$3"
    local status="$4"
    
    printf "${PRIMARY_BLUE}%2s${NC} ${BOLD}%-25s${NC} ${LIGHT_GRAY}%-30s${NC}" "$number" "$title" "$desc"
    [[ -n "$status" ]] && printf " ${SUCCESS_GREEN}[$status]${NC}"
    echo
}

# 等待用户输入
wait_enter() {
    echo
    echo -e "${SECONDARY_GRAY}${DIM}按 Enter 键继续...${NC}"
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
    
    # 安装jq用于JSON解析
    if ! command -v jq &> /dev/null; then
        print_info "安装JSON解析工具..."
        apt install -y jq > /dev/null 2>&1
    fi
    
    # 启用服务
    systemctl enable nftables.service > /dev/null 2>&1
    systemctl start nftables.service > /dev/null 2>&1
    print_success "nftables 服务已启用"
}

# 自动检测网络接口
auto_detect_interfaces() {
    # 自动检测WAN接口（有默认路由的接口）
    local auto_wan=$(ip route | grep default | head -n1 | awk '{print $5}' 2>/dev/null)
    if [[ -n "$auto_wan" && "$auto_wan" != "lo" ]]; then
        WAN_INTERFACE="$auto_wan"
        print_debug "自动检测到WAN接口: $WAN_INTERFACE"
    else
        print_debug "无法自动检测WAN接口，使用默认值: $WAN_INTERFACE"
    fi
    
    # 如果LAN接口不存在，设置为和WAN相同
    if ! ip link show "$LAN_INTERFACE" &>/dev/null; then
        LAN_INTERFACE="$WAN_INTERFACE"
        print_debug "LAN接口设置为: $LAN_INTERFACE"
    fi
}

# 初始化nftables配置
init_nftables() {
    print_section "初始化 nftables 配置" "IP模式: $IP_MODE"
    
    # 自动检测网络接口
    auto_detect_interfaces
    
    # 验证接口存在
    if ! ip link show "$WAN_INTERFACE" &>/dev/null; then
        print_warning "WAN接口 $WAN_INTERFACE 不存在，使用第一个可用接口"
        WAN_INTERFACE=$(ip link show | grep -E "^[0-9]+:" | grep -v lo | head -n1 | sed 's/.*: \([^:]*\):.*/\1/')
    fi
    
    # 创建配置文件
    cat > "${NFTABLES_CONF}" << EOF
#!/usr/sbin/nft -f

flush ruleset

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
    
    # 保存配置
    save_config
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
        # SNAT/Masquerade规则 - 关键！确保返回流量经过本机
        masquerade
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
        # SNAT/Masquerade规则 - 关键！确保返回流量经过本机
        masquerade
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
        # SNAT/Masquerade规则 - 关键！确保返回流量经过本机
        masquerade
    }
}

table ip6 nat {
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
    }
    
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        # SNAT/Masquerade规则 - 关键！确保返回流量经过本机
        masquerade
    }
}
EOF
}

# 主菜单
show_main_menu() {
    print_header
    
    echo -e "${PRIMARY_BLUE}${BOLD}主菜单${NC}"
    draw_line 60
    
    draw_menu_item "1" "转发规则管理" "添加、删除、查看转发规则"
    draw_menu_item "2" "系统配置" "IP模式、接口配置等"
    draw_menu_item "3" "系统状态" "查看服务状态和统计"
    draw_menu_item "4" "批量管理" "导入导出规则配置"
    draw_menu_item "5" "高级功能" "高级转发、测试等"
    draw_menu_item "6" "帮助文档" "使用说明和示例"
    draw_menu_item "0" "退出程序" "安全退出脚本"
    
    draw_line 60
    echo -ne "${ACCENT_BLUE}请选择功能 [0-6]: ${NC}"
    
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
        6) show_help_menu ;;
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
    echo -ne "${ACCENT_BLUE}请选择操作 [1-4,9]: ${NC}"
    
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
    echo -e "${LIGHT_BLUE}1${NC} TCP  ${LIGHT_BLUE}2${NC} UDP  ${LIGHT_BLUE}3${NC} TCP + UDP"
    echo -ne "${ACCENT_BLUE}协议 [1-3]: ${NC}"
    read -r proto_choice
    [[ -z "$proto_choice" ]] && proto_choice="3"
    
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
    echo -ne "${ACCENT_BLUE}外部端口 (回车=随机): ${NC}"
    read -r external_port
    
    if [[ -z "$external_port" ]]; then
        external_port=$((RANDOM % 30000 + 10000))
        print_success "已生成随机端口: $external_port"
    elif ! [[ "$external_port" =~ ^[0-9]+$ ]] || [[ "$external_port" -lt 1 || "$external_port" -gt 65535 ]]; then
        print_error "端口号无效"
        wait_enter
        show_forward_menu
        return
    fi
    
    # 内网IP
    echo -ne "${ACCENT_BLUE}目标IP: ${NC}"
    read -r internal_ip
    
    if [[ -z "$internal_ip" ]]; then
        print_error "目标IP不能为空"
        wait_enter
        show_forward_menu
        return
    fi
    
    # 检测目标IP类型
    local target_ip_type="unknown"
    if [[ "$internal_ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        target_ip_type="ipv4"
    elif [[ "$internal_ip" =~ ^[0-9a-fA-F:]+$ ]]; then
        target_ip_type="ipv6"
    else
        print_error "无效IP格式"
        wait_enter
        show_forward_menu
        return
    fi
    
    # 内网端口
    echo -ne "${ACCENT_BLUE}目标端口 (默认: $external_port): ${NC}"
    read -r internal_port
    [[ -z "$internal_port" ]] && internal_port="$external_port"
    
    # 源IP限制
    echo -e "${LIGHT_BLUE}1${NC} 不限制  ${LIGHT_BLUE}2${NC} 限制源IP"
    echo -ne "${ACCENT_BLUE}源IP限制 [1-2]: ${NC}"
    read -r source_choice
    [[ -z "$source_choice" ]] && source_choice="1"
    
    local source_ip="any"
    if [[ "$source_choice" == "2" ]]; then
        echo -ne "${ACCENT_BLUE}源IP: ${NC}"
        read -r source_ip
        [[ -z "$source_ip" ]] && source_ip="any"
    fi
    
    # 规则名称
    echo -ne "${ACCENT_BLUE}规则名称 (回车=自动): ${NC}"
    read -r rule_name
    [[ -z "$rule_name" ]] && rule_name="forward_${external_port}_$(date +%s)"
    
    # 确认添加
    echo
    echo -e "${LIGHT_GRAY}$protocol $external_port → $internal_ip:$internal_port ($rule_name)${NC}"
    echo -ne "${WARNING_YELLOW}确认添加? [Y/n]: ${NC}"
    read -r confirm
    [[ -z "$confirm" ]] && confirm="y"
    
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        if add_forward_rule_core "$protocol" "$external_port" "$internal_ip" "$internal_port" "$source_ip" "$rule_name" "$target_ip_type"; then
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
    local target_ip_type="${7:-ipv4}"
    
    print_debug "添加规则: $protocol $external_port -> $internal_ip:$internal_port"
    
    # 检查nftables表是否存在，如果不存在则初始化
    if ! nft list tables 2>/dev/null | grep -q "table"; then
        print_warning "初始化NFTables..."
        if ! init_nftables; then
            print_error "初始化失败"
            return 1
        fi
    fi
    
    # 根据目标IP类型选择表
    local table_family=""
    case "$target_ip_type" in
        "ipv4") table_family="ip" ;;
        "ipv6") table_family="ip6" ;;
        *) table_family="ip" ;;
    esac
    
    # 构建规则
    local src_condition=""
    if [[ "$external_ip" != "any" ]]; then
        if [[ "$target_ip_type" == "ipv4" ]]; then
            src_condition="ip saddr $external_ip "
        else
            src_condition="ip6 saddr $external_ip "
        fi
    fi
    
    # 添加转发规则到nftables
    local success=true
    
    if [[ "$protocol" == "tcp" || "$protocol" == "both" ]]; then
        local to_target_tcp="$internal_ip:$internal_port"
        if [[ "$target_ip_type" == "ipv6" ]]; then
            to_target_tcp="[$internal_ip]:$internal_port"
        fi
        local tcp_rule="${src_condition}tcp dport $external_port dnat to $to_target_tcp comment \"$rule_name\""
        print_debug "执行命令: nft add rule $table_family nat prerouting $tcp_rule"
        if ! nft add rule $table_family nat prerouting $tcp_rule 2>/dev/null; then
            print_error "TCP转发规则添加失败: $(nft add rule $table_family nat prerouting $tcp_rule 2>&1)"
            success=false
        else
            print_success "TCP转发规则添加成功"
            echo "tcp|$external_port|$internal_ip|$internal_port|$external_ip|$rule_name|$(date)" >> "${FORWARD_RULES_FILE}"
        fi
    fi
    
    if [[ "$protocol" == "udp" || "$protocol" == "both" ]]; then
        local to_target_udp="$internal_ip:$internal_port"
        if [[ "$target_ip_type" == "ipv6" ]]; then
            to_target_udp="[$internal_ip]:$internal_port"
        fi
        local udp_rule="${src_condition}udp dport $external_port dnat to $to_target_udp comment \"$rule_name\""
        print_debug "执行命令: nft add rule $table_family nat prerouting $udp_rule"
        if ! nft add rule $table_family nat prerouting $udp_rule 2>/dev/null; then
            print_error "UDP转发规则添加失败: $(nft add rule $table_family nat prerouting $udp_rule 2>&1)"
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

# 系统配置菜单
show_config_menu() {
    print_header
    print_section "系统配置"
    
    draw_menu_item "1" "IP协议模式" "当前: $IP_MODE"
    draw_menu_item "2" "网络接口配置" "WAN: $WAN_INTERFACE | LAN: $LAN_INTERFACE"
    draw_menu_item "3" "其他设置" "自动保存等"
    draw_menu_item "9" "返回主菜单" ""
    
    draw_line 40
    echo -ne "${ACCENT_BLUE}请选择配置项 [1-3,9]: ${NC}"
    
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
    print_section "IP协议模式"
    
    echo -e "${LIGHT_BLUE}当前: ${BOLD}$IP_MODE${NC}"
    echo
    echo -e "${LIGHT_BLUE}1${NC} IPv4  ${LIGHT_BLUE}2${NC} IPv6  ${LIGHT_BLUE}3${NC} Mixed"
    echo -ne "${ACCENT_BLUE}选择模式 [1-3]: ${NC}"
    
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
        print_success "模式已更改: $IP_MODE"
        print_warning "需重新初始化配置"
    else
        print_info "模式未更改"
    fi
    
    wait_enter
    show_config_menu
}

# 初始化nftables交互式菜单
init_nftables_interactive() {
    print_header
    print_section "初始化配置"
    
    echo -e "${WARNING_YELLOW}将重置所有配置和规则！${NC}"
    echo -ne "${ACCENT_BLUE}确认? [y/N]: ${NC}"
    read -r confirm
    
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        if init_nftables; then
            print_success "初始化成功"
        else
            print_error "初始化失败"
        fi
    else
        print_info "操作已取消"
    fi
    
    wait_enter
    show_advanced_menu
}

# 保存规则交互式菜单
save_rules_interactive() {
    print_header
    print_section "保存规则"
    
    echo -ne "${ACCENT_BLUE}保存当前规则? [Y/n]: ${NC}"
    read -r confirm
    [[ -z "$confirm" ]] && confirm="y"
    
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        if save_rules_core; then
            print_success "规则保存成功"
        else
            print_error "规则保存失败"
        fi
    else
        print_info "操作已取消"
    fi
    
    wait_enter
    show_advanced_menu
}

# 删除转发规则交互式函数
delete_forward_rule_interactive() {
    print_header
    print_section "删除转发规则"
    
    # 首先显示现有规则
    if [[ ! -f "${FORWARD_RULES_FILE}" ]] || [[ ! -s "${FORWARD_RULES_FILE}" ]]; then
        print_warning "暂无转发规则"
        wait_enter
        show_forward_menu
        return
    fi
    
    echo -e "${LIGHT_BLUE}当前转发规则:${NC}"
    draw_line 60
    
    local counter=1
    while IFS='|' read -r protocol external_port internal_ip internal_port external_ip rule_name create_time; do
        [[ -z "$protocol" ]] && continue
        printf "${PRIMARY_BLUE}%2s${NC} ${BOLD}%-8s${NC} ${LIGHT_GRAY}%5s -> %15s:%-5s %20s${NC}\n" \
            "$counter" "$protocol" "$external_port" "$internal_ip" "$internal_port" "$rule_name"
        ((counter++))
    done < "${FORWARD_RULES_FILE}"
    
    draw_line 60
    echo -ne "${ACCENT_BLUE}请输入要删除的规则序号或规则名称: ${NC}"
    read -r rule_identifier
    
    if [[ -z "$rule_identifier" ]]; then
        print_error "输入不能为空"
        wait_enter
        show_forward_menu
        return
    fi
    
    # 确认删除
    echo -ne "${WARNING_YELLOW}确认删除规则 '$rule_identifier'? [y/N]: ${NC}"
    read -r confirm
    
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        if delete_forward_rule_core "$rule_identifier"; then
            print_success "转发规则删除成功！"
        else
            print_error "转发规则删除失败！"
        fi
    else
        print_info "操作已取消"
    fi
    
    wait_enter
    show_forward_menu
}

# 核心删除规则函数
delete_forward_rule_core() {
    local rule_identifier="$1"
    local deleted=false
    
    # 通过序号删除
    if [[ "$rule_identifier" =~ ^[0-9]+$ ]]; then
        local line_number=$(($rule_identifier))
        local rule_info=$(sed -n "${line_number}p" "${FORWARD_RULES_FILE}")
        
        if [[ -n "$rule_info" ]]; then
            local protocol=$(echo "$rule_info" | cut -d'|' -f1)
            local external_port=$(echo "$rule_info" | cut -d'|' -f2)
            
            # 删除nftables规则
            nft list ruleset -a | grep "dport $external_port" | grep "$protocol" | while read -r line; do
                local handle=$(echo "$line" | grep -o 'handle [0-9]*' | awk '{print $2}')
                if [[ -n "$handle" ]]; then
                    local table_family="ip"
                    [[ "$IP_MODE" == "ipv6" ]] && table_family="ip6"
                    nft delete rule $table_family nat prerouting handle "$handle" 2>/dev/null
                fi
            done
            
            # 从记录文件中删除
            sed -i "${line_number}d" "${FORWARD_RULES_FILE}"
            deleted=true
        fi
    else
        # 通过规则名称删除
        if grep -q "|$rule_identifier|" "${FORWARD_RULES_FILE}" 2>/dev/null; then
            local rule_info=$(grep "|$rule_identifier|" "${FORWARD_RULES_FILE}")
            local protocol=$(echo "$rule_info" | cut -d'|' -f1)
            local external_port=$(echo "$rule_info" | cut -d'|' -f2)
            
            # 删除nftables规则
            nft list ruleset -a | grep "dport $external_port" | grep "$protocol" | while read -r line; do
                local handle=$(echo "$line" | grep -o 'handle [0-9]*' | awk '{print $2}')
                if [[ -n "$handle" ]]; then
                    local table_family="ip"
                    [[ "$IP_MODE" == "ipv6" ]] && table_family="ip6"
                    nft delete rule $table_family nat prerouting handle "$handle" 2>/dev/null
                fi
            done
            
            # 从记录文件中删除
            sed -i "/$rule_identifier/d" "${FORWARD_RULES_FILE}"
            deleted=true
        fi
    fi
    
    # 自动保存
    if [[ "$AUTO_SAVE" == "true" && "$deleted" == "true" ]]; then
        save_rules_core
    fi
    
    [[ "$deleted" == "true" ]]
}

# 列出转发规则交互式函数
list_forward_rules_interactive() {
    print_header
    print_section "转发规则列表"
    
    if [[ ! -f "${FORWARD_RULES_FILE}" ]] || [[ ! -s "${FORWARD_RULES_FILE}" ]]; then
        print_warning "暂无转发规则"
        wait_enter
        show_forward_menu
        return
    fi
    
    printf "${PRIMARY_BLUE}%-4s %-8s %-6s %-15s %-6s %-15s %-20s %-20s${NC}\n" \
        "序号" "协议" "外端口" "内网IP" "内端口" "源IP限制" "规则名称" "创建时间"
    draw_line 100
    
    local counter=1
    while IFS='|' read -r protocol external_port internal_ip internal_port external_ip rule_name create_time; do
        [[ -z "$protocol" ]] && continue
        
        local src_display="any"
        [[ "$external_ip" != "any" ]] && src_display="$external_ip"
        
        printf "${LIGHT_GRAY}%-4s %-8s %-6s %-15s %-6s %-15s %-20s %-20s${NC}\n" \
            "$counter" "$protocol" "$external_port" "$internal_ip" "$internal_port" \
            "$src_display" "$rule_name" "$create_time"
        
        ((counter++))
    done < "${FORWARD_RULES_FILE}"
    
    echo
    print_info "总计 $((counter-1)) 条转发规则"
    
    # 显示当前活动的nftables规则
    echo
    print_section "当前活动的NAT规则"
    local table_family="ip"
    [[ "$IP_MODE" == "ipv6" ]] && table_family="ip6"
    nft list table $table_family nat 2>/dev/null || print_warning "无法获取NAT规则"
    
    wait_enter
    show_forward_menu
}

# 清空所有规则交互式函数
flush_all_rules_interactive() {
    print_header
    print_section "清空所有转发规则"
    
    if [[ ! -f "${FORWARD_RULES_FILE}" ]] || [[ ! -s "${FORWARD_RULES_FILE}" ]]; then
        print_warning "暂无转发规则需要清空"
        wait_enter
        show_forward_menu
        return
    fi
    
    local rule_count=$(wc -l < "${FORWARD_RULES_FILE}")
    print_warning "当前有 $rule_count 条转发规则"
    echo
    echo -ne "${ERROR_RED}${BOLD}清空所有规则？不可恢复！ [y/N]: ${NC}"
    read -r confirm
    
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        print_info "正在清空所有转发规则..."
        
        # 清空NAT表
        local table_family="ip"
        [[ "$IP_MODE" == "ipv6" ]] && table_family="ip6"
        
        nft flush table $table_family nat 2>/dev/null
        [[ "$IP_MODE" == "mix" ]] && nft flush table ip6 nat 2>/dev/null
        
        # 重新创建链并添加masquerade规则
        nft add chain $table_family nat prerouting { type nat hook prerouting priority dstnat\; policy accept\; } 2>/dev/null
        nft add chain $table_family nat postrouting { type nat hook postrouting priority srcnat\; policy accept\; } 2>/dev/null
        nft add rule $table_family nat postrouting masquerade 2>/dev/null
        
        if [[ "$IP_MODE" == "mix" ]]; then
            nft add chain ip6 nat prerouting { type nat hook prerouting priority dstnat\; policy accept\; } 2>/dev/null
            nft add chain ip6 nat postrouting { type nat hook postrouting priority srcnat\; policy accept\; } 2>/dev/null
            nft add rule ip6 nat postrouting masquerade 2>/dev/null
        fi
        
        # 清空记录文件
        > "${FORWARD_RULES_FILE}"
        
        # 自动保存
        if [[ "$AUTO_SAVE" == "true" ]]; then
            save_rules_core
        fi
        
        print_success "所有转发规则已清空"
    else
        print_info "操作已取消"
    fi
    
    wait_enter
    show_forward_menu
}

# 配置网络接口
config_interfaces() {
    print_header
    print_section "网络接口"
    
    echo -e "${LIGHT_BLUE}当前: WAN=$WAN_INTERFACE LAN=$LAN_INTERFACE${NC}"
    echo
    
    # 显示可用接口
    echo -e "${LIGHT_BLUE}可用接口:${NC}"
    ip link show | grep -E "^[0-9]+:" | sed 's/.*: \([^:]*\):.*/\1/' | tr '\n' ' '
    echo -e "\n"
    
    echo -ne "${ACCENT_BLUE}WAN (当前: $WAN_INTERFACE): ${NC}"
    read -r new_wan
    [[ -n "$new_wan" ]] && WAN_INTERFACE="$new_wan"
    
    echo -ne "${ACCENT_BLUE}LAN (当前: $LAN_INTERFACE): ${NC}"
    read -r new_lan
    [[ -n "$new_lan" ]] && LAN_INTERFACE="$new_lan"
    
    save_config
    print_success "接口已更新"
    print_warning "需重新初始化配置"
    
    wait_enter
    show_config_menu
}

# 其他设置
config_other_settings() {
    print_header
    print_section "其他设置"
    
    echo -e "${LIGHT_BLUE}当前: 自动保存=$AUTO_SAVE 日志=$LOG_LEVEL${NC}"
    echo
    
    echo -e "${LIGHT_BLUE}1${NC} 启用自动保存  ${LIGHT_BLUE}2${NC} 禁用自动保存"
    echo -ne "${ACCENT_BLUE}自动保存 [1-2]: ${NC}"
    read -r auto_save_choice
    
    case "$auto_save_choice" in
        1) AUTO_SAVE="true" ;;
        2) AUTO_SAVE="false" ;;
    esac
    
    echo
    echo -e "${LIGHT_BLUE}1${NC} info  ${LIGHT_BLUE}2${NC} debug"
    echo -ne "${ACCENT_BLUE}日志级别 [1-2]: ${NC}"
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

# 重新加载规则交互式菜单
reload_rules_interactive() {
    print_header
    print_section "重新加载"
    
    echo -ne "${ACCENT_BLUE}重新加载规则? [y/N]: ${NC}"
    read -r confirm
    
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        if nft -f "${NFTABLES_CONF}"; then
            print_success "规则重新加载成功"
        else
            print_error "规则重新加载失败"
        fi
    else
        print_info "操作已取消"
    fi
    
    wait_enter
    show_advanced_menu
}

# 高级端口转发交互式菜单
add_advanced_forward_interactive() {
    print_header
    print_section "高级转发"
    
    print_info "请使用基本转发规则管理"
    
    wait_enter
    show_advanced_menu
}

# 测试转发规则交互式菜单
test_forward_rule_interactive() {
    print_header
    print_section "测试转发规则"
    
    echo -ne "${ACCENT_BLUE}请输入要测试的端口: ${NC}"
    read -r test_port
    
    if [[ -z "$test_port" ]] || ! [[ "$test_port" =~ ^[0-9]+$ ]]; then
        print_error "端口号无效"
        wait_enter
        show_advanced_menu
        return
    fi
    
    echo -e "${LIGHT_BLUE}正在测试端口 $test_port 的连通性...${NC}"
    
    # 测试端口是否监听
    if netstat -ln 2>/dev/null | grep -q ":$test_port "; then
        print_success "端口 $test_port 正在监听"
    else
        print_warning "端口 $test_port 未监听"
    fi
    
    # 显示相关的nftables规则
    echo
    print_section "相关转发规则"
    nft list ruleset | grep "$test_port" || print_info "未找到相关规则"
    
    wait_enter
    show_advanced_menu
}

# 系统状态菜单
show_status_menu() {
    print_header
    print_section "系统状态"
    
    # 服务状态
    echo -e "${PRIMARY_BLUE}${BOLD}服务状态:${NC}"
    systemctl status nftables.service --no-pager -l
    echo
    
    # 规则统计
    print_section "规则统计"
    local rule_count=$(wc -l < "${FORWARD_RULES_FILE}" 2>/dev/null || echo "0")
    echo -e "${LIGHT_GRAY}总转发规则数: $rule_count${NC}"
    echo -e "${LIGHT_GRAY}当前IP模式: $IP_MODE${NC}"
    echo -e "${LIGHT_GRAY}WAN接口: $WAN_INTERFACE${NC}"
    echo -e "${LIGHT_GRAY}LAN接口: $LAN_INTERFACE${NC}"
    echo
    
    # 内核模块
    print_section "相关内核模块"
    lsmod | grep -E "(nf_tables|nf_nat|nf_conntrack)" || echo -e "${WARNING_YELLOW}未加载相关模块${NC}"
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
    echo -ne "${ACCENT_BLUE}请选择操作 [1-4,9]: ${NC}"
    
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
    echo -ne "${ACCENT_BLUE}请选择功能 [1-5,9]: ${NC}"
    
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

# 帮助菜单
show_help_menu() {
    print_header
    print_section "帮助"
    
    echo -e "${LIGHT_BLUE}快速使用:${NC}"
    echo -e "${LIGHT_GRAY}1. 初始化配置 2. 添加转发规则 3. 查看规则状态${NC}"
    echo
    echo -e "${LIGHT_BLUE}常用命令:${NC}"
    echo -e "${LIGHT_GRAY}检查IP转发: sysctl net.ipv4.ip_forward${NC}"
    echo -e "${LIGHT_GRAY}启用IP转发: echo 1 > /proc/sys/net/ipv4/ip_forward${NC}"
    
    wait_enter
    show_main_menu
}

# 核心保存函数
save_rules_core() {
    print_debug "保存规则到配置文件..."
    
    # 备份原配置
    if [[ -f "${NFTABLES_CONF}" ]]; then
        cp "${NFTABLES_CONF}" "${NFTABLES_CONF}.bak.$(date +%Y%m%d_%H%M%S)"
    fi
    
    # 导出当前规则集
    nft list ruleset > "${NFTABLES_CONF}"
    
    # 在文件开头添加shebang
    sed -i '1i#!/usr/sbin/nft -f' "${NFTABLES_CONF}"
    
    print_debug "规则已保存到 $NFTABLES_CONF"
}

# 导出规则交互式函数（示例，其他函数类似实现）
export_rules_interactive() {
    print_header
    print_section "导出转发规则"
    
    local default_filename="nftables_forward_rules_$(date +%Y%m%d_%H%M%S).txt"
    echo -ne "${ACCENT_BLUE}导出文件名 (默认: $default_filename): ${NC}"
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
    
    # 添加头部注释
    cat > "$export_file" << EOF
# nftables转发规则导出文件
# 生成时间: $(date)
# 格式: protocol|external_port|internal_ip|internal_port|external_ip|rule_name
# 协议: tcp, udp, both
# external_ip: any 表示不限制源IP
EOF
    
    # 复制规则
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

# 导入规则交互式函数
import_rules_interactive() {
    print_header
    print_section "导入转发规则"
    
    echo -ne "${ACCENT_BLUE}请输入规则文件路径: ${NC}"
    read -r import_file
    
    if [[ ! -f "$import_file" ]]; then
        print_error "文件不存在: $import_file"
        wait_enter
        show_batch_menu
        return
    fi
    
    echo -ne "${WARNING_YELLOW}导入规则? [y/N]: ${NC}"
    read -r confirm
    
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        if import_rules_core "$import_file"; then
            print_success "规则导入成功"
        else
            print_error "规则导入失败"
        fi
    else
        print_info "操作已取消"
    fi
    
    wait_enter
    show_batch_menu
}

# 核心导入函数
import_rules_core() {
    local import_file="$1"
    local imported_count=0
    
    print_info "正在导入规则..."
    
    while IFS='|' read -r protocol external_port internal_ip internal_port external_ip rule_name create_time; do
        # 跳过注释和空行
        [[ -z "$protocol" || "$protocol" =~ ^# ]] && continue
        
        # 检测目标IP类型
        local target_ip_type="ipv4"
        if [[ "$internal_ip" =~ ^[0-9a-fA-F:]+$ ]]; then
            target_ip_type="ipv6"
        fi
        
        if add_forward_rule_core "$protocol" "$external_port" "$internal_ip" "$internal_port" "$external_ip" "$rule_name" "$target_ip_type"; then
            ((imported_count++))
            print_success "导入规则: $protocol $external_port -> $internal_ip:$internal_port"
        else
            print_error "导入失败: $protocol $external_port -> $internal_ip:$internal_port"
        fi
    done < "$import_file"
    
    print_info "共导入 $imported_count 条规则"
    [[ $imported_count -gt 0 ]]
}

# 备份配置交互式函数
backup_config_interactive() {
    print_header
    print_section "备份配置"
    
    local backup_dir="/etc/nftables_backup_$(date +%Y%m%d_%H%M%S)"
    echo -ne "${ACCENT_BLUE}备份目录 (默认: $backup_dir): ${NC}"
    read -r custom_backup_dir
    [[ -n "$custom_backup_dir" ]] && backup_dir="$custom_backup_dir"
    
    echo -ne "${ACCENT_BLUE}创建备份? [Y/n]: ${NC}"
    read -r confirm
    [[ -z "$confirm" ]] && confirm="y"
    
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        if backup_config_core "$backup_dir"; then
            print_success "配置备份成功: $backup_dir"
        else
            print_error "配置备份失败"
        fi
    else
        print_info "操作已取消"
    fi
    
    wait_enter
    show_batch_menu
}

# 核心备份函数
backup_config_core() {
    local backup_dir="$1"
    
    if mkdir -p "$backup_dir"; then
        # 备份配置文件
        [[ -f "$CONFIG_FILE" ]] && cp "$CONFIG_FILE" "$backup_dir/"
        [[ -f "$NFTABLES_CONF" ]] && cp "$NFTABLES_CONF" "$backup_dir/"
        [[ -f "$FORWARD_RULES_FILE" ]] && cp "$FORWARD_RULES_FILE" "$backup_dir/"
        
        # 保存当前nftables规则
        nft list ruleset > "$backup_dir/current_ruleset.nft"
        
        # 创建备份信息文件
        cat > "$backup_dir/backup_info.txt" << EOF
# NFTables配置备份信息
备份时间: $(date)
系统版本: $(lsb_release -ds 2>/dev/null || cat /etc/debian_version)
脚本版本: $SCRIPT_VERSION
IP模式: $IP_MODE
WAN接口: $WAN_INTERFACE
LAN接口: $LAN_INTERFACE
规则数量: $(wc -l < "${FORWARD_RULES_FILE}" 2>/dev/null || echo "0")
EOF
        
        print_debug "备份已创建: $backup_dir"
        return 0
    else
        print_error "无法创建备份目录: $backup_dir"
        return 1
    fi
}

# 恢复配置交互式函数
restore_config_interactive() {
    print_header
    print_section "恢复配置"
    
    echo -ne "${ACCENT_BLUE}请输入备份目录路径: ${NC}"
    read -r restore_dir
    
    if [[ ! -d "$restore_dir" ]]; then
        print_error "备份目录不存在: $restore_dir"
        wait_enter
        show_batch_menu
        return
    fi
    
    # 显示备份信息
    if [[ -f "$restore_dir/backup_info.txt" ]]; then
        echo -e "${LIGHT_BLUE}备份信息:${NC}"
        cat "$restore_dir/backup_info.txt"
        echo
    fi
    
    echo -ne "${WARNING_YELLOW}恢复配置? 将覆盖当前! [y/N]: ${NC}"
    read -r confirm
    
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        if restore_config_core "$restore_dir"; then
            print_success "恢复成功"
            print_warning "需重启脚本"
        else
            print_error "恢复失败"
        fi
    else
        print_info "操作已取消"
    fi
    
    wait_enter
    show_batch_menu
}

# 核心恢复函数
restore_config_core() {
    local restore_dir="$1"
    
    print_info "正在恢复配置..."
    
    # 恢复配置文件
    [[ -f "$restore_dir/$(basename "$CONFIG_FILE")" ]] && cp "$restore_dir/$(basename "$CONFIG_FILE")" "$CONFIG_FILE"
    [[ -f "$restore_dir/$(basename "$NFTABLES_CONF")" ]] && cp "$restore_dir/$(basename "$NFTABLES_CONF")" "$NFTABLES_CONF"
    [[ -f "$restore_dir/$(basename "$FORWARD_RULES_FILE")" ]] && cp "$restore_dir/$(basename "$FORWARD_RULES_FILE")" "$FORWARD_RULES_FILE"
    
    # 恢复nftables规则
    if [[ -f "$restore_dir/current_ruleset.nft" ]]; then
        nft -f "$restore_dir/current_ruleset.nft" 2>/dev/null || print_warning "无法恢复nftables规则，请手动重新加载"
    fi
    
    # 重新加载配置
    load_config
    
    print_debug "配置已恢复: $restore_dir"
    return 0
}

# 安全退出
exit_program() {
    print_header
    print_section "退出程序"
    
    echo -ne "${WARNING_YELLOW}退出程序? [y/N]: ${NC}"
    read -r confirm
    
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        print_success "感谢使用 NFTables 转发管理系统！"
        echo -e "${SECONDARY_GRAY}${DIM}再见！${NC}"
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
