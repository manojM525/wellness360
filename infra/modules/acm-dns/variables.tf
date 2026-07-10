variable "domain_name" {
  description = "Root domain (must match the zone created in global/dns), e.g. taskmaster-devops.com"
  type        = string
}

variable "subdomain" {
  description = "Subdomain for this environment, e.g. 'dev' -> dev.taskmaster-devops.com. Leave empty for the root domain (typically prod)."
  type        = string
  default     = ""
}

variable "environment" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
