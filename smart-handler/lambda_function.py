import boto3
import json
import os
from datetime import datetime, timedelta, timezone

def lambda_handler(event, context):
    """Lambda 入口函数"""
    try:
        print(f"收到PHD事件: {json.dumps(event, ensure_ascii=False)}")
        
        # 检查是否为测试模式
        test_mode = event.get('test_mode', False)
        if test_mode:
            print("运行在测试模式下")
        
        # 解析PHD事件
        detail = event.get('detail', {})
        
        # 获取维护窗口时间
        start_time_str = detail.get('startTime')
        end_time_str = detail.get('endTime')
        
        if not start_time_str or not end_time_str:
            print("未找到维护窗口时间信息")
            return {'statusCode': 200, 'body': 'No maintenance window found'}
        
        # 解析时间
        maintenance_start = datetime.fromisoformat(start_time_str.replace('Z', '+00:00'))
        maintenance_end = datetime.fromisoformat(end_time_str.replace('Z', '+00:00'))
        
        print(f"维护窗口: {maintenance_start} - {maintenance_end}")
        
        # 检查是否与节假日冲突
        has_conflict = check_holiday_conflict(maintenance_start, maintenance_end)
        
        if not has_conflict:
            print("维护窗口未与节假日冲突，无需提前重启")
            # 发送通知但不创建重启计划
            now = datetime.now(timezone.utc)
            send_notification({
                'event_type': 'ECS_PHD_MAINTENANCE_NOTIFICATION',
                'action': 'NO_ACTION_NEEDED',
                'resource_id': 'ECS服务',  # 添加资源ID
                'maintenance_window': {
                    'start': maintenance_start.isoformat(),
                    'end': maintenance_end.isoformat(),
                    'days_until_maintenance': (maintenance_start - now).days  # 添加缺失的字段
                },
                'message': 'ECS 维护窗口未与节假日冲突，无需提前重启',
                'severity': 'INFO',
                'holiday_conflict': False,
                'test_mode': test_mode
            })
            return {'statusCode': 200, 'body': 'No holiday conflict detected'}
        
        print("检测到维护窗口与节假日冲突，需要提前重启")
        
        # 计算提前重启时间（下个凌晨4点）
        restart_time = calculate_next_4am()
        
        # 处理受影响的资源
        affected_entities = detail.get('affectedEntities', [])
        resource_id = None
        
        for entity in affected_entities:
            entity_value = entity.get('entityValue', '')
            
            # 解析ECS资源信息
            # 检查是否是ECS相关资源（ARN格式或cluster|service格式）
            if ('ecs' in entity_value.lower()) or ('|' in entity_value):
                cluster_name, service_name = parse_ecs_resource_info(entity_value)
                if cluster_name != 'unknown-cluster' and service_name != 'unknown-service':
                    resource_id = f"{cluster_name}/{service_name}"
                    
                    # 创建重启计划（测试模式下跳过实际创建）
                    rule_name = create_restart_schedule(
                        resource_id=service_name,
                        cluster_name=cluster_name,
                        service_name=service_name,
                        restart_time=restart_time,
                        resource_arn=entity_value,
                        test_mode=test_mode
                    )
                    
                    print(f"已为 {resource_id} 创建提前重启计划: {rule_name}")
        
        # 发送通知
        now = datetime.now(timezone.utc)
        notification_data = {
            'event_type': 'ECS_PHD_MAINTENANCE_NOTIFICATION',
            'resource_id': resource_id or 'unknown',
            'notification_time': now.isoformat(),
            'maintenance_window': {
                'start': maintenance_start.isoformat(),
                'end': maintenance_end.isoformat(),
                'days_until_maintenance': (maintenance_start - now).days
            },
            'action': 'EARLY_RESTART',
            'restart_time': restart_time.isoformat(),
            'message': 'ECS 维护窗口与节假日冲突，将提前执行重启' + (' (测试模式)' if test_mode else ''),
            'severity': 'HIGH',
            'holiday_conflict': True,
            'test_mode': test_mode
        }
        
        send_notification(notification_data)
        
        return {
            'statusCode': 200,
            'body': json.dumps({
                'message': '已处理PHD事件并创建重启计划' + (' (测试模式)' if test_mode else ''),
                'affected_resources': len(affected_entities),
                'restart_time': restart_time.isoformat(),
                'test_mode': test_mode
            }, ensure_ascii=False)
        }
        
    except Exception as e:
        error_msg = str(e)
        print(f"处理PHD事件时发生错误: {error_msg}")
        
        # 发送错误通知
        send_notification({
            'event_type': 'ECS_PHD_PROCESSING_ERROR',
            'error': error_msg,
            'test_mode': event.get('test_mode', False),
            'timestamp': datetime.now().isoformat()
        })
        
        return {
            'statusCode': 500,
            'body': json.dumps({'error': error_msg}, ensure_ascii=False)
        }

def check_holiday_conflict(maintenance_start, maintenance_end):
    """检查维护窗口是否与节假日冲突"""
    year = maintenance_start.year
    
    # 确保维护窗口日期是带时区信息的
    if maintenance_start.tzinfo is None:
        maintenance_start = maintenance_start.replace(tzinfo=timezone.utc)
    if maintenance_end.tzinfo is None:
        maintenance_end = maintenance_end.replace(tzinfo=timezone.utc)
    
    # 定义节假日期间（使用中国时间，然后转换为UTC）
    china_tz = timezone(timedelta(hours=8))
    national_day_start = datetime(year, 10, 1, 0, 0, 0, tzinfo=china_tz).astimezone(timezone.utc)
    national_day_end = datetime(year, 10, 8, 23, 59, 59, tzinfo=china_tz).astimezone(timezone.utc)
    
    holidays = [
        # 国庆长假：10月1日-8日（中国时间）
        (national_day_start, national_day_end),
        # 春节长假
        get_spring_festival_dates(year)
    ]
    
    # 检查维护窗口是否与任何节假日重叠
    for holiday_start, holiday_end in holidays:
        # 确保节假日日期也是带时区信息的
        if holiday_start.tzinfo is None:
            holiday_start = holiday_start.replace(tzinfo=timezone.utc)
        if holiday_end.tzinfo is None:
            holiday_end = holiday_end.replace(tzinfo=timezone.utc)
            
        if (maintenance_start <= holiday_end and maintenance_end >= holiday_start):
            return True
    
    return False

def get_spring_festival_dates(year):
    """从 Parameter Store 获取春节长假日期"""
    try:
        ssm_client = boto3.client('ssm')
        
        # 尝试从 Parameter Store 获取春节日期配置
        parameter_name = f'/ecs-phd-restart/spring-festival/{year}'
        
        try:
            response = ssm_client.get_parameter(Name=parameter_name)
            dates_config = json.loads(response['Parameter']['Value'])
            
            start_date = datetime.fromisoformat(dates_config['start'])
            end_date = datetime.fromisoformat(dates_config['end'])
            
            # 智能处理时区信息
            if start_date.tzinfo is None:
                # 如果没有时区信息，假设是中国时间（UTC+8）
                china_tz = timezone(timedelta(hours=8))
                start_date = start_date.replace(tzinfo=china_tz)
                print(f"春节开始日期未指定时区，假设为中国时间: {start_date}")
            
            if end_date.tzinfo is None:
                # 如果没有时区信息，假设是中国时间（UTC+8）
                china_tz = timezone(timedelta(hours=8))
                end_date = end_date.replace(tzinfo=china_tz)
                print(f"春节结束日期未指定时区，假设为中国时间: {end_date}")
            
            # 转换为UTC时区进行统一处理
            start_date_utc = start_date.astimezone(timezone.utc)
            end_date_utc = end_date.astimezone(timezone.utc)
            
            print(f"从 Parameter Store 获取到 {year} 年春节日期: {start_date.strftime('%Y-%m-%d %H:%M %Z')} - {end_date.strftime('%Y-%m-%d %H:%M %Z')}")
            print(f"转换为UTC时间: {start_date_utc.strftime('%Y-%m-%d %H:%M %Z')} - {end_date_utc.strftime('%Y-%m-%d %H:%M %Z')}")
            
            return (start_date_utc, end_date_utc)
            
        except ssm_client.exceptions.ParameterNotFound:
            print(f"Parameter Store 中未找到 {year} 年春节配置，使用默认配置")
            
            # 如果没有找到参数，使用内置的默认配置
            default_dates = get_default_spring_festival_dates(year)
            
            # 自动创建参数供下次使用（转换回中国时间格式存储）
            try:
                china_tz = timezone(timedelta(hours=8))
                start_china = default_dates[0].astimezone(china_tz)
                end_china = default_dates[1].astimezone(china_tz)
                
                dates_config = {
                    'start': start_china.isoformat(),
                    'end': end_china.isoformat(),
                    'description': f'{year}年春节长假（自动生成）',
                    'timezone': 'Asia/Shanghai'
                }
                
                ssm_client.put_parameter(
                    Name=parameter_name,
                    Value=json.dumps(dates_config),
                    Type='String',
                    Description=f'{year}年春节长假日期配置',
                    Overwrite=True
                )
                print(f"已自动创建 {year} 年春节配置参数")
                
            except Exception as e:
                print(f"创建春节配置参数失败: {str(e)}")
            
            return default_dates
            
    except Exception as e:
        print(f"获取春节日期配置时发生错误: {str(e)}")
        return get_default_spring_festival_dates(year)

def get_default_spring_festival_dates(year):
    """获取默认的春节长假日期（中国时间，自动转换为UTC）"""
    china_tz = timezone(timedelta(hours=8))
    
    spring_festival_dates = {
        2024: (datetime(2024, 2, 10, 0, 0, 0, tzinfo=china_tz), datetime(2024, 2, 17, 23, 59, 59, tzinfo=china_tz)),
        2025: (datetime(2025, 1, 29, 0, 0, 0, tzinfo=china_tz), datetime(2025, 2, 5, 23, 59, 59, tzinfo=china_tz)),
        2026: (datetime(2026, 2, 17, 0, 0, 0, tzinfo=china_tz), datetime(2026, 2, 24, 23, 59, 59, tzinfo=china_tz)),
        2027: (datetime(2027, 2, 6, 0, 0, 0, tzinfo=china_tz), datetime(2027, 2, 13, 23, 59, 59, tzinfo=china_tz)),
        2028: (datetime(2028, 1, 26, 0, 0, 0, tzinfo=china_tz), datetime(2028, 2, 2, 23, 59, 59, tzinfo=china_tz)),
        2029: (datetime(2029, 2, 13, 0, 0, 0, tzinfo=china_tz), datetime(2029, 2, 20, 23, 59, 59, tzinfo=china_tz)),
        2030: (datetime(2030, 2, 3, 0, 0, 0, tzinfo=china_tz), datetime(2030, 2, 10, 23, 59, 59, tzinfo=china_tz)),
    }
    
    default_dates = spring_festival_dates.get(year, (
        datetime(year, 2, 1, 0, 0, 0, tzinfo=china_tz), 
        datetime(year, 2, 8, 23, 59, 59, tzinfo=china_tz)
    ))
    
    # 转换为UTC时区
    return (default_dates[0].astimezone(timezone.utc), default_dates[1].astimezone(timezone.utc))

def calculate_next_4am():
    """计算下个凌晨4点"""
    now = datetime.now(timezone.utc)
    next_4am = now.replace(hour=4, minute=0, second=0, microsecond=0)
    
    # 如果当前时间已经过了4点，或者距离4点不足10分钟，则安排到明天
    # 这样确保有足够的时间缓冲，避免AWS EventBridge的ValidationException
    if now.hour >= 4 or (now.hour == 3 and now.minute >= 50):
        next_4am += timedelta(days=1)
    
    print(f"当前时间: {now}, 计算的下个4点: {next_4am}")
    return next_4am

def create_restart_schedule(resource_id, cluster_name, service_name, restart_time, resource_arn, test_mode=False):
    """创建定时重启计划"""
    try:
        # 生成短的唯一规则名称（EventBridge规则名称限制64字符）
        import hashlib
        # 使用resource_arn的hash来生成短的唯一标识
        resource_hash = hashlib.md5(resource_arn.encode()).hexdigest()[:8]
        timestamp = int(restart_time.timestamp())
        rule_name = f"ecs-restart-{resource_hash}-{timestamp}"
        
        print(f"生成规则名称: {rule_name} (长度: {len(rule_name)})")
        
        if test_mode:
            print(f"测试模式：跳过创建EventBridge规则 {rule_name}")
            print(f"测试模式：模拟计划执行时间 {restart_time}")
            return rule_name
        
        events_client = boto3.client('events')
        
        # 创建一次性定时规则（使用cron表达式）
        # AWS EventBridge格式：cron(分钟 小时 日 月 星期 年)
        # 对于一次性任务，星期字段使用 ? 通配符
        cron_expression = f"cron({restart_time.minute} {restart_time.hour} {restart_time.day} {restart_time.month} ? {restart_time.year})"
        
        print(f"生成cron表达式: {cron_expression} (时间: {restart_time})")
        
        events_client.put_rule(
            Name=rule_name,
            ScheduleExpression=cron_expression,
            State='ENABLED',
            Description=f"ECS 节假日提前重启任务 - {resource_id}"
        )
        
        # 获取重启执行器 ARN
        restart_executor_arn = os.environ.get('RESTART_EXECUTOR_ARN')
        if not restart_executor_arn:
            raise ValueError("未配置 RESTART_EXECUTOR_ARN 环境变量")
        
        # 添加目标（重启执行器 Lambda）
        target_input = {
            'resource_id': resource_id,
            'cluster_name': cluster_name,
            'service_name': service_name,
            'resource_arn': resource_arn,
            'rule_name': rule_name,
            'restart_reason': 'holiday_conflict_early_restart'
        }
        
        events_client.put_targets(
            Rule=rule_name,
            Targets=[
                {
                    'Id': '1',
                    'Arn': restart_executor_arn,
                    'Input': json.dumps(target_input)
                }
            ]
        )
        
        print(f"成功创建重启计划: {rule_name}, 执行时间: {restart_time}")
        return rule_name
        
    except Exception as e:
        print(f"创建重启计划失败: {e}")
        raise

def parse_ecs_resource_info(entity_value):
    """从 ECS 资源信息中解析集群名称和服务名称"""
    try:
        print(f"解析ECS资源信息: {entity_value}")
        
        # 检查是否是标准的ECS ARN格式
        if entity_value.startswith('arn:aws'):
            # ECS ARN 格式示例:
            # arn:aws:ecs:region:account:service/cluster-name/service-name
            # arn:aws:ecs:region:account:task/cluster-name/task-id
            
            parts = entity_value.split('/')
            if len(parts) >= 3:
                resource_type = entity_value.split(':')[5].split('/')[0]  # service 或 task
                cluster_name = parts[-2]  # 倒数第二个部分是集群名
                
                if resource_type == 'service':
                    service_name = parts[-1]  # 最后一个部分是服务名
                elif resource_type == 'task':
                    # 如果是任务ARN，需要通过ECS API查找对应的服务
                    service_name = get_service_from_task_arn(entity_value, cluster_name)
                else:
                    # 未知资源类型，使用默认值
                    service_name = 'unknown-service'
                
                return cluster_name, service_name
        
        # 检查是否是 cluster|service 格式
        elif '|' in entity_value:
            parts = entity_value.split('|')
            if len(parts) == 2:
                cluster_name = parts[0].strip()
                service_name = parts[1].strip()
                print(f"解析到集群: {cluster_name}, 服务: {service_name}")
                return cluster_name, service_name
        
        # 如果都不匹配，尝试从字符串中提取可能的集群和服务信息
        print(f"无法解析 ECS 资源信息，使用默认值: {entity_value}")
        return 'unknown-cluster', 'unknown-service'
            
    except Exception as e:
        print(f"解析 ECS 资源信息时发生错误: {str(e)}")
        return 'unknown-cluster', 'unknown-service'

def get_service_from_task_arn(task_arn, cluster_name):
    """通过任务ARN查找对应的服务名称"""
    try:
        ecs_client = boto3.client('ecs')
        
        # 从任务ARN中提取任务ID
        task_id = task_arn.split('/')[-1]
        
        # 描述任务以获取服务信息
        response = ecs_client.describe_tasks(
            cluster=cluster_name,
            tasks=[task_id]
        )
        
        if response['tasks']:
            task = response['tasks'][0]
            # 从任务定义ARN中提取服务名称，或者使用group字段
            if 'group' in task and task['group'].startswith('service:'):
                return task['group'].replace('service:', '')
            elif 'serviceName' in task:
                return task['serviceName']
        
        # 如果无法从任务中获取服务信息，列出集群中的服务作为备选
        services_response = ecs_client.list_services(cluster=cluster_name)
        if services_response['serviceArns']:
            # 返回第一个服务作为默认值
            first_service_arn = services_response['serviceArns'][0]
            return first_service_arn.split('/')[-1]
        
        return 'unknown-service'
        
    except Exception as e:
        print(f"从任务ARN获取服务名称时发生错误: {str(e)}")
        return 'unknown-service'

def send_notification(notification_data):
    """发送 Webhook 通知"""
    # 发送到飞书 Webhook
    webhook_url = os.environ.get('WEBHOOK_URL')
    if webhook_url:
        try:
            # 如果有维护窗口信息，创建飞书消息
            if 'maintenance_window' in notification_data:
                maintenance_start = datetime.fromisoformat(notification_data['maintenance_window']['start'])
                maintenance_end = datetime.fromisoformat(notification_data['maintenance_window']['end'])
                feishu_message = create_feishu_message(notification_data, maintenance_start, maintenance_end)
                send_feishu_notification(webhook_url, feishu_message)
            else:
                # 简单的错误通知
                simple_message = {
                    "msg_type": "text",
                    "content": {
                        "text": f"ECS PHD 处理错误: {notification_data.get('error', 'Unknown error')}"
                    }
                }
                send_feishu_notification(webhook_url, simple_message)
        except Exception as e:
            print(f"飞书通知发送失败: {str(e)}")
    
    # 输出到日志
    print(json.dumps(notification_data, indent=2, ensure_ascii=False))

def create_feishu_message(notification_data, maintenance_start, maintenance_end):
    """创建飞书消息格式"""
    resource_id = notification_data['resource_id']
    holiday_conflict = notification_data['holiday_conflict']
    action = notification_data['action']
    days_until = notification_data['maintenance_window']['days_until_maintenance']
    
    # 设置消息颜色和图标
    if holiday_conflict:
        color = "red"
        icon = "🚨"
        title = "ECS 维护通知 - 节假日冲突"
    else:
        color = "blue"
        icon = "ℹ️"
        title = "ECS 维护通知 - 正常处理"
    
    # 构建飞书富文本消息
    feishu_message = {
        "msg_type": "interactive",
        "card": {
            "config": {
                "wide_screen_mode": True
            },
            "header": {
                "title": {
                    "tag": "plain_text",
                    "content": f"{icon} {title}"
                },
                "template": color
            },
            "elements": [
                {
                    "tag": "div",
                    "fields": [
                        {
                            "is_short": True,
                            "text": {
                                "tag": "lark_md",
                                "content": f"**资源ID**\n{resource_id}"
                            }
                        },
                        {
                            "is_short": True,
                            "text": {
                                "tag": "lark_md",
                                "content": f"**处理方式**\n{'🔄 提前重启' if action == 'EARLY_RESTART' else '⏳ AWS自动处理'}"
                            }
                        }
                    ]
                },
                {
                    "tag": "div",
                    "fields": [
                        {
                            "is_short": True,
                            "text": {
                                "tag": "lark_md",
                                "content": f"**维护窗口**\n{maintenance_start.strftime('%Y-%m-%d')} 至 {maintenance_end.strftime('%Y-%m-%d')}"
                            }
                        },
                        {
                            "is_short": True,
                            "text": {
                                "tag": "lark_md",
                                "content": f"**距离维护**\n{days_until} 天"
                            }
                        }
                    ]
                }
            ]
        }
    }
    
    # 如果是节假日冲突，添加重启时间信息
    if holiday_conflict and notification_data.get('restart_time'):
        restart_time = datetime.fromisoformat(notification_data['restart_time'])
        feishu_message["card"]["elements"].append({
            "tag": "div",
            "text": {
                "tag": "lark_md",
                "content": f"**⏰ 计划重启时间**\n{restart_time.strftime('%Y-%m-%d %H:%M:%S')}"
            }
        })
    
    # 添加说明文本
    description = "维护窗口与节假日冲突，系统将在隔天凌晨4点提前执行重启，以避免节假日期间的服务中断。" if holiday_conflict else "维护窗口无节假日冲突，AWS将在指定时间窗口内自动处理，无需人工干预。"
    
    feishu_message["card"]["elements"].append({
        "tag": "div",
        "text": {
            "tag": "lark_md",
            "content": f"**说明**\n{description}"
        }
    })
    
    return feishu_message

def send_feishu_notification(webhook_url, message):
    """发送飞书通知"""
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
        
        if response.status == 200:
            print("飞书通知发送成功")
        else:
            print(f"飞书通知发送失败，状态码: {response.status}")
            print(f"响应内容: {response.data.decode('utf-8')}")
            
    except Exception as e:
        print(f"发送飞书通知时发生错误: {str(e)}")
        raise