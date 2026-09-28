# prod: same code, sized and hardened for availability.
environment = "prod"

vpc_cidr           = "10.20.0.0/16"
single_nat_gateway = false # NAT per AZ: an AZ outage can't cut egress for the other

instance_type        = "t3.small"
asg_min_size         = 2 # at least one instance per AZ
asg_max_size         = 6
asg_desired_capacity = 2
web_concurrency      = 4

db_instance_class        = "db.t4g.small"
db_multi_az              = true # synchronous standby + automatic failover
db_backup_retention_days = 7
db_deletion_protection   = true
db_skip_final_snapshot   = false

alb_deletion_protection = true
log_retention_days      = 30
