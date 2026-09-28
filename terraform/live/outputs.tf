output "app_url" {
  description = "Where the smoke test and humans should look."
  value = (
    module.alb.https_enabled && var.public_domain != null
    ? "https://${var.public_domain}"
    : "http://${module.alb.dns_name}"
  )
}

output "alb_dns_name" {
  value = module.alb.dns_name
}

output "deployed_image" {
  value = local.image_uri
}

output "asg_name" {
  value = module.compute.asg_name
}

output "launch_template_version" {
  value = module.compute.launch_template_version
}

output "ami_id" {
  value = module.compute.ami_id
}

output "vpc_id" {
  value = module.network.vpc_id
}

output "nat_public_ips" {
  description = "Egress IPs of the app tier (for allow-listing on third-party APIs)."
  value       = module.network.nat_public_ips
}

output "db_endpoint" {
  value = "${module.database.address}:${module.database.port}"
}

output "db_secret_arn" {
  value = module.database.master_user_secret_arn
}

output "app_log_group" {
  value = module.compute.log_group_name
}

output "sns_topic_arn" {
  value = module.monitoring.sns_topic_arn
}

output "dashboard_url" {
  value = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards/dashboard/${module.monitoring.dashboard_name}"
}

output "environment_summary" {
  description = "What differs between environments, at a glance."
  value = {
    environment   = var.environment
    nat_gateways  = length(module.network.nat_gateway_ids)
    instance_type = module.compute.instance_type
    asg_min_max   = "${module.compute.capacity.min}/${module.compute.capacity.max}"
    db_class      = module.database.instance_class
    db_multi_az   = module.database.multi_az
    https         = module.alb.https_enabled
    image         = local.image_uri
  }
}
