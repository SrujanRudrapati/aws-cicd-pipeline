data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_default_tags" "current" {}

data "aws_ssm_parameter" "al2023" {
  count = var.ami_id == null ? 1 : 0
  name  = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

locals {
  # A concrete AMI ID (not a "resolve:ssm:" alias) so instance-refresh
  # auto-rollback can return to the previous launch template version.
  ami_id = var.ami_id != null ? var.ami_id : data.aws_ssm_parameter.al2023[0].insecure_value
}

resource "aws_cloudwatch_log_group" "app" {
  name              = "/${var.name}/app"
  retention_in_days = var.log_retention_days
}

# ------------------------------------------------ Ansible bootstrap bundle
# The playbook is zipped and uploaded to a versioned bucket. User data pins
# the exact object version, so every launch template version (and therefore
# an auto-rollback) boots with the playbook it was released with.

resource "aws_s3_bucket" "bootstrap" {
  bucket        = "${var.name}-bootstrap-${data.aws_caller_identity.current.account_id}"
  force_destroy = var.force_destroy_bootstrap_bucket
}

resource "aws_s3_bucket_versioning" "bootstrap" {
  bucket = aws_s3_bucket.bootstrap.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "bootstrap" {
  bucket = aws_s3_bucket.bootstrap.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "bootstrap" {
  bucket                  = aws_s3_bucket.bootstrap.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "bootstrap" {
  bucket = aws_s3_bucket.bootstrap.id

  rule {
    id     = "expire-old-bundles"
    status = "Enabled"
    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

data "archive_file" "ansible" {
  type        = "zip"
  source_dir  = var.ansible_source_dir
  output_path = "${path.root}/.build/${var.name}-ansible.zip"
  excludes    = [".ansible", ".ansible/**", "**/*.retry", "**/__pycache__/**"]
}

resource "aws_s3_object" "ansible" {
  bucket      = aws_s3_bucket.bootstrap.id
  key         = "ansible/bundle.zip"
  source      = data.archive_file.ansible.output_path
  source_hash = data.archive_file.ansible.output_base64sha256

  depends_on = [aws_s3_bucket_versioning.bootstrap]
}

# ---------------------------------------------------------- launch template

locals {
  ansible_vars = {
    app_image           = var.image_uri
    app_env             = var.environment
    app_port            = var.app_port
    app_aws_region      = var.aws_region
    app_log_group       = aws_cloudwatch_log_group.app.name
    app_web_concurrency = var.web_concurrency
    app_db_host         = var.db_host
    app_db_port         = var.db_port
    app_db_name         = var.db_name
    app_db_secret_arn   = var.db_secret_arn
  }

  user_data = templatefile("${path.module}/templates/user_data.sh.tftpl", {
    region            = var.aws_region
    bundle_bucket     = aws_s3_bucket.bootstrap.id
    bundle_key        = aws_s3_object.ansible.key
    bundle_version_id = aws_s3_object.ansible.version_id
    vars_json         = jsonencode(local.ansible_vars)
  })

  instance_tags = merge(data.aws_default_tags.current.tags, {
    Name = "${var.name}-app"
  })
}

resource "aws_launch_template" "app" {
  name_prefix   = "${var.name}-app-"
  description   = "App instances for ${var.name}; image ${var.image_uri}"
  image_id      = local.ami_id
  instance_type = var.instance_type
  user_data     = base64encode(local.user_data)

  update_default_version = true
  vpc_security_group_ids = [var.security_group_id]

  iam_instance_profile {
    arn = aws_iam_instance_profile.app.arn
  }

  # IMDSv2 only. Hop limit 2 lets the app *container* (one extra network hop
  # through the Docker bridge) reach instance credentials for Secrets Manager.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = var.root_volume_size
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  # Default tags don't propagate to resources the ASG launches, so tag them here.
  tag_specifications {
    resource_type = "instance"
    tags          = local.instance_tags
  }

  tag_specifications {
    resource_type = "volume"
    tags          = local.instance_tags
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ---------------------------------------------------------- auto scaling

resource "aws_autoscaling_group" "app" {
  name                = "${var.name}-app"
  vpc_zone_identifier = var.app_subnet_ids
  target_group_arns   = [var.target_group_arn]

  min_size         = var.min_size
  max_size         = var.max_size
  desired_capacity = var.desired_capacity

  # Replace instances the ALB considers unhealthy, not just ones EC2 considers dead.
  health_check_type         = "ELB"
  health_check_grace_period = var.health_check_grace_period
  default_instance_warmup   = var.instance_warmup

  launch_template {
    id      = aws_launch_template.app.id
    version = aws_launch_template.app.latest_version # a number, never $Latest
  }

  # A deploy is a new launch template version (new image tag in user data).
  # Terraform then starts a rolling instance refresh:
  #   min 100% / max 200% healthy -> launch replacements first, drain old ones after
  #   auto_rollback               -> if new instances never get healthy, revert
  #                                  to the previous launch template version
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 100
      max_healthy_percentage = 200
      instance_warmup        = var.instance_warmup
      skip_matching          = true
      auto_rollback          = true
    }
  }

  enabled_metrics = [
    "GroupDesiredCapacity",
    "GroupInServiceInstances",
    "GroupPendingInstances",
    "GroupTerminatingInstances",
    "GroupTotalInstances",
  ]

  dynamic "tag" {
    for_each = local.instance_tags
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = false # the launch template already tags instances
    }
  }

  lifecycle {
    ignore_changes = [desired_capacity] # owned by target tracking after creation
  }
}

resource "aws_autoscaling_policy" "cpu" {
  name                   = "${var.name}-cpu-target"
  autoscaling_group_name = aws_autoscaling_group.app.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = var.cpu_target_percent
  }
}
