output "aws_region" {
  description = "Set as the AWS_REGION repository variable."
  value       = var.aws_region
}

output "state_bucket" {
  description = "Set as the TF_STATE_BUCKET repository variable."
  value       = aws_s3_bucket.state.bucket
}

output "ecr_repository_name" {
  description = "Set as the ECR_REPOSITORY repository variable."
  value       = aws_ecr_repository.app.name
}

output "ecr_repository_url" {
  value = aws_ecr_repository.app.repository_url
}

output "github_actions_role_arn" {
  description = "Set as the AWS_ROLE_ARN repository variable."
  value       = aws_iam_role.github_actions.arn
}
