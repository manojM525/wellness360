terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Same rationale as bootstrap/ and global/dns/: this is applied once, kept
  # out of the per-environment (dev/prod) pipeline. One repository serves both
  # environments — the whole point of build-once/promote-by-reference is that
  # dev and prod pull the SAME immutable image, just at different times.
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

variable "github_actions_role_arn" {
  description = "ARN of the GitHub OIDC-federated IAM role that CI uses to push images (built in the iam module — passed in here once that role exists)"
  type        = string
  default = "arn:aws:iam::329769990983:role/manoj-taskmaster-github-deploy-role"
}

variable "image_count_to_keep" {
  description = "How many tagged images to retain per lifecycle policy before expiring the oldest"
  type        = number
  default     = 20
}

resource "aws_ecr_repository" "app" {
  name = "${var.project_name}/app"

  # IMMUTABLE is what actually enforces the build-once/promote-by-reference
  # model at the registry level: once a tag (a Git SHA) is pushed, it can
  # never be overwritten. This is what makes "deployed image tag" a reliable
  # audit trail instead of a moving target like `:latest` would be.
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true # Trivy runs in CI too, but this is a second, independent check on the artifact that actually landed in the registry
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  force_delete = false # never let a `terraform destroy` silently wipe every image in the registry

  tags = {
    Project   = var.project_name
    ManagedBy = "terraform"
  }
}

# Repository policy: CI (via its OIDC role) can push; anything in this AWS
# account can pull (ECS task execution roles in dev and prod both need to,
# and scoping pull to specific role ARNs adds complexity without a real
# security benefit inside a single account boundary).
data "aws_caller_identity" "current" {}

resource "aws_ecr_repository_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowPullWithinAccount"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action = [
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:BatchCheckLayerAvailability"
        ]
      },
      {
        Sid       = "AllowCIPush"
        Effect    = "Allow"
        Principal = { AWS = var.github_actions_role_arn }
        Action = [
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage"
        ]
      }
    ]
  })
}

# Lifecycle policy: cost + hygiene control. Untagged images (failed/superseded
# pushes) expire fast; we keep only the most recent N *tagged* images so the
# registry doesn't grow unbounded while every commit's image lives forever.
resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 1 day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep only the most recent ${var.image_count_to_keep} tagged images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["sha-"] # matches the git-sha tagging convention used by CI
          countType     = "imageCountMoreThan"
          countNumber   = var.image_count_to_keep
        }
        action = { type = "expire" }
      }
    ]
  })
}

output "repository_url" {
  value = aws_ecr_repository.app.repository_url
}

output "repository_arn" {
  value = aws_ecr_repository.app.arn
}
