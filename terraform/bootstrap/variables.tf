variable "aws_region" {
  description = "Region for the state bucket, ECR repository and deployed environments."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Name prefix for every resource. Must match `project` in terraform/live."
  type        = string
  default     = "aws-cicd-pipeline"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,30}$", var.project))
    error_message = "project must be 3-31 chars of lowercase letters, digits and hyphens."
  }
}

variable "github_repository" {
  description = "owner/repo allowed to assume the deploy role through GitHub OIDC."
  type        = string
  default     = "SrujanRudrapati/aws-cicd-pipeline"
}

variable "ecr_repository_name" {
  description = "ECR repository the pipeline pushes application images to."
  type        = string
  default     = "aws-cicd-pipeline-app"
}

variable "environments" {
  description = "Environments the deploy role may manage (used to scope IAM permissions)."
  type        = list(string)
  default     = ["dev", "prod"]
}

variable "create_github_oidc_provider" {
  description = "Create the account-wide GitHub OIDC provider. Set false if the account already has one."
  type        = bool
  default     = true
}

variable "force_destroy" {
  description = "Allow `terraform destroy` to delete a non-empty state bucket / ECR repo. Only for throwaway accounts."
  type        = bool
  default     = false
}
