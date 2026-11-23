#!/usr/bin/env node
import * as cdk from 'aws-cdk-lib';
import { PlatformStack } from '../lib/platform-stack';
import { CicdStack } from '../lib/cicd-stack';

const app = new cdk.App();

const account = process.env.CDK_DEFAULT_ACCOUNT;
const region = process.env.CDK_DEFAULT_REGION || 'ap-south-1';

const platform = new PlatformStack(app, 'AgserPlatform', {
  env: { account, region },
  description: 'Self-hosted Agent Server platform for deep agents (company-internal)',

  // ACM certificate ARN for HTTPS on the ALB. If empty, the ALB serves plain
  // HTTP on :80 (fine for testing behind a VPN; set it for production).
  certificateArn: app.node.tryGetContext('certificateArn') as string | undefined,

  // Restrict ALB ingress; defaults to everywhere (API key still required).
  allowedCidrs: (app.node.tryGetContext('allowedCidrs') as string[] | undefined) ?? ['0.0.0.0/0'],
});

// ---------------------------------------------------------------------------
// OPTIONAL CI/CD pipeline (CodePipeline → CodeBuild → ECR → ECS). Opt-in only:
// requires an existing CodeStar connection ARN plus the GitHub repo details.
// Without `-c agser:cicd=true` the app is exactly what it was before — the
// pipeline stack is not synthesized at all. See deploy/cicd/README.md.
//
//   cdk deploy \
//     -c agser:cicd=true \
//     -c agser:codestarConnectionArn=arn:aws:codestar-connections:<region>:<acct>:connection/<id> \
//     -c agser:githubOwner=<owner> -c agser:githubRepo=<repo> \
//     [-c agser:githubBranch=main]
if (app.node.tryGetContext('agser:cicd')) {
  new CicdStack(app, 'AgserCicd', {
    env: { account, region },
    description: 'Optional AWS-native CI/CD: GitHub → CodeBuild (build+test) → ECR → ECS rolling deploy',
    // Reuse the platform's existing infrastructure; nothing is recreated.
    cluster: platform.cluster,
    service: platform.service,
    repository: platform.repository,
  });
}

app.synth();
