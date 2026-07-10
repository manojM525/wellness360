terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Deliberately NO backend block here.
  # This config's own state stays local (or, once created, can be migrated into
  # the very bucket it provisions — a one-time manual `terraform init -migrate-state`).
  # It must NOT be re-applied as part of the normal per-environment pipeline.
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  description = "AWS region for the state backend resources"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Used as a naming prefix for the state bucket and lock table"
  type        = string
  default     = "taskmaster"
}

# --- S3 bucket for Terraform state ---
# Versioning: lets us recover a previous state file if a bad apply corrupts it.
# Encryption: state files can contain sensitive values (e.g. RDS endpoint, ARNs) —
#             SSE-S3 here is sufficient since nothing secret is stored in state
#             (DB password comes from Secrets Manager, referenced by ARN, not by value).
# Public access block: state must never be reachable outside this AWS account.
resource "aws_s3_bucket" "tf_state" {
  bucket = "${var.project_name}-terraform-state"

  lifecycle {
    prevent_destroy = true # guardrail: an accidental `destroy` here would be catastrophic
  }
}

resource "aws_s3_bucket_versioning" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tf_state" {
  bucket                  = aws_s3_bucket.tf_state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# --- DynamoDB table for state locking ---
# PAY_PER_REQUEST: lock/unlock traffic is bursty and low-volume — provisioned
# capacity would mean paying for idle throughput almost all the time.
# "LockID" (String) is the exact partition key name/type Terraform's S3 backend expects.
resource "aws_dynamodb_table" "tf_lock" {
  name         = "${var.project_name}-terraform-locks"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  lifecycle {
    prevent_destroy = true
  }
}

output "state_bucket_name" {
  value = aws_s3_bucket.tf_state.id
}

output "lock_table_name" {
  value = aws_dynamodb_table.tf_lock.name
}
