locals {
  alarm_actions = [aws_sns_topic.alerts.arn]
  alb_dims      = { LoadBalancer = var.alb_arn_suffix }
  tg_dims       = { LoadBalancer = var.alb_arn_suffix, TargetGroup = var.target_group_arn_suffix }
  has_email     = var.alert_email != null && var.alert_email != ""
}

# Not KMS-encrypted on purpose: CloudWatch alarms cannot publish to a topic
# encrypted with the AWS-managed aws/sns key. Encrypting it would need a
# customer-managed key whose policy grants cloudwatch.amazonaws.com kms:Decrypt
# and kms:GenerateDataKey*. Alert payloads here contain no sensitive data.
resource "aws_sns_topic" "alerts" {
  name = "${var.name}-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  count = local.has_email ? 1 : 0

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# -------------------------------------------------------------- load balancer

resource "aws_cloudwatch_metric_alarm" "target_5xx" {
  alarm_name          = "${var.name}-app-5xx"
  alarm_description   = "Application instances are returning 5xx responses."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_Target_5XX_Count"
  dimensions          = local.tg_dims
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = var.target_5xx_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching" # no traffic = no errors
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "elb_5xx" {
  alarm_name          = "${var.name}-alb-5xx"
  alarm_description   = "The load balancer itself is returning 5xx (502/503/504: no healthy targets, connection resets, timeouts)."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_ELB_5XX_Count"
  dimensions          = local.alb_dims
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 10
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "latency_p95" {
  alarm_name          = "${var.name}-latency-p95"
  alarm_description   = "p95 target response time above ${var.p95_latency_threshold_seconds}s for 15 minutes."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "TargetResponseTime"
  dimensions          = local.alb_dims
  extended_statistic  = "p95"
  period              = 300
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  threshold           = var.p95_latency_threshold_seconds
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "unhealthy_hosts" {
  alarm_name          = "${var.name}-unhealthy-hosts"
  alarm_description   = "At least one instance has been failing ALB health checks for 5 minutes."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  dimensions          = local.tg_dims
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 5
  datapoints_to_alarm = 5
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "no_healthy_hosts" {
  alarm_name          = "${var.name}-no-healthy-hosts"
  alarm_description   = "No healthy instances behind the load balancer: the site is down."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HealthyHostCount"
  dimensions          = local.tg_dims
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching" # no data here means no targets reporting at all
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

# ------------------------------------------------------------------- compute

resource "aws_cloudwatch_metric_alarm" "asg_cpu" {
  alarm_name          = "${var.name}-app-cpu-high"
  alarm_description   = "Average app CPU above 80% for 15 minutes despite target-tracking scaling (at max capacity?)."
  namespace           = "AWS/EC2"
  metric_name         = "CPUUtilization"
  dimensions          = { AutoScalingGroupName = var.asg_name }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "missing"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

# ------------------------------------------------------------------ database

resource "aws_cloudwatch_metric_alarm" "db_cpu" {
  alarm_name          = "${var.name}-db-cpu-high"
  alarm_description   = "RDS CPU above 80% for 15 minutes."
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  dimensions          = { DBInstanceIdentifier = var.db_instance_id }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "db_storage" {
  alarm_name          = "${var.name}-db-storage-low"
  alarm_description   = "RDS free storage below ${floor(var.db_free_storage_threshold_bytes / 1048576)} MiB."
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  dimensions          = { DBInstanceIdentifier = var.db_instance_id }
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 1
  threshold           = var.db_free_storage_threshold_bytes
  comparison_operator = "LessThanThreshold"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "db_memory" {
  alarm_name          = "${var.name}-db-memory-low"
  alarm_description   = "RDS freeable memory below ${floor(var.db_freeable_memory_threshold_bytes / 1048576)} MiB for 15 minutes."
  namespace           = "AWS/RDS"
  metric_name         = "FreeableMemory"
  dimensions          = { DBInstanceIdentifier = var.db_instance_id }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = var.db_freeable_memory_threshold_bytes
  comparison_operator = "LessThanThreshold"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

# ----------------------------------------------------------------- dashboard

resource "aws_cloudwatch_dashboard" "this" {
  dashboard_name = var.name

  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric", x = 0, y = 0, width = 12, height = 6
        properties = {
          title  = "Requests and errors"
          region = var.aws_region
          stat   = "Sum"
          period = 60
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", var.alb_arn_suffix],
            [".", "HTTPCode_Target_5XX_Count", ".", ".", "TargetGroup", var.target_group_arn_suffix],
            [".", "HTTPCode_ELB_5XX_Count", ".", "."],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 0, width = 12, height = 6
        properties = {
          title  = "Target response time"
          region = var.aws_region
          period = 60
          metrics = [
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", var.alb_arn_suffix, { stat = "p50" }],
            ["...", { stat = "p95" }],
            ["...", { stat = "p99" }],
          ]
          annotations = {
            horizontal = [{ label = "p95 alarm", value = var.p95_latency_threshold_seconds }]
          }
        }
      },
      {
        type = "metric", x = 0, y = 6, width = 8, height = 6
        properties = {
          title  = "Target health"
          region = var.aws_region
          stat   = "Minimum"
          period = 60
          metrics = [
            ["AWS/ApplicationELB", "HealthyHostCount", "TargetGroup", var.target_group_arn_suffix, "LoadBalancer", var.alb_arn_suffix],
            [".", "UnHealthyHostCount", ".", ".", ".", "."],
          ]
        }
      },
      {
        type = "metric", x = 8, y = 6, width = 8, height = 6
        properties = {
          title  = "CPU"
          region = var.aws_region
          stat   = "Average"
          period = 300
          metrics = [
            ["AWS/EC2", "CPUUtilization", "AutoScalingGroupName", var.asg_name, { label = "app (ASG avg)" }],
            ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", var.db_instance_id, { label = "database" }],
          ]
        }
      },
      {
        type = "metric", x = 16, y = 6, width = 8, height = 6
        properties = {
          title  = "Database"
          region = var.aws_region
          period = 300
          metrics = [
            ["AWS/RDS", "DatabaseConnections", "DBInstanceIdentifier", var.db_instance_id, { stat = "Maximum" }],
            [".", "FreeableMemory", ".", ".", { stat = "Minimum", yAxis = "right" }],
          ]
        }
      },
      {
        type = "log", x = 0, y = 12, width = 24, height = 6
        properties = {
          title  = "Recent application errors"
          region = var.aws_region
          query  = "SOURCE '${var.app_log_group}' | fields @timestamp, @logStream, @message | filter @message like /(?i)(error|exception|traceback)/ | sort @timestamp desc | limit 50"
          view   = "table"
        }
      },
    ]
  })
}
