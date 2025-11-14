#!/bin/bash

# ECS PHD 自动重启系统部署脚本 (仅 Lambda 函数)
# 使用方法: ./deploy.sh [smart-handler|restart-executor|all]
# 注意: 此脚本仅部署 Lambda 函数，如需完整部署请使用 deploy-full.sh

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 配置
AWS_REGION=${AWS_REGION:-"cn-northwest-1"}
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "unknown")
FUNCTION_TIMEOUT=300
FUNCTION_MEMORY=512
WEBHOOK_URL=${WEBHOOK_URL:-""}

# 资源名称
SMART_HANDLER_FUNCTION_NAME="ecs-phd-smart-handler"
RESTART_EXECUTOR_FUNCTION_NAME="ecs-phd-restart-executor"

# ARN 前缀（支持中国区域）
if [[ "${AWS_REGION}" == cn-* ]]; then
    ARN_PREFIX="arn:aws-cn"
else
    ARN_PREFIX="arn:aws"
fi

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
    log_info "当前 AWS 账户: ${AWS_ACCOUNT_ID}"
    log_info "当前 AWS 区域: ${AWS_REGION}"
}

# 创建部署包
create_deployment_package() {
    local function_name=$1
    local source_dir="../${function_name}"
    local package_file="${function_name}-deployment.zip"
    
    log_info "为 ${function_name} 创建部署包..."
    
    # 检查源目录
    if [ ! -d "${source_dir}" ]; then
        log_error "源目录不存在: ${source_dir}"
        return 1
    fi
    
    if [ ! -f "${source_dir}/lambda_function.py" ]; then
        log_error "Lambda 函数文件不存在: ${source_dir}/lambda_function.py"
        return 1
    fi
    
    # 清理旧的部署包
    rm -f "${package_file}"
    
    # 创建部署包（使用绝对路径避免目录切换问题）
    local current_dir=$(pwd)
    local package_path="${current_dir}/${package_file}"
    
    # 使用 -j 选项避免目录结构，直接在源目录打包
    (cd "${source_dir}" && zip -j "${package_path}" lambda_function.py > /dev/null)
    
    log_success "部署包创建完成: ${package_file}"
}

# 部署Lambda函数
deploy_lambda() {
    local function_name=$1
    local package_file="${function_name}-deployment.zip"
    local lambda_function_name
    
    # 根据函数名确定 Lambda 函数名称
    if [ "${function_name}" = "smart-handler" ]; then
        lambda_function_name="${SMART_HANDLER_FUNCTION_NAME}"
    elif [ "${function_name}" = "restart-executor" ]; then
        lambda_function_name="${RESTART_EXECUTOR_FUNCTION_NAME}"
    else
        lambda_function_name="ecs-phd-${function_name//-/_}"
    fi
    
    log_info "部署 Lambda 函数: ${lambda_function_name}"
    
    # 检查函数是否存在
    if aws lambda get-function --function-name "${lambda_function_name}" --region "${AWS_REGION}" &> /dev/null; then
        log_info "更新现有 Lambda 函数..."
        aws lambda update-function-code \
            --function-name "${lambda_function_name}" \
            --zip-file "fileb://${package_file}" \
            --region "${AWS_REGION}" > /dev/null
        
        # 更新函数配置
        aws lambda update-function-configuration \
            --function-name "${lambda_function_name}" \
            --timeout "${FUNCTION_TIMEOUT}" \
            --memory-size "${FUNCTION_MEMORY}" \
            --region "${AWS_REGION}" > /dev/null
        
        # 设置环境变量
        set_environment_variables "${lambda_function_name}" "${function_name}"
        
    else
        log_warning "Lambda 函数不存在: ${lambda_function_name}"
        log_info "请先使用以下方式创建函数:"
        log_info "1. 使用 deploy-full.sh 进行完整部署"
        log_info "2. 通过 AWS 控制台手动创建"
        log_info "3. 使用 CloudFormation 模板"
        echo ""
        log_info "函数配置信息:"
        log_info "  - 函数名称: ${lambda_function_name}"
        log_info "  - 运行时: python3.9"
        log_info "  - 处理程序: lambda_function.lambda_handler"
        log_info "  - 超时时间: ${FUNCTION_TIMEOUT}s"
        log_info "  - 内存大小: ${FUNCTION_MEMORY}MB"
        return 1
    fi
    
    log_success "Lambda 函数部署完成: ${lambda_function_name}"
}

# 设置环境变量
set_environment_variables() {
    local lambda_function_name=$1
    local function_name=$2
    
    log_info "设置环境变量: ${lambda_function_name}"
    
    local env_vars="{}"
    
    if [ "${function_name}" = "smart-handler" ]; then
        # Smart Handler 环境变量
        local restart_executor_arn="${ARN_PREFIX}:lambda:${AWS_REGION}:${AWS_ACCOUNT_ID}:function:${RESTART_EXECUTOR_FUNCTION_NAME}"
        env_vars="{\"RESTART_EXECUTOR_ARN\":\"${restart_executor_arn}\""
        
        if [ -n "${WEBHOOK_URL}" ]; then
            env_vars="${env_vars},\"WEBHOOK_URL\":\"${WEBHOOK_URL}\""
        fi
        env_vars="${env_vars}}"
        
    elif [ "${function_name}" = "restart-executor" ]; then
        # Restart Executor 环境变量
        if [ -n "${WEBHOOK_URL}" ]; then
            env_vars="{\"WEBHOOK_URL\":\"${WEBHOOK_URL}\"}"
        fi
    fi
    
    if [ "${env_vars}" != "{}" ]; then
        aws lambda update-function-configuration \
            --function-name "${lambda_function_name}" \
            --environment "Variables=${env_vars}" \
            --region "${AWS_REGION}" > /dev/null
        
        log_success "环境变量设置完成"
    else
        log_info "无需设置环境变量"
    fi
}

# 验证部署
verify_deployment() {
    local function_name=$1
    local lambda_function_name
    
    # 根据函数名确定 Lambda 函数名称
    if [ "${function_name}" = "smart-handler" ]; then
        lambda_function_name="${SMART_HANDLER_FUNCTION_NAME}"
    elif [ "${function_name}" = "restart-executor" ]; then
        lambda_function_name="${RESTART_EXECUTOR_FUNCTION_NAME}"
    else
        lambda_function_name="ecs-phd-${function_name//-/_}"
    fi
    
    log_info "验证 Lambda 函数: ${lambda_function_name}"
    
    # 获取函数信息
    local function_info
    function_info=$(aws lambda get-function --function-name "${lambda_function_name}" --region "${AWS_REGION}" 2>/dev/null)
    
    if [ $? -eq 0 ]; then
        local runtime=$(echo "${function_info}" | jq -r '.Configuration.Runtime' 2>/dev/null || echo "unknown")
        local timeout=$(echo "${function_info}" | jq -r '.Configuration.Timeout' 2>/dev/null || echo "unknown")
        local memory=$(echo "${function_info}" | jq -r '.Configuration.MemorySize' 2>/dev/null || echo "unknown")
        local last_modified=$(echo "${function_info}" | jq -r '.Configuration.LastModified' 2>/dev/null || echo "unknown")
        
        log_success "函数验证通过:"
        echo "  - 运行时: ${runtime}"
        echo "  - 超时时间: ${timeout}s"
        echo "  - 内存大小: ${memory}MB"
        echo "  - 最后修改: ${last_modified}"
        
        # 显示环境变量（如果有）
        local env_vars=$(echo "${function_info}" | jq -r '.Configuration.Environment.Variables // {}' 2>/dev/null)
        if [ "${env_vars}" != "{}" ] && [ "${env_vars}" != "null" ]; then
            echo "  - 环境变量: 已配置"
        fi
    else
        log_error "函数验证失败"
        return 1
    fi
}

# 部署单个函数
deploy_function() {
    local function_name=$1
    
    log_info "开始部署 ${function_name}..."
    
    create_deployment_package "${function_name}"
    if deploy_lambda "${function_name}"; then
        verify_deployment "${function_name}"
        
        # 清理部署包
        rm -f "${function_name}-deployment.zip"
        
        log_success "${function_name} 部署完成"
    else
        # 清理部署包
        rm -f "${function_name}-deployment.zip"
        return 1
    fi
}

# 显示帮助信息
show_help() {
    echo "ECS PHD 自动重启系统部署脚本 (仅 Lambda 函数)"
    echo ""
    echo "使用方法:"
    echo "  ./deploy.sh [选项]"
    echo ""
    echo "选项:"
    echo "  smart-handler     部署 Smart Handler Lambda"
    echo "  restart-executor  部署 Restart Executor Lambda"
    echo "  all              部署所有 Lambda 函数"
    echo "  help             显示此帮助信息"
    echo ""
    echo "环境变量:"
    echo "  AWS_REGION       AWS 区域 (默认: cn-northwest-1)"
    echo "  WEBHOOK_URL      飞书 Webhook URL (可选)"
    echo ""
    echo "示例:"
    echo "  ./deploy.sh smart-handler"
    echo "  ./deploy.sh all"
    echo "  WEBHOOK_URL=https://open.feishu.cn/... ./deploy.sh all"
    echo ""
    echo "注意:"
    echo "  - 此脚本仅部署 Lambda 函数代码"
    echo "  - 如需完整部署 (IAM 角色、EventBridge 规则等)，请使用 deploy-full.sh"
    echo "  - Lambda 函数必须已存在，否则部署将失败"
}

# 主函数
main() {
    local target=${1:-"help"}
    
    case "${target}" in
        "smart-handler")
            check_aws_cli
            deploy_function "smart-handler"
            ;;
        "restart-executor")
            check_aws_cli
            deploy_function "restart-executor"
            ;;
        "all")
            check_aws_cli
            log_info "开始部署所有 Lambda 函数..."
            echo ""
            
            if deploy_function "smart-handler"; then
                echo ""
                if deploy_function "restart-executor"; then
                    echo ""
                    log_success "🎉 所有函数部署完成！"
                    echo ""
                    log_info "提示: 如果这是首次部署，请确保:"
                    log_info "1. EventBridge 规则已创建并指向 Smart Handler"
                    log_info "2. IAM 角色权限配置正确"
                    log_info "3. 环境变量已正确设置"
                else
                    log_error "Restart Executor 部署失败"
                    exit 1
                fi
            else
                log_error "Smart Handler 部署失败"
                exit 1
            fi
            ;;
        "help"|*)
            show_help
            ;;
    esac
}

# 执行主函数
main "$@"