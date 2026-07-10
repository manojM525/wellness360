output "certificate_arn" {
  description = "Validated cert ARN — use this in the ALB listener, not the unvalidated cert resource"
  value       = aws_acm_certificate_validation.this.certificate_arn
}

output "zone_id" {
  value = data.aws_route53_zone.this.zone_id
}

output "fqdn" {
  value = local.fqdn
}
