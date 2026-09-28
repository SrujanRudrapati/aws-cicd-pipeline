variable "name" {
  type = string
}

variable "environment" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "app_subnet_ids" {
  description = "Private subnets for the instances (egress via NAT)."
  type        = list(string)
}

variable "security_group_id" {
  type = string
}

variable "target_group_arn" {
  type = string
}

variable "instance_type" {
  type = string
}

variable "ami_id" {
  description = "Pin an AMI. null = latest Amazon Linux 2023, re-resolved on every plan (so new AMIs roll out with the next deploy)."
  type        = string
  default     = null
}

variable "root_volume_size" {
  description = "GiB"
  type        = number
  default     = 20
}

variable "min_size" {
  type = number
}

variable "max_size" {
  type = number
}

variable "desired_capacity" {
  description = "Initial size only; afterwards target tracking owns it."
  type        = number
}

variable "cpu_target_percent" {
  type    = number
  default = 60
}

variable "health_check_grace_period" {
  description = "Seconds to let first-boot bootstrap (packages, Ansible, image pull) finish before ELB health checks count."
  type        = number
  default     = 420
}

variable "instance_warmup" {
  type    = number
  default = 120
}

variable "image_uri" {
  description = "Full image reference, <repo-url>:<tag>."
  type        = string
}

variable "ecr_repository_arn" {
  type = string
}

variable "app_port" {
  type = number
}

variable "web_concurrency" {
  description = "Gunicorn worker processes per instance."
  type        = number
}

variable "db_host" {
  type = string
}

variable "db_port" {
  type = number
}

variable "db_name" {
  type = string
}

variable "db_secret_arn" {
  type = string
}

variable "ansible_source_dir" {
  description = "Directory holding the Ansible playbook and roles that bootstrap each instance."
  type        = string
}

variable "log_retention_days" {
  type = number
}

variable "force_destroy_bootstrap_bucket" {
  type    = bool
  default = true
}
