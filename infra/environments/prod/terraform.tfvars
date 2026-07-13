aws_region   = "us-east-1"
project_name = "manoj-taskmaster"
environment  = "prod"

vpc_cidr           = "10.20.0.0/16"
availability_zones = ["us-east-1a", "us-east-1b"]

public_subnet_cidrs       = ["10.20.0.0/24", "10.20.1.0/24"]
private_app_subnet_cidrs  = ["10.20.10.0/24", "10.20.11.0/24"]
private_data_subnet_cidrs = ["10.20.20.0/24", "10.20.21.0/24"]

# Same registered domain as dev — acm-dns's subdomain="" in main.tf resolves
# this to the root domain instead of a "prod." prefix.
domain_name = "roadtofuture.shop"

# RDS: Multi-AZ for real failover, deletion protection on, and a final
# snapshot is mandatory on any destroy — the opposite of every dev default,
# because prod data actually matters.
db_instance_class      = "db.t4g.small"
db_multi_az            = true
db_deletion_protection = true
db_skip_final_snapshot = false

# ALB: deletion protection on — an accidental `terraform destroy` in prod
# should not be a one-command mistake.
alb_deletion_protection = true

# ECS: standard Fargate (not Spot) for predictable capacity during scale-out,
# 2 as the desired/minimum count for real HA (see architecture Phase 3.6 —
# 1 task in "prod" guarantees downtime on every deploy and on any crash).
# Sizing bumped over dev's for real headroom, same reasoning as the earlier
# dev bump for the ADOT sidecar, just with more room for actual traffic.
task_cpu                 = 1024
task_memory              = 2048
desired_count            = 2
autoscaling_min_capacity = 2
autoscaling_max_capacity = 4
use_fargate_spot         = false
log_retention_days       = 30
