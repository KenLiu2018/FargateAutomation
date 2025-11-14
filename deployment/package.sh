#!/bin/bash

# ECS PHD 自动重启系统打包脚本
# 使用方法: ./package.sh [smart-handler|restart-executor|all]

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 配置
PACKAGE_DIR="packages"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

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

# 创建打包目录
create_package_dir() {
    if [ ! -d "${PACKAGE_DIR}" ]; then
        mkdir -p "${PACKAGE_DIR}"
        log_info "创建打包目录: ${PACKAGE_DIR}"
    fi
}

# 打包单个Lambda函数
package_function() {
    local function_name=$1
    local source_dir="../${function_name}"
    local package_name="${function_name}-${TIMESTAMP}.zip"
    local package_path="${PACKAGE_DIR}/${package_name}"
    
    log_info "打包 ${function_name}..."
    
    if [ ! -d "${source_dir}" ]; then
        log_error "源目录不存在: ${source_dir}"
        return 1
    fi
    
    # 创建临时目录
    local temp_dir=$(mktemp -d)
    
    # 复制源代码
    cp "${source_dir}/lambda_function.py" "${temp_dir}/"
    
    # 创建部署包（避免目录切换）
    (cd "${temp_dir}" && zip -j "${package_path}" lambda_function.py > /dev/null)
    
    # 清理临时目录
    rm -rf "${temp_dir}"
    
    # 显示包信息
    local package_size=$(du -h "${package_path}" | cut -f1)
    log_success "打包完成: ${package_name} (${package_size})"
    
    return 0
}

# 创建完整发布包
create_release_package() {
    local release_name="ecs-phd-restart-v2-${TIMESTAMP}.zip"
    local release_path="${PACKAGE_DIR}/${release_name}"
    
    log_info "创建完整发布包..."
    
    # 创建临时目录
    local temp_dir=$(mktemp -d)
    local release_dir="${temp_dir}/ecs-phd-restart-v2"
    
    # 创建发布目录结构
    mkdir -p "${release_dir}"
    
    # 复制项目文件
    cp -r ../smart-handler "${release_dir}/"
    cp -r ../restart-executor "${release_dir}/"
    cp -r ../tests "${release_dir}/"
    cp -r ../deployment "${release_dir}/"
    cp -r ../docs "${release_dir}/" 2>/dev/null || true
    cp ../README.md "${release_dir}/"
    cp ../.gitignore "${release_dir}/" 2>/dev/null || true
    
    # 创建版本信息文件
    cat > "${release_dir}/VERSION" << EOF
ECS PHD 自动重启系统 v2.0
构建时间: $(date)
构建版本: ${TIMESTAMP}

基于Q Developer验证和优化的版本
- 使用urllib3替代requests
- 修复EventBridge cron表达式
- 优化权限模型
- 完善测试支持
EOF
    
    # 创建发布包
    cd "${temp_dir}"
    zip -r "${release_name}" ecs-phd-restart-v2/
    cd - > /dev/null
    
    # 移动到打包目录
    mv "${temp_dir}/${release_name}" "${release_path}"
    
    # 清理临时目录
    rm -rf "${temp_dir}"
    
    # 显示包信息
    local package_size=$(du -h "${release_path}" | cut -f1)
    log_success "发布包创建完成: ${release_name} (${package_size})"
    
    return 0
}

# 显示打包结果
show_package_summary() {
    log_info "打包结果汇总:"
    echo ""
    
    if [ -d "${PACKAGE_DIR}" ]; then
        ls -lh "${PACKAGE_DIR}"/*.zip 2>/dev/null | while read -r line; do
            echo "  ${line}"
        done
    else
        log_warning "没有找到打包文件"
    fi
}

# 清理旧的打包文件
cleanup_old_packages() {
    if [ -d "${PACKAGE_DIR}" ]; then
        log_info "清理7天前的打包文件..."
        find "${PACKAGE_DIR}" -name "*.zip" -mtime +7 -delete 2>/dev/null || true
    fi
}

# 显示帮助信息
show_help() {
    echo "ECS PHD 自动重启系统打包脚本"
    echo ""
    echo "使用方法:"
    echo "  ./package.sh [选项]"
    echo ""
    echo "选项:"
    echo "  smart-handler     打包 Smart Handler Lambda"
    echo "  restart-executor  打包 Restart Executor Lambda"
    echo "  all              打包所有 Lambda 函数"
    echo "  release          创建完整发布包"
    echo "  clean            清理旧的打包文件"
    echo "  help             显示此帮助信息"
    echo ""
    echo "示例:"
    echo "  ./package.sh smart-handler"
    echo "  ./package.sh all"
    echo "  ./package.sh release"
}

# 主函数
main() {
    local target=${1:-"help"}
    
    case "${target}" in
        "smart-handler")
            create_package_dir
            cleanup_old_packages
            package_function "smart-handler"
            show_package_summary
            ;;
        "restart-executor")
            create_package_dir
            cleanup_old_packages
            package_function "restart-executor"
            show_package_summary
            ;;
        "all")
            create_package_dir
            cleanup_old_packages
            package_function "smart-handler"
            package_function "restart-executor"
            show_package_summary
            ;;
        "release")
            create_package_dir
            cleanup_old_packages
            create_release_package
            show_package_summary
            ;;
        "clean")
            if [ -d "${PACKAGE_DIR}" ]; then
                rm -rf "${PACKAGE_DIR}"
                log_success "清理完成"
            else
                log_info "没有需要清理的文件"
            fi
            ;;
        "help"|*)
            show_help
            ;;
    esac
}

# 执行主函数
main "$@"