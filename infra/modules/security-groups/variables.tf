variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "vpc_id" {
  description = "VPC to create these security groups in (from the network module output)"
  type        = string
}

variable "app_port" {
  description = "Port the Spring Boot container listens on"
  type        = number
  default     = 8080
}

variable "db_port" {
  description = "MySQL port"
  type        = number
  default     = 3306
}

variable "tags" {
  type    = map(string)
  default = {}
}
