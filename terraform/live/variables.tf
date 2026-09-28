# ------------------------------------------------------------------- identity

variable "project" {
  type    = string
  default = "aws-cicd-pipeline"
}

variable "environment" {
  description = "dev or prod. Selects nothing by itself: all sizing comes from env/<environment>.tfvars."
  type        = string

  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "environment must be dev or prod."
  }
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "repository" {
  description = "Tagged onto every resource so you can find the code that owns it."
  type        = string
  default     = "github.com/SrujanRudrapati/aws-cicd-pipeline"
}

# ---------------------------------------------------------------- release

variable "ecr_repository_name" {
  type    = string
  default = "aws-cicd-pipeline-app"
}

variable "image_tag" {
  description = "Image tag to deploy: the full git commit SHA the pipeline built and pushed."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$", var.image_tag))
    error_message = "image_tag must be a valid Docker tag (e.g. a git SHA)."
  }
}

# ---------------------------------------------------------------- network

variable "vpc_cidr" {
  type = string
}

variable "az_count" {
  type    = number
  default = 2
}

variable "single_nat_gateway" {
  type = bool
}

# -------------------------------------------------------------- app tier

variable "app_port" {
  type    = number
  default = 8080
}

variable "instance_type" {
  type = string
}

variable "ami_id" {
  type    = string
  default = null
}

variable "asg_min_size" {
  type = number
}

variable "asg_max_size" {
  type = number
}

variable "asg_desired_capacity" {
  type = number
}

variable "web_concurrency" {
  description = "Gunicorn workers per instance (roughly 2 x vCPUs)."
  type        = number
  default     = 2
}

# -------------------------------------------------------------- database

variable "db_instance_class" {
  type = string
}

variable "db_multi_az" {
  type = bool
}

variable "db_allocated_storage" {
  type    = number
  default = 20
}

variable "db_backup_retention_days" {
  type = number
}

variable "db_deletion_protection" {
  type = bool
}

variable "db_skip_final_snapshot" {
  type = bool
}

# ------------------------------------------------------------ edge / ops

variable "certificate_arn" {
  description = "ACM certificate ARN to enable HTTPS on the ALB (optional)."
  type        = string
  default     = null
}

variable "public_domain" {
  description = "Hostname the certificate covers, used for app_url. Point a DNS record at alb_dns_name."
  type        = string
  default     = null
}

variable "alb_deletion_protection" {
  type    = bool
  default = false
}

variable "alert_email" {
  description = "Receives CloudWatch alarm notifications. Supplied by CI (TF_VAR_alert_email), not committed."
  type        = string
  default     = null
}

variable "log_retention_days" {
  type = number
}
