variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "public_subnet_ids" {
  type = list(string)
}

variable "alb_security_group_id" {
  type = string
}

variable "certificate_arn" {
  description = "Validated ACM cert ARN from the acm-dns module — the HTTPS listener refuses to be created without this"
  type        = string
}

variable "app_port" {
  type    = number
  default = 8080
}

variable "health_check_path" {
  description = "Requires spring-boot-starter-actuator in the app — see Phase 1 findings"
  type        = string
  default     = "/actuator/health"
}

variable "alb_deletion_protection" {
  description = "true for prod, false for dev — explicit, not inferred"
  type        = bool
}

variable "tags" {
  type    = map(string)
  default = {}
}
