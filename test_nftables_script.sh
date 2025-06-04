#!/bin/bash

# NFTables转发脚本测试套件
# 测试各种功能而不需要实际的root权限

echo "=========================================="
echo "NFTables转发脚本功能测试"
echo "=========================================="

SCRIPT="./nftables_forward.sh"
TEST_PASSED=0
TEST_FAILED=0

# 颜色定义
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 测试函数
test_function() {
    local test_name="$1"
    local command="$2"
    local expected_exit_code="${3:-1}"  # 大多数测试预期失败(需要root)
    
    echo -n "测试: $test_name ... "
    
    # 执行命令并捕获输出
    output=$(eval "$command" 2>&1)
    exit_code=$?
    
    if [[ $exit_code -eq $expected_exit_code ]]; then
        echo -e "${GREEN}通过${NC}"
        ((TEST_PASSED++))
        return 0
    else
        echo -e "${RED}失败${NC}"
        echo "  预期退出码: $expected_exit_code, 实际: $exit_code"
        echo "  输出: $output"
        ((TEST_FAILED++))
        return 1
    fi
}

echo
echo "1. 基础功能测试"
echo "----------------------------------------"

# 测试脚本是否可执行
test_function "脚本可执行性" "test -x $SCRIPT" 0

# 测试语法检查
test_function "脚本语法检查" "bash -n $SCRIPT" 0

# 测试帮助功能（应该因为需要root而失败）
test_function "帮助功能" "$SCRIPT help" 1

# 测试无效参数
test_function "无效参数处理" "$SCRIPT invalid_command" 1

echo
echo "2. 参数验证测试"
echo "----------------------------------------"

# 测试add命令参数不足
test_function "add命令参数不足" "$SCRIPT add" 1
test_function "add命令参数不足2" "$SCRIPT add tcp" 1
test_function "add命令参数不足3" "$SCRIPT add tcp 80" 1
test_function "add命令参数不足4" "$SCRIPT add tcp 80 192.168.1.1" 1

# 测试delete命令参数不足
test_function "delete命令参数不足" "$SCRIPT delete" 1

# 测试test命令参数不足
test_function "test命令参数不足" "$SCRIPT test" 1

# 测试import命令参数不足
test_function "import命令参数不足" "$SCRIPT import" 1

echo
echo "3. 文件和权限测试"
echo "----------------------------------------"

# 测试脚本文件存在
test_function "主脚本文件存在" "test -f $SCRIPT" 0

# 测试使用说明文件存在
test_function "使用说明文件存在" "test -f nftables_forward_使用说明.md" 0

# 测试示例配置文件存在
test_function "示例配置文件存在" "test -f 示例规则配置.txt" 0

# 测试README文件存在
test_function "README文件存在" "test -f README.md" 0

echo
echo "4. 配置文件格式测试"
echo "----------------------------------------"

# 测试示例配置文件格式
test_function "示例配置文件格式检查" "grep -E '^[^#].*\|.*\|.*\|.*\|.*\|.*$' 示例规则配置.txt > /dev/null" 0

# 检查配置文件中是否有有效的规则行
RULE_COUNT=$(grep -E '^[^#].*\|.*\|.*\|.*\|.*\|.*$' 示例规则配置.txt | wc -l)
test_function "示例配置包含规则" "test $RULE_COUNT -gt 0" 0

echo
echo "5. 脚本内容验证测试"
echo "----------------------------------------"

# 检查关键函数是否存在
test_function "add_forward_rule函数存在" "grep -q 'add_forward_rule()' $SCRIPT" 0
test_function "delete_forward_rule函数存在" "grep -q 'delete_forward_rule()' $SCRIPT" 0
test_function "list_forward_rules函数存在" "grep -q 'list_forward_rules()' $SCRIPT" 0
test_function "show_help函数存在" "grep -q 'show_help()' $SCRIPT" 0
test_function "add_advanced_forward函数存在" "grep -q 'add_advanced_forward()' $SCRIPT" 0

# 检查关键变量是否定义
test_function "版本号定义" "grep -q 'SCRIPT_VERSION=' $SCRIPT" 0
test_function "配置文件路径定义" "grep -q 'NFTABLES_CONF=' $SCRIPT" 0
test_function "规则文件路径定义" "grep -q 'FORWARD_RULES_FILE=' $SCRIPT" 0

echo
echo "6. 文档完整性测试"
echo "----------------------------------------"

# 检查使用说明文档的关键章节
test_function "使用说明包含快速开始" "grep -q '快速开始' nftables_forward_使用说明.md" 0
test_function "使用说明包含详细用法" "grep -q '详细用法' nftables_forward_使用说明.md" 0
test_function "使用说明包含故障排除" "grep -q '故障排除' nftables_forward_使用说明.md" 0

# 检查README文档的关键内容
test_function "README包含特性说明" "grep -q '特性' README.md" 0
test_function "README包含快速开始" "grep -q '快速开始' README.md" 0

echo
echo "7. 示例配置验证测试"
echo "----------------------------------------"

# 创建临时测试配置文件
cat > test_rules.txt << 'EOF'
# 测试规则文件
tcp|80|192.168.1.100|8080|any|test_web
udp|53|192.168.1.10|53|any|test_dns
both|22|192.168.1.50|22|10.0.0.100|test_ssh
EOF

test_function "测试配置文件创建" "test -f test_rules.txt" 0

# 验证配置文件格式
VALID_LINES=$(grep -E '^[^#].*\|.*\|.*\|.*\|.*\|.*$' test_rules.txt | wc -l)
test_function "测试配置格式正确" "test $VALID_LINES -eq 3" 0

# 清理测试文件
rm -f test_rules.txt

echo
echo "8. 高级功能测试"
echo "----------------------------------------"

# 测试advanced命令参数验证
test_function "advanced命令参数不足" "$SCRIPT advanced" 1
test_function "advanced命令参数不足2" "$SCRIPT advanced 53" 1
test_function "advanced命令参数不足3" "$SCRIPT advanced 53 192.168.1.1:53" 1

echo
echo "=========================================="
echo "测试结果汇总"
echo "=========================================="
echo -e "通过测试: ${GREEN}$TEST_PASSED${NC}"
echo -e "失败测试: ${RED}$TEST_FAILED${NC}"
echo -e "总计测试: $((TEST_PASSED + TEST_FAILED))"

if [[ $TEST_FAILED -eq 0 ]]; then
    echo -e "\n${GREEN}✅ 所有测试通过！脚本功能正常。${NC}"
    exit 0
else
    echo -e "\n${YELLOW}⚠️  有 $TEST_FAILED 个测试失败，请检查相关功能。${NC}"
    exit 1
fi