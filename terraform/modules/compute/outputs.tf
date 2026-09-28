output "asg_name" {
  value = aws_autoscaling_group.app.name
}

output "launch_template_id" {
  value = aws_launch_template.app.id
}

output "launch_template_version" {
  value = aws_launch_template.app.latest_version
}

output "ami_id" {
  value = local.ami_id
}

output "log_group_name" {
  value = aws_cloudwatch_log_group.app.name
}

output "instance_role_name" {
  value = aws_iam_role.app.name
}

output "bootstrap_bundle" {
  value = "s3://${aws_s3_bucket.bootstrap.id}/${aws_s3_object.ansible.key}?versionId=${aws_s3_object.ansible.version_id}"
}

output "instance_type" {
  value = aws_launch_template.app.instance_type
}

output "capacity" {
  value = {
    min = aws_autoscaling_group.app.min_size
    max = aws_autoscaling_group.app.max_size
  }
}
