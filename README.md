# ECS PHD 自动重启系统 v2.0

基于Q Developer验证和优化的ECS Personal Health Dashboard (PHD) 自动重启系统。

## 系统概述

当AWS PHD检测到ECS维护窗口与节假日冲突时，系统会自动创建提前重启计划，避免节假日期间的服务中断。

## 架构组件

### 1. Smart Handler Lambda
- **功能**: 处理PHD事件，检测节假日冲突，创建重启计划
- **触发**: AWS Personal Health Dashboard事件
- **输出**: EventBridge定时规则

### 2. Restart Executor Lambda  
- **功能**: 执行ECS服务重启，清理定时规则
- **触发**: EventBridge定时规则
- **输出**: ECS服务重启，飞书通知

## 核心特性

- ✅ **节假日冲突检测** - 支持国庆、春节等中国节假日
- ✅ **智能时间调度** - 自动安排到下个凌晨4点执行
- ✅ **测试模式支持** - 安全的测试和验证机制
- ✅ **飞书通知集成** - 实时状态通知
- ✅ **无外部依赖** - 使用Lambda内置库
- ✅ **中国区域支持** - 完全支持AWS中国区域

## 部署前准备

- ✅ AWS CLI 已安装并配置
- ✅ 具有必要的IAM权限（Lambda、EventBridge、IAM、SSM）
- ✅ 飞书机器人已创建（可选，用于通知）

## 快速开始

### 1. 完整部署系统（推荐）
```bash
# 进入部署目录
cd deployment

# 完整部署所有资源（IAM角色、Lambda函数、EventBridge规则）
./deploy-full.sh all

# 或者设置飞书Webhook后部署
WEBHOOK_URL=https://open.feishu.cn/... ./deploy-full.sh all
```

### 2. 验证部署
```bash
# 验证所有资源是否创建成功
./deploy-full.sh verify
```

### 3. 测试系统
```bash
# 测试PHD事件处理
./test.sh phd-event

# 测试重启执行
./test.sh restart-event

# 运行完整测试
./test.sh all
```

### 4. 初始化春节假期参数（可选）
```bash
# 初始化所有年份的春节参数
./init-parameters.sh all

# 或初始化特定年份
./init-parameters.sh 2025
```

### 仅更新Lambda代码（如果基础设施已存在）
```bash
# 仅更新Lambda函数代码
./deploy.sh all
```

## 项目结构

```
ecs-phd-restart-v2/
├── README.md                          # 项目说明
├── smart-handler/
│   ├── lambda_function.py             # Smart Handler主代码
│   └── requirements.txt               # 依赖（空文件，无外部依赖）
├── restart-executor/
│   ├── lambda_function.py             # Restart Executor主代码
│   └── requirements.txt               # 依赖（空文件，无外部依赖）
├── tests/
│   ├── test-phd-event.json           # PHD事件测试数据
│   └── test-restart-event.json       # 重启事件测试数据
├── deployment/
│   ├── deploy-full.sh                 # 完整部署脚本（推荐）
│   ├── deploy.sh                      # Lambda函数部署脚本
│   ├── init-parameters.sh             # Parameter Store初始化脚本
│   ├── test.sh                        # 测试脚本
│   ├── package.sh                     # 打包脚本
│   └── README.md                      # 部署指南
├── docs/
│   ├── architecture.md               # 架构说明
│   ├── configuration.md              # 配置指南
│   └── troubleshooting.md            # 故障排除
└── .gitignore                        # Git忽略文件
```

## 版本历史

### v2.0 (当前版本)
- ✅ 基于Q Developer验证的代码
- ✅ 使用urllib3替代requests，消除外部依赖
- ✅ 修复EventBridge cron表达式格式问题
- ✅ 优化时间计算逻辑，增加缓冲时间
- ✅ 简化权限模型，移除不必要的权限设置
- ✅ 统一错误处理和通知机制

### v1.0 (历史版本)
- 初始版本，存在依赖和权限问题

## 技术亮点

1. **零外部依赖** - 完全使用Lambda内置库
2. **智能cron表达式** - 使用?通配符避免ValidationException
3. **优雅的权限处理** - 避免不必要的lambda:AddPermission调用
4. **完善的测试支持** - test_mode确保安全测试
5. **中文友好** - 完整的中文字符支持和时区处理

## 许可证

MIT License