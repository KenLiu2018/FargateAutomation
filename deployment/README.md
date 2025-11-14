# 部署指南

ECS PHD 自动重启系统提供了两种部署方式，您可以根据需要选择最适合的方式。

## 🚀 部署选项

### 1. 完整自动化部署 (推荐)

使用 `deploy-full.sh` 脚本进行完整的基础设施部署，包括 IAM 角色、Lambda 函数、EventBridge 规则等。

```bash
# 完整部署所有资源
./deploy-full.sh all

# 仅部署基础设施 (IAM 角色)
./deploy-full.sh infrastructure

# 仅部署 Lambda 函数和 EventBridge 规则
./deploy-full.sh lambda

# 验证部署结果
./deploy-full.sh verify

# 清理所有资源
./deploy-full.sh cleanup
```

**环境变量**：
- `AWS_REGION`: AWS 区域 (默认: cn-northwest-1)
- `WEBHOOK_URL`: 飞书 Webhook URL (可选)

### 2. Lambda 函数部署

使用 `deploy.sh` 脚本仅部署 Lambda 函数代码（需要预先存在的基础设施）。

```bash
# 部署所有 Lambda 函数
./deploy.sh all

# 部署单个函数
./deploy.sh smart-handler
./deploy.sh restart-executor
```

**适用场景**：
- 基础设施已存在，仅需更新代码
- 通过其他方式创建了基础设施

### 3. Parameter Store 初始化

使用 `init-parameters.sh` 脚本初始化春节假期配置。

```bash
# 初始化所有年份的春节参数
./init-parameters.sh all

# 初始化特定年份
./init-parameters.sh 2025

# 列出现有参数
./init-parameters.sh list

# 验证参数配置
./init-parameters.sh verify

# 删除参数
./init-parameters.sh delete 2024
```

**支持的年份**：2024-2033（共10年）

**参数格式**：
```json
{
  "start": "2025-01-29T00:00:00+08:00",
  "end": "2025-02-05T23:59:59+08:00", 
  "description": "2025年春节长假",
  "timezone": "Asia/Shanghai"
}
```

## 📋 部署前检查清单

### 必需条件
- [ ] AWS CLI 已安装并配置
- [ ] 具有必要的 IAM 权限
- [ ] 目标 AWS 区域可访问

### 可选配置
- [ ] 飞书机器人已创建 (获取 Webhook URL)
- [ ] S3 存储桶已准备 (用于 CloudFormation 部署)
- [ ] Parameter Store 参数已配置 (春节日期等)

## 🔧 权限要求

部署脚本需要以下 AWS 权限：

### IAM 权限
- `iam:CreateRole`
- `iam:AttachRolePolicy`
- `iam:CreatePolicy`
- `iam:GetRole`
- `iam:GetPolicy`

### Lambda 权限
- `lambda:CreateFunction`
- `lambda:UpdateFunctionCode`
- `lambda:UpdateFunctionConfiguration`
- `lambda:GetFunction`
- `lambda:AddPermission`

### EventBridge 权限
- `events:PutRule`
- `events:PutTargets`
- `events:DescribeRule`



## 🧪 测试部署

部署完成后，使用测试脚本验证系统功能：

```bash
# 运行所有测试
./test.sh all

# 测试 PHD 事件处理
./test.sh phd-event

# 测试重启执行
./test.sh restart-event
```

## 🔍 故障排除

### 常见问题

1. **权限不足**
   - 确保 AWS 凭证具有必要权限
   - 检查 IAM 角色和策略配置

2. **区域问题**
   - 确认目标区域支持所需服务
   - 检查 ARN 格式（中国区域使用 `arn:aws-cn`）

3. **资源冲突**
   - 检查资源名称是否已存在
   - 使用不同的堆栈名称或资源前缀

4. **网络问题**
   - 确认网络连接正常
   - 检查防火墙和代理设置

### 日志查看

```bash
# 查看 Lambda 函数日志
aws logs filter-log-events \
  --log-group-name "/aws/lambda/ecs-phd-smart-handler" \
  --start-time $(date -d '1 hour ago' +%s)000

# 查看 EventBridge 规则
aws events describe-rule \
  --name ecs-phd-event-rule
```

## 📚 相关文档

- [架构说明](../docs/architecture.md)
- [配置指南](../docs/configuration.md)
- [故障排除](../docs/troubleshooting.md)

## 🆘 获取帮助

如果遇到问题，请：

1. 查看相关文档和故障排除指南
2. 检查 CloudWatch 日志
3. 验证 AWS 权限和配置
4. 联系系统管理员或开发团队