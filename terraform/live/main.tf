# One root module for every environment. dev and prod run exactly this code;
# they differ only in env/<env>.tfvars and their state file.

locals {
  name = "${var.project}-${var.environment}"
}

# ------------------------------------------------------------ release guard
# Fail at *plan* time if the image tag was never pushed, instead of rolling
# out instances that can't pull their image and waiting for the refresh to fail.

data "aws_ecr_repository" "app" {
  name = var.ecr_repository_name
}

data "aws_ecr_image" "release" {
  repository_name = data.aws_ecr_repository.app.name
  image_tag       = var.image_tag
}

locals {
  image_uri = "${data.aws_ecr_repository.app.repository_url}:${data.aws_ecr_image.release.image_tag}"
}

# ------------------------------------------------------------------ tiers

module "network" {
  source = "../modules/network"

  name               = local.name
  vpc_cidr           = var.vpc_cidr
  az_count           = var.az_count
  single_nat_gateway = var.single_nat_gateway
}

module "security" {
  source = "../modules/security"

  name         = local.name
  vpc_id       = module.network.vpc_id
  app_port     = var.app_port
  enable_https = var.certificate_arn != null
}

module "alb" {
  source = "../modules/alb"

  name                = local.name
  vpc_id              = module.network.vpc_id
  public_subnet_ids   = module.network.public_subnet_ids
  security_group_id   = module.security.alb_security_group_id
  app_port            = var.app_port
  certificate_arn     = var.certificate_arn
  deletion_protection = var.alb_deletion_protection
}

module "database" {
  source = "../modules/database"

  name                  = local.name
  db_subnet_ids         = module.network.db_subnet_ids
  security_group_id     = module.security.db_security_group_id
  instance_class        = var.db_instance_class
  allocated_storage     = var.db_allocated_storage
  multi_az              = var.db_multi_az
  backup_retention_days = var.db_backup_retention_days
  deletion_protection   = var.db_deletion_protection
  skip_final_snapshot   = var.db_skip_final_snapshot
  log_retention_days    = var.log_retention_days
}

module "compute" {
  source = "../modules/compute"

  name              = local.name
  environment       = var.environment
  aws_region        = var.aws_region
  app_subnet_ids    = module.network.app_subnet_ids
  security_group_id = module.security.app_security_group_id
  target_group_arn  = module.alb.target_group_arn

  instance_type    = var.instance_type
  ami_id           = var.ami_id
  min_size         = var.asg_min_size
  max_size         = var.asg_max_size
  desired_capacity = var.asg_desired_capacity

  image_uri          = local.image_uri
  ecr_repository_arn = data.aws_ecr_repository.app.arn
  app_port           = var.app_port
  web_concurrency    = var.web_concurrency

  db_host       = module.database.address
  db_port       = module.database.port
  db_name       = module.database.db_name
  db_secret_arn = module.database.master_user_secret_arn

  ansible_source_dir = "${path.root}/../../ansible"
  log_retention_days = var.log_retention_days
}

module "monitoring" {
  source = "../modules/monitoring"

  name                    = local.name
  aws_region              = var.aws_region
  alert_email             = var.alert_email
  alb_arn_suffix          = module.alb.arn_suffix
  target_group_arn_suffix = module.alb.target_group_arn_suffix
  asg_name                = module.compute.asg_name
  db_instance_id          = module.database.instance_id
  app_log_group           = module.compute.log_group_name
}
