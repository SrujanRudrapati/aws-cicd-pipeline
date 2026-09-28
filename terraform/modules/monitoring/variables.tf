variable "name" {
  type = string
}

variable "aws_region" {
  description = "Used by the dashboard widgets."
  type        = string
}

variable "alert_email" {
  description = "Subscribed to the alert topic. null or \"\" = no subscription (confirm the email AWS sends after apply)."
  type        = string
  default     = null
}

variable "alb_arn_suffix" {
  type = string
}

variable "target_group_arn_suffix" {
  type = string
}

variable "asg_name" {
  type = string
}

variable "db_instance_id" {
  type = string
}

variable "app_log_group" {
  type = string
}

variable "p95_latency_threshold_seconds" {
  type    = number
  default = 0.5
}

variable "target_5xx_threshold" {
  description = "5xx responses from the app per 5-minute period before alarming."
  type        = number
  default     = 10
}

variable "db_free_storage_threshold_bytes" {
  type    = number
  default = 2147483648 # 2 GiB
}

variable "db_freeable_memory_threshold_bytes" {
  type    = number
  default = 67108864 # 64 MiB
}
