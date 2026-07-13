# Taskmaster Platform — Operator Runbook

This document is written so that someone who has never seen this repository
before can clone it and stand up the entire system — dev and prod, infra,
CI/CD, and observability — without hitting any of the issues that were found
and fixed during the original build. Follow it top to bottom, in order.

**Repo**: `manojM525/wellness360` (monorepo: `infra/` + `taskmaster/` + `.github/`)
**Region**: `us-east-1`
**Project name prefix**: `manoj-taskmaster`

Throughout this document, `<your-registered-domain>` means a domain you
actually own — substitute it everywhere it appears.

---

## 1. System Overview

```
GitHub repo (manojM525/wellness360, monorepo: infra/ + taskmaster/)
   │
   ▼
GitHub Actions (OIDC -> AWS IAM Role, no static AWS keys anywhere)
   │
   ├─ app-pipeline.yml:  test -> build/scan(Trivy)/push(ECR) -> deploy(ECS) -> smoke test
   └─ infra-pipeline.yml: fmt/validate -> plan (posted as PR comment) -> apply (on merge)
                                                                                    │
                                                                                    ▼
                                                              ECS Service (Fargate) in private subnets
                                                                     │            │
                                                              ┌──────┘            └──────┐
                                                              ▼                          ▼
                                                        ALB (public subnets)      RDS MySQL (private-data subnet)
                                                              │                          ▲
                                                              ▼                          │
                                                         Internet users          Secrets Manager (RDS-managed secret)

Per ECS task, two containers:
  app             -> serves the REST API (/api/tasks) + static UI (/) + /actuator/health + /actuator/prometheus
  adot-collector  -> scrapes app's /actuator/prometheus locally, remote-writes (SigV4) to that
                     environment's AMP workspace. essential=false: its failure never takes the app down.

AMG (one shared Grafana workspace) queries both AMP workspaces + CloudWatch for dashboards.
All container stdout (JSON) -> awslogs driver -> CloudWatch Logs.
```

### The Global vs. Per-Environment split

Not everything lives inside `environments/dev`/`environments/prod`. Five
stacks are shared across both environments, applied **once**, each in its
own separate Terraform state:

| Location | Creates | Why it's global |
|---|---|---|
| `infra/bootstrap/` | S3 state bucket + DynamoDB lock table | Can't be created by the very state it holds |
| `infra/global/dns/` | Route53 hosted zone | One domain, not one per environment |
| `infra/global/iam-ci/` | GitHub OIDC provider + `terraform-apply` role + `deploy` role | One CI pipeline serves both environments |
| `infra/global/ecr/` | ECR repository | Build-once/promote-by-reference needs exactly ONE repository — dev and prod deploy the identical immutable image, just at different times |
| `infra/global/observability/` | AMG (Grafana) workspace | One dashboard pane across both environments |

Everything else — VPC, security groups, ACM cert, RDS, ECS cluster/service,
per-environment IAM (task execution/task roles), AMP workspace — lives in
`infra/environments/dev/` and `infra/environments/prod/`, each with its own
state file under the one shared S3 backend.

**Required apply order** — each stage must fully exist before the next:
```
bootstrap → global/dns → global/iam-ci → global/ecr → global/observability
                                                           → environments/dev
                                                           → environments/prod
```
`global/ecr` specifically needs `global/iam-ci`'s `deploy_role_arn` output
(it's granted push access in the repository policy) — hence that ordering.

---

## 2. Prerequisites

- AWS account, AWS CLI v2 configured locally with sufficient permissions for
  the one-time manual steps below (account admin or equivalent is simplest).
- Terraform >= 1.9.0.
- Docker, JDK 17, Maven (for local application work only — CI does this for you).
- A registered domain, either directly in Route53 or elsewhere with NS
  records pointable at a Route53 zone.
- **AWS IAM Identity Center (SSO) enabled** on the account *before* attempting
  `global/observability` — this is an account-level, one-time console toggle
  Terraform cannot perform for you (IAM Identity Center → Enable). If it
  isn't on, `aws_grafana_workspace` fails to create.
- A GitHub repository you control, with Actions enabled.
- **If on Windows using Git Bash/MINGW64**: run `export MSYS_NO_PATHCONV=1`
  in any shell session where you'll pass AWS CLI arguments starting with `/`
  (log group names, IAM paths, etc.) — Git Bash silently rewrites these as
  Windows paths otherwise, producing a confusing `InvalidParameterException`
  that has nothing to do with the actual command.

---

## 3. ⚠️ Required fix before first apply — `infra/global/iam-ci/main.tf`

**This is the single most important correction in this document.** The
version of this file that may currently be in the repository trusts only
branch-ref-shaped OIDC subjects. That breaks the moment any job declares
`environment:` (used by `deploy-dev`, `deploy-prod`, `apply-dev`,
`apply-prod` for GitHub Environment approval gates) — GitHub's OIDC token
`sub` claim changes shape entirely to `environment:{name}` in that case, not
`ref:refs/heads/{branch}`, and the old trust policy has never seen that
shape. Applying it as-is and then running the pipeline reproduces
`Error: Could not assume role with OIDC: Not authorized to perform
sts:AssumeRoleWithWebIdentity` exactly.

Before running `terraform apply` in Section 4, Step 3, replace
`infra/global/iam-ci/main.tf` with this corrected version:

```hcl
terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "project_name" {
  type    = string
  default = "manoj-taskmaster"
}

variable "github_org" {
  type    = string
  default = "manojM525"
}

variable "github_repo" {
  type    = string
  default = "wellness360"
}

data "aws_caller_identity" "current" {}

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

locals {
  # GitHub's OIDC `sub` claim shape depends on trigger AND on whether the job
  # declares `environment:` (which OVERRIDES the ref/pull_request shape
  # entirely, it does not add to it):
  #   push, no environment   -> repo:{org}/{repo}:ref:refs/heads/{branch}
  #   pull_request            -> repo:{org}/{repo}:pull_request
  #   job has `environment:`  -> repo:{org}/{repo}:environment:{env_name}
  terraform_apply_subjects = [
    "repo:${var.github_org}/${var.github_repo}:pull_request",
    "repo:${var.github_org}/${var.github_repo}:environment:development",
    "repo:${var.github_org}/${var.github_repo}:environment:production",
  ]

  deploy_subjects = [
    "repo:${var.github_org}/${var.github_repo}:ref:refs/heads/develop",
    "repo:${var.github_org}/${var.github_repo}:ref:refs/heads/main",
    "repo:${var.github_org}/${var.github_repo}:environment:development",
    "repo:${var.github_org}/${var.github_repo}:environment:production",
  ]

  terraform_apply_trust_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = { "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com" }
        StringLike   = { "token.actions.githubusercontent.com:sub" = local.terraform_apply_subjects }
      }
    }]
  })

  deploy_trust_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = { "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com" }
        StringLike   = { "token.actions.githubusercontent.com:sub" = local.deploy_subjects }
      }
    }]
  })
}

resource "aws_iam_role" "terraform_apply" {
  name               = "${var.project_name}-github-terraform-role"
  assume_role_policy = local.terraform_apply_trust_policy
}

resource "aws_iam_role_policy" "terraform_apply" {
  name = "${var.project_name}-terraform-apply-policy"
  role = aws_iam_role.terraform_apply.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "InfraServicesBroad"
        Effect = "Allow"
        Action = [
          "ec2:*", "rds:*", "ecs:*", "elasticloadbalancing:*", "ecr:*",
          "logs:*", "ssm:*", "secretsmanager:*", "route53:*", "acm:*",
          "application-autoscaling:*", "cloudwatch:*",
        ]
        Resource = "*"
      },
      {
        Sid    = "IAMScopedToProjectResources"
        Effect = "Allow"
        Action = [
          "iam:CreateRole", "iam:DeleteRole", "iam:GetRole",
          "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:GetRolePolicy",
          "iam:AttachRolePolicy", "iam:DetachRolePolicy",
          "iam:ListRolePolicies", "iam:ListAttachedRolePolicies",
          "iam:TagRole", "iam:PassRole",
        ]
        Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project_name}-*"
      },
      {
        Sid    = "TerraformStateBackend"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject", "s3:ListBucket"]
        Resource = [
          "arn:aws:s3:::${var.project_name}-terraform-state",
          "arn:aws:s3:::${var.project_name}-terraform-state/*",
        ]
      },
      {
        Sid      = "TerraformStateLock"
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem"]
        Resource = "arn:aws:dynamodb:${var.aws_region}:${data.aws_caller_identity.current.account_id}:table/${var.project_name}-terraform-locks"
      }
    ]
  })
}

resource "aws_iam_role" "deploy" {
  name               = "${var.project_name}-github-deploy-role"
  assume_role_policy = local.deploy_trust_policy
}

resource "aws_iam_role_policy" "deploy" {
  name = "${var.project_name}-deploy-policy"
  role = aws_iam_role.deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ECRAuth"
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Sid    = "ECSDeploy"
        Effect = "Allow"
        Action = [
          "ecs:UpdateService", "ecs:DescribeServices",
          "ecs:RegisterTaskDefinition", "ecs:DescribeTaskDefinition",
          "ecs:DescribeTasks", "ecs:ListTasks",
        ]
        Resource = "*"
      },
      {
        Sid      = "PassECSRoles"
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project_name}-*-ecs-task*"
      }
    ]
  })
}

output "terraform_apply_role_arn" {
  value = aws_iam_role.terraform_apply.arn
}

output "deploy_role_arn" {
  value = aws_iam_role.deploy.arn
}
```

---

## 4. One-time global infrastructure (apply in this exact order)

Each of these is applied once, manually, from your local machine — never
through the CI pipeline (the pipeline authenticates using roles some of
these steps create; they can't create themselves).

```bash
# 1. State backend
cd infra/bootstrap
terraform init
terraform apply
# Note outputs: state_bucket_name, lock_table_name

# 2. DNS zone
cd ../global/dns
terraform init
terraform apply -var="domain_name=<your-registered-domain>"
# Note output: name_servers
# If the domain is registered outside Route53, point your registrar's NS
# records at these now, before continuing — DNS propagation can take time,
# and ACM certificate validation later depends on this.

# 3. GitHub OIDC + CI roles (use the CORRECTED file from Section 3 above)
cd ../iam-ci
terraform init
terraform apply
# Note outputs: terraform_apply_role_arn, deploy_role_arn

# 4. ECR (needs the deploy role ARN from step 3)
cd ../ecr
terraform init
terraform apply -var="github_actions_role_arn=<deploy_role_arn from step 3>"
# Note output: repository_url

# 5. Observability — requires IAM Identity Center already enabled (Section 2)
cd ../observability
terraform init
terraform apply
# Note output: grafana_endpoint
```

If step 5 fails referencing authentication providers or SSO, stop, enable
IAM Identity Center in the AWS Console, then re-run.

---

## 5. Per-environment infrastructure

```bash
cd infra/environments/dev
terraform init
terraform apply
```

Read the plan before confirming. First apply typically takes 10-15 minutes
(RDS and the ADOT-sidecar-enabled ECS service are the slowest parts). This
creates: VPC (single NAT Gateway for dev), security groups, ACM cert +
Route53 validation record, RDS MySQL (single-AZ, no deletion protection),
ECS cluster + service (Fargate Spot, 1 task), per-environment IAM roles, AMP
workspace.

Repeat for prod:
```bash
cd ../prod
terraform init
terraform apply
```
Prod differs deliberately: one NAT Gateway per AZ, RDS Multi-AZ with
deletion protection and a mandatory final snapshot, ALB deletion protection
on, standard Fargate (not Spot), 2 tasks minimum for real HA, larger
CPU/memory allocation, 30-day log retention (vs. dev's 7).

**Expected, not a bug**: immediately after either apply, the ECS service
will crash-loop. The task definition points at `image_tag = "initial"`,
which doesn't exist in ECR yet — this resolves the moment Section 7's
pipeline pushes a real image.

---

## 6. GitHub repository configuration

### 6a. Create the `develop` branch
```bash
git checkout -b develop
git push -u origin develop
```

### 6b. Set repository Variables
Settings → Secrets and variables → Actions → **Variables** tab → New
repository variable, for each:

| Name | Value | Source |
|---|---|---|
| `AWS_REGION` | `us-east-1` | — |
| `AWS_DEPLOY_ROLE_ARN` | `deploy_role_arn` | Section 4, step 3 |
| `AWS_TERRAFORM_ROLE_ARN` | `terraform_apply_role_arn` | Section 4, step 3 |
| `ECR_REGISTRY` | everything before the last `/` in `repository_url` | Section 4, step 4 |
| `ECR_REPOSITORY` | everything after the last `/` in `repository_url` | Section 4, step 4 |
| `DEV_ECS_CLUSTER` | `terraform output ecs_cluster_name` | Section 5 (dev) |
| `DEV_ECS_SERVICE` | `terraform output ecs_service_name` | Section 5 (dev) |
| `DEV_ECS_TASK_FAMILY` | `terraform output ecs_task_definition_family` | Section 5 (dev) |
| `DEV_APP_URL` | `https://` + `terraform output app_fqdn` | Section 5 (dev) |
| `PROD_ECS_CLUSTER` / `PROD_ECS_SERVICE` / `PROD_ECS_TASK_FAMILY` / `PROD_APP_URL` | same pattern | Section 5 (prod) |

No secrets are required anywhere — authentication is entirely OIDC-based.

### 6c. Create GitHub Environments
Settings → Environments:
- **development** — create it, no protection rules needed.
- **production** — create it, then under *Deployment protection rules*
  enable **Required reviewers** and add at least one person. This is what
  actually makes `environment: production` in the workflow files pause for
  approval — without this step that line does nothing.

---

## 7. First real deploy

```bash
git checkout develop
git push origin develop
```

Watch the **Actions** tab with `develop` selected. Expected sequence:
`Lint & Test` → `Build, Scan, Push Image` → `Deploy to Dev` → smoke test
against `/actuator/health` then `/api/tasks`. This run is what resolves the
crash-loop from Section 5 — it's the first time a real image exists in ECR.

Once dev is green, merge `develop` into `main` (or push to `main` directly)
to trigger `Deploy to Prod` — it will pause in the Actions tab awaiting the
required reviewer's approval from Section 6c.

---

## 8. Verification checklist

```bash
# App + API
curl https://<dev-or-prod-fqdn>/actuator/health      # expect {"status":"UP"}
curl https://<dev-or-prod-fqdn>/api/tasks            # expect HAL+JSON with "_links"
# Browser: https://<dev-or-prod-fqdn>/                # expect the task-board UI, not raw JSON

# ADOT sidecar actually running (not just defined)
aws ecs describe-task-definition --task-definition manoj-taskmaster-<env>-app \
  --query 'taskDefinition.containerDefinitions[*].name'
# expect: ["app", "adot-collector"]

# Metrics reaching AMP (CloudWatch's own usage-metric emission lags real
# ingestion by several minutes — query AMP directly for an authoritative
# answer instead of waiting on CloudWatch):
eval $(aws configure export-credentials --format env)
curl --aws-sigv4 "aws:amz:us-east-1:aps" \
  --user "${AWS_ACCESS_KEY_ID}:${AWS_SECRET_ACCESS_KEY}" \
  -H "X-Amz-Security-Token: ${AWS_SESSION_TOKEN}" \
  -G "https://aps-workspaces.us-east-1.amazonaws.com/workspaces/<workspace-id>/api/v1/query" \
  --data-urlencode 'query=up'
# expect: a result with value "1"
```

**Grafana datasource (one-time, manual, per the observability module's own
design — AMG authenticates to AMP via SigV4/IAM, not a pasteable API key,
so this isn't Terraform-automated here):**
1. Open the `grafana_endpoint` output, sign in via IAM Identity Center.
2. Data sources → Add data source → Amazon Managed Service for Prometheus →
   select region + workspace → Save.
3. Explore → run `up` → confirm real data renders.

---

## 9. Operations quick reference

- **Logs**: `/ecs/manoj-taskmaster-dev` and `/ecs/manoj-taskmaster-prod`
  log groups, JSON-structured. Useful Insights query:
  ```
  fields @timestamp, message, logger_name
  | filter level = "ERROR"
  | sort @timestamp desc
  ```
- **A failed deploy** almost always means the ECS deployment circuit
  breaker rolled back automatically (`deployment_circuit_breaker { enable =
  true, rollback = true }` in the `ecs-service` module) — check
  `aws ecs describe-services ... --query 'services[0].events[0:15].message'`
  for the actual reason before assuming anything else.
- **Rollback**: `aws ecs update-service --cluster <cluster> --service
  <service> --task-definition <family>:<previous-revision>`.
- **No SSH anywhere** — Fargate has no host. Use ECS Exec / SSM Session
  Manager for container-level shell access if ever needed.
- **No long-lived AWS credentials anywhere in CI** — everything is OIDC.

---

## 10. Known issues already found and fixed (context for reviewers)

This list exists so nobody re-discovers these the hard way. Each was found
through hands-on verification, not assumed from a clean `terraform apply`/
`plan`:

1. **OIDC trust policy didn't cover `environment:`-shaped subjects** — see
   Section 3. The single highest-impact fix in this project.
2. **Stale, EOL Spring Boot dependencies** — `pom.xml` bumped from `3.2.11`
   to `3.5.16` with explicit version-property overrides for Tomcat/Jackson/
   Spring Framework, closing every HIGH/CRITICAL Trivy finding. Thymeleaf
   and the HAL Explorer were removed entirely (confirmed unused — no
   `@Controller`, no `templates/` dir) rather than patched, reducing attack
   surface instead of just patching it.
2. **Deploy scripts committed without the executable bit** (`Permission
   denied`, exit 126) — `app-pipeline.yml` invokes them as `bash
   ./.github/scripts/*.sh` rather than `./*.sh`, making the executable bit
   irrelevant rather than re-fixing it every time it's accidentally dropped.
4. **Spring Data REST's root HAL resource shadowed the static UI** — fixed
   via `spring.data.rest.base-path: /api` in `application.yml`, moving the
   API off `/` so `index.html` can be served there instead.
5. **The ADOT sidecar was fully defined in Terraform but never actually
   running** — `aws_ecs_task_definition.app` had its own separate,
   hardcoded `container_definitions`, never wired to the `locals` block
   that correctly assembled both containers. Fixed by referencing
   `jsonencode(local.container_definitions)` directly. This is the kind of
   bug that produces zero Terraform errors or warnings — only found by
   querying AMP directly and getting persistent, real zero-datapoints.
6. **CPU/memory contention after adding the sidecar** caused the app to
   miss the ALB health-check window and trigger the deployment circuit
   breaker's automatic rollback. Fixed by raising `task_cpu`/`task_memory`
   (dev: 512/1024 → 1024/2048) and `health_check_grace_period_seconds`
   (30 → 90).
7. **Two argument-name/missing-argument bugs in `prod/main.tf`**, never
   caught because prod had never been applied: the `alb` module call used
   `deletion_protection` instead of the module's actual declared input
   `alb_deletion_protection`; the `ecs_service` module call was missing
   `alb_arn` entirely (required by its ALB-request-count autoscaling
   policy). Both would fail at `terraform plan` time, not silently.
8. **`terraform plan | tee` in `infra-pipeline.yml` swallowed a failing
   plan's exit code** without `pipefail` — fixed with an explicit
   `set -o pipefail` before the piped command.
9. **`AmazonGrafanaCloudWatchAccess` is not a real AWS managed policy** —
   corrected to `CloudWatchReadOnlyAccess` in `global/observability`.
10. **AMG `permission_type` must be `CUSTOMER_MANAGED`**, not
    `SERVICE_MANAGED` — under `SERVICE_MANAGED`, the hand-built Grafana IAM
    role is silently unused; AWS auto-manages its own instead.

---

*Questions or issues not covered here should be diagnosed the same way every
item above was: query the actual AWS resource state directly (CloudWatch
Logs, `describe-services`, `describe-tasks`, AMP's own query API) rather
than inferring from `terraform apply` succeeding — a clean apply confirms
the Terraform is valid, not that the resulting system behaves correctly.*
