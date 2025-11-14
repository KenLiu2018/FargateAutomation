# 系统架构说明

## 整体架构

ECS PHD 自动重启系统采用事件驱动的无服务器架构，主要由两个Lambda函数组成：

```
AWS Personal Health Dashboard
           ↓
    Smart Handler Lambda
           ↓
    EventBridge Rule (cron)
           ↓
   Restart Executor Lambda
           ↓
      ECS Service Restart
```

## 组件详解

### 1. Smart Handler Lambda

**职责**:
- 接收和解析AWS PHD事件
- 检测维护窗口与节假日的冲突
- 创建EventBridge定时规则
- 发送飞书通知

**触发方式**:
- AWS Personal Health Dashboard事件
- 手动测试调用

**关键功能**:
- 节假日冲突检测算法
- 智能时间调度（下个凌晨4点）
- EventBridge规则创建
- 飞书富文本消息推送

### 2. Restart Executor Lambda

**职责**:
- 执行ECS服务重启操作
- 清理已完成的EventBridge规则
- 发送重启结果通知

**触发方式**:
- EventBridge定时规则
- 手动测试调用

**关键功能**:
- ECS服务强制重新部署
- EventBridge规则自动清理
- 重启结果通知

## 数据流

### 1. PHD事件处理流程

```json
{
  "PHD Event": {
    "startTime": "2025-11-09T16:00:00Z",
    "endTime": "2025-11-17T15:59:00Z",
    "affectedEntities": [
      {
        "entityValue": "cluster|service"
      }
    ]
  }
}
```

### 2. 重启事件数据结构

```json
{
  "resource_id": "cluster/service",
  "cluster_name": "cluster-name",
  "service_name": "service-name",
  "restart_reason": "holiday_conflict_early_restart",
  "rule_name": "ecs-restart-hash-timestamp",
  "test_mode": false
}
```

## 核心算法

### 1. 节假日冲突检测

```python
def check_holiday_conflict(maintenance_start, maintenance_end):
    holidays = [
        # 国庆长假：10月1日-8日
        (national_day_start, national_day_end),
        # 春节长假（从Parameter Store获取）
        get_spring_festival_dates(year)
    ]
    
    for holiday_start, holiday_end in holidays:
        if (maintenance_start <= holiday_end and 
            maintenance_end >= holiday_start):
            return True
    return False
```

### 2. 智能时间调度

```python
def calculate_next_4am():
    now = datetime.now(timezone.utc)
    next_4am = now.replace(hour=4, minute=0, second=0, microsecond=0)
    
    # 确保至少10分钟缓冲时间
    if now.hour >= 4 or (now.hour == 3 and now.minute >= 50):
        next_4am += timedelta(days=1)
    
    return next_4am
```

### 3. Cron表达式生成

```python
# 使用?通配符避免ValidationException
cron_expression = f"cron({restart_time.minute} {restart_time.hour} {restart_time.day} {restart_time.month} ? {restart_time.year})"
```

## 权限模型

### Smart Handler 权限

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "events:PutRule",
        "events:PutTargets"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "ssm:GetParameter",
        "ssm:PutParameter"
      ],
      "Resource": "arn:aws:ssm:*:*:parameter/ecs-phd-restart/*"
    }
  ]
}
```

### Restart Executor 权限

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
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
      "Effect": "Allow",
      "Action": [
        "events:RemoveTargets",
        "events:DeleteRule"
      ],
      "Resource": "*"
    }
  ]
}
```

## 错误处理策略

### 1. 优雅降级

- 权限错误不阻止主要功能
- 通知发送失败不影响核心逻辑
- 规则清理失败不影响重启操作

### 2. 测试模式支持

- `test_mode=true` 跳过实际操作
- 保留完整的日志输出
- 安全的功能验证

### 3. 详细日志记录

- 结构化JSON日志
- 关键操作步骤记录
- 错误堆栈信息保留

## 监控和告警

### 1. CloudWatch指标

- Lambda函数执行次数
- 执行持续时间
- 错误率统计
- 内存使用情况

### 2. 飞书通知

- 维护窗口冲突告警
- 重启操作结果通知
- 系统错误告警

### 3. 日志分析

- CloudWatch Logs集中存储
- 结构化查询支持
- 异常模式检测

## 扩展性设计

### 1. 节假日配置

- Parameter Store动态配置
- 支持多年份配置
- 自动配置生成

### 2. 多区域支持

- 中国区域完全支持
- 全球区域兼容
- 区域特定配置

### 3. 多服务支持

- 批量服务处理
- 服务优先级配置
- 分批重启策略