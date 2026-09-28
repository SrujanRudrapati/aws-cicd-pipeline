variable "name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "app_port" {
  description = "Port the application container listens on."
  type        = number
}

variable "db_port" {
  type    = number
  default = 5432
}

variable "enable_https" {
  description = "Open 443 on the ALB (when an ACM certificate is configured)."
  type        = bool
  default     = false
}

variable "alb_ingress_cidrs" {
  description = "Who may reach the load balancer."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}
