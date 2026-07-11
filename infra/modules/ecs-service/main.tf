locals {
  name_prefix = "${var.project_name}-${var.environment}"

  common_tags = merge(var.tags, {
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "terraform"
  })

  container_name = "app"
}

# ---------------------------------------------------------------------------
# CloudWatch Log Group — created explicitly (not left to auto-create on first
# log write) so retention is set from day one; an auto-created group defaults
# to "Never expire," which quietly costs money forever.
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${local.name_prefix}"
  retention_in_days = var.log_retention_days

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# Task Definition
# ---------------------------------------------------------------------------
resource "aws_ecs_task_definition" "app" {
  family                   = "${local.name_prefix}-app"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc" # mandatory for Fargate — gives every task its own ENI, which is why the task-level SG is meaningful
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = var.execution_role_arn
  task_role_arn            = var.task_role_arn

  container_definitions = jsonencode([
    {
      name      = local.container_name
      image     = "${var.ecr_repository_url}:${var.image_tag}"
      essential = true

      portMappings = [
        {
          containerPort = var.container_port
          protocol      = "tcp"
        }
      ]

      # Non-secret DB config via SSM Parameter Store, credentials via the
      # RDS-managed Secrets Manager secret (JSON-key syntax pulls just the
      # field needed, never the whole secret blob, into a single env var).
      secrets = [
        { name = "DB_HOST", valueFrom = var.db_host_ssm_arn },
        { name = "DB_PORT", valueFrom = var.db_port_ssm_arn },
        { name = "DB_NAME", valueFrom = var.db_name_ssm_arn },
        { name = "DB_USERNAME", valueFrom = "${var.db_secret_arn}:username::" },
        { name = "DB_PASSWORD", valueFrom = "${var.db_secret_arn}:password::" },
      ]

      environment = [
        { name = "SPRING_PROFILES_ACTIVE", value = var.environment }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.app.name
          "awslogs-region"        = data.aws_region.current.name
          "awslogs-stream-prefix" = "ecs"
        }
      }
    }
  ])

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-app-taskdef" })
}

data "aws_region" "current" {}

# ---------------------------------------------------------------------------
# Service
# ---------------------------------------------------------------------------
resource "aws_ecs_service" "app" {
  name            = "${local.name_prefix}-service"
  cluster         = var.cluster_id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = var.desired_count

  capacity_provider_strategy {
    capacity_provider = var.use_fargate_spot ? "FARGATE_SPOT" : "FARGATE"
    weight            = 100
  }

  network_configuration {
    subnets         = var.private_app_subnet_ids
    security_groups = [var.ecs_task_security_group_id]
    # no public IP — tasks are never directly internet-reachable, matching
    # the network design's private-app subnet routing (egress via NAT only)
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = var.target_group_arn
    container_name   = local.container_name
    container_port   = var.container_port
  }

  deployment_controller {
    type = "ECS" # native rolling update, not CODE_DEPLOY — see architecture Phase 2 for the Blue/Green trade-off discussion
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true # failed health checks during a deploy -> automatic rollback to the previous task definition revision, no human in the loop
  }

  deployment_maximum_percent         = 200 # can briefly run double capacity during a deploy
  deployment_minimum_healthy_percent = 100 # never drop below current capacity mid-deploy

  health_check_grace_period_seconds = 30 # give the JVM a moment to actually start before the ALB's health check can fail it

  # See the design note above this module: CI owns which revision is
  # running after the first apply; Application Auto Scaling owns the count.
  # Terraform stops trying to reconcile either after initial creation.
  lifecycle {
    ignore_changes = [task_definition, desired_count]
  }

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-service" })
}

# ---------------------------------------------------------------------------
# Auto Scaling
# ---------------------------------------------------------------------------
resource "aws_appautoscaling_target" "ecs" {
  service_namespace  = "ecs"
  resource_id        = "service/${var.cluster_name}/${aws_ecs_service.app.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = var.autoscaling_min_capacity
  max_capacity       = var.autoscaling_max_capacity
}

resource "aws_appautoscaling_policy" "cpu" {
  name               = "${local.name_prefix}-cpu-target-tracking"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.ecs.service_namespace
  resource_id        = aws_appautoscaling_target.ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value       = 60
    scale_in_cooldown  = 120
    scale_out_cooldown = 60 # scale out faster than we scale in — bias toward availability over cost on a spike
  }
}

# CPU alone misses I/O-bound pileups (e.g. slow DB queries under load that
# don't spike CPU but do spike request queuing) — a second signal on request
# volume per target catches that case.
resource "aws_appautoscaling_policy" "request_count" {
  name               = "${local.name_prefix}-request-count-target-tracking"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.ecs.service_namespace
  resource_id        = aws_appautoscaling_target.ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ALBRequestCountPerTarget"
      resource_label = "${element(split("loadbalancer/", var.alb_arn), 1)}/${element(split(":", var.target_group_arn), 5)}"
    }
    target_value       = 1000
    scale_in_cooldown  = 120
    scale_out_cooldown = 60
  }
}

# ---------------------------------------------------------------------------
# Alarms — tied to real operational decisions, not decoration (Phase 3.8)
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "high_cpu" {
  alarm_name          = "${local.name_prefix}-ecs-high-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = 60
  statistic           = "Average"
  threshold           = 75
  alarm_description   = "Sustained high CPU — autoscaling should already be reacting; this is the human-notification tripwire if it doesn't keep up"
  alarm_actions       = var.sns_alarm_topic_arn != null ? [var.sns_alarm_topic_arn] : []

  dimensions = {
    ClusterName = var.cluster_name
    ServiceName = aws_ecs_service.app.name
  }
}

resource "aws_cloudwatch_metric_alarm" "deployment_failure" {
  alarm_name          = "${local.name_prefix}-ecs-deployment-failed-tasks"
  comparison_operator = "LessThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "RunningTaskCount"
  namespace           = "ECS/ContainerInsights"
  period              = 60
  statistic           = "Minimum"
  threshold           = 0
  alarm_description   = "Running task count hit zero — service has no healthy tasks at all"
  alarm_actions       = var.sns_alarm_topic_arn != null ? [var.sns_alarm_topic_arn] : []
  treat_missing_data  = "breaching"

  dimensions = {
    ClusterName = var.cluster_name
    ServiceName = aws_ecs_service.app.name
  }
}
