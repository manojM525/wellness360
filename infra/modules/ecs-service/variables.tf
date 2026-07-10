variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "cluster_id" {
  type = string
}

variable "cluster_name" {
  type = string
}

variable "private_app_subnet_ids" {
  type = list(string)
}

variable "ecs_task_security_group_id" {
  type = string
}

variable "target_group_arn" {
  type = string
}

variable "execution_role_arn" {
  type = string
}

variable "task_role_arn" {
  type = string
}

variable "ecr_repository_url" {
  type = string
}

variable "image_tag" {
  description = "Git-SHA tag for the initial/bootstrap deploy only — CI owns this afterward (see lifecycle.ignore_changes on the service)"
  type        = string
  default     = "initial"
}

variable "container_port" {
  type    = number
  default = 8080
}

variable "task_cpu" {
  description = "e.g. 256 for dev, 512 for prod"
  type        = number
}

variable "task_memory" {
  description = "e.g. 512 for dev, 1024 for prod"
  type        = number
}

variable "desired_count" {
  description = "Initial count only — Application Auto Scaling owns this afterward"
  type        = number
}

variable "autoscaling_min_capacity" {
  type = number
}

variable "autoscaling_max_capacity" {
  type = number
}

variable "use_fargate_spot" {
  description = "true for dev (cost), false for prod (predictable capacity/availability)"
  type        = bool
}

variable "log_retention_days" {
  description = "7 for dev, 30 for prod"
  type        = number
}

# --- DB connection injection: SSM for non-secret config, Secrets Manager for credentials ---
variable "db_host_ssm_arn" {
  type = string
}

variable "db_port_ssm_arn" {
  type = string
}

variable "db_name_ssm_arn" {
  type = string
}

variable "db_secret_arn" {
  description = "RDS-managed master user secret ARN (JSON keys: username, password, host, port, dbname, ...)"
  type        = string
}

variable "sns_alarm_topic_arn" {
  description = "Optional — if set, CloudWatch alarms notify this topic"
  type        = string
  default     = null
}

variable "tags" {
  type    = map(string)
  default = {}
}
