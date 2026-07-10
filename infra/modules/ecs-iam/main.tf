locals {
  name_prefix = "${var.project_name}-${var.environment}"

  common_tags = merge(var.tags, {
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "terraform"
  })

  ecs_tasks_trust_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "ecs-tasks.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# Task Execution Role — used by the ECS AGENT before your code runs: pulling
# the image from ECR, writing bootstrap logs to CloudWatch, decrypting and
# injecting Secrets Manager / Parameter Store values as container env vars.
# Naming matches "${project_name}-*-ecs-task*" so the global deploy role's
# iam:PassRole permission (scoped by that pattern) covers this without either
# stack needing to reference the other's state.
# ---------------------------------------------------------------------------
resource "aws_iam_role" "execution" {
  name               = "${local.name_prefix}-ecs-task-execution-role"
  assume_role_policy = local.ecs_tasks_trust_policy

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "execution_managed" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
  # This managed policy already covers: ecr:GetAuthorizationToken,
  # ecr:BatchGetImage, ecr:GetDownloadUrlForLayer, and
  # logs:CreateLogStream / logs:PutLogEvents. We only need to add secrets
  # access on top of it, below.
}

resource "aws_iam_role_policy" "execution_secrets" {
  count = length(var.secrets_manager_secret_arns) > 0 ? 1 : 0
  name  = "${local.name_prefix}-execution-secrets-policy"
  role  = aws_iam_role.execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadSpecificSecretsOnly"
        Effect   = "Allow"
        Action   = "secretsmanager:GetSecretValue"
        Resource = var.secrets_manager_secret_arns # exact ARNs, never "*"
      }
    ]
  })
}

resource "aws_iam_role_policy" "execution_ssm" {
  count = length(var.ssm_parameter_arns) > 0 ? 1 : 0
  name  = "${local.name_prefix}-execution-ssm-policy"
  role  = aws_iam_role.execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadSpecificParametersOnly"
        Effect   = "Allow"
        Action   = ["ssm:GetParameters", "ssm:GetParameter"]
        Resource = var.ssm_parameter_arns
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# Task Role — used by the RUNNING APPLICATION CODE, if it ever calls an AWS
# API directly. Deliberately created with ZERO permissions attached: this app
# doesn't call any AWS SDK at runtime, so it gets none. If a future feature
# needs one (e.g. uploading a file to S3), add a narrowly-scoped policy HERE,
# not to the execution role — a compromised app container should never
# inherit ECR pull or Secrets Manager read access just because it happened to
# share a role with the startup bootstrap process.
# ---------------------------------------------------------------------------
resource "aws_iam_role" "task" {
  name               = "${local.name_prefix}-ecs-task-role"
  assume_role_policy = local.ecs_tasks_trust_policy

  tags = local.common_tags
}
