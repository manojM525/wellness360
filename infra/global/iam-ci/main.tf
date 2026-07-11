terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Same one-time, out-of-pipeline pattern as bootstrap/, global/dns/, global/ecr/.
  # These roles are what the rest of the pipeline authenticates with, so they
  # can't be created BY the pipeline they're needed to run.
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

variable "github_org" {
  type = string
  default = "manojM525"
}

variable "github_repo" {
  type = string
  default = "wellness360"
}

data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------------------
# GitHub OIDC provider — this is what lets GitHub Actions assume an AWS role
# using a short-lived token instead of a long-lived AWS access key stored as
# a GitHub Secret. One provider per AWS account; if your account already has
# one (e.g. from a prior project), this resource would conflict — check first.
# ---------------------------------------------------------------------------
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  # GitHub's OIDC root CA thumbprint. AWS no longer strictly validates this
  # value against the actual cert chain for GitHub's provider, but the API
  # still requires a well-formed value here — confirm against GitHub's current
  # docs at deploy time in case it's rotated.
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

locals {
  # Scope trust to specific branches only — main (-> prod) and develop (-> dev).
  # A StringLike condition on `sub` with these exact values means a workflow
  # run from any other branch, or a fork's PR, cannot assume either role.
  allowed_subjects = [
    "repo:${var.github_org}/${var.github_repo}:ref:refs/heads/main",
    "repo:${var.github_org}/${var.github_repo}:ref:refs/heads/develop",
  ]

  oidc_trust_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
        Action    = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            "token.actions.githubusercontent.com:sub" = local.allowed_subjects
          }
        }
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# Role 1: Terraform apply role — BROAD, because Terraform genuinely needs to
# create/update/delete across many AWS services to manage full infra
# lifecycle. This is a real, known limit of "least privilege": you can scope
# WHO can trigger this (branch-restricted OIDC trust, environment protection
# rules with required reviewers on prod) far more effectively than you can
# scope WHAT a general-purpose IaC role is allowed to touch action-by-action.
# I'm separating this from the deploy role specifically so that the everyday
# CI/CD path (build, push, deploy) never holds infrastructure-modifying
# permissions at all.
# ---------------------------------------------------------------------------
resource "aws_iam_role" "terraform_apply" {
  name               = "${var.project_name}-github-terraform-role"
  assume_role_policy = local.oidc_trust_policy
}

resource "aws_iam_role_policy" "terraform_apply" {
  name = "${var.project_name}-terraform-apply-policy"
  role = aws_iam_role.terraform_apply.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "InfraServicesBroad"
        Effect = "Allow"
        Action = [
          "ec2:*",
          "rds:*",
          "ecs:*",
          "elasticloadbalancing:*",
          "ecr:*",
          "logs:*",
          "ssm:*",
          "secretsmanager:*",
          "route53:*",
          "acm:*",
          "application-autoscaling:*",
          "cloudwatch:*",
        ]
        Resource = "*"
      },
      {
        # IAM is the one category kept name-scoped rather than wide open —
        # this role can manage roles/policies THIS project creates, and
        # nothing else in the account.
        Sid    = "IAMScopedToProjectResources"
        Effect = "Allow"
        Action = [
          "iam:CreateRole",
          "iam:DeleteRole",
          "iam:GetRole",
          "iam:PutRolePolicy",
          "iam:DeleteRolePolicy",
          "iam:GetRolePolicy",
          "iam:AttachRolePolicy",
          "iam:DetachRolePolicy",
          "iam:ListRolePolicies",
          "iam:ListAttachedRolePolicies",
          "iam:TagRole",
          "iam:PassRole",
        ]
        Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project_name}-*"
      },
      {
        Sid    = "TerraformStateBackend"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:ListBucket",
        ]
        Resource = [
          "arn:aws:s3:::${var.project_name}-terraform-state",
          "arn:aws:s3:::${var.project_name}-terraform-state/*",
        ]
      },
      {
        Sid    = "TerraformStateLock"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:DeleteItem",
        ]
        Resource = "arn:aws:dynamodb:${var.aws_region}:${data.aws_caller_identity.current.account_id}:table/${var.project_name}-terraform-locks"
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# Role 2: Build-and-deploy role — everything the ordinary CI run needs
# (push an image, roll out a new ECS task definition revision) and NOTHING
# that can modify infrastructure. This is the role used on every normal
# commit; terraform_apply is only assumed on the explicit infra-change jobs.
# ---------------------------------------------------------------------------
resource "aws_iam_role" "deploy" {
  name               = "${var.project_name}-github-deploy-role"
  assume_role_policy = local.oidc_trust_policy
}

resource "aws_iam_role_policy" "deploy" {
  name = "${var.project_name}-deploy-policy"
  role = aws_iam_role.deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ECRAuth"
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken" # not resource-scopable; account-level action
        Resource = "*"
      },
      {
        Sid    = "ECSDeploy"
        Effect = "Allow"
        Action = [
          "ecs:UpdateService",
          "ecs:DescribeServices",
          "ecs:RegisterTaskDefinition",
          "ecs:DescribeTaskDefinition",
          "ecs:DescribeTasks",
          "ecs:ListTasks",
        ]
        Resource = "*" # ECS register/describe task definition actions don't support resource-level scoping
      },
      {
        # RegisterTaskDefinition and UpdateService need to pass the task role
        # and execution role to ECS. Scoped by naming pattern (not literal
        # ARNs) so this role doesn't need to know about per-environment IAM
        # resources created after this one — see ecs-iam module naming.
        Sid      = "PassECSRoles"
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project_name}-*-ecs-task*"
      }
    ]
  })
}

output "terraform_apply_role_arn" {
  value = aws_iam_role.terraform_apply.arn
}

output "deploy_role_arn" {
  value = aws_iam_role.deploy.arn
}
