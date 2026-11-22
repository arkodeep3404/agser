#!/usr/bin/env node
import * as cdk from 'aws-cdk-lib';
import { PlatformStack } from '../lib/platform-stack';

const app = new cdk.App();

const account = process.env.CDK_DEFAULT_ACCOUNT;
const region = process.env.CDK_DEFAULT_REGION || 'ap-south-1';

new PlatformStack(app, 'AgserPlatform', {
  env: { account, region },
  description: 'Self-hosted Agent Server platform for deep agents (company-internal)',

  // ACM certificate ARN for HTTPS on the ALB. If empty, the ALB serves plain
  // HTTP on :80 (fine for testing behind a VPN; set it for production).
  certificateArn: app.node.tryGetContext('certificateArn') as string | undefined,

  // Restrict ALB ingress; defaults to everywhere (API key still required).
  allowedCidrs: (app.node.tryGetContext('allowedCidrs') as string[] | undefined) ?? ['0.0.0.0/0'],
});

app.synth();
