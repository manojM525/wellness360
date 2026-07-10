variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "secrets_manager_secret_arns" {
  description = "Secrets the execution role may read and inject into the container at startup (e.g. the RDS master user secret). Scoped exactly — never a wildcard."
  type        = list(string)
  default     = []
}

variable "ssm_parameter_arns" {
  description = "Parameter Store values the execution role may read and inject (e.g. db host/port/name)"
  type        = list(string)
  default     = []
}

variable "tags" {
  type    = map(string)
  default = {}
}
