output "alb_arn" {
  value = aws_lb.this.arn
}

output "alb_dns_name" {
  value = aws_lb.this.dns_name
}

output "alb_zone_id" {
  description = "The ALB's own hosted zone ID (needed for a Route53 alias record — different from your domain's zone_id)"
  value       = aws_lb.this.zone_id
}

output "target_group_arn" {
  value = aws_lb_target_group.app.arn
}
