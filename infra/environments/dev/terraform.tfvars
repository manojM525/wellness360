aws_region  = "us-east-1"
project_name = "manoj-taskmaster"
environment  = "dev"

vpc_cidr            = "10.10.0.0/16"
availability_zones  = ["us-east-1a", "us-east-1b"]

public_subnet_cidrs      = ["10.10.0.0/24", "10.10.1.0/24"]
private_app_subnet_cidrs = ["10.10.10.0/24", "10.10.11.0/24"]
private_data_subnet_cidrs = ["10.10.20.0/24", "10.10.21.0/24"]

# Replace with your actual registered domain once purchased.
domain_name = "roadtofuture.shop"

# RDS: dev is intentionally minimal — single-AZ, no deletion protection,
# skip final snapshot on destroy so `terraform destroy` in dev is actually fast.
db_instance_class      = "db.t4g.micro"
db_multi_az             = false
db_deletion_protection  = false
db_skip_final_snapshot  = true

# ALB: no deletion protection in dev so the environment can be torn down freely
alb_deletion_protection = false

# ECS: dev is small and cost-optimized, uses Fargate Spot since a demo
# environment can tolerate the rare Spot interruption; prod will not.
task_cpu                 = 512
task_memory               = 1024
desired_count             = 1
autoscaling_min_capacity  = 1
autoscaling_max_capacity  = 2
use_fargate_spot          = true
log_retention_days        = 7
