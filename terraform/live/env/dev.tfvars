# dev: smallest footprint that still exercises every tier across two AZs.
environment = "dev"

vpc_cidr           = "10.10.0.0/16"
single_nat_gateway = true # one shared NAT (~$33/mo instead of ~$66)

instance_type        = "t3.micro"
asg_min_size         = 1
asg_max_size         = 2
asg_desired_capacity = 1
web_concurrency      = 2

db_instance_class        = "db.t4g.micro"
db_multi_az              = false
db_backup_retention_days = 1
db_deletion_protection   = false
db_skip_final_snapshot   = true

log_retention_days = 7
