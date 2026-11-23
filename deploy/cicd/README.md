# Agser CI/CD (AWS CodePipeline)

An **optional, opt-in** AWS-native pipeline for the platform. It is *not* part
of the default `cdk deploy`: the `AgserCicd` stack is only instantiated when
the context flag `agser:cicd` is set (see below), and it never creates
platform infrastructure — it reuses the existing ECR repository, ECS cluster
and ECS service from `PlatformStack`.

## What the pipeline does

```
GitHub (main) ──CodeStar Connections──▶ CodeBuild (privileged Docker, AL2023)
                                        │ pre_build:  build server/aegra.Dockerfile
                                        │             (linux/arm64, tagged by commit SHA),
                                        │             push to the platform ECR repo
                                        │ build:      compose up the local stack,
                                        │             wait for :8123/ok, then run
                                        │             verify.sh, test-features.sh,
                                        │             RUN_LLM=0 test-hitl.sh,
                                        │             test-failures.sh
                                        │ post_build: write imagedefinitions.json
                                        ▼
                     ECS rolling deploy of $ECR:$COMMIT_SHA to the existing service
                     (min-healthy 100%, circuit-breaker auto-rollback from PlatformStack)
```

A broken commit fails the build **before** anything reaches ECS; a deploy that
cannot start healthy tasks is rolled back automatically by the ECS circuit
breaker already configured on the service.

## 1. Create the CodeStar connection (one-time)

1. AWS Console → **Developer Tools → Settings → Connections** (or
   `AWS CodePipeline → Settings → Connections`), region = the stack's region.
2. **Create connection** → provider **GitHub** → give it a name (e.g.
   `agser-github`) → **Connect to GitHub**, install the GitHub App / choose the
   repository owner if asked, and authorize.
3. Copy the connection **ARN** once its status is **Available** — it looks like
   `arn:aws:codestar-connections:<region>:<account>:connection/<uuid>`.
4. After the *first* deploy of `AgserCicd`, CodePipeline may pause asking you
   to authorize the pipeline to use the connection. Open the pipeline in the
   console and approve ("Update detected connection resources") once.

The GitHub repo **does not** need any AWS credentials or secrets: the
CodeStar connection is the only trust anchor, and all AWS-side auth is
role-based (CodeBuild role with ECR/CloudWatch-Logs permissions).

## 2. Deploy the pipeline

Prereq: `PlatformStack` (`AgserPlatform`) is already deployed — the pipeline
targets its ECR repo, cluster and service.

```bash
cd deploy/cdk

npx cdk deploy AgserCicd \
  -c agser:cicd=true \
  -c agser:codestarConnectionArn=arn:aws:codestar-connections:<region>:<account>:connection/<uuid> \
  -c agser:githubOwner=<your-github-owner> \
  -c agser:githubRepo=<your-github-repo> \
  -c agser:githubBranch=main        # optional, default is main
```

All five context values are required when `agser:cicd=true` is set — synth
fails fast with a clear error if any of the connection ARN, owner or repo is
missing. With no `-c agser:cicd=true` the pipeline stack is not created and
`cdk synth`/`cdk deploy` behave exactly as before.

CLI equivalent for the connection (optional):

```bash
aws codestar-connections create-connection \
  --provider-type GitHub --connection-name agser-github
# then finish the handshake in the console (Pending → Available)
```

## 3. Relationship to the GitHub Actions workflow (`.github/workflows/ci.yml`)

The two are complementary and independent:

| | GitHub Actions `ci` | CodePipeline `AgserCicd` |
|---|---|---|
| Runs on | every push + every PR | pushes to the selected branch |
| Scope | PR/merge gate for public contributors | in-account deploy path for the running AWS stack |
| AWS access | none (GitHub-hosted, no AWS creds) | fully IAM-role-based inside your account |
| Deploys | never — stops after tests (plus parity vs the official build) | yes — pushes the image to ECR by commit SHA and rolls the ECS service |

Use GitHub Actions as the public, PR-facing quality gate (including the
parity check against the official image, which is intentionally *not* part of
the AWS pipeline), and CodePipeline as the closed-loop, in-account path that
builds, tests, publishes and rolls out to the already-running platform.

## Notes

- The buildspec is `deploy/cicd/buildspec.yml`; the image is pushed as
  `$ECR_REPO_URI:$CODEBUILD_RESOLVED_SOURCE_VERSION` (the commit SHA) — the
  same tagging scheme as `scripts/deploy-image.sh`, just keyed by commit.
- The ECS tasks run on **ARM64** (Graviton, per `PlatformStack`), so the
  buildspec registers QEMU binfmt handlers and builds the server image with
  `--platform linux/arm64`; the local compose test stack runs natively.
- `imagedefinitions.json` uses the container name `server`, matching
  `taskDef.addContainer('server', ...)` in `platform-stack.ts`.
- To tear the pipeline down without touching the platform:
  `npx cdk destroy AgserCicd` (the ECR images and the ECS service are
  unaffected — the pipeline only ever *pushes* to them).
