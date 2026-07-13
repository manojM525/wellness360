output "vpc_id" {
  value = module.network.vpc_id
}

output "public_subnet_ids" {
  value = module.network.public_subnet_ids
}

output "private_app_subnet_ids" {
  value = module.network.private_app_subnet_ids
}

output "private_data_subnet_ids" {
  value = module.network.private_data_subnet_ids
}

output "alb_security_group_id" {
  value = module.security_groups.alb_security_group_id
}

output "ecs_task_security_group_id" {
  value = module.security_groups.ecs_task_security_group_id
}

output "rds_security_group_id" {
  value = module.security_groups.rds_security_group_id
}

output "acm_certificate_arn" {
  value = module.acm_dns.certificate_arn
}

output "route53_zone_id" {
  value = module.acm_dns.zone_id
}

output "app_fqdn" {
  value = module.acm_dns.fqdn
}

output "db_address" {
  value = module.rds.db_address
}

output "db_master_user_secret_arn" {
  value = module.rds.master_user_secret_arn
}

output "ecs_task_execution_role_arn" {
  value = module.ecs_iam.execution_role_arn
}

output "ecs_task_role_arn" {
  value = module.ecs_iam.task_role_arn
}

output "alb_dns_name" {
  value = module.alb.alb_dns_name
}

output "alb_target_group_arn" {
  value = module.alb.target_group_arn
}

output "ecs_cluster_name" {
  value = module.ecs_cluster.cluster_name
}

output "ecs_service_name" {
  value = module.ecs_service.service_name
}

output "ecs_task_definition_family" {
  value = module.ecs_service.task_definition_family
}

output "amp_workspace_id" {
  value = module.observability.workspace_id
}
