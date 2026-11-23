#!/usr/bin/env bash
# Restart the ECS service's tasks through the ECS API (NOT docker restart —
# bypassing ECS leaves the service without running tasks on FloCI, and skips
# the real-world replacement path we want to exercise).
#
# Use as the crash hook for the suites against an AWS target:
#   RESTART_CMD="./scripts/aws-restart-tasks.sh" BASE=http://<alb> \
#     PLATFORM_API_KEY=... ./scripts/test-workflow.sh
set -uo pipefail
export AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID:-000000000000}
export AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY:-local-only-not-a-secret}
export AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION:-ap-south-1}
export AWS_ENDPOINT_URL=${AWS_ENDPOINT_URL:-http://127.0.0.1:4566}

CLUSTER=${ECS_CLUSTER:-agser}
SERVICE=${ECS_SERVICE:-$(aws cloudformation describe-stacks --stack-name ${STACK_NAME:-AgserPlatform} \
  --query 'Stacks[0].Outputs[?OutputKey==`ServiceName`].OutputValue' --output text 2>/dev/null)}
[ -n "$SERVICE" ] || { echo "cannot resolve ECS service name" >&2; exit 1; }

# 1. stop every running task (ECS replaces them — the real crash path)
for arn in $(aws ecs list-tasks --cluster "$CLUSTER" --query 'taskArns[]' --output text 2>/dev/null); do
  aws ecs stop-task --cluster "$CLUSTER" --task "$arn" --reason "suite crash hook" >/dev/null 2>&1
done
# 2. nudge the reconciler (FloCI needs an explicit reconcile after cold starts)
aws ecs update-service --cluster "$CLUSTER" --service "$SERVICE" --desired-count 2 >/dev/null 2>&1

# 3. wait for at least one healthy task
for i in $(seq 1 40); do
  n=$(aws ecs list-tasks --cluster "$CLUSTER" --query 'length(taskArns)' --output text 2>/dev/null || echo 0)
  [ "${n:-0}" -ge 1 ] && exit 0
  sleep 3
done
echo "no ECS tasks came back" >&2
exit 1
