variable "name" {
  description = "Name prefix, e.g. aws-cicd-pipeline-dev."
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR. Must be a /16 so it can be split into /24 subnets per tier and AZ."
  type        = string

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0)) && endswith(var.vpc_cidr, "/16")
    error_message = "vpc_cidr must be a valid /16, e.g. 10.10.0.0/16."
  }
}

variable "az_count" {
  description = "Number of Availability Zones to span (ALB and Multi-AZ RDS need at least 2)."
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 4
    error_message = "az_count must be between 2 and 4."
  }
}

variable "single_nat_gateway" {
  description = "true: one shared NAT gateway (cheap, dev). false: one per AZ, so losing an AZ doesn't cut egress for the others (prod)."
  type        = bool
}
