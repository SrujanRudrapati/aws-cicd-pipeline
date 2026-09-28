variable "name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "public_subnet_ids" {
  type = list(string)
}

variable "security_group_id" {
  type = string
}

variable "app_port" {
  type = number
}

variable "health_check_path" {
  description = "Liveness endpoint. Deliberately not /ready: a database blip should raise an alarm, not make the ALB pull every instance at once."
  type        = string
  default     = "/health"
}

variable "certificate_arn" {
  description = "ACM certificate for HTTPS. When null the ALB serves plain HTTP only."
  type        = string
  default     = null
}

variable "deletion_protection" {
  type    = bool
  default = false
}

variable "idle_timeout" {
  description = "Must stay below gunicorn's keepalive (75s) so the ALB, not the app, closes idle connections."
  type        = number
  default     = 60
}
