# Langfuse — tracing & observability (replaces LangSmith)

Self-hosted Langfuse on your own AWS, wired to this platform. Data never
leaves your account: the server exports OpenTelemetry spans directly to your
Langfuse instance; LangSmith tracing is permanently off.

## How it works (verified end-to-end)

The server core ships a native Langfuse target:

```
OTEL_TARGETS=LANGFUSE
LANGFUSE_BASE_URL=http://<your-langfuse>:3000
LANGFUSE_PUBLIC_KEY=pk-...
LANGFUSE_SECRET_KEY=sk-...
```

Exports OTLP to `{BASE_URL}/api/public/otel/v1/traces` with basic auth —
the official Langfuse ingestion contract.

Verified locally (Langfuse v4.83.0, docker compose):
- deep-agent run (research agent, real LLM) → **295 events ingested**:
  3 AGENT spans, 32 CHAIN (planning/subagent), 10 TOOL executions,
  12 GENERATION spans (model: `ChatOpenAI` via OpenRouter), 238 SPANs.
- Langfuse v4 runs in "events_only" mode: trace data arrives via OTLP and
  is viewed in the Langfuse UI / analytics; the legacy
  `GET /api/public/traces` REST endpoint is retired in v4.

## Deploy on AWS (production)

Use the official Langfuse Terraform module in your AWS account:
https://github.com/langfuse/langfuse-terraform-aws
(docs: https://langfuse.com/self-hosting/deployment/aws)

1. Deploy the module (provisions Langfuse web/worker containers, Postgres,
   ClickHouse, Redis, S3 blob storage).
2. Create an org/project + API keys in your Langfuse (or use the
   `LANGFUSE_INIT_*` headless bootstrap env vars).
3. Point this platform at it — either set the four env vars on the ECS
   task definition (deploy/cdk), or pass them via compose/.env. No code
   changes needed anywhere.
4. Security: restrict the Langfuse ALB to your VPC/office CIDRs; keep the
   secret key in AWS Secrets Manager like the other platform secrets.

## Local development

Langfuse's official compose (repo: langfuse/langfuse) runs on :3000.
Note: its ClickHouse publishes host port 8123 which collides with this
platform's server port — remap it (see the override used in this repo's
verification, `127.0.0.1:18123:8123`). Headless init env vars
(`LANGFUSE_INIT_ORG_ID/PROJECT_ID/PROJECT_PUBLIC_KEY/...`) create the
org, project, user, and API keys automatically on first boot — no UI
signup needed.

The compose defaults in this repo already target a local Langfuse
(`docker-compose.yml` → OTEL_TARGETS/LANGFUSE_* env).
