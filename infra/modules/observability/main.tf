locals {
  common_tags = merge(var.tags, {
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "terraform"
  })
}

resource "aws_prometheus_workspace" "this" {
  alias = "${var.project_name}-${var.environment}"

  tags = local.common_tags
}
