terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Same one-time, out-of-pipeline pattern as bootstrap/, global/dns/,
  # global/ecr/, global/iam-ci/ — a shared dashboard workspace has no natural
  # per-environment lifecycle of its own.
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "project_name" {
  type    = string
  default = "manoj-taskmaster"
}

# ---------------------------------------------------------------------------
# IAM role Grafana assumes to query data sources. Using AWS's own managed
# policies here rather than a hand-rolled ABAC/tag-scoped policy — this is
# what AWS's own AMG setup guidance recommends, it's well-documented, and
# it avoids a real state-ordering problem: a tag- or ARN-scoped policy would
# need to know about the dev and prod AMP workspace ARNs, which live in
# separate, independently-applied state. AmazonPrometheusQueryAccess grants
# read/query access to every AMP workspace in the account — broader than a
# hand-scoped policy would be, and an explicit trade-off worth being able to
# name: convenience and decoupled state vs. tighter per-workspace scoping.
# ---------------------------------------------------------------------------
resource "aws_iam_role" "grafana" {
  name = "${var.project_name}-grafana-workspace-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "grafana.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "prometheus_query" {
  role       = aws_iam_role.grafana.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonPrometheusQueryAccess"
}

resource "aws_iam_role_policy_attachment" "cloudwatch_access" {
  role       = aws_iam_role.grafana.name
  # CORRECTED: the original ARN here (AmazonGrafanaCloudWatchAccess) does not
  # exist — it was a fabricated policy name and failed on a real apply with
  # NoSuchEntity. CloudWatchReadOnlyAccess is a real, standard AWS managed
  # policy and the correct fix.
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchReadOnlyAccess"
}

# ---------------------------------------------------------------------------
# The workspace itself.
#
# CORRECTED: permission_type must be CUSTOMER_MANAGED for the custom
# aws_iam_role.grafana above to actually be the role Grafana uses.
# SERVICE_MANAGED (the original value here) tells AWS to auto-generate and
# manage its own IAM role and policy attachments instead — our hand-built
# role would have been silently unused dead configuration in that mode,
# which is why the workspace still finished creating even while the
# (broken) policy attachment resource failed: the workspace never actually
# depended on our role under SERVICE_MANAGED. CUSTOMER_MANAGED is also the
# more defensible choice given everything else in this project explicitly
# scopes IAM rather than accepting an AWS-managed default — see the
# execution/task role split and the two CI roles for the same reasoning.
#
# REAL PREREQUISITE, still applies regardless of the fix above:
# authentication_providers = ["AWS_SSO"] requires AWS IAM Identity Center to
# already be enabled for this AWS account/organization — that's an
# account-level, largely one-time-and-manual toggle. If it isn't enabled,
# this resource will fail to create. The alternative is a SAML identity
# provider, which is a separate, larger integration.
# ---------------------------------------------------------------------------
resource "aws_grafana_workspace" "this" {
  name                     = "${var.project_name}-observability"
  account_access_type      = "CURRENT_ACCOUNT"
  authentication_providers = ["AWS_SSO"]
  permission_type          = "CUSTOMER_MANAGED"
  role_arn                 = aws_iam_role.grafana.arn
  data_sources             = ["PROMETHEUS", "CLOUDWATCH"]

  tags = {
    Project   = var.project_name
    ManagedBy = "terraform"
  }
}

output "grafana_workspace_id" {
  value = aws_grafana_workspace.this.id
}

output "grafana_endpoint" {
  value = aws_grafana_workspace.this.endpoint
}