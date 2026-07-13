locals {
  name_prefix = "${var.project_name}-${var.environment}"

  common_tags = merge(var.tags, {
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "terraform"
  })
}

resource "aws_db_subnet_group" "this" {
  name       = "${local.name_prefix}-db-subnet-group"
  subnet_ids = var.private_data_subnet_ids

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-db-subnet-group" })
}

resource "aws_db_instance" "this" {
  identifier = "${local.name_prefix}-mysql"

  engine         = "mysql"
  engine_version = var.engine_version
  instance_class = var.instance_class

  allocated_storage = var.allocated_storage
  storage_type      = "gp3"
  storage_encrypted = true # encryption at rest — non-negotiable for any RDS instance holding app data

  db_name  = var.db_name
  username = var.master_username

  # RDS-native master password management: AWS generates and stores the
  # password in Secrets Manager itself, with rotation support built in.
  # Chosen over manually generating a `random_password` + separate
  # `aws_secretsmanager_secret` because it's less custom code, the password
  # never appears as a plain Terraform resource attribute, and rotation is a
  # config flag away instead of something we'd have to build ourselves.
  manage_master_user_password = true

  multi_az               = var.multi_az
  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [var.security_group_id]
  publicly_accessible    = false # non-negotiable — reinforced further by the private-data route table having no internet route at all

  backup_retention_period    = var.backup_retention_period
  auto_minor_version_upgrade = true
  copy_tags_to_snapshot      = true

  deletion_protection       = var.deletion_protection
  skip_final_snapshot       = var.skip_final_snapshot
  final_snapshot_identifier = "${local.name_prefix}-final-snapshot"

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-mysql" })
}

# --- Non-secret connection config in Parameter Store, per the earlier
# decision: host/port/db name aren't secrets, so they don't belong in
# Secrets Manager (which bills per secret) — Parameter Store Standard tier
# is free and the right tool for plain config. ---
resource "aws_ssm_parameter" "db_host" {
  name  = "/${var.project_name}/${var.environment}/db/host"
  type  = "String"
  value = aws_db_instance.this.address

  tags = local.common_tags
}

resource "aws_ssm_parameter" "db_port" {
  name  = "/${var.project_name}/${var.environment}/db/port"
  type  = "String"
  value = tostring(aws_db_instance.this.port)

  tags = local.common_tags
}

resource "aws_ssm_parameter" "db_name" {
  name  = "/${var.project_name}/${var.environment}/db/name"
  type  = "String"
  value = aws_db_instance.this.db_name

  tags = local.common_tags
}
