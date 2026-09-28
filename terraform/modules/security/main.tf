# Layered security groups: internet -> ALB -> app -> database.
# Each tier only accepts traffic from the security group of the tier in front
# of it (SG references, not CIDRs), so a host in the wrong group can't reach
# the next tier even from inside the VPC.
#
# Rules are separate aws_vpc_security_group_*_rule resources, so changing one
# rule never forces the group (and every ENI using it) to be replaced.

locals {
  alb_ports = var.enable_https ? [80, 443] : [80]
  alb_ingress = {
    for pair in setproduct(local.alb_ports, var.alb_ingress_cidrs) :
    "${pair[0]}-${pair[1]}" => { port = pair[0], cidr = pair[1] }
  }
}

resource "aws_security_group" "alb" {
  name_prefix = "${var.name}-alb-"
  description = "Internet-facing load balancer"
  vpc_id      = var.vpc_id

  tags = { Name = "${var.name}-alb" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "app" {
  name_prefix = "${var.name}-app-"
  description = "Application instances; reachable only from the ALB"
  vpc_id      = var.vpc_id

  tags = { Name = "${var.name}-app" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "db" {
  name_prefix = "${var.name}-db-"
  description = "PostgreSQL; reachable only from application instances"
  vpc_id      = var.vpc_id

  tags = { Name = "${var.name}-db" }

  lifecycle {
    create_before_destroy = true
  }
}

# ---------------------------------------------------------------------- ALB

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  for_each = local.alb_ingress

  security_group_id = aws_security_group.alb.id
  description       = "Clients on ${each.value.port}"
  ip_protocol       = "tcp"
  from_port         = each.value.port
  to_port           = each.value.port
  cidr_ipv4         = each.value.cidr
}

resource "aws_vpc_security_group_egress_rule" "alb_to_app" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Forward to app instances"
  ip_protocol                  = "tcp"
  from_port                    = var.app_port
  to_port                      = var.app_port
  referenced_security_group_id = aws_security_group.app.id
}

# ---------------------------------------------------------------------- app

resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  security_group_id            = aws_security_group.app.id
  description                  = "Traffic and health checks from the ALB"
  ip_protocol                  = "tcp"
  from_port                    = var.app_port
  to_port                      = var.app_port
  referenced_security_group_id = aws_security_group.alb.id
}

# HTTPS out (via NAT) for ECR, SSM, CloudWatch Logs, Secrets Manager and
# package repos. No other outbound ports; no SSH in at all (access is via SSM).
resource "aws_vpc_security_group_egress_rule" "app_https" {
  security_group_id = aws_security_group.app.id
  description       = "AWS APIs and package repositories"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "app_to_db" {
  security_group_id            = aws_security_group.app.id
  description                  = "PostgreSQL"
  ip_protocol                  = "tcp"
  from_port                    = var.db_port
  to_port                      = var.db_port
  referenced_security_group_id = aws_security_group.db.id
}

# ----------------------------------------------------------------------- db

resource "aws_vpc_security_group_ingress_rule" "db_from_app" {
  security_group_id            = aws_security_group.db.id
  description                  = "PostgreSQL from app instances"
  ip_protocol                  = "tcp"
  from_port                    = var.db_port
  to_port                      = var.db_port
  referenced_security_group_id = aws_security_group.app.id
}
# No egress rules on the db group: RDS never initiates connections here.
