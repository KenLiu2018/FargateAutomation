import boto3
import json
import os
from datetime import datetime

def lambda_handler(event, context):
    """Lambda 入口函数"""
    try:
        print(f"收到重启事件: {json.dumps(event, ensure_ascii=False)}")
        
        # 解析事件数据
        resource_id = event.get('resource_id')
        cluster_name = event.get('cluster_name')
        service_name = event.get('service_name')
        restart_reason = event.get('restart_reason', 'scheduled_restart')
        rule_name = event.get('rule_name')
        test_mode = event.get('test_mode', False)  # 测试模式标志
        
        if not all([resource_id, cluster_name, service_name]):
            raise ValueError("缺少必要的参数: resource_id, cluster_name, service_name")
        
        # 执行重启（测试模式下跳过实际ECS操作）
        if test_mode:
            print("测试模式：跳过实际ECS重启操作")
            result = {
                'status': 'test_success',
                'message': '测试模式下模拟重启成功',
                'cluster': cluster_name,
                'service': service_name
            }
        else:
            result = restart_ecs_service(cluster_name, service_name, restart_reason)
        
        # 清理定时规则（测试模式下也跳过）
        if rule_name and not test_mode:
            cleanup_rule(rule_name)
        elif rule_name and test_mode:
            print(f"测试模式：跳过清理规则 {rule_name}")
        
        # 发送通知
        send_restart_notification(
            resource_id=resource_id,
            status='SUCCESS' if result['status'] in ['success', 'test_success'] else 'FAILED',
            cluster_name=cluster_name,
            service_name=service_name,
            restart_reason=restart_reason,
            test_mode=test_mode,
            result=result
        )
        
        return {
            'statusCode': 200,
            'body': json.dumps({
                'message': 'ECS服务重启成功' if not test_mode else 'ECS服务重启测试成功',
                'resource_id': resource_id,
                'result': result,
                'test_mode': test_mode
            }, ensure_ascii=False)
        }
        
    except Exception as e:
        error_msg = str(e)
        print(f"重启执行失败: {error_msg}")
        
        # 发送错误通知
        send_restart_notification(
            resource_id=event.get('resource_id', 'unknown'),
            status='FAILED',
            cluster_name=event.get('cluster_name', 'unknown'),
            service_name=event.get('service_name', 'unknown'),
            restart_reason=event.get('restart_reason', 'scheduled_restart'),
            test_mode=event.get('test_mode', False),
            error_msg=error_msg
        )
        
        return {
            'statusCode': 500,
            'body': json.dumps({
                'message': 'ECS服务重启失败',
                'error': error_msg,
                'resource_id': event.get('resource_id', 'unknown'),
                'test_mode': event.get('test_mode', False)
            }, ensure_ascii=False)
        }

def restart_ecs_service(cluster_name, service_name, restart_reason):
    """执行ECS服务重启"""
    try:
        ecs_client = boto3.client('ecs')
        
        print(f"开始重启 ECS 服务: {cluster_name}/{service_name}, 原因: {restart_reason}")
        
        # 执行 ECS 服务重启
        response = ecs_client.update_service(
            cluster=cluster_name,
            service=service_name,
            forceNewDeployment=True
        )
        
        print(f"ECS 服务重启成功: {response['service']['serviceName']}")
        
        return {
            'status': 'success',
            'message': 'ECS服务重启成功',
            'cluster': cluster_name,
            'service': service_name,
            'deployment_id': response['service']['deployments'][0]['id'] if response['service']['deployments'] else None
        }
        
    except Exception as e:
        print(f"ECS服务重启失败: {str(e)}")
        raise

def cleanup_rule(rule_name):
    """清理EventBridge规则"""
    try:
        events_client = boto3.client('events')
        
        # 删除规则的目标
        events_client.remove_targets(
            Rule=rule_name,
            Ids=['1']
        )
        
        # 删除规则
        events_client.delete_rule(Name=rule_name)
        
        print(f"成功清理规则: {rule_name}")
        
    except Exception as e:
        print(f"清理规则失败: {str(e)}")
        # 不抛出异常，因为清理失败不应该影响主要流程

def send_notification(notification_data):
    """发送通知"""
    # 发送到飞书 Webhook
    webhook_url = os.environ.get('WEBHOOK_URL')
    if webhook_url:
        try:
            # 简单的文本通知
            message = {
                "msg_type": "text",
                "content": {
                    "text": f"ECS重启通知: {notification_data.get('message', 'Unknown event')}\n资源: {notification_data.get('resource_id', 'Unknown')}\n时间: {notification_data.get('timestamp', 'Unknown')}"
                }
            }
            send_feishu_notification(webhook_url, message)
        except Exception as e:
            print(f"飞书通知发送失败: {str(e)}")
    
    # 输出到日志
    print(json.dumps(notification_data, indent=2, ensure_ascii=False))

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
            
    except Exception as e:
        print(f"发送飞书通知时发生错误: {str(e)}")

# 以下是辅助函数

def parse_ecs_resource_info(entity_value):
    """从 ECS 资源 ARN 中解析集群名称和服务名称"""
    try:
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
        else:
            print(f"无法解析 ECS 资源 ARN: {entity_value}")
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

def get_cluster_name_from_resource(resource_id):
    """根据资源ID获取集群名称（备选方案）"""
    # 仅作为备选方案，优先使用从ARN解析的信息
    cluster_name = os.environ.get('ECS_CLUSTER_NAME')
    if cluster_name:
        return cluster_name
    return 'default-cluster'

def get_service_name_from_resource(resource_id):
    """根据资源ID获取服务名称（备选方案）"""
    # 仅作为备选方案，优先使用从ARN解析的信息
    service_name = os.environ.get('ECS_SERVICE_NAME')
    if service_name:
        return service_name
    return 'default-service'

def send_restart_notification(resource_id, status, cluster_name, service_name, restart_reason=None, test_mode=False, result=None, error_msg=None):
    """发送重启结果通知"""
    notification_data = {
        'event_type': 'ECS_RESTART_RESULT',
        'resource_id': resource_id,
        'cluster_name': cluster_name,
        'service_name': service_name,
        'status': status,
        'restart_reason': restart_reason or 'scheduled_restart',
        'test_mode': test_mode,
        'result': result,
        'timestamp': datetime.now().isoformat(),
        'message': f"ECS 服务 {cluster_name}/{service_name} 重启{'成功' if status == 'SUCCESS' else '失败'}{'（测试模式）' if test_mode else ''}",
        'error': error_msg if error_msg else None
    }
    
    # 发送到飞书 Webhook
    webhook_url = os.environ.get('WEBHOOK_URL')
    if webhook_url:
        try:
            feishu_message = create_restart_feishu_message(notification_data)
            send_feishu_notification(webhook_url, feishu_message)
        except Exception as e:
            print(f"飞书通知发送失败: {str(e)}")
    
    # 输出到日志
    print(json.dumps(notification_data, indent=2, ensure_ascii=False))

def create_restart_feishu_message(notification_data):
    """创建重启结果的飞书消息格式"""
    status = notification_data['status']
    resource_id = notification_data['resource_id']
    cluster_name = notification_data['cluster_name']
    service_name = notification_data['service_name']
    timestamp = notification_data['timestamp']
    restart_reason = notification_data.get('restart_reason', 'scheduled_restart')
    test_mode = notification_data.get('test_mode', False)
    error_msg = notification_data.get('error')
    result = notification_data.get('result', {})
    
    # 设置消息颜色和图标
    if status == 'SUCCESS':
        color = "green"
        icon = "✅"
        title = "ECS 重启成功" + ("（测试模式）" if test_mode else "")
    else:
        color = "red"
        icon = "❌"
        title = "ECS 重启失败" + ("（测试模式）" if test_mode else "")
    
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
                                "content": f"**集群名称**\n{cluster_name}"
                            }
                        },
                        {
                            "is_short": True,
                            "text": {
                                "tag": "lark_md",
                                "content": f"**服务名称**\n{service_name}"
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
                                "content": f"**重启原因**\n{'节假日冲突提前重启' if restart_reason == 'holiday_conflict_early_restart' else '计划重启'}"
                            }
                        },
                        {
                            "is_short": True,
                            "text": {
                                "tag": "lark_md",
                                "content": f"**执行时间**\n{datetime.fromisoformat(timestamp).strftime('%Y-%m-%d %H:%M:%S')}"
                            }
                        }
                    ]
                },
                {
                    "tag": "div",
                    "text": {
                        "tag": "lark_md",
                        "content": f"**资源ID**\n{resource_id}"
                    }
                }
            ]
        }
    }
    
    # 如果有部署ID，添加部署信息
    if status == 'SUCCESS' and result and result.get('deployment_id'):
        feishu_message["card"]["elements"].append({
            "tag": "div",
            "text": {
                "tag": "lark_md",
                "content": f"**🚀 部署ID**\n{result['deployment_id']}"
            }
        })
    
    # 如果重启失败，添加错误信息
    if status == 'FAILED' and error_msg:
        feishu_message["card"]["elements"].append({
            "tag": "div",
            "text": {
                "tag": "lark_md",
                "content": f"**❗ 错误信息**\n```\n{error_msg}\n```"
            }
        })
    
    # 添加说明文本
    if status == 'SUCCESS':
        if test_mode:
            description = "测试模式下模拟重启成功，实际环境中ECS服务将被重启并部署新任务。"
        else:
            description = "ECS 服务已成功重启，新的任务正在启动中。请在AWS控制台查看部署进度。"
    else:
        if test_mode:
            description = "测试模式下模拟重启失败，请检查配置和权限设置。"
        else:
            description = "ECS 服务重启失败，请检查服务配置、权限设置和集群状态。"
    
    feishu_message["card"]["elements"].append({
        "tag": "div",
        "text": {
            "tag": "lark_md",
            "content": f"**说明**\n{description}"
        }
    })
    
    return feishu_message