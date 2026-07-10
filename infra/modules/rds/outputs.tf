output "db_instance_id" {
  value = aws_db_instance.this.id
}

output "db_address" {
  value = aws_db_instance.this.address
}

output "db_port" {
  value = aws_db_instance.this.port
}

output "db_name" {
  value = aws_db_instance.this.db_name
}

# The ARN of the RDS-managed Secrets Manager secret holding the master
# password — the ECS task execution role (built in the iam module) will need
# secretsmanager:GetSecretValue scoped to exactly this ARN.
output "master_user_secret_arn" {
  value = aws_db_instance.this.master_user_secret[0].secret_arn
}

output "ssm_db_host_param_name" {
  value = aws_ssm_parameter.db_host.name
}

output "ssm_db_port_param_name" {
  value = aws_ssm_parameter.db_port.name
}

output "ssm_db_name_param_name" {
  value = aws_ssm_parameter.db_name.name
}
