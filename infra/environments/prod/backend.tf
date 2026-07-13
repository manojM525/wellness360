terraform {
  required_version = ">= 1.9.0"

  backend "s3" {
    bucket         = "manoj-taskmaster-terraform-state" # from bootstrap output: state_bucket_name
    key            = "prod/terraform.tfstate"           # env-scoped key — isolates prod's state from dev's
    region         = "us-east-1"
    dynamodb_table = "taskmaster-terraform-locks" # from bootstrap output: lock_table_name
    encrypt        = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
