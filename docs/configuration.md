# 配置指南

## 环境变量配置

### Smart Handler Lambda

| 变量名 | 必需 | 说明 | 示例值 |
|--------|------|------|--------|
| `RESTART_EXECUTOR_ARN` | 是 | Restart Executor Lambda的ARN | `arn:aws-cn:lambda:cn-northwest-1:123456789012:function:ecs-restart-executor` |
| `WEBHOOK_URL` | 否 | 飞书Webhook URL | `https://open.feishu.cn/open-apis/bot/v2/hook/xxx` |

### Restart Executor Lambda

| 变量名 | 必需 | 说明 | 示例值 |
|--------|------|------|--------|
| `WEBHOOK_URL` | 否 | 飞书Webhook URL | `https://open.feishu.cn/open-apis/bot/v2/hook/xxx` |
| `ECS_CLUSTER_NAME` | 否 | 默认ECS集群名称（备用） | `production-cluster` |
| `ECS_SERVICE_NAME` | 否 | 默认ECS服务名称（备用） | `web-service` |

## Lambda函数配置

### 基本配置

```yaml
# Smart Handler
FunctionName: ecs-phd-smart-handler
Runtime: python3.9
Handler: lambda_function.lambda_handler
Timeout: 300
MemorySize: 512

# Restart Executor
FunctionName: ecs-phd-restart-executor
Runtime: python3.9
Handler: lambda_function.lambda_handler
Timeout: 300
MemorySize: 512
```

### 执行角色权限

#### Smart Handler 角色

```json
{
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
        "arn:aws-cn:events:*:*:rule/ecs-restart-*"
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
        "arn:aws-cn:ssm:*:*:parameter/ecs-phd-restart/*"
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
      "Resource": "arn:aws-cn:logs:*:*:*"
    }
  ]
}
```

#### Restart Executor 角色

```json
{
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
        "arn:aws-cn:events:*:*:rule/ecs-restart-*"
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
      "Resource": "arn:aws-cn:logs:*:*:*"
    }
  ]
}
```

## EventBridge配置

### PHD事件规则

```json
{
  "Name": "ecs-phd-event-rule",
  "EventPattern": {
    "source": ["aws.health"],
    "detail-type": ["AWS Health Event"],
    "detail": {
      "service": ["ECS"],
      "eventTypeCategory": ["scheduledChange"]
    }
  },
  "State": "ENABLED",
  "Targets": [
    {
      "Id": "1",
      "Arn": "arn:aws-cn:lambda:cn-northwest-1:123456789012:function:ecs-phd-smart-handler"
    }
  ]
}
```

## Parameter Store配置

### 春节日期配置

#### 参数名称格式
```
/ecs-phd-restart/spring-festival/{year}
```

#### 参数值格式
```json
{
  "start": "2025-01-29T00:00:00+08:00",
  "end": "2025-02-05T23:59:59+08:00",
  "description": "2025年春节长假",
  "timezone": "Asia/Shanghai"
}
```

#### 批量创建示例
```bash
# 2025年春节
aws ssm put-parameter \
  --name "/ecs-phd-restart/spring-festival/2025" \
  --value '{
    "start": "2025-01-29T00:00:00+08:00",
    "end": "2025-02-05T23:59:59+08:00",
    "description": "2025年春节长假",
    "timezone": "Asia/Shanghai"
  }' \
  --type "String" \
  --description "2025年春节长假日期配置"

# 2026年春节
aws ssm put-parameter \
  --name "/ecs-phd-restart/spring-festival/2026" \
  --value '{
    "start": "2026-02-17T00:00:00+08:00",
    "end": "2026-02-24T23:59:59+08:00",
    "description": "2026年春节长假",
    "timezone": "Asia/Shanghai"
  }' \
  --type "String" \
  --description "2026年春节长假日期配置"
```

## 飞书机器人配置

### 1. 创建飞书机器人

1. 登录飞书开放平台：https://open.feishu.cn/
2. 创建企业自建应用
3. 添加机器人功能
4. 获取Webhook URL

### 2. 配置Webhook权限

确保机器人有以下权限：
- 发送消息到群聊
- 发送富文本消息
- 发送卡片消息

### 3. 测试Webhook

```bash
curl -X POST \
  "https://open.feishu.cn/open-apis/bot/v2/hook/your-webhook" \
  -H "Content-Type: application/json" \
  -d '{
    "msg_type": "text",
    "content": {
      "text": "ECS PHD 系统测试消息"
    }
  }'
```

## 部署检查清单

### 部署前检查

- [ ] AWS CLI已配置
- [ ] 具有必要的IAM权限
- [ ] 飞书机器人已创建
- [ ] Webhook URL已获取
- [ ] 目标ECS集群和服务存在

### 部署后验证

- [ ] Lambda函数部署成功
- [ ] 环境变量配置正确
- [ ] EventBridge规则已创建
- [ ] 权限配置正确
- [ ] 测试事件处理正常
- [ ] 飞书通知发送成功

### 监控配置

- [ ] CloudWatch日志组已创建
- [ ] 告警规则已配置
- [ ] 监控面板已设置
- [ ] 错误通知已配置

## 部署脚本使用

### 完整部署

```bash
# 进入部署目录
cd deployment

# 完整部署所有资源
./deploy-full.sh all

# 设置环境变量后部署
WEBHOOK_URL=https://open.feishu.cn/... ./deploy-full.sh all
```

### 仅更新Lambda函数

```bash
# 更新所有Lambda函数
./deploy.sh all

# 更新单个函数
./deploy.sh smart-handler
```

### 测试部署

```bash
# 运行所有测试
./test.sh all

# 测试PHD事件处理
./test.sh phd-event
```