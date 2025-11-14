#!/bin/bash

# ECS PHD 自动重启系统测试脚本
# 使用方法: ./test.sh [phd-event|restart-event|all]

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 配置
AWS_REGION=${AWS_REGION:-"cn-northwest-1"}
SMART_HANDLER_FUNCTION="ecs-phd-smart-handler"
RESTART_EXECUTOR_FUNCTION="ecs-phd-restart-executor"

# 日志函数
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检查AWS CLI
check_aws_cli() {
    if ! command -v aws &> /dev/null; then
        log_error "AWS CLI 未安装，请先安装 AWS CLI"
        exit 1
    fi
    
    if ! aws sts get-caller-identity &> /dev/null; then
        log_error "AWS 凭证未配置，请先配置 AWS 凭证"
        exit 1
    fi
    
    log_info "AWS CLI 检查通过"
}

# 检查jq工具
check_jq() {
    if ! command -v jq &> /dev/null; then
        log_warning "jq 未安装，输出格式可能不够友好"
        return 1
    fi
    return 0
}

# 测试PHD事件处理
test_phd_event() {
    local test_file="../tests/test-phd-event.json"
    
    log_info "测试 PHD 事件处理..."
    
    if [ ! -f "${test_file}" ]; then
        log_error "测试文件不存在: ${test_file}"
        return 1
    fi
    
    log_info "调用 Smart Handler Lambda..."
    local result
    result=$(aws lambda invoke \
        --function-name "${SMART_HANDLER_FUNCTION}" \
        --payload "file://${test_file}" \
        --region "${AWS_REGION}" \
        --cli-binary-format raw-in-base64-out \
        response.json 2>&1)
    
    if [ $? -eq 0 ]; then
        log_success "Smart Handler 调用成功"
        
        # 显示响应
        if check_jq; then
            echo "响应内容:"
            jq '.' response.json
        else
            echo "响应内容:"
            cat response.json
        fi
        
        # 清理响应文件
        rm -f response.json
        
        return 0
    else
        log_error "Smart Handler 调用失败: ${result}"
        return 1
    fi
}

# 测试重启事件处理
test_restart_event() {
    local test_file="../tests/test-restart-event.json"
    
    log_info "测试重启事件处理..."
    
    if [ ! -f "${test_file}" ]; then
        log_error "测试文件不存在: ${test_file}"
        return 1
    fi
    
    log_info "调用 Restart Executor Lambda..."
    local result
    result=$(aws lambda invoke \
        --function-name "${RESTART_EXECUTOR_FUNCTION}" \
        --payload "file://${test_file}" \
        --region "${AWS_REGION}" \
        --cli-binary-format raw-in-base64-out \
        response.json 2>&1)
    
    if [ $? -eq 0 ]; then
        log_success "Restart Executor 调用成功"
        
        # 显示响应
        if check_jq; then
            echo "响应内容:"
            jq '.' response.json
        else
            echo "响应内容:"
            cat response.json
        fi
        
        # 清理响应文件
        rm -f response.json
        
        return 0
    else
        log_error "Restart Executor 调用失败: ${result}"
        return 1
    fi
}

# 检查Lambda函数状态
check_function_status() {
    local function_name=$1
    
    log_info "检查 Lambda 函数状态: ${function_name}"
    
    local function_info
    function_info=$(aws lambda get-function --function-name "${function_name}" --region "${AWS_REGION}" 2>/dev/null)
    
    if [ $? -eq 0 ]; then
        local state=$(echo "${function_info}" | jq -r '.Configuration.State // "Unknown"')
        local last_update=$(echo "${function_info}" | jq -r '.Configuration.LastModified // "Unknown"')
        
        log_success "函数状态: ${state}"
        echo "  - 最后更新: ${last_update}"
        return 0
    else
        log_error "无法获取函数信息，请检查函数是否存在"
        return 1
    fi
}

# 运行完整测试套件
run_full_test() {
    log_info "运行完整测试套件..."
    
    # 检查函数状态
    check_function_status "${SMART_HANDLER_FUNCTION}"
    echo ""
    check_function_status "${RESTART_EXECUTOR_FUNCTION}"
    echo ""
    
    # 测试PHD事件
    test_phd_event
    echo ""
    
    # 测试重启事件
    test_restart_event
    
    log_success "完整测试套件执行完成！"
}

# 显示帮助信息
show_help() {
    echo "ECS PHD 自动重启系统测试脚本"
    echo ""
    echo "使用方法:"
    echo "  ./test.sh [选项]"
    echo ""
    echo "选项:"
    echo "  phd-event        测试 PHD 事件处理"
    echo "  restart-event    测试重启事件处理"
    echo "  all              运行完整测试套件"
    echo "  help             显示此帮助信息"
    echo ""
    echo "环境变量:"
    echo "  AWS_REGION       AWS 区域 (默认: cn-northwest-1)"
    echo ""
    echo "示例:"
    echo "  ./test.sh phd-event"
    echo "  ./test.sh all"
    echo "  AWS_REGION=us-east-1 ./test.sh all"
    echo ""
    echo "注意:"
    echo "  - 测试使用 test_mode=true，不会执行实际的 ECS 操作"
    echo "  - 需要安装 jq 工具以获得更好的输出格式"
}

# 主函数
main() {
    local target=${1:-"help"}
    
    case "${target}" in
        "phd-event")
            check_aws_cli
            test_phd_event
            ;;
        "restart-event")
            check_aws_cli
            test_restart_event
            ;;
        "all")
            check_aws_cli
            run_full_test
            ;;
        "help"|*)
            show_help
            ;;
    esac
}

# 执行主函数
main "$@"