variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "private_data_subnet_ids" {
  description = "From the network module — RDS subnet group lives entirely in the private-data tier"
  type        = list(string)
}

variable "security_group_id" {
  description = "The RDS security group from the security-groups module"
  type        = string
}

variable "engine_version" {
  type    = string
  default = "8.0"
}

variable "instance_class" {
  description = "e.g. db.t4g.micro for dev, db.t4g.small for prod"
  type        = string
}

variable "allocated_storage" {
  type    = number
  default = 20
}

variable "multi_az" {
  description = "Explicit per-environment decision, not inferred from environment name"
  type        = bool
}

variable "backup_retention_period" {
  description = "Days of automated backups to retain"
  type        = number
  default     = 7
}

variable "deletion_protection" {
  description = "Should be true for prod, false for dev — explicit input, not inferred"
  type        = bool
}

variable "skip_final_snapshot" {
  description = "true for dev (fast teardown), false for prod (always snapshot before delete)"
  type        = bool
}

variable "db_name" {
  type    = string
  default = "taskmaster"
}

variable "master_username" {
  type    = string
  default = "taskmaster_admin"
}

variable "tags" {
  type    = map(string)
  default = {}
}
