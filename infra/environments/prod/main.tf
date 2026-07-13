data "aws_caller_identity" "current" {}

locals {
  # Built once, used by both ecs_iam (grants read access) and ecs_service
  # (references the same ARNs when injecting env vars) — avoids repeating
  # this interpolation three times across two module blocks.
  ssm_db_arns = {
    host = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${module.rds.ssm_db_host_param_name}"
    port = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${module.rds.ssm_db_port_param_name}"
    name = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${module.rds.ssm_db_name_param_name}"
  }
}

module "network" {
  source = "../../modules/network"

  project_name = var.project_name
  environment  = var.environment

  vpc_cidr           = var.vpc_cidr
  availability_zones = var.availability_zones

  public_subnet_cidrs       = var.public_subnet_cidrs
  private_app_subnet_cidrs  = var.private_app_subnet_cidrs
  private_data_subnet_cidrs = var.private_data_subnet_cidrs

  # prod: one NAT Gateway per AZ — full AZ independence for egress, the
  # opposite trade-off from dev's cost-optimized single NAT.
  single_nat_gateway = false
}

module "security_groups" {
  source = "../../modules/security-groups"

  project_name = var.project_name
  environment  = var.environment
  vpc_id       = module.network.vpc_id

  # app_port / db_port left at module defaults (8080 / 3306)
}

module "acm_dns" {
  source = "../../modules/acm-dns"

  domain_name = var.domain_name
  subdomain   = "" # empty -> root domain, e.g. taskmaster-devops.example.com
  environment = var.environment
}

module "rds" {
  source = "../../modules/rds"

  project_name = var.project_name
  environment  = var.environment

  private_data_subnet_ids = module.network.private_data_subnet_ids
  security_group_id       = module.security_groups.rds_security_group_id

  instance_class      = var.db_instance_class
  multi_az            = var.db_multi_az
  deletion_protection = var.db_deletion_protection
  skip_final_snapshot = var.db_skip_final_snapshot
}

module "ecs_iam" {
  source = "../../modules/ecs-iam"

  project_name = var.project_name
  environment  = var.environment

  secrets_manager_secret_arns = [module.rds.master_user_secret_arn]

  ssm_parameter_arns = [
    local.ssm_db_arns.host,
    local.ssm_db_arns.port,
    local.ssm_db_arns.name,
  ]
}

module "alb" {
  source = "../../modules/alb"

  project_name = var.project_name
  environment  = var.environment

  vpc_id                = module.network.vpc_id
  public_subnet_ids     = module.network.public_subnet_ids
  alb_security_group_id = module.security_groups.alb_security_group_id
  certificate_arn       = module.acm_dns.certificate_arn

  alb_deletion_protection = var.alb_deletion_protection
}

# Ties acm_dns's hosted zone to alb's DNS name — deliberately a root-level
# resource, not buried in either module, since it's the one place that
# genuinely needs both modules' outputs at once.
resource "aws_route53_record" "app" {
  zone_id = module.acm_dns.zone_id
  name    = module.acm_dns.fqdn
  type    = "A"

  alias {
    name                   = module.alb.alb_dns_name
    zone_id                = module.alb.alb_zone_id
    evaluate_target_health = true
  }
}

# Looked up via data source, not a module/state reference — global/ecr has
# its own separate state, same reasoning as the acm-dns zone lookup.
data "aws_ecr_repository" "app" {
  name = "${var.project_name}/app"
}

module "ecs_cluster" {
  source = "../../modules/ecs-cluster"

  project_name = var.project_name
  environment  = var.environment
}

module "observability" {
  source = "../../modules/observability"

  project_name = var.project_name
  environment  = var.environment
}

# The ADOT sidecar uses the TASK role (not the execution role) to sign its
# remote-write requests — it's the running container calling AWS, not the
# ECS agent's startup bootstrap. Attached externally here rather than inside
# ecs-iam, so that module stays unaware of AMP specifics.
resource "aws_iam_role_policy" "task_amp_remote_write" {
  name = "${var.project_name}-${var.environment}-amp-remote-write"
  role = module.ecs_iam.task_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["aps:RemoteWrite"]
        Resource = module.observability.workspace_arn
      }
    ]
  })
}

module "ecs_service" {
  source = "../../modules/ecs-service"

  project_name = var.project_name
  environment  = var.environment

  cluster_id   = module.ecs_cluster.cluster_id
  cluster_name = module.ecs_cluster.cluster_name

  private_app_subnet_ids     = module.network.private_app_subnet_ids
  ecs_task_security_group_id = module.security_groups.ecs_task_security_group_id
  target_group_arn           = module.alb.target_group_arn
  alb_arn                    = module.alb.alb_arn

  execution_role_arn = module.ecs_iam.execution_role_arn
  task_role_arn      = module.ecs_iam.task_role_arn

  ecr_repository_url = data.aws_ecr_repository.app.repository_url
  # image_tag left at module default ("initial") — CI takes ownership of the
  # running revision from its first real deploy onward (see lifecycle.ignore_changes)

  task_cpu      = var.task_cpu
  task_memory   = var.task_memory
  desired_count = var.desired_count

  autoscaling_min_capacity = var.autoscaling_min_capacity
  autoscaling_max_capacity = var.autoscaling_max_capacity
  use_fargate_spot         = var.use_fargate_spot

  log_retention_days = var.log_retention_days

  db_host_ssm_arn = local.ssm_db_arns.host
  db_port_ssm_arn = local.ssm_db_arns.port
  db_name_ssm_arn = local.ssm_db_arns.name
  db_secret_arn   = module.rds.master_user_secret_arn

  enable_observability      = true
  amp_remote_write_endpoint = module.observability.remote_write_endpoint
}
