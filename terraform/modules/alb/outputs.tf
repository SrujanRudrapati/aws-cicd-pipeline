output "dns_name" {
  value = aws_lb.this.dns_name
}

output "zone_id" {
  value = aws_lb.this.zone_id
}

output "arn_suffix" {
  description = "For CloudWatch metric dimensions."
  value       = aws_lb.this.arn_suffix
}

output "target_group_arn" {
  value = aws_lb_target_group.app.arn
}

output "target_group_arn_suffix" {
  value = aws_lb_target_group.app.arn_suffix
}

output "https_enabled" {
  value = local.https_enabled
}
