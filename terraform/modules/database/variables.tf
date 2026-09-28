variable "name" {
  type = string
}

variable "db_subnet_ids" {
  description = "Isolated subnets (no internet route) in at least two AZs."
  type        = list(string)
}

variable "security_group_id" {
  type = string
}

variable "engine_major_version" {
  type    = string
  default = "16"
}

variable "instance_class" {
  type = string
}

variable "allocated_storage" {
  description = "GiB"
  type        = number
  default     = 20
}

variable "max_allocated_storage" {
  description = "Upper bound for storage autoscaling (GiB)."
  type        = number
  default     = 100
}

variable "multi_az" {
  description = "Synchronous standby in a second AZ with automatic failover."
  type        = bool
}

variable "backup_retention_days" {
  type = number
}

variable "deletion_protection" {
  type = bool
}

variable "skip_final_snapshot" {
  type = bool
}

variable "db_name" {
  type    = string
  default = "app"
}

variable "master_username" {
  type    = string
  default = "appadmin"
}

variable "log_retention_days" {
  type = number
}
