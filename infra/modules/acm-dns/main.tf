locals {
  fqdn = var.subdomain != "" ? "${var.subdomain}.${var.domain_name}" : var.domain_name

  common_tags = merge(var.tags, {
    Environment = var.environment
    ManagedBy   = "terraform"
  })
}

# Looks up the zone created once in global/dns — deliberately a data source,
# not a module reference, so this environment's state has zero dependency on
# global/dns's state file. Any environment can look up the same zone independently.
data "aws_route53_zone" "this" {
  name         = var.domain_name
  private_zone = false
}

resource "aws_acm_certificate" "this" {
  domain_name       = local.fqdn
  validation_method = "DNS"

  tags = merge(local.common_tags, { Name = "${var.environment}-${local.fqdn}-cert" })

  lifecycle {
    create_before_destroy = true # avoid a window with no valid cert during cert rotation
  }
}

# ACM gives back one or more CNAME records to prove domain ownership.
# for_each here (keyed by domain_name) handles both the single-domain case
# and, if SANs are added later, multiple validation records without code changes.
resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.this.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id         = data.aws_route53_zone.this.zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true # safe to re-run if a previous partial apply already created it
}

# Blocks until AWS confirms the CNAME(s) were seen and the cert is issued —
# downstream resources (the ALB listener) should depend on THIS, not on
# aws_acm_certificate.this directly, or you can end up attaching a
# not-yet-validated cert to a listener.
resource "aws_acm_certificate_validation" "this" {
  certificate_arn         = aws_acm_certificate.this.arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}
