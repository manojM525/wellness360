terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Same reasoning as bootstrap/: this is a one-time, manually-applied step,
  # deliberately outside the per-environment (dev/prod) apply pipeline.
  # A hosted zone shouldn't be destroyed just because an environment is torn
  # down and rebuilt — it has its own, longer lifecycle.
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "domain_name" {
  description = "The root domain you registered (e.g. taskmaster-devops.com). Registration itself is a manual step — done via Route53 or an external registrar with NS records pointed at this zone."
  type        = string
}

resource "aws_route53_zone" "primary" {
  name = var.domain_name

  lifecycle {
    prevent_destroy = true
  }
}

output "zone_id" {
  value = aws_route53_zone.primary.zone_id
}

output "name_servers" {
  description = "Point your registrar's NS records at these if the domain wasn't registered directly in Route53"
  value       = aws_route53_zone.primary.name_servers
}
