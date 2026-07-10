variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

locals {
  name_prefix = "${var.project_name}-${var.environment}"

  common_tags = merge(var.tags, {
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "terraform"
  })
}

resource "aws_ecs_cluster" "this" {
  name = "${local.name_prefix}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled" # per-task CPU/memory/network metrics in CloudWatch beyond the basic service-level ones — worth the small extra cost for real observability
  }

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-cluster" })
}

# Both capacity providers available; the actual weighting (e.g. dev leaning
# on FARGATE_SPOT for cost, prod staying on standard FARGATE for predictable
# availability during scale-out) is set per-service, not per-cluster.
resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name       = aws_ecs_cluster.this.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]
}

output "cluster_id" {
  value = aws_ecs_cluster.this.id
}

output "cluster_name" {
  value = aws_ecs_cluster.this.name
}
