# 故障排除指南

## 常见问题

### 1. EventBridge规则创建失败

#### 问题：ValidationException: Parameter ScheduleExpression is not valid

**原因**：
- cron表达式格式错误
- 时间设置过于接近当前时间
- 星期字段使用了不支持的通配符

**解决方案**：
```python
# 正确的cron表达式格式
cron_expression = f"cron({minute} {hour} {day} {month} ? {year})"

# 确保时间缓冲
if now.hour >= 4 or (now.hour == 3 and now.minute >= 50):
    next_4am += timedelta(days=1)
```

**验证方法**：
```bash
# 测试cron表达式
aws events put-rule \
  --name "test-cron-rule" \
  --schedule-expression "cron(0 4 6 11 ? 2025)" \
  --state ENABLED
```

### 2. Lambda权限问题

#### 问题：AccessDeniedException: User is not authorized to perform: lambda:AddPermission

**原因**：
- Lambda执行角色缺少必要权限
- 尝试设置不必要的权限

**解决方案**：
1. 移除不必要的 `lambda:AddPermission` 调用
2. 确保EventBridge规则有正确的目标权限

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
    }
  ]
}
```

### 3. ECS服务重启失败

#### 问题：ECS服务更新失败

**可能原因**：
- 服务不存在
- 集群名称错误
- ECS权限不足
- 服务正在更新中

**诊断步骤**：
```bash
# 1. 检查服务是否存在
aws ecs describe-services \
  --cluster "cluster-name" \
  --services "service-name"

# 2. 检查集群状态
aws ecs describe-clusters \
  --clusters "cluster-name"

# 3. 检查权限
aws iam simulate-principal-policy \
  --policy-source-arn "arn:aws:iam::account:role/role-name" \
  --action-names "ecs:UpdateService" \
  --resource-arns "*"
```

**解决方案**：
```python
# 添加重试逻辑
import time

def restart_ecs_service_with_retry(cluster_name, service_name, max_retries=3):
    for attempt in range(max_retries):
        try:
            response = ecs_client.update_service(
                cluster=cluster_name,
                service=service_name,
                forceNewDeployment=True
            )
            return response
        except ClientError as e:
            if attempt == max_retries - 1:
                raise
            print(f"重试 {attempt + 1}/{max_retries}: {str(e)}")
            time.sleep(2 ** attempt)  # 指数退避
```

### 4. 飞书通知发送失败

#### 问题：飞书消息发送失败

**可能原因**：
- Webhook URL错误
- 网络连接问题
- 消息格式错误
- 机器人权限不足

**诊断步骤**：
```bash
# 1. 测试Webhook连通性
curl -X POST \
  "$WEBHOOK_URL" \
  -H "Content-Type: application/json" \
  -d '{
    "msg_type": "text",
    "content": {
      "text": "测试消息"
    }
  }'

# 2. 检查响应状态
echo $?
```

**解决方案**：
```python
# 添加详细的错误处理
def send_feishu_notification(webhook_url, message):
    try:
        import urllib3
        import json
        
        http = urllib3.PoolManager()
        response = http.request(
            'POST',
            webhook_url,
            body=json.dumps(message, ensure_ascii=False).encode('utf-8'),
            headers={
                'Content-Type': 'application/json; charset=utf-8'
            }
        )
        
        print(f"飞书API响应状态: {response.status}")
        print(f"飞书API响应内容: {response.data.decode('utf-8')}")
        
        if response.status == 200:
            print("飞书通知发送成功")
        else:
            print(f"飞书通知发送失败，状态码: {response.status}")
            
    except Exception as e:
        print(f"发送飞书通知时发生错误: {str(e)}")
```

### 5. 节假日检测错误

#### 问题：节假日冲突检测不准确

**可能原因**：
- 时区转换错误
- Parameter Store配置错误
- 日期格式不正确

**诊断步骤**：
```python
# 检查时区转换
from datetime import datetime, timezone, timedelta

# 测试时区转换
china_tz = timezone(timedelta(hours=8))
test_date = datetime(2025, 10, 1, 0, 0, 0, tzinfo=china_tz)
utc_date = test_date.astimezone(timezone.utc)

print(f"中国时间: {test_date}")
print(f"UTC时间: {utc_date}")
```

**解决方案**：
```python
# 标准化时区处理
def normalize_timezone(dt):
    if dt.tzinfo is None:
        # 假设是中国时间
        china_tz = timezone(timedelta(hours=8))
        dt = dt.replace(tzinfo=china_tz)
    return dt.astimezone(timezone.utc)
```

## 调试技巧

### 1. 启用详细日志

```python
import logging

# 设置日志级别
logging.basicConfig(level=logging.DEBUG)
logger = logging.getLogger(__name__)

def lambda_handler(event, context):
    logger.debug(f"收到事件: {json.dumps(event, ensure_ascii=False)}")
    # ... 其他代码
```

### 2. 使用测试模式

```python
# 在测试事件中添加test_mode标志
{
  "test_mode": true,
  "detail": {
    # ... 其他字段
  }
}
```

### 3. 本地测试

```python
# 创建本地测试脚本
import json
from lambda_function import lambda_handler

# 加载测试事件
with open('test-phd-event.json', 'r') as f:
    test_event = json.load(f)

# 模拟Lambda上下文
class MockContext:
    def __init__(self):
        self.function_name = 'test-function'
        self.memory_limit_in_mb = 512
        self.invoked_function_arn = 'arn:aws:lambda:region:account:function:test'
        self.aws_request_id = 'test-request-id'

# 执行测试
result = lambda_handler(test_event, MockContext())
print(json.dumps(result, indent=2, ensure_ascii=False))
```

## 监控和告警

### 1. CloudWatch告警

```bash
# 创建错误率告警
aws cloudwatch put-metric-alarm \
  --alarm-name "ECS-PHD-Smart-Handler-Errors" \
  --alarm-description "Smart Handler错误率过高" \
  --metric-name "Errors" \
  --namespace "AWS/Lambda" \
  --statistic "Sum" \
  --period 300 \
  --threshold 1 \
  --comparison-operator "GreaterThanOrEqualToThreshold" \
  --dimensions Name=FunctionName,Value=ecs-phd-smart-handler \
  --evaluation-periods 1
```

### 2. 日志查询

```bash
# 查询错误日志
aws logs filter-log-events \
  --log-group-name "/aws/lambda/ecs-phd-smart-handler" \
  --filter-pattern "ERROR" \
  --start-time $(date -d '1 hour ago' +%s)000

# 查询特定事件
aws logs filter-log-events \
  --log-group-name "/aws/lambda/ecs-phd-smart-handler" \
  --filter-pattern "ValidationException" \
  --start-time $(date -d '1 day ago' +%s)000
```

### 3. 性能监控

```python
# 添加性能监控
import time

def monitor_performance(func):
    def wrapper(*args, **kwargs):
        start_time = time.time()
        try:
            result = func(*args, **kwargs)
            duration = time.time() - start_time
            print(f"函数 {func.__name__} 执行时间: {duration:.2f}秒")
            return result
        except Exception as e:
            duration = time.time() - start_time
            print(f"函数 {func.__name__} 执行失败，耗时: {duration:.2f}秒，错误: {str(e)}")
            raise
    return wrapper

@monitor_performance
def create_restart_schedule(...):
    # 函数实现
    pass
```

## 恢复程序

### 1. 手动清理EventBridge规则

```bash
# 列出所有ECS重启规则
aws events list-rules --name-prefix "ecs-restart-"

# 删除特定规则
aws events remove-targets --rule "rule-name" --ids "1"
aws events delete-rule --name "rule-name"
```

### 2. 手动触发重启

```bash
# 直接调用Restart Executor
aws lambda invoke \
  --function-name "ecs-phd-restart-executor" \
  --payload '{
    "resource_id": "cluster/service",
    "cluster_name": "cluster-name",
    "service_name": "service-name",
    "restart_reason": "manual_restart",
    "test_mode": false
  }' \
  response.json
```

### 3. 紧急停止

```bash
# 禁用所有ECS重启规则
for rule in $(aws events list-rules --name-prefix "ecs-restart-" --query 'Rules[].Name' --output text); do
  aws events disable-rule --name "$rule"
  echo "已禁用规则: $rule"
done
```

## 联系支持

如果问题仍然无法解决，请收集以下信息：

1. **错误日志**：完整的CloudWatch日志
2. **事件数据**：触发问题的原始事件
3. **环境信息**：AWS区域、账户ID、Lambda版本
4. **配置信息**：环境变量、IAM角色权限
5. **时间信息**：问题发生的具体时间

提供这些信息将有助于快速定位和解决问题。