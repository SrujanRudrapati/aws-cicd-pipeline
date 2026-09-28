output "sns_topic_arn" {
  value = aws_sns_topic.alerts.arn
}

output "dashboard_name" {
  value = aws_cloudwatch_dashboard.this.dashboard_name
}

output "alarm_names" {
  value = [
    aws_cloudwatch_metric_alarm.target_5xx.alarm_name,
    aws_cloudwatch_metric_alarm.elb_5xx.alarm_name,
    aws_cloudwatch_metric_alarm.latency_p95.alarm_name,
    aws_cloudwatch_metric_alarm.unhealthy_hosts.alarm_name,
    aws_cloudwatch_metric_alarm.no_healthy_hosts.alarm_name,
    aws_cloudwatch_metric_alarm.asg_cpu.alarm_name,
    aws_cloudwatch_metric_alarm.db_cpu.alarm_name,
    aws_cloudwatch_metric_alarm.db_storage.alarm_name,
    aws_cloudwatch_metric_alarm.db_memory.alarm_name,
  ]
}
