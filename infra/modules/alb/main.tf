locals {
  name_prefix = "${var.project_name}-${var.environment}"

  common_tags = merge(var.tags, {
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "terraform"
  })
}

resource "aws_lb" "this" {
  name               = "${local.name_prefix}-alb"
  internal           = false
  load_balancer_type = "application"
  subnets            = var.public_subnet_ids
  security_groups    = [var.alb_security_group_id]

  enable_deletion_protection = var.alb_deletion_protection

  # NOTE: access logging to S3 is deliberately not implemented in this pass —
  # flagging it explicitly as a documented gap rather than a silent omission.
  # It's a straightforward addition (a bucket + bucket policy + this block)
  # and worth adding before this is genuinely production-facing.

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-alb" })
}

# type = "ip" is mandatory for Fargate: tasks don't correspond to a registered
# EC2 instance, so targets are registered by ENI IP address directly.
resource "aws_lb_target_group" "app" {
  name        = "${local.name_prefix}-tg"
  port        = var.app_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    path                = var.health_check_path
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  # Short deregistration delay: when ECS drains a task during a deploy, this
  # is how long the ALB keeps sending it traffic after marking it for
  # removal. 30s balances "let in-flight requests finish" against "don't
  # slow down every rolling deployment by minutes" (the AWS default is 300s,
  # which is needlessly slow for a stateless API with no long-lived requests).
  deregistration_delay = 30

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-tg" })
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06" # modern policy: TLS 1.2 minimum, TLS 1.3 supported
  certificate_arn   = var.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }

  tags = local.common_tags
}

# Port 80 exists ONLY to redirect. It never forwards traffic to a target —
# there is no plaintext path to the application anywhere in this design.
resource "aws_lb_listener" "http_redirect" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }

  tags = local.common_tags
}
