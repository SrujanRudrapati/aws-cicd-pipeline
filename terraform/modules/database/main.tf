locals {
  identifier = "${var.name}-db"
}

resource "aws_db_subnet_group" "this" {
  name       = local.identifier
  subnet_ids = var.db_subnet_ids
  tags       = { Name = local.identifier }
}

resource "aws_db_parameter_group" "this" {
  name_prefix = "${local.identifier}-pg${var.engine_major_version}-"
  family      = "postgres${var.engine_major_version}"
  description = "Parameters for ${local.identifier}"

  # Refuse unencrypted client connections.
  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }

  # Log queries slower than 500 ms to CloudWatch Logs.
  parameter {
    name  = "log_min_duration_statement"
    value = "500"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Created up front so Terraform owns its retention instead of RDS creating
# it implicitly with "never expire".
resource "aws_cloudwatch_log_group" "postgresql" {
  name              = "/aws/rds/instance/${local.identifier}/postgresql"
  retention_in_days = var.log_retention_days
}

resource "aws_db_instance" "this" {
  identifier     = local.identifier
  engine         = "postgres"
  engine_version = var.engine_major_version # latest minor of this major
  instance_class = var.instance_class

  db_name  = var.db_name
  username = var.master_username
  # RDS generates the password, stores it in Secrets Manager and rotates it.
  # It never appears in Terraform state, variables or CI logs.
  manage_master_user_password = true

  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [var.security_group_id]
  parameter_group_name   = aws_db_parameter_group.this.name
  publicly_accessible    = false
  multi_az               = var.multi_az

  backup_retention_period    = var.backup_retention_days
  backup_window              = "07:00-08:00" # UTC, before the maintenance window
  maintenance_window         = "sun:08:30-sun:09:30"
  auto_minor_version_upgrade = true
  copy_tags_to_snapshot      = true

  deletion_protection       = var.deletion_protection
  skip_final_snapshot       = var.skip_final_snapshot
  final_snapshot_identifier = var.skip_final_snapshot ? null : "${local.identifier}-final"

  enabled_cloudwatch_logs_exports = ["postgresql"]

  tags = { Name = local.identifier }

  depends_on = [aws_cloudwatch_log_group.postgresql]
}
