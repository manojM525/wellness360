locals {
  name_prefix = "${var.project_name}-${var.environment}"

  common_tags = merge(var.tags, {
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "terraform"
  })
}

# ---------------------------------------------------------------------------
# Bare security groups — NO inline ingress/egress here.
# Cross-referencing rules (ALB -> ECS, ECS -> RDS) are declared below as
# separate aws_vpc_security_group_{ingress,egress}_rule resources, specifically
# to avoid a create-time cycle: if ALB's SG inline-referenced the ECS task SG's
# ID and the ECS task SG's inline ingress referenced the ALB SG's ID in the
# same resource block, each SG would need the other to exist first.
# ---------------------------------------------------------------------------
resource "aws_security_group" "alb" {
  name        = "${local.name_prefix}-alb-sg"
  description = "Internet-facing ALB — only SG in this stack that accepts traffic from 0.0.0.0/0"
  vpc_id      = var.vpc_id

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-alb-sg" })
}

resource "aws_security_group" "ecs_task" {
  name        = "${local.name_prefix}-ecs-task-sg"
  description = "ECS Fargate tasks — accepts traffic only from the ALB, never directly from the internet"
  vpc_id      = var.vpc_id

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-ecs-task-sg" })
}

resource "aws_security_group" "rds" {
  name        = "${local.name_prefix}-rds-sg"
  description = "RDS MySQL — accepts traffic only from the ECS task SG, no egress rules (RDS never initiates outbound)"
  vpc_id      = var.vpc_id

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-rds-sg" })
}

# ---------------------------------------------------------------------------
# ALB rules
# ---------------------------------------------------------------------------
resource "aws_vpc_security_group_ingress_rule" "alb_https_in" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS from the internet"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "alb_http_in" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP from the internet — listener rule redirects this to 443, never forwarded to targets"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_ecs" {
  security_group_id            = aws_security_group.alb.id
  description                  = "ALB forwards only to the ECS task SG, only on the app port"
  referenced_security_group_id = aws_security_group.ecs_task.id
  from_port                    = var.app_port
  to_port                      = var.app_port
  ip_protocol                  = "tcp"
}

# ---------------------------------------------------------------------------
# ECS task rules
# ---------------------------------------------------------------------------
resource "aws_vpc_security_group_ingress_rule" "ecs_from_alb" {
  security_group_id            = aws_security_group.ecs_task.id
  description                  = "Only the ALB can reach the app port — no direct internet or peer-to-peer task access"
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = var.app_port
  to_port                      = var.app_port
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "ecs_to_rds" {
  security_group_id            = aws_security_group.ecs_task.id
  description                  = "App tier reaches MySQL, and only MySQL, on the RDS SG"
  referenced_security_group_id = aws_security_group.rds.id
  from_port                    = var.db_port
  to_port                      = var.db_port
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "ecs_https_out" {
  security_group_id = aws_security_group.ecs_task.id
  description       = "HTTPS egress via NAT — ECR image pulls, AMP remote-write, CloudWatch Logs/Secrets Manager API calls"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

# ---------------------------------------------------------------------------
# RDS rules — ingress only. No egress rule is declared anywhere in this file
# for the rds SG, which means Terraform manages zero egress rules for it:
# RDS cannot initiate any outbound connection. This is intentional, not an
# omission — pair it with the private-data route table having no 0.0.0.0/0
# route (network module) for defense-in-depth at two independent layers.
# ---------------------------------------------------------------------------
resource "aws_vpc_security_group_ingress_rule" "rds_from_ecs" {
  security_group_id            = aws_security_group.rds.id
  description                  = "Only the ECS task SG can reach MySQL"
  referenced_security_group_id = aws_security_group.ecs_task.id
  from_port                    = var.db_port
  to_port                      = var.db_port
  ip_protocol                  = "tcp"
}
