# Runbook — operate, deploy, upgrade, troubleshoot

For AI agents continuing this project. Read `AGENTS.md` first.

## 1. Daily operations

### Local stack
```bash
docker compose up -d --build            # platform :8123 (+infra)
./scripts/verify.sh                     # must be green
./scripts/local-down.sh                 # stop (-v wipes Postgres)
```

### Deploy a new version (local)
The server image is rebuilt by any `docker compose up -d --build server`;
the DB schema is managed by alembic migrations run on boot
(`RUN_MIGRATIONS_ON_STARTUP=true`). Rolling deploys on ECS are zero-downtime
(min-healthy 100%); in-flight runs drain via SIGTERM then re-queue.

### Deploy to real AWS (Mumbai)
```bash
aws login                                    # IAM Identity Center creds
cd deploy/cdk
cdk bootstrap aws://<ACCOUNT>/ap-south-1
cdk deploy -c certificateArn=<acm-arn>       # first time
../scripts/deploy-image.sh                   # every release: build → ECR → rollout
# rollback: ROLLBACK_TO=<git-sha-tag> ./scripts/deploy-image.sh
```
After first deploy: set the model provider secrets
(`aws secretsmanager put-secret-value` on `agser/openrouter-api-key`
and/or `agser/anthropic-api-key`), then read the platform key from
`agser/platform-api-key` and run:
```bash
BASE=http://<AlbDns> PLATFORM_API_KEY=$(aws secretsmanager get-secret-value \
  --secret-id agser/platform-api-key --query SecretString --output text) \
  ./scripts/verify.sh
```

### Deploy to the FloCI AWS emulator (local laptop)
FloCI must run with the Docker socket mounted and port 80 published (the
ALB listener lives inside the FloCI container). Start it, then:
```bash
export AWS_ACCESS_KEY_ID=000000000000 AWS_SECRET_ACCESS_KEY=local-only-not-a-secret \
       AWS_DEFAULT_REGION=ap-south-1 AWS_ENDPOINT_URL=http://127.0.0.1:4566
cd deploy/cdk
cdk bootstrap aws://000000000000/ap-south-1
aws rds delete-db-instance --db-instance-identifier agser-postgres \
    --skip-final-snapshot 2>/dev/null; sleep 6      # orphans from prior runs
cdk destroy --force 2>/dev/null; sleep 4             # FloCI can't update VPC in place
cdk deploy --require-approval never --force \
  -c agser:dbPassword=sim-local-pw-1234 \
  -c agser:imageUri=localhost:5100/<ECR_REPO_PATH>:latest \
  -c agser:redisUri=redis://host.docker.internal:56379/1
docker tag agser-server:latest localhost:5100/<ECR_REPO_PATH>  # from stack output
docker push localhost:5100/<ECR_REPO_PATH>
aws ecs update-service --cluster agser --service <ServiceName> --force-new-deployment
```
Emulator-only context flags: `dbPassword`, `imageUri`, `redisUri` — never
set them for real AWS.

### Multi-gate HITL crash drill (the hardest guarantee)
The `workflow` graph pauses at three sequential approval gates. To prove
"recover from the exact point where the human was called":

```bash
# local
./scripts/test-workflow.sh

# against AWS through the ALB (uses the ECS-API crash hook)
ALB=$(aws elbv2 describe-load-balancers --query 'LoadBalancers[0].DNSName' --output text)
KEY=$(aws secretsmanager get-secret-value --secret-id agser/platform-api-key --query SecretString --output text)
BASE="http://$ALB" PLATFORM_API_KEY="$KEY" API_TIMEOUT=150 \
  RESTART_CMD=./scripts/aws-restart-tasks.sh ./scripts/test-workflow.sh
```

Manual version: start the workflow, approve gate 1 (now paused at gate 2),
then crash everything — `docker rm -f $(docker ps -q --filter name=floci-ecs)`
plus `docker stop floci-sim` — verify the platform is unreachable, restart
`floci-sim`, nudge the reconciler with
`aws ecs update-service --cluster agser --service <svc> --desired-count 2`,
then read the thread: status must still be `interrupted`, `side_effects`
must still be exactly `[intake, enrich]`, `stage_results` intact. Resume →
`execute` runs once → gate 3 → `report` runs once.

### Chaos drill on the emulator (the flagship test)
```bash
# start a sleepy run via the ALB, wait 12s (prep checkpointed),
aws ecs stop-task --cluster agser --task <arn> --reason "chaos test"
# then poll thread state via the ALB: long_work finishes AND
# side_effects prep count stays EXACTLY 1 (lease reaper + checkpoint resume)
```
Expected log trail: worker picked up → task killed → "Reaping crashed
worker runs" → "Re-enqueued recovered run" → new worker picks up → finish.

## 2. Upgrades (dependencies or server-core)

1. Make the change (edit requirements/server-core).
2. `./scripts/upgrade-check.sh` — rebuilds with fresh resolution and runs
   verify + features + failures + HITL. Gate must be GREEN.
3. If red and you need a rollback reference: `server/requirements.lock.txt`
   is the last-known-good set (reference only, never enforced).
4. Re-vendoring server-core from upstream: copy new `libs/aegra-api`,
   re-apply every `agser (ours)` patch (AGENTS §5), keep the alembic
   migration chain, run the gate AND the official-parity suite.

## 3. Monitoring & alerts

- `/ok` (public) and `/health` (readiness + DB/checkpointer/store) —
  ECS container health check + ALB target check use `/health`/`/ok`.
- `/metrics` Prometheus: process gauges + `agser_runs{status}` +
  `agser_threads`. AWS: the extensions publisher also emits
  `AgserPlatform/PendingRuns|RunningRuns` to CloudWatch every 60s.
- CDK alarms → SNS (`agser-platform-alerts`; subscribe with
  `-c alertEmail=`): ALB 5xx, unhealthy hosts, p95 latency > 5 min,
  Postgres unreachable.
- Traces: self-hosted Langfuse (deploy/langfuse/README.md). v4 is
  events_only — inspect via the Langfuse UI or ClickHouse `events_core`.

## 4. Troubleshooting

### Runs stuck `pending` forever, reaper logs "Re-enqueueing stuck pending runs" every sweep
Classic **queue theft**: two deployments share one Redis db — one stack's
BLPOP workers steal the other's `aegra:jobs` entries and can't claim them
(different Postgres). Check: every stack must have its own Redis db
(compose /0, FloCI ECS /1) — and kill **orphan ECS task containers** left
by FloCI stack destroys (`docker ps | grep floci-ecs`; verify each one's
`REDIS_URL` db matches the CURRENT deploy).

### ECS tasks run a stale image after you push `:latest`
FloCI caches images by reference. Push an **immutable tag** and redeploy
with `-c agser:imageUri=localhost:5100/<repo>:<tag>`; then confirm inside a
task: `docker exec <task> python3 -c "import json;print(json.load(open('aegra.aws.json'))['graphs'])"`.

### ECS tasks do not come back after an emulator restart
FloCI's reconciler is not automatic on cold start (real ECS is). Nudge it:
`aws ecs update-service --cluster agser --service <svc> --desired-count 2`.

### ECS task crash-loops on boot
Read `docker logs <task-container>`: past causes were (a) alembic
revision mismatch — drop & recreate the emulator DB, (b) pgvector missing
— FloCI RDS has no vector extension; remove `store.index` from the config
for emulator runs, (c) DB name env is `POSTGRES_DB` (not
`POSTGRES_DATABASE`), (d) `POSTGRES_PORT` must come from the RDS endpoint
token (FloCI proxies on :7002).

### FloCI deploy fails with "Rollback is not implemented for AWS::EC2::VPC"
FloCI cannot update some resources in place: `cdk destroy --force`, then
`cdk deploy` fresh. Also pre-delete orphaned RDS instance
`agser-postgres` (deletion protection survives stack destroy).

### ECR pull fails inside FloCI ("no basic auth credentials" / HTTPS to HTTP registry)
FloCI's ECR is a `registry:2` container on host :5100 (HTTP). Reference
images as `localhost:5100/<full-repo-path>:latest` via
`agser:imageUri` (docker allows plain HTTP only for localhost).

### The ALB is unreachable (HTTP 000)
FloCI's ALB listens on port 80 **inside** its container — run FloCI with
`-p 127.0.0.1:80:80`. The DNS `*.elb.localhost.floci.io` resolves to
127.0.0.1.

### Webhook test blocked
Webhook URL policy lives in `aegra.json` (`webhooks.url`): allowed
domains must include `host.docker.internal` with `disable_loopback:
false` for local e2e. Receiver: `AGSER_WEBHOOK_SECRET=... python
examples/webhook_receiver.py 9999`; verify signature in the output.

### HITL resume behaves unexpectedly
- Resume shape: `{"command": {"resume": {"decisions": [{"type":
  "approve"}]}}}` for deepagents gates (multiple rounds possible — loop
  while status==interrupted), `{"command":{"resume":{"approved":true}}}`
  for the approval graph.
- Ours returns 4xx for resume-without-interrupt (official returns 200) —
  documented divergence, not a bug.
- After a restart the interrupt survives (state is checkpointed); resume
  still works, prep stays exactly-once (H7).

### Official parity profile
`docker compose --profile official up -d --build` → :8124. Use it to
diff API behavior: `BASE=http://127.0.0.1:8124 ./scripts/test-features.sh`.
If our platform and official diverge on a contract point, fix OUR side to
match official unless the divergence is a deliberate hardening (then
document it in FEATURE-VERIFICATION.md).

## 5. Security posture (know these cold)

- API key auth on every data route (`auth.py`); open routes are exactly
  `/ok`, `/health`, `/ready`, `/live`, `/metrics`, `/info`, `/docs`,
  `/openapi.json` (EXEMPT_PATHS).
- AES-256-GCM checkpoint encryption at rest (`LANGGRAPH_AES_KEY`) —
  verified ciphertext in Postgres; store items + metadata rely on RDS
  storage encryption + KMS.
- Secrets in AWS: Secrets Manager, injected into the task; local: `.env`
  (gitignored).
- Webhooks: SSRF policy (domain allowlist, loopback/private-IP controls) +
  HMAC signatures.
- Tracing: Langfuse only, in your account; LangSmith tracing hardcoded
  off (`LANGSMITH_TRACING=false`).
- ALB: restrict with `-c allowedCidrs=[...]` + HTTPS via
  `-c certificateArn=...`.
