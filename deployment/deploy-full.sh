#!/bin/bash

# ECS PHD 自动重启系统完整部署脚本
# 包含 IAM 角色、Lambda 函数、EventBridge 规则等所有资源
# 使用方法: ./deploy-full.sh [infrastructure|lambda|all|cleanup]

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 配置
AWS_REGION=${AWS_REGION:-"cn-northwest-1"}
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
FUNCTION_TIMEOUT=300
FUNCTION_MEMORY=512
WEBHOOK_URL=${WEBHOOK_URL:-""}

# 资源名称
SMART_HANDLER_ROLE_NAME="ecs-phd-smart-handler-role"
RESTART_EXECUTOR_ROLE_NAME="ecs-phd-restart-executor-role"
SMART_HANDLER_FUNCTION_NAME="ecs-phd-smart-handler"
RESTART_EXECUTOR_FUNCTION_NAME="ecs-phd-restart-executor"
PHD_EVENT_RULE_NAME="ecs-phd-event-rule"

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

# 检查前置条件
check_prerequisites() {
    log_info "检查前置条件..."
    
    # 检查 AWS CLI
    if ! command -v aws &> /dev/null; then
        log_error "AWS CLI 未安装，请先安装 AWS CLI"
        exit 1
    fi
    
    # 检查 AWS 凭证
    if ! aws sts get-caller-identity &> /dev/null; then
        log_error "AWS 凭证未配置，请先配置 AWS 凭证"
        exit 1
    fi
    
    # 检查 jq
    if ! command -v jq &> /dev/null; then
        log_warning "jq 未安装，某些功能可能受限"
    fi
    
    log_info "当前 AWS 账户: ${AWS_ACCOUNT_ID}"
    log_info "当前 AWS 区域: ${AWS_REGION}"
    log_success "前置条件检查通过"
}

# 创建 IAM 角色
create_iam_role() {
    local role_name=$1
    local trust_policy=$2
    local policy_document=$3
    local policy_name="${role_name}-policy"
    
    log_info "创建 IAM 角色: ${role_name}"
    
    # 检查角色是否存在
    if aws iam get-role --role-name "${role_name}" &> /dev/null; then
        log_warning "IAM 角色已存在: ${role_name}"
    else
        # 创建角色
        aws iam create-role \
            --role-name "${role_name}" \
            --assume-role-policy-document "${trust_policy}" \
            --description "ECS PHD Auto Restart System Role" > /dev/null
        
        log_success "IAM 角色创建成功: ${role_name}"
    fi
    
    # 创建或更新策略
    local policy_arn="${ARN_PREFIX}:iam::${AWS_ACCOUNT_ID}:policy/${policy_name}"
    
    if aws iam get-policy --policy-arn "${policy_arn}" &> /dev/null; then
        log_info "更新现有策略: ${policy_name}"
        
        # 检查策略版本数量，如果达到限制则删除最旧的版本
        local versions=$(aws iam list-policy-versions --policy-arn "${policy_arn}" --query 'Versions[?!IsDefaultVersion].VersionId' --output text)
        local version_count=$(echo "${versions}" | wc -w)
        
        if [ ${version_count} -ge 4 ]; then
            # 获取最旧的非默认版本并删除
            local oldest_version=$(aws iam list-policy-versions --policy-arn "${policy_arn}" --query 'Versions[?!IsDefaultVersion] | sort_by(@, &CreateDate) | [0].VersionId' --output text)
            if [ -n "${oldest_version}" ] && [ "${oldest_version}" != "None" ]; then
                log_info "删除最旧的策略版本: ${oldest_version}"
                aws iam delete-policy-version --policy-arn "${policy_arn}" --version-id "${oldest_version}" 2>/dev/null || true
            fi
        fi
        
        # 创建新版本
        local version_id=$(aws iam create-policy-version \
            --policy-arn "${policy_arn}" \
            --policy-document "${policy_document}" \
            --set-as-default \
            --query 'PolicyVersion.VersionId' \
            --output text 2>/dev/null || echo "")
        
        if [ -n "${version_id}" ]; then
            log_success "策略版本更新成功: ${version_id}"
        else
            log_success "策略版本更新成功"
        fi
    else
        log_info "创建新策略: ${policy_name}"
        
        aws iam create-policy \
            --policy-name "${policy_name}" \
            --policy-document "${policy_document}" \
            --description "ECS PHD Auto Restart System Policy" > /dev/null
        
        log_success "策略创建成功: ${policy_name}"
    fi
    
    # 附加策略到角色
    aws iam attach-role-policy \
        --role-name "${role_name}" \
        --policy-arn "${policy_arn}" 2>/dev/null || true
    
    # 附加基础执行策略
    aws iam attach-role-policy \
        --role-name "${role_name}" \
        --policy-arn "${ARN_PREFIX}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole" 2>/dev/null || true
    
    log_success "IAM 角色配置完成: ${role_name}"
}

# 创建 Smart Handler IAM 角色
create_smart_handler_role() {
    local trust_policy='{
        "Version": "2012-10-17",
        "Statement": [
            {
                "Effect": "Allow",
                "Principal": {
                    "Service": "lambda.amazonaws.com"
                },
                "Action": "sts:AssumeRole"
            }
        ]
    }'
    
    local policy_document='{
        "Version": "2012-10-17",
        "Statement": [
            {
                "Sid": "EventBridgeAccess",
                "Effect": "Allow",
                "Action": [
                    "events:PutRule",
                    "events:PutTargets",
                    "events:DescribeRule"
                ],
                "Resource": [
                    "'${ARN_PREFIX}':events:'${AWS_REGION}':'${AWS_ACCOUNT_ID}':rule/ecs-restart-*"
                ]
            },
            {
                "Sid": "ParameterStoreAccess",
                "Effect": "Allow",
                "Action": [
                    "ssm:GetParameter",
                    "ssm:PutParameter"
                ],
                "Resource": [
                    "'${ARN_PREFIX}':ssm:'${AWS_REGION}':'${AWS_ACCOUNT_ID}':parameter/ecs-phd-restart/*"
                ]
            },
            {
                "Sid": "BasicLambdaExecution",
                "Effect": "Allow",
                "Action": [
                    "logs:CreateLogGroup",
                    "logs:CreateLogStream",
                    "logs:PutLogEvents"
                ],
                "Resource": "'${ARN_PREFIX}':logs:'${AWS_REGION}':'${AWS_ACCOUNT_ID}':*"
            }
        ]
    }'
    
    create_iam_role "${SMART_HANDLER_ROLE_NAME}" "${trust_policy}" "${policy_document}"
}

# 创建 Restart Executor IAM 角色
create_restart_executor_role() {
    local trust_policy='{
        "Version": "2012-10-17",
        "Statement": [
            {
                "Effect": "Allow",
                "Principal": {
                    "Service": "lambda.amazonaws.com"
                },
                "Action": "sts:AssumeRole"
            }
        ]
    }'
    
    local policy_document='{
        "Version": "2012-10-17",
        "Statement": [
            {
                "Sid": "ECSAccess",
                "Effect": "Allow",
                "Action": [
                    "ecs:UpdateService",
                    "ecs:DescribeServices",
                    "ecs:DescribeTasks",
                    "ecs:ListServices"
                ],
                "Resource": "*"
            },
            {
                "Sid": "EventBridgeCleanup",
                "Effect": "Allow",
                "Action": [
                    "events:RemoveTargets",
                    "events:DeleteRule"
                ],
                "Resource": [
                    "'${ARN_PREFIX}':events:'${AWS_REGION}':'${AWS_ACCOUNT_ID}':rule/ecs-restart-*"
                ]
            },
            {
                "Sid": "BasicLambdaExecution",
                "Effect": "Allow",
                "Action": [
                    "logs:CreateLogGroup",
                    "logs:CreateLogStream",
                    "logs:PutLogEvents"
                ],
                "Resource": "'${ARN_PREFIX}':logs:'${AWS_REGION}':'${AWS_ACCOUNT_ID}':*"
            }
        ]
    }'
    
    create_iam_role "${RESTART_EXECUTOR_ROLE_NAME}" "${trust_policy}" "${policy_document}"
}

# 等待角色生效
wait_for_role() {
    local role_name=$1
    local max_attempts=30
    local attempt=1
    
    log_info "等待 IAM 角色生效: ${role_name}"
    
    while [ ${attempt} -le ${max_attempts} ]; do
        if aws iam get-role --role-name "${role_name}" &> /dev/null; then
            log_success "IAM 角色已生效: ${role_name}"
            return 0
        fi
        
        echo -n "."
        sleep 2
        ((attempt++))
    done
    
    log_error "IAM 角色等待超时: ${role_name}"
    return 1
}

# 等待 Lambda 函数更新完成
wait_for_lambda_update() {
    local function_name=$1
    local max_attempts=30
    local attempt=1
    
    log_info "等待 Lambda 函数更新完成: ${function_name}"
    
    while [ ${attempt} -le ${max_attempts} ]; do
        local state=$(aws lambda get-function --function-name "${function_name}" --region "${AWS_REGION}" --query 'Configuration.State' --output text 2>/dev/null)
        
        if [ "$state" = "Active" ]; then
            log_success "Lambda 函数更新完成: ${function_name}"
            return 0
        elif [ "$state" = "Failed" ]; then
            log_error "Lambda 函数更新失败: ${function_name}"
            return 1
        fi
        
        echo -n "."
        sleep 3
        ((attempt++))
    done
    
    log_error "Lambda 函数更新等待超时: ${function_name}"
    return 1
}

# 创建部署包
create_deployment_package() {
    local function_name=$1
    local source_dir="../${function_name}"
    local package_file="${function_name}-deployment.zip"
    
    log_info "为 ${function_name} 创建部署包..."
    
    # 清理旧的部署包
    rm -f "${package_file}"
    
    # 创建部署包（使用绝对路径避免目录切换问题）
    local current_dir=$(pwd)
    local package_path="${current_dir}/${package_file}"
    
    # 使用 -j 选项避免目录结构，直接在源目录打包
    (cd "${source_dir}" && zip -j "${package_path}" lambda_function.py > /dev/null)
    
    log_success "部署包创建完成: ${package_file}"
}

# 部署 Lambda 函数
deploy_lambda_function() {
    local function_name=$1
    local lambda_function_name=$2
    local role_name=$3
    local package_file="${function_name}-deployment.zip"
    local role_arn="${ARN_PREFIX}:iam::${AWS_ACCOUNT_ID}:role/${role_name}"
    
    log_info "部署 Lambda 函数: ${lambda_function_name}"
    
    # 创建部署包
    create_deployment_package "${function_name}"
    
    # 检查函数是否存在
    if aws lambda get-function --function-name "${lambda_function_name}" --region "${AWS_REGION}" &> /dev/null; then
        log_info "更新现有 Lambda 函数..."
        
        # 更新函数代码
        aws lambda update-function-code \
            --function-name "${lambda_function_name}" \
            --zip-file "fileb://${package_file}" \
            --region "${AWS_REGION}" > /dev/null
        
        # 等待代码更新完成
        wait_for_lambda_update "${lambda_function_name}"
        
        # 更新函数配置
        aws lambda update-function-configuration \
            --function-name "${lambda_function_name}" \
            --timeout "${FUNCTION_TIMEOUT}" \
            --memory-size "${FUNCTION_MEMORY}" \
            --region "${AWS_REGION}" > /dev/null
        
        # 等待配置更新完成
        wait_for_lambda_update "${lambda_function_name}"
    else
        log_info "创建新 Lambda 函数..."
        
        # 等待角色生效
        wait_for_role "${role_name}"
        
        # 创建函数
        aws lambda create-function \
            --function-name "${lambda_function_name}" \
            --runtime python3.9 \
            --role "${role_arn}" \
            --handler lambda_function.lambda_handler \
            --zip-file "fileb://${package_file}" \
            --timeout "${FUNCTION_TIMEOUT}" \
            --memory-size "${FUNCTION_MEMORY}" \
            --description "ECS PHD Auto Restart System - ${function_name}" \
            --region "${AWS_REGION}" > /dev/null
    fi
    
    # 清理部署包
    rm -f "${package_file}"
    
    log_success "Lambda 函数部署完成: ${lambda_function_name}"
}

# 设置环境变量
set_lambda_environment() {
    local function_name=$1
    local env_vars=$2
    
    log_info "设置 Lambda 环境变量: ${function_name}"
    
    aws lambda update-function-configuration \
        --function-name "${function_name}" \
        --environment Variables="${env_vars}" \
        --region "${AWS_REGION}" > /dev/null
    
    log_success "环境变量设置完成: ${function_name}"
}

# 创建 EventBridge 规则
create_eventbridge_rule() {
    log_info "创建 EventBridge 规则: ${PHD_EVENT_RULE_NAME}"
    
    local event_pattern='{
        "source": ["aws.health"],
        "detail-type": ["AWS Health Event"],
        "detail": {
            "service": ["ECS"],
            "eventTypeCategory": ["scheduledChange"],
            "eventTypeCode": ["AWS_ECS_TASK_PATCHING_RETIREMENT"]
        }
    }'
    
    # 检查规则是否存在
    if aws events describe-rule --name "${PHD_EVENT_RULE_NAME}" --region "${AWS_REGION}" &> /dev/null; then
        log_warning "EventBridge 规则已存在: ${PHD_EVENT_RULE_NAME}"
    else
        # 创建规则
        aws events put-rule \
            --name "${PHD_EVENT_RULE_NAME}" \
            --event-pattern "${event_pattern}" \
            --state ENABLED \
            --description "ECS PHD Event Processing Rule" \
            --region "${AWS_REGION}" > /dev/null
        
        log_success "EventBridge 规则创建成功: ${PHD_EVENT_RULE_NAME}"
    fi
    
    # 添加目标
    local smart_handler_arn="${ARN_PREFIX}:lambda:${AWS_REGION}:${AWS_ACCOUNT_ID}:function:${SMART_HANDLER_FUNCTION_NAME}"
    
    aws events put-targets \
        --rule "${PHD_EVENT_RULE_NAME}" \
        --targets "Id=1,Arn=${smart_handler_arn}" \
        --region "${AWS_REGION}" > /dev/null
    
    # 添加 Lambda 权限
    aws lambda add-permission \
        --function-name "${SMART_HANDLER_FUNCTION_NAME}" \
        --statement-id "AllowExecutionFromEventBridge" \
        --action "lambda:InvokeFunction" \
        --principal events.amazonaws.com \
        --source-arn "${ARN_PREFIX}:events:${AWS_REGION}:${AWS_ACCOUNT_ID}:rule/${PHD_EVENT_RULE_NAME}" \
        --region "${AWS_REGION}" 2>/dev/null || true
    
    log_success "EventBridge 规则配置完成: ${PHD_EVENT_RULE_NAME}"
}

# 部署基础设施
deploy_infrastructure() {
    log_info "开始部署基础设施..."
    
    # 创建 IAM 角色
    create_smart_handler_role
    create_restart_executor_role
    
    log_success "基础设施部署完成"
}

# 部署 Lambda 函数
deploy_lambda_functions() {
    log_info "开始部署 Lambda 函数..."
    
    # 部署 Smart Handler
    deploy_lambda_function "smart-handler" "${SMART_HANDLER_FUNCTION_NAME}" "${SMART_HANDLER_ROLE_NAME}"
    
    # 部署 Restart Executor
    deploy_lambda_function "restart-executor" "${RESTART_EXECUTOR_FUNCTION_NAME}" "${RESTART_EXECUTOR_ROLE_NAME}"
    
    # 设置环境变量
    local restart_executor_arn="${ARN_PREFIX}:lambda:${AWS_REGION}:${AWS_ACCOUNT_ID}:function:${RESTART_EXECUTOR_FUNCTION_NAME}"
    
    # 确保两个函数都已就绪
    wait_for_lambda_update "${SMART_HANDLER_FUNCTION_NAME}"
    wait_for_lambda_update "${RESTART_EXECUTOR_FUNCTION_NAME}"
    
    # Smart Handler 环境变量
    log_info "设置 Smart Handler 环境变量..."
    
    # 创建临时环境变量文件
    local smart_handler_env_file=$(mktemp)
    if [ -n "${WEBHOOK_URL}" ]; then
        cat > "${smart_handler_env_file}" <<EOF
{
    "Variables": {
        "RESTART_EXECUTOR_ARN": "${restart_executor_arn}",
        "WEBHOOK_URL": "${WEBHOOK_URL}"
    }
}
EOF
    else
        cat > "${smart_handler_env_file}" <<EOF
{
    "Variables": {
        "RESTART_EXECUTOR_ARN": "${restart_executor_arn}"
    }
}
EOF
    fi
    
    aws lambda update-function-configuration \
        --function-name "${SMART_HANDLER_FUNCTION_NAME}" \
        --environment file://"${smart_handler_env_file}" \
        --region "${AWS_REGION}" > /dev/null
    
    rm -f "${smart_handler_env_file}"
    log_success "Smart Handler 环境变量设置完成"
    
    # Restart Executor 环境变量
    log_info "设置 Restart Executor 环境变量..."
    
    local restart_executor_env_file=$(mktemp)
    if [ -n "${WEBHOOK_URL}" ]; then
        cat > "${restart_executor_env_file}" <<EOF
{
    "Variables": {
        "WEBHOOK_URL": "${WEBHOOK_URL}"
    }
}
EOF
    else
        cat > "${restart_executor_env_file}" <<EOF
{
    "Variables": {}
}
EOF
    fi
    
    aws lambda update-function-configuration \
        --function-name "${RESTART_EXECUTOR_FUNCTION_NAME}" \
        --environment file://"${restart_executor_env_file}" \
        --region "${AWS_REGION}" > /dev/null
    
    rm -f "${restart_executor_env_file}"
    log_success "Restart Executor 环境变量设置完成"
    
    # 创建 EventBridge 规则
    create_eventbridge_rule
    
    log_success "Lambda 函数部署完成"
}

# 验证部署
verify_deployment() {
    log_info "验证部署结果..."
    
    # 验证 IAM 角色
    for role in "${SMART_HANDLER_ROLE_NAME}" "${RESTART_EXECUTOR_ROLE_NAME}"; do
        if aws iam get-role --role-name "${role}" &> /dev/null; then
            log_success "✓ IAM 角色: ${role}"
        else
            log_error "✗ IAM 角色: ${role}"
        fi
    done
    
    # 验证 Lambda 函数
    for func in "${SMART_HANDLER_FUNCTION_NAME}" "${RESTART_EXECUTOR_FUNCTION_NAME}"; do
        if aws lambda get-function --function-name "${func}" --region "${AWS_REGION}" &> /dev/null; then
            log_success "✓ Lambda 函数: ${func}"
        else
            log_error "✗ Lambda 函数: ${func}"
        fi
    done
    
    # 验证 EventBridge 规则
    if aws events describe-rule --name "${PHD_EVENT_RULE_NAME}" --region "${AWS_REGION}" &> /dev/null; then
        log_success "✓ EventBridge 规则: ${PHD_EVENT_RULE_NAME}"
    else
        log_error "✗ EventBridge 规则: ${PHD_EVENT_RULE_NAME}"
    fi
    
    log_success "部署验证完成"
}

# 清理资源
cleanup_resources() {
    log_warning "开始清理资源..."
    
    # 删除 EventBridge 规则
    log_info "删除 EventBridge 规则..."
    aws events remove-targets --rule "${PHD_EVENT_RULE_NAME}" --ids "1" --region "${AWS_REGION}" 2>/dev/null || true
    aws events delete-rule --name "${PHD_EVENT_RULE_NAME}" --region "${AWS_REGION}" 2>/dev/null || true
    
    # 删除 Lambda 函数
    log_info "删除 Lambda 函数..."
    aws lambda delete-function --function-name "${SMART_HANDLER_FUNCTION_NAME}" --region "${AWS_REGION}" 2>/dev/null || true
    aws lambda delete-function --function-name "${RESTART_EXECUTOR_FUNCTION_NAME}" --region "${AWS_REGION}" 2>/dev/null || true
    
    # 删除 IAM 角色和策略
    log_info "删除 IAM 资源..."
    for role in "${SMART_HANDLER_ROLE_NAME}" "${RESTART_EXECUTOR_ROLE_NAME}"; do
        # 分离策略
        aws iam detach-role-policy --role-name "${role}" --policy-arn "${ARN_PREFIX}:iam::${AWS_ACCOUNT_ID}:policy/${role}-policy" 2>/dev/null || true
        aws iam detach-role-policy --role-name "${role}" --policy-arn "${ARN_PREFIX}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole" 2>/dev/null || true
        
        # 删除角色
        aws iam delete-role --role-name "${role}" 2>/dev/null || true
        
        # 删除策略
        aws iam delete-policy --policy-arn "${ARN_PREFIX}:iam::${AWS_ACCOUNT_ID}:policy/${role}-policy" 2>/dev/null || true
    done
    
    log_success "资源清理完成"
}

# 显示帮助信息
show_help() {
    echo "ECS PHD 自动重启系统完整部署脚本"
    echo ""
    echo "使用方法:"
    echo "  ./deploy-full.sh [选项]"
    echo ""
    echo "选项:"
    echo "  infrastructure    部署基础设施 (IAM 角色)"
    echo "  lambda           部署 Lambda 函数和 EventBridge 规则"
    echo "  all              部署所有资源"
    echo "  verify           验证部署结果"
    echo "  cleanup          清理所有资源"
    echo "  help             显示此帮助信息"
    echo ""
    echo "环境变量:"
    echo "  AWS_REGION       AWS 区域 (默认: cn-northwest-1)"
    echo "  WEBHOOK_URL      飞书 Webhook URL (可选)"
    echo ""
    echo "示例:"
    echo "  ./deploy-full.sh all"
    echo "  WEBHOOK_URL=https://open.feishu.cn/... ./deploy-full.sh all"
    echo "  ./deploy-full.sh cleanup"
}

# 主函数
main() {
    local action=${1:-"help"}
    
    case "${action}" in
        "infrastructure")
            check_prerequisites
            deploy_infrastructure
            ;;
        "lambda")
            check_prerequisites
            deploy_lambda_functions
            ;;
        "all")
            check_prerequisites
            deploy_infrastructure
            echo ""
            deploy_lambda_functions
            echo ""
            verify_deployment
            echo ""
            
            # 询问是否初始化Parameter Store参数
            read -p "是否初始化春节假期参数到Parameter Store？(y/N): " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                log_info "初始化Parameter Store参数..."
                if [ -f "./init-parameters.sh" ]; then
                    AWS_REGION="${AWS_REGION}" ./init-parameters.sh all
                else
                    log_warning "未找到init-parameters.sh脚本"
                fi
            fi
            
            log_success "🎉 完整部署成功！"
            ;;
        "verify")
            check_prerequisites
            verify_deployment
            ;;
        "cleanup")
            check_prerequisites
            cleanup_resources
            ;;
        "help"|*)
            show_help
            ;;
    esac
}

# 执行主函数
main "$@"