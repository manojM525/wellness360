# Taskmaster Platform — Operator Runbook

This document is written so that someone who has never seen this repository
before can clone it and stand up the entire system — dev and prod, infra,
CI/CD, and observability — **entirely through the two GitHub Actions
pipelines**, without hitting any of the issues that were found and fixed
during the original build. Follow it top to bottom, in order. The only
Terraform ever run from a laptop is the handful of one-time global stacks in
Section 4 — everything environment-specific (dev, prod) is created and
deployed by pushing to a branch and watching CI do it, exactly as a reviewer
evaluating this project should expect.

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

### The two pipelines are independent — this matters for sequencing

`infra-pipeline.yml` and `app-pipeline.yml` are two separate workflow files
with **no dependency on each other**. Both can trigger off the same push (a
push to `develop` touching both `infra/**` and `taskmaster/**`, for example),
and GitHub Actions runs them in parallel with no awareness that one logically
needs the other to finish first. Sections 6 and 7 below exist specifically to
manage that — read them carefully rather than skimming, especially the first
time you bring up each environment.

### The Global vs. Per-Environment split

Not everything lives inside `environments/dev`/`environments/prod`. Five
stacks are shared across both environments, applied **once, manually**, each
in its own separate Terraform state — these are the only manual `terraform
apply` commands in this entire runbook:

| Location | Creates | Why it's global |
|---|---|---|
| `infra/bootstrap/` | S3 state bucket + DynamoDB lock table | Can't be created by the very state it holds |
| `infra/global/dns/` | Route53 hosted zone | One domain, not one per environment |
| `infra/global/iam-ci/` | GitHub OIDC provider + `terraform-apply` role + `deploy` role | One CI pipeline serves both environments |
| `infra/global/ecr/` | ECR repository | Build-once/promote-by-reference needs exactly ONE repository — dev and prod deploy the identical immutable image, just at different times |
| `infra/global/observability/` | AMG (Grafana) workspace | One dashboard pane across both environments |

Everything else — VPC, security groups, ACM cert, RDS, ECS cluster/service,
per-environment IAM (task execution/task roles), AMP workspace — lives in
`infra/environments/dev/` and `infra/environments/prod/`. **These two are
created by the pipeline** (`infra-pipeline.yml`'s `apply-dev`/`apply-prod`
jobs), triggered by pushing/merging to `develop`/`main` — not by running
Terraform locally. This is the part that differs from a naive "just run
terraform apply everywhere" approach, and it's the point of this runbook.

**Required apply order** — each stage must fully exist before the next:
```
bootstrap → global/dns → global/iam-ci → global/ecr → global/observability
                                                           → environments/dev  (via pipeline)
                                                           → environments/prod (via pipeline)
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
- **Your own copy of the repository, on your own GitHub account.** The OIDC
  trust policy in `infra/global/iam-ci/main.tf` is scoped to a specific
  `github_org`/`github_repo` pair (defaults to `manojM525`/`wellness360`), so
  running the pipelines yourself means the code needs to live somewhere you
  control. **Fork the repo on GitHub** (one click, top-right of the repo
  page) rather than cloning and pushing to a new repo you create by hand —
  a fork copies every branch automatically, including `develop`, with no
  extra flags. The manual alternative (`git clone` the original, create a
  blank repo, repoint the remote, push) works too, but only if you remember
  `git push --all origin` — pushing just `main` after repointing the remote
  silently leaves `develop` behind, and you'd only discover that later when
  Section 5's dev bring-up has no `develop` to check out.
  When you reach Section 4, Step 3 (`iam-ci`), pass your fork's org/repo as
  Terraform variables so the trust policy matches the token your fork's
  Actions runs will actually present:
  ```bash
  terraform apply -var="github_org=<your-github-username-or-org>" -var="github_repo=<your-fork-name>"
  ```
  Skipping this reproduces `Not authorized to perform
  sts:AssumeRoleWithWebIdentity` — the role exists, but its trust condition
  is checking for someone else's repository identity.
- **If on Windows using Git Bash/MINGW64**: run `export MSYS_NO_PATHCONV=1`
  in any shell session where you'll pass AWS CLI arguments starting with `/`
  (log group names, IAM paths, etc.) — Git Bash silently rewrites these as
  Windows paths otherwise, producing a confusing `InvalidParameterException`
  that has nothing to do with the actual command.
- **The repository as cloned is already `terraform fmt`-clean** — no action
  needed on this front unless you edit a `.tf` file yourself before pushing.
  If you do, run `terraform fmt -recursive infra/` and commit the result
  first: `infra-pipeline.yml`'s very first job, `fmt-and-validate`, runs
  `terraform fmt -check -recursive infra/` with no AWS credentials at all —
  deliberately placed first so a purely cosmetic issue fails in seconds
  rather than after a `plan`/`apply` cycle. `-check` mode never rewrites
  your files; it only reports and exits non-zero if anything doesn't match
  canonical formatting.

---

## 3. Fork and clone the repository

Fork `manojM525/wellness360` into your own GitHub account first (button,
top-right of the repo page on GitHub) — this copies `develop` and `main`
both, with full history, in one action. Then clone **your fork**:

```bash
git clone https://github.com/<your-github-username>/wellness360.git
cd wellness360
```

Everything from here on operates on this clone.

---

## 4. One-time global infrastructure (apply in this exact order)

Each of these is applied once, manually, from your local machine — the
**only** manual `terraform apply` commands in this entire process. The
pipeline authenticates using roles some of these steps create, so they
can't create themselves.

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

# 3. GitHub OIDC + CI roles
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

**From this point on, no more local `terraform apply` commands appear in
this runbook.** `infra/environments/dev` and `infra/environments/prod` are
created entirely by pushing/merging to `develop`/`main` — Sections 6 and 7.

---

## 5. GitHub repository configuration

Do this now, before your first push — some of it is genuinely required
before `develop` exists, and doing it up front avoids a confusing
first-push failure.

### 5a. Switch to the `develop` branch
It already exists on the remote from the clone — no need to create it:
```bash
git checkout develop
```

### 5b. Set repository Variables — Part 1 (available now)
Settings → Secrets and variables → Actions → **Variables** tab → New
repository variable:

| Name | Value | Source |
|---|---|---|
| `AWS_REGION` | `us-east-1` | — |
| `AWS_DEPLOY_ROLE_ARN` | `deploy_role_arn` | Section 4, step 3 |
| `AWS_TERRAFORM_ROLE_ARN` | `terraform_apply_role_arn` | Section 4, step 3 |
| `ECR_REGISTRY` | everything before the last `/` in `repository_url` | Section 4, step 4 |
| `ECR_REPOSITORY` | everything after the last `/` in `repository_url` | Section 4, step 4 |

**Do not try to set `DEV_*`/`PROD_*` variables yet — they don't exist yet.**
Their values are Terraform outputs from `environments/dev`/`environments/prod`,
which haven't been created. That happens in Sections 6 and 7. Setting these
now is impossible, not just premature.

No secrets are required anywhere in this project — authentication is
entirely OIDC-based, there are no long-lived AWS keys to store.

### 5c. Create GitHub Environments
Settings → Environments:
- **development** — create it, no protection rules needed. This is what
  makes `apply-dev` and `deploy-dev` run automatically with no pause.
- **production** — create it, then under *Deployment protection rules*
  enable **Required reviewers** and add at least one person. This is what
  actually makes `environment: production` in both workflow files pause for
  approval — without this step, that line does nothing, and both
  `apply-prod` and `deploy-prod` would run immediately and unattended.

### 5d. Trigger the first pipeline run
Both `develop` and `main` already have identical content to what's on the
remote — a plain `git push` here does nothing (`Everything up-to-date`), and
even an empty commit won't help: GitHub's `paths:` filter only fires a
workflow when the *actual changed files in that push* match the glob, and an
empty commit changes nothing. Conveniently, there's a **required** change
waiting anyway: `infra/environments/dev/terraform.tfvars` has
`domain_name = "<your-registered-domain>"` as a placeholder — it must be set
to the same domain you actually applied in Section 4, Step 2
(`global/dns`), or `acm-dns` won't find a matching hosted zone to validate
the certificate against.

```bash
# Edit infra/environments/dev/terraform.tfvars — replace
#   domain_name = "<your-registered-domain>"
# with your actual domain, matching Section 4 Step 2 exactly.

git add infra/environments/dev/terraform.tfvars
git commit -m "config: set dev domain_name for acm-dns"
git push origin develop
```

This is a genuine, required change under `infra/**` — not a manufactured
one — so it satisfies `infra-pipeline.yml`'s path filter honestly. Because
the same commit touches nothing under `taskmaster/**`, `app-pipeline.yml`'s
`test`/`build-and-push`/`deploy-dev` jobs correctly stay idle from this
particular push — see Section 6 for what happens next.

---

## 6. Bringing up dev — via the pipelines

Because Section 5d's trigger only touched a file under `infra/**`, only
`infra-pipeline.yml` fires from that push — `app-pipeline.yml`'s path filter
(`taskmaster/**`, `.github/workflows/app-pipeline.yml`) doesn't match, so it
correctly stays idle. This is deliberate: it lets dev infra finish creating
itself before anything tries to deploy an image into it, without needing to
rely on a failure-and-retry workaround.

### What `infra-pipeline.yml` does
`fmt-and-validate` → `apply-dev` (no approval gate on `development`, runs
immediately). This creates the VPC, security groups, ACM cert + Route53
validation record, RDS MySQL (single-AZ, no deletion protection), ECS
cluster + service (Fargate Spot, 1 task) with a placeholder image tag
(`"initial"`, which doesn't exist in ECR yet — the service **will
crash-loop**, expected until the app pipeline runs below), per-environment
IAM roles, and the AMP workspace. Typically takes 10-15 minutes — RDS is the
slowest part. Wait for this to finish successfully before continuing.

### Add the `DEV_*` repository Variables
Only possible now that `apply-dev` has actually created these resources:
```bash
cd infra/environments/dev
terraform output
```
Add these four (same location as Section 5b):

| Name | Value |
|---|---|
| `DEV_ECS_CLUSTER` | `ecs_cluster_name` output |
| `DEV_ECS_SERVICE` | `ecs_service_name` output |
| `DEV_ECS_TASK_FAMILY` | `ecs_task_definition_family` output |
| `DEV_APP_URL` | `https://` + `app_fqdn` output |

### Trigger the app pipeline
Unlike the infra side, there's no equivalent *required* edit here — the
Spring Boot application has no environment-specific values baked into its
source at all; DB host/credentials are injected at container runtime via
ECS task environment variables and Secrets Manager, not read from anything
under `taskmaster/`. So any real, honest first change works. The natural,
non-arbitrary one is marking this as the initial release:

```bash
# Edit taskmaster/pom.xml — bump <version> from 0.0.1-SNAPSHOT to 0.1.0
# (or whatever your actual current version is, incremented once)

git add taskmaster/pom.xml
git commit -m "chore: initial release 0.1.0"
git push origin develop
```

Now that dev infra and the `DEV_*` variables both exist, this cleanly
builds, pushes, and deploys a real image on the first try — no failure
expected this time. Expected sequence in the Actions tab: `Lint & Test` →
`Build, Scan, Push Image` → `Deploy to Dev` (registers a new task
definition revision pointing at the real image, updates the service, waits
for stability — this is what actually resolves the crash-loop) → smoke test
against `/actuator/health` then `/api/tasks`.

---

## 7. Promoting to prod — via the pipelines

Prod has never been applied, so bring it up carefully and in order — unlike
dev, `production`'s required-reviewer gate means **you** control the
sequencing here, not GitHub Actions' default parallelism.

### 7a. Fix prod's domain_name, then open a PR — don't push directly to `main`
`infra/environments/prod/terraform.tfvars` has the same
`domain_name = "<your-registered-domain>"` placeholder dev had — it hasn't
been touched yet, since Section 5d only edited the dev copy. Fix it on
`develop` now, so the fix rides along in the PR diff:

```bash
# Edit infra/environments/prod/terraform.tfvars — replace
#   domain_name = "<your-registered-domain>"
# with the same domain used in Section 4 Step 2 and Section 5d.

git add infra/environments/prod/terraform.tfvars
git commit -m "config: set prod domain_name for acm-dns"
git push origin develop   # make sure develop is fully up to date remotely
```
Open a PR `develop` → `main` via the GitHub UI.

### 7b. Read the plan before merging
Two automatic checks run on the PR:
- `fmt-and-validate` — should pass cleanly if Section 2's fmt step was followed.
- `plan` (infra-pipeline) — detects the PR targets `main`, plans against
  `infra/environments/prod`, and posts the full plan as a PR comment. Since
  prod has never been applied, this should show only resource **creations**
  — no destroys, no modifies. If anything else appears, stop and investigate
  before merging.
- `app-pipeline`'s PR run does lint + test only — no build, push, or deploy
  happens from a PR, by design.

### 7c. Merge the PR
This triggers both workflows on `main`. Unlike dev:
- `infra-pipeline.yml`'s `apply-prod` pauses, waiting for your approval on
  the `production` Environment.
- `app-pipeline.yml`'s `test` and `build-and-push` run automatically (not
  gated); `deploy-prod` also pauses, waiting for the same approval gate.

Both `apply-prod` and `deploy-prod` will be sitting in the Actions tab
simultaneously, both "Waiting." **This is exactly what gives you manual
control of the order — use it.**

### 7d. Approve `apply-prod` only — do not approve `deploy-prod` yet
Let the full prod infra apply complete. Expect this to take longer than dev:
- ACM certificate DNS validation for the domain (a few minutes).
- RDS with `multi_az = true` — meaningfully slower than dev's single-AZ
  instance, potentially 10-15+ minutes.
- The ECS service Terraform creates here also uses the placeholder
  `"initial"` image tag and **will crash-loop** — expected, same as dev.

### 7e. Add the `PROD_*` repository Variables
Only possible now that `apply-prod` has finished:
```bash
cd infra/environments/prod
terraform output
```
Add `PROD_ECS_CLUSTER`, `PROD_ECS_SERVICE`, `PROD_ECS_TASK_FAMILY`,
`PROD_APP_URL` the same way as Section 6.

### 7f. Approve `deploy-prod`
This registers a new task definition revision pointing at the real image and
updates the prod service. Watch it wait for stability, then run the smoke
test against your prod domain.

### Known gap worth stating plainly
Because `build-and-push` triggers on every push to `main` (not just `develop`),
merging `develop` → `main` causes a **second image build** from the merge
commit, not a redeploy of the exact image already validated in dev — a
deviation from strict build-once/promote-by-reference. Functionally
equivalent as long as the merge is a clean fast-forward with no conflicts,
but worth being able to name if asked: the correct fix is having prod deploy
reference dev's already-built image tag directly rather than rebuild.

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
through hands-on verification — running the real pipelines against a real
account and reading the actual error — not assumed from a clean `terraform
apply`/`plan`:

1. **OIDC trust policy originally didn't cover `environment:`-shaped
   subjects.** GitHub's OIDC token `sub` claim changes shape entirely to
   `environment:{name}` the moment a job declares `environment:` (used by
   `deploy-dev`, `deploy-prod`, `apply-dev`, `apply-prod` for their approval
   gates) — it does not additionally keep the `ref:refs/heads/{branch}`
   shape. `infra/global/iam-ci/main.tf`'s trust policy now explicitly
   includes both shapes for the roles that need them. The single
   highest-impact fix in this project — already reflected in the current
   `infra/global/iam-ci/main.tf`, nothing further to do here.
2. **`terraform-apply` role's policy was originally missing `aps:*` and
   `kms:*`.** Found by actually running `apply-dev` from scratch: AMP's
   `CreateWorkspace`/`TagResource` and RDS's default-KMS-key usage both
   failed with `AccessDenied`/`KMSKeyNotAccessibleFault` respectively,
   because neither action had ever been granted to the CI role. Neither
   surfaces when applying with personal admin credentials, only with a
   scoped CI role — a good example of why "it works from my laptop" isn't
   the same as "the pipeline can do it." Already reflected in the current
   `infra/global/iam-ci/main.tf`.
3. **`terraform fmt -check` failures from files edited outside the
   pipeline** — a manual local `terraform destroy`/edit cycle (e.g. tearing
   down dev to test a from-scratch pipeline rebuild) can leave formatting
   drift that `fmt-and-validate` catches immediately, by design, before any
   AWS credentials are even used. Fix is always `terraform fmt -recursive
   infra/`, commit, push.
4. **Stale, EOL Spring Boot dependencies** — `pom.xml` bumped from `3.2.11`
   to `3.5.16` with explicit version-property overrides for Tomcat/Jackson/
   Spring Framework, closing every HIGH/CRITICAL Trivy finding. Thymeleaf
   and the HAL Explorer were removed entirely (confirmed unused — no
   `@Controller`, no `templates/` dir) rather than patched, reducing attack
   surface instead of just patching it.
5. **Deploy scripts committed without the executable bit** (`Permission
   denied`, exit 126) — `app-pipeline.yml` invokes them as `bash
   ./.github/scripts/*.sh` rather than `./*.sh`, making the executable bit
   irrelevant rather than re-fixing it every time it's accidentally dropped.
6. **Spring Data REST's root HAL resource shadowed the static UI** — fixed
   via `spring.data.rest.base-path: /api` in `application.yml`, moving the
   API off `/` so `index.html` can be served there instead.
7. **The ADOT sidecar was fully defined in Terraform but never actually
   running** — `aws_ecs_task_definition.app` had its own separate,
   hardcoded `container_definitions`, never wired to the `locals` block
   that correctly assembled both containers. Fixed by referencing
   `jsonencode(local.container_definitions)` directly. This is the kind of
   bug that produces zero Terraform errors or warnings — only found by
   querying AMP directly and getting persistent, real zero-datapoints.
8. **CPU/memory contention after adding the sidecar** caused the app to
   miss the ALB health-check window and trigger the deployment circuit
   breaker's automatic rollback. Fixed by raising `task_cpu`/`task_memory`
   (dev: 512/1024 → 1024/2048) and `health_check_grace_period_seconds`
   (30 → 90).
9. **Two argument-name/missing-argument bugs in `prod/main.tf`**, never
   caught because prod had never been applied: the `alb` module call used
   `deletion_protection` instead of the module's actual declared input
   `alb_deletion_protection`; the `ecs_service` module call was missing
   `alb_arn` entirely (required by its ALB-request-count autoscaling
   policy). Both would fail at `terraform plan` time, not silently.
10. **`terraform plan | tee` in `infra-pipeline.yml` swallowed a failing
    plan's exit code** without `pipefail` — fixed with an explicit
    `set -o pipefail` before the piped command.
11. **`AmazonGrafanaCloudWatchAccess` is not a real AWS managed policy** —
    corrected to `CloudWatchReadOnlyAccess` in `global/observability`.
12. **AMG `permission_type` must be `CUSTOMER_MANAGED`**, not
    `SERVICE_MANAGED` — under `SERVICE_MANAGED`, the hand-built Grafana IAM
    role is silently unused; AWS auto-manages its own instead.

**Documented, not yet fixed** (fair to raise unprompted in review):
- `kms:*` on the `terraform-apply` role (item 2 above) is broader than
  necessary — a tighter policy would scope it to the specific default key
  ARNs and the exact actions RDS needs.
- **`apply-dev` and `deploy-dev` still have no formal dependency between
  them** — `infra-pipeline.yml` and `app-pipeline.yml` remain two fully
  decoupled workflow files, by design, with neither gated behind the other's
  completion. This runbook works around it operationally, by controlling
  *which paths a given commit touches* so only one workflow fires at a time
  during first-time bring-up (Section 6). That's a process discipline, not
  an enforced guarantee — a normal day-to-day commit touching both
  `infra/**` and `taskmaster/**` together (a routine occurrence once the
  environment already exists) would still fire both in parallel, which is
  fine *after* first bring-up since the ECS service and variables already
  exist by then. A more robust design would have `deploy-dev` explicitly
  depend on `apply-dev`'s completion via a `workflow_run` trigger, rather
  than relying on this ordering being followed correctly.
- Merging `develop` → `main` triggers a second image build rather than
  promoting the exact image already validated in dev (Section 7's "Known
  gap").

---

*Questions or issues not covered here should be diagnosed the same way every
item above was: query the actual AWS resource state directly (CloudWatch
Logs, `describe-services`, `describe-tasks`, AMP's own query API) rather
than inferring from `terraform apply` succeeding — a clean apply confirms
the Terraform is valid, not that the resulting system behaves correctly.*
