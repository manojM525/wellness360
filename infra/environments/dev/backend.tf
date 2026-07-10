terraform {
  required_version = ">= 1.9.0"

  backend "s3" {
    bucket         = "manoj-taskmaster-terraform-state" # from bootstrap output: state_bucket_name
    key            = "dev/terraform.tfstate"      # env-scoped key — this is what isolates dev's state from prod's
    region         = "us-east-1"
    dynamodb_table = "manoj-taskmaster-terraform-locks"  # from bootstrap output: lock_table_name
    encrypt        = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
