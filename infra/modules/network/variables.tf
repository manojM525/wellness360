variable "environment" {
  description = "Environment name (dev, prod) — used in resource names and tags"
  type        = string

  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "environment must be one of: dev, prod."
  }
}

variable "project_name" {
  description = "Project name, used as a naming/tagging prefix"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC (e.g. 10.10.0.0/16 for dev, 10.20.0.0/16 for prod)"
  type        = string

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid CIDR block."
  }
}

variable "availability_zones" {
  description = "AZs to spread subnets across — exactly 2 per the HA/cost trade-off decided in the architecture design"
  type        = list(string)

  validation {
    condition     = length(var.availability_zones) == 2
    error_message = "This module is designed for exactly 2 AZs (see architecture doc, section 3.1)."
  }
}

variable "public_subnet_cidrs" {
  description = "CIDR per AZ for public subnets (ALB, NAT). List order must match availability_zones."
  type        = list(string)
}

variable "private_app_subnet_cidrs" {
  description = "CIDR per AZ for private application subnets (ECS tasks)."
  type        = list(string)
}

variable "private_data_subnet_cidrs" {
  description = "CIDR per AZ for private data subnets (RDS only)."
  type        = list(string)
}

variable "single_nat_gateway" {
  description = "If true, provisions one NAT Gateway (dev — cost-optimized, documented AZ-dependency trade-off). If false, one NAT per AZ (prod — full AZ independence)."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Common tags applied to every resource this module creates"
  type        = map(string)
  default     = {}
}
