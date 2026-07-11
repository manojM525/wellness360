#!/usr/bin/env bash
set -euo pipefail

# Required env vars: IMAGE_URI, CLUSTER, SERVICE, TASK_FAMILY

echo "Fetching current task definition: ${TASK_FAMILY}"
aws ecs describe-task-definition \
  --task-definition "${TASK_FAMILY}" \
  --query 'taskDefinition' \
  --output json > task-def-raw.json

# describe-task-definition returns several read-only fields that
# register-task-definition rejects if you pass them back verbatim
# (taskDefinitionArn, revision, status, etc.) — strip them before re-registering.
jq 'del(.taskDefinitionArn, .revision, .status, .requiresAttributes, .compatibilities, .registeredAt, .registeredBy, .deregisteredAt)' \
  task-def-raw.json > task-def-stripped.json

# Swap in the new image on the "app" container specifically — this is the
# ONLY thing this deploy changes; CPU/memory/roles/env structure all stay
# exactly as Terraform defined them.
jq --arg IMAGE "${IMAGE_URI}" \
  '.containerDefinitions = [.containerDefinitions[] | if .name == "app" then .image = $IMAGE else . end]' \
  task-def-stripped.json > task-def-new.json

echo "Registering new task definition revision..."
NEW_TASK_DEF_ARN=$(aws ecs register-task-definition \
  --cli-input-json file://task-def-new.json \
  --query 'taskDefinition.taskDefinitionArn' \
  --output text)

echo "Registered: ${NEW_TASK_DEF_ARN}"

echo "Updating service ${SERVICE} on cluster ${CLUSTER}..."
aws ecs update-service \
  --cluster "${CLUSTER}" \
  --service "${SERVICE}" \
  --task-definition "${NEW_TASK_DEF_ARN}" \
  --force-new-deployment > /dev/null

echo "Waiting for the service to reach a stable state..."
# This is what actually surfaces a bad deploy to CI: if the deployment
# circuit breaker (configured in Terraform) rolls back due to failed health
# checks, `services-stable` will eventually time out/fail rather than hang
# forever, and this script — and the whole job — fails loudly instead of
# reporting a false success.
if ! aws ecs wait services-stable --cluster "${CLUSTER}" --services "${SERVICE}"; then
  echo "::error::Service did not reach a stable state — the deployment circuit breaker likely rolled back to the previous task definition. Check ECS console deployment events for the failure reason."
  exit 1
fi

echo "Deployment complete and stable."
