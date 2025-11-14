#!/bin/bash

# ECS PHD 自动重启系统 Parameter Store 初始化脚本
# 用于初始化春节假期配置参数
# 使用方法: ./init-parameters.sh [year|all|list|delete]

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 配置
AWS_REGION=${AWS_REGION:-"cn-northwest-1"}
PARAMETER_PREFIX="/ecs-phd-restart/spring-festival"

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
    
    log_success "前置条件检查通过"
}

# 春节日期数据（中国时间）
declare -A SPRING_FESTIVAL_DATES=(
    ["2024"]="2024-02-10T00:00:00+08:00|2024-02-17T23:59:59+08:00|2024年春节长假"
    ["2025"]="2025-01-29T00:00:00+08:00|2025-02-05T23:59:59+08:00|2025年春节长假"
    ["2026"]="2026-02-17T00:00:00+08:00|2026-02-24T23:59:59+08:00|2026年春节长假"
    ["2027"]="2027-02-06T00:00:00+08:00|2027-02-13T23:59:59+08:00|2027年春节长假"
    ["2028"]="2028-01-26T00:00:00+08:00|2028-02-02T23:59:59+08:00|2028年春节长假"
    ["2029"]="2029-02-13T00:00:00+08:00|2029-02-20T23:59:59+08:00|2029年春节长假"
    ["2030"]="2030-02-03T00:00:00+08:00|2030-02-10T23:59:59+08:00|2030年春节长假"
    ["2031"]="2031-01-23T00:00:00+08:00|2031-01-30T23:59:59+08:00|2031年春节长假"
    ["2032"]="2032-02-11T00:00:00+08:00|2032-02-18T23:59:59+08:00|2032年春节长假"
    ["2033"]="2033-01-31T00:00:00+08:00|2033-02-07T23:59:59+08:00|2033年春节长假"
)

# 创建单个年份的参数
create_parameter() {
    local year=$1
    local force_overwrite=${2:-false}
    local parameter_name="${PARAMETER_PREFIX}/${year}"
    
    if [[ -z "${SPRING_FESTIVAL_DATES[$year]}" ]]; then
        log_error "未找到 ${year} 年的春节日期数据"
        return 1
    fi
    
    # 解析日期数据
    IFS='|' read -r start_date end_date description <<< "${SPRING_FESTIVAL_DATES[$year]}"
    
    # 构建参数值
    local parameter_value=$(cat <<EOF
{
  "start": "${start_date}",
  "end": "${end_date}",
  "description": "${description}",
  "timezone": "Asia/Shanghai",
  "created_by": "init-parameters.sh",
  "created_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF
)
    
    log_info "创建 ${year} 年春节参数..."
    
    # 检查参数是否已存在
    if aws ssm get-parameter --name "${parameter_name}" --region "${AWS_REGION}" &> /dev/null; then
        if [ "${force_overwrite}" = "true" ]; then
            log_warning "参数已存在，强制覆盖: ${parameter_name}"
        else
            log_warning "参数已存在: ${parameter_name}"
            read -p "是否覆盖现有参数？(y/N): " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                log_info "跳过 ${year} 年参数创建"
                return 2  # 返回2表示跳过
            fi
        fi
    fi
    
    # 创建参数
    if aws ssm put-parameter \
        --name "${parameter_name}" \
        --value "${parameter_value}" \
        --type "String" \
        --description "${description}" \
        --overwrite \
        --region "${AWS_REGION}" > /dev/null; then
        
        log_success "✓ ${year} 年春节参数创建成功"
        
        # 显示参数详情
        echo "  参数名称: ${parameter_name}"
        echo "  开始时间: ${start_date}"
        echo "  结束时间: ${end_date}"
        echo "  描述: ${description}"
        echo ""
        
        return 0  # 明确返回成功
    else
        log_error "✗ ${year} 年春节参数创建失败"
        return 1
    fi
}

# 创建所有年份的参数
create_all_parameters() {
    log_info "开始创建所有春节参数..."
    
    # 询问是否覆盖所有现有参数
    local force_overwrite=false
    local existing_params=$(aws ssm get-parameters-by-path \
        --path "${PARAMETER_PREFIX}" \
        --recursive \
        --region "${AWS_REGION}" \
        --query 'Parameters[*].Name' \
        --output text 2>/dev/null)
    
    if [ -n "${existing_params}" ]; then
        echo "发现现有参数:"
        for param in ${existing_params}; do
            echo "  - ${param}"
        done
        echo ""
        read -p "是否覆盖所有现有参数？(y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            force_overwrite=true
        fi
    else
        # 没有现有参数时，询问是否创建所有参数
        echo "将创建以下年份的春节参数:"
        for year in $(printf '%s\n' "${!SPRING_FESTIVAL_DATES[@]}" | sort); do
            echo "  - ${year}"
        done
        echo ""
        read -p "是否继续创建所有参数？(Y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Nn]$ ]]; then
            log_info "取消创建操作"
            return 0
        fi
        force_overwrite=true  # 没有现有参数时，直接创建
    fi
    
    local success_count=0
    local skip_count=0
    local total_count=${#SPRING_FESTIVAL_DATES[@]}
    
    local years_to_process=($(printf '%s\n' "${!SPRING_FESTIVAL_DATES[@]}" | sort))
    
    for year in "${years_to_process[@]}"; do
        local result
        create_parameter "${year}" "${force_overwrite}"
        result=$?
        
        if [ $result -eq 0 ]; then
            success_count=$((success_count + 1))
        elif [ $result -eq 2 ]; then
            skip_count=$((skip_count + 1))
        else
            log_error "年份 ${year} 处理失败，结果码: ${result}"
        fi
    done
    
    echo ""
    log_success "参数创建完成: ${success_count} 成功, ${skip_count} 跳过, 总计 ${total_count}"
}

# 列出现有参数
list_parameters() {
    log_info "查询现有春节参数..."
    
    local parameters=$(aws ssm get-parameters-by-path \
        --path "${PARAMETER_PREFIX}" \
        --recursive \
        --region "${AWS_REGION}" \
        --query 'Parameters[*].[Name,LastModifiedDate,Description]' \
        --output table 2>/dev/null)
    
    if [ $? -eq 0 ] && [ -n "${parameters}" ]; then
        echo "${parameters}"
        echo ""
        
        # 显示参数详情
        log_info "参数详情:"
        
        # 获取所有参数名称
        local param_names=$(aws ssm get-parameters-by-path \
            --path "${PARAMETER_PREFIX}" \
            --recursive \
            --region "${AWS_REGION}" \
            --query 'Parameters[*].Name' \
            --output text 2>/dev/null)
        
        for name in ${param_names}; do
            local year=$(basename "${name}")
            echo "  ${year} 年:"
            
            # 单独获取每个参数的值以避免截断
            local value=$(aws ssm get-parameter \
                --name "${name}" \
                --region "${AWS_REGION}" \
                --query 'Parameter.Value' \
                --output text 2>/dev/null)
            
            if command -v jq &> /dev/null && echo "${value}" | jq . >/dev/null 2>&1; then
                echo "${value}" | jq -r '
                    "    开始时间: " + .start + 
                    "\n    结束时间: " + .end + 
                    "\n    描述: " + .description'
            else
                echo "    配置: ${value}"
                if command -v jq &> /dev/null; then
                    log_warning "    JSON 格式错误，请检查参数: ${name}"
                fi
            fi
            echo ""
        done
    else
        log_warning "未找到任何春节参数"
        echo ""
        log_info "可用的年份: $(printf '%s ' "${!SPRING_FESTIVAL_DATES[@]}" | tr ' ' '\n' | sort | tr '\n' ' ')"
    fi
}

# 删除参数
delete_parameter() {
    local year=$1
    local parameter_name="${PARAMETER_PREFIX}/${year}"
    
    log_warning "删除 ${year} 年春节参数..."
    
    # 检查参数是否存在
    if ! aws ssm get-parameter --name "${parameter_name}" --region "${AWS_REGION}" &> /dev/null; then
        log_warning "参数不存在: ${parameter_name}"
        return 0
    fi
    
    # 确认删除
    read -p "确定要删除 ${year} 年的春节参数吗？(y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "取消删除操作"
        return 0
    fi
    
    # 删除参数
    if aws ssm delete-parameter \
        --name "${parameter_name}" \
        --region "${AWS_REGION}" > /dev/null; then
        
        log_success "✓ ${year} 年春节参数删除成功"
    else
        log_error "✗ ${year} 年春节参数删除失败"
        return 1
    fi
}

# 删除所有参数
delete_all_parameters() {
    log_warning "删除所有春节参数..."
    
    # 获取所有参数
    local parameter_names=$(aws ssm get-parameters-by-path \
        --path "${PARAMETER_PREFIX}" \
        --recursive \
        --region "${AWS_REGION}" \
        --query 'Parameters[*].Name' \
        --output text 2>/dev/null)
    
    if [ -z "${parameter_names}" ]; then
        log_warning "未找到任何春节参数"
        return 0
    fi
    
    echo "将要删除的参数:"
    for name in ${parameter_names}; do
        echo "  - ${name}"
    done
    echo ""
    
    # 确认删除
    read -p "确定要删除所有春节参数吗？(y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "取消删除操作"
        return 0
    fi
    
    # 批量删除
    local success_count=0
    local total_count=0
    
    for name in ${parameter_names}; do
        ((total_count++))
        if aws ssm delete-parameter --name "${name}" --region "${AWS_REGION}" > /dev/null 2>&1; then
            ((success_count++))
            log_success "✓ 删除成功: ${name}"
        else
            log_error "✗ 删除失败: ${name}"
        fi
    done
    
    echo ""
    log_success "参数删除完成: ${success_count}/${total_count} 成功"
}

# 验证参数
verify_parameters() {
    log_info "验证春节参数配置..."
    
    local error_count=0
    
    for year in $(printf '%s\n' "${!SPRING_FESTIVAL_DATES[@]}" | sort); do
        local parameter_name="${PARAMETER_PREFIX}/${year}"
        
        if aws ssm get-parameter --name "${parameter_name}" --region "${AWS_REGION}" &> /dev/null; then
            # 获取参数值并验证JSON格式
            local parameter_value=$(aws ssm get-parameter \
                --name "${parameter_name}" \
                --region "${AWS_REGION}" \
                --query 'Parameter.Value' \
                --output text 2>/dev/null)
            
            if command -v jq &> /dev/null; then
                if echo "${parameter_value}" | jq . > /dev/null 2>&1; then
                    log_success "✓ ${year} 年参数格式正确"
                else
                    log_error "✗ ${year} 年参数JSON格式错误"
                    ((error_count++))
                fi
            else
                log_success "✓ ${year} 年参数存在"
            fi
        else
            log_warning "✗ ${year} 年参数不存在"
            ((error_count++))
        fi
    done
    
    echo ""
    if [ ${error_count} -eq 0 ]; then
        log_success "所有参数验证通过"
    else
        log_warning "发现 ${error_count} 个问题"
    fi
}

# 显示帮助信息
show_help() {
    echo "ECS PHD 自动重启系统 Parameter Store 初始化脚本"
    echo ""
    echo "使用方法:"
    echo "  ./init-parameters.sh [选项]"
    echo ""
    echo "选项:"
    echo "  <year>           创建指定年份的春节参数 (如: 2025)"
    echo "  all              创建所有年份的春节参数"
    echo "  list             列出现有的春节参数"
    echo "  verify           验证参数配置"
    echo "  delete <year>    删除指定年份的参数"
    echo "  delete-all       删除所有春节参数"
    echo "  help             显示此帮助信息"
    echo ""
    echo "环境变量:"
    echo "  AWS_REGION       AWS 区域 (默认: cn-northwest-1)"
    echo ""
    echo "支持的年份:"
    printf "  %s " "${!SPRING_FESTIVAL_DATES[@]}" | tr ' ' '\n' | sort | tr '\n' ' '
    echo ""
    echo ""
    echo "示例:"
    echo "  ./init-parameters.sh 2025        # 创建2025年春节参数"
    echo "  ./init-parameters.sh all         # 创建所有年份参数"
    echo "  ./init-parameters.sh list        # 列出现有参数"
    echo "  ./init-parameters.sh verify      # 验证参数配置"
    echo "  ./init-parameters.sh delete 2024 # 删除2024年参数"
}

# 主函数
main() {
    local action=${1:-"help"}
    local year=${2:-""}
    
    case "${action}" in
        "all")
            check_prerequisites
            create_all_parameters
            ;;
        "list")
            check_prerequisites
            list_parameters
            ;;
        "verify")
            check_prerequisites
            verify_parameters
            ;;
        "delete")
            if [ -z "${year}" ]; then
                log_error "请指定要删除的年份"
                echo "使用方法: ./init-parameters.sh delete <year>"
                exit 1
            fi
            check_prerequisites
            delete_parameter "${year}"
            ;;
        "delete-all")
            check_prerequisites
            delete_all_parameters
            ;;
        "help"|"")
            show_help
            ;;
        *)
            # 检查是否是年份
            if [[ "${action}" =~ ^[0-9]{4}$ ]]; then
                check_prerequisites
                create_parameter "${action}"
            else
                log_error "未知选项: ${action}"
                echo ""
                show_help
                exit 1
            fi
            ;;
    esac
}

# 执行主函数
main "$@"