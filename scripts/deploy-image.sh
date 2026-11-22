#!/usr/bin/env bash
# Build the Agent Server image, push it to ECR, and roll it out on ECS.
#
# Prereqs: aws CLI with credentials, Docker, and the AgserPlatform stack
# deployed (deploy/cdk). Stack outputs supply the ECR repo and service names;
# override with env vars if you prefer.
#
#   ./scripts/deploy-image.sh                    # build → push :latest → rollout
#   ROLLBACK_TO=<sha-tag> ./scripts/deploy-image.sh   # redeploy a previous tag
set -euo pipefail

cd "$(dirname "$0")/.."

fail() { printf '\033[31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }

command -v aws  >/dev/null || fail "aws CLI not installed"
command -v docker >/dev/null || fail "docker not installed"
aws sts get-caller-identity >/dev/null 2>&1 || fail "no AWS credentials"

REGION=${AWS_REGION:-$(aws configure get region)}
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
STACK=${STACK_NAME:-AgserPlatform}

# Pull stack outputs (falls back to env vars for manual runs).
outputs() { aws cloudformation describe-stacks --stack-name "$STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue|[0]" --output text; }

ECR_URI=${ECR_URI:-$(outputs EcrRepoUri)}
CLUSTER=${ECS_CLUSTER:-$(outputs ClusterName)}
SERVICE=${ECS_SERVICE:-$(outputs ServiceName)}
[ "${ECR_URI}" != "None" ] || fail "stack '${STACK}' not found / no EcrRepoUri output"

if [ -n "${ROLLBACK_TO:-}" ]; then
  IMAGE="${ECR_URI%:latest}:${ROLLBACK_TO}"
  echo "rolling back to ${IMAGE}"
else
  TAG="${DEPLOY_TAG:-$(git rev-parse --short HEAD 2>/dev/null || date +%Y%m%d%H%M)}"
  IMAGE="${ECR_URI%:latest}:${TAG}"
  echo "building ${IMAGE}"
  docker build -t "$IMAGE" -t "${ECR_URI}" -f server/Dockerfile .
  docker push "$IMAGE"
  docker push "${ECR_URI}"   # :latest is what the task definition references
fi

echo "restarting ECS service ${CLUSTER}/${SERVICE}"
aws ecs update-service --cluster "$CLUSTER" --service "$SERVICE" \
  --force-new-deployment --region "$REGION" >/dev/null

echo "waiting for service to stabilize (this runs rolling, minHealthy=100%)"
aws ecs wait services-stable --cluster "$CLUSTER" --service "$SERVICE" --region "$REGION" \
  || fail "service did not stabilize — check ECS console events; previous tag: ${TAG:-n/a}"

ALB_DNS=$(outputs AlbDns)
echo
echo "  deployed  ${IMAGE}"
echo "  endpoint  http://${ALB_DNS}"
echo "  verify    BASE=http://${ALB_DNS} PLATFORM_API_KEY=\$(aws secretsmanager get-secret-value --secret-id agser/platform-api-key --query SecretString --output text) ./scripts/verify.sh"
