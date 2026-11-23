import * as cdk from 'aws-cdk-lib';
import * as cloudwatch from 'aws-cdk-lib/aws-cloudwatch';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as ecs from 'aws-cdk-lib/aws-ecs';
import * as ecr from 'aws-cdk-lib/aws-ecr';
import * as elasticache from 'aws-cdk-lib/aws-elasticache';
import * as elbv2 from 'aws-cdk-lib/aws-elasticloadbalancingv2';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as logs from 'aws-cdk-lib/aws-logs';
import * as rds from 'aws-cdk-lib/aws-rds';
import * as secretsmanager from 'aws-cdk-lib/aws-secretsmanager';
import * as sns from 'aws-cdk-lib/aws-sns';
import * as subscriptions from 'aws-cdk-lib/aws-sns-subscriptions';
import { Construct } from 'constructs';

export interface PlatformStackProps extends cdk.StackProps {
  /** ACM certificate ARN for HTTPS. Omitted → HTTP-only ALB. */
  readonly certificateArn?: string;
  /** CIDRs allowed to reach the ALB. */
  readonly allowedCidrs: string[];
}

/**
 * Self-hosted Agent Server platform for deep agents — company internal.
 *
 * Reliability model (what handles what):
 *
 *   Auto scaling      ECS service autoscaling (ALB requests-per-target + CPU),
 *                     spread across 2 AZs, min 2 tasks for rolling deploys.
 *   Auto recovery     ECS replaces any task failing the /ok health check
 *                     (container + ALB level); deployments run 100%
 *                     min-healthy with circuit-breaker auto-rollback; the
 *                     watchdog sidecar re-drives runs orphaned by a task
 *                     death, resuming from the last Postgres checkpoint so
 *                     completed steps never re-execute.
 *   Failover          RDS Postgres Multi-AZ (automatic standby failover),
 *                     ElastiCache Redis replication group with automatic
 *                     failover, one NAT gateway per AZ.
 *   Data durability   RDS automated backups + PITR; checkpoints/threads/store
 *                     live in Postgres; LangSmith tracing is disabled — no
 *                     telemetry or data leaves this AWS account.
 *   Inference         MODEL_PROVIDER chooses per deployment: "bedrock"
 *                     (in-account, IAM-based) or any direct provider via
 *                     AGENT_MODEL + its API key secret. Not hardcoded.
 */
export class PlatformStack extends cdk.Stack {
  /** ECR repository the server image is pushed to (deploy-image.sh / CI/CD). */
  readonly repository: ecr.Repository;
  /** ECS cluster — passed to the optional CicdStack as ecs.ICluster. */
  readonly cluster: ecs.Cluster;
  /** ECS service — passed to the optional CicdStack as ecs.IBaseService. */
  readonly service: ecs.FargateService;

  constructor(scope: Construct, id: string, props: PlatformStackProps) {
    super(scope, id, props);

    const ctx = (n: string, d: unknown) =>
      this.node.tryGetContext(`agser:${n}`) ?? d;
    const desiredCount = ctx('desiredCount', 2) as number;
    const cpu = ctx('cpu', 1024) as number;
    const memoryMiB = ctx('memoryMiB', 4096) as number;
    // t4g.* is the valid RDS class family (db.t4g.small).
    const dbInstanceClass = ctx('dbInstanceClass', 't4g.small') as string;
    const dbMultiAz = ctx('dbMultiAz', true) as boolean;
    // SIMULATION ONLY (FloCI/local emulator): an explicit DB password so the
    // emulator can start its real Postgres container. Leave unset in prod —
    // the generated-secret dynamic reference is used instead.
    const dbPassword = ctx('dbPassword', '') as string;
    const redisNodeType = ctx('redisNodeType', 'cache.t4g.small') as string;
    const maxCapacity = ctx('maxCapacity', 12) as number;
    const modelProvider = ctx('modelProvider', 'bedrock') as string;
    const agentModel = ctx('agentModel', 'anthropic:claude-sonnet-4-5') as string;
    const bedrockModelId =
      ctx('bedrockModelId', 'anthropic.claude-sonnet-4-5-20250929-v1:0') as string;
    // Emulator override: a registry-reachable image reference (e.g.
    // host.docker.internal:5100/<repo> for FloCI). Default: ECR (real AWS).
    const imageOverride = ctx('imageUri', '') as string;
    // Emulator override for the Redis URI (FloCI's ElastiCache is limited);
    // default builds it from the replication group endpoint (real AWS).
    const redisOverride = ctx('redisUri', '') as string;
    // OTLP trace export endpoint (Langfuse/Phoenix), or unset for off.
    const otelEndpoint = ctx('otelEndpoint', '') as string;
    // Which config file the task loads. Real AWS default keeps the semantic
    // store index (RDS supports pgvector). The FloCI emulator's RDS has no
    // pgvector, so emulator deploys pass aegra.aws.emulator.json.
    const configFile = ctx('configFile', 'aegra.aws.json') as string;

    // ---------------------------------------------------------------- VPC
    // One NAT per AZ: outbound traffic (model calls) survives an AZ failure.
    const vpc = new ec2.Vpc(this, 'Vpc', {
      maxAzs: 2,
      natGateways: 2,
    });

    // ---------------------------------------------------------------- ECR
    const repo = new ecr.Repository(this, 'AgentServerRepo', {
      imageTagMutability: ecr.TagMutability.MUTABLE, // deploy script pushes :latest
      removalPolicy: cdk.RemovalPolicy.RETAIN,
      imageScanOnPush: true,
    });
    this.repository = repo;

    // ---------------------------------------------------------------- Secrets
    const platformApiKey = new secretsmanager.Secret(this, 'PlatformApiKey', {
      secretName: 'agser/platform-api-key',
      description: 'Shared API key clients send as x-api-key / Bearer',
      generateSecretString: {
        excludePunctuation: true,
        passwordLength: 40,
      },
    });
    const anthropicKey = new secretsmanager.Secret(this, 'AnthropicKey', {
      secretName: 'agser/anthropic-api-key',
      description:
        'Anthropic API key (only needed when MODEL_PROVIDER is not bedrock)',
    });
    const openrouterKey = new secretsmanager.Secret(this, 'OpenrouterKey', {
      secretName: 'agser/openrouter-api-key',
      description: 'OpenRouter API key (or any OpenAI-compatible gateway)',
    });
    // agser (ours): AES checkpoint encryption in production — restore of the
    // official LANGGRAPH_AES_KEY contract on AWS (32-char generated key).
    const aesKey = new secretsmanager.Secret(this, 'AesKey', {
      secretName: 'agser/aes-key',
      description: 'LANGGRAPH_AES_KEY — checkpoint encryption at rest',
      generateSecretString: {
        excludePunctuation: true,
        excludeUppercase: false,
        excludeLowercase: false,
        includeSpace: false,
        passwordLength: 32,
      },
    });

    // ---------------------------------------------------------------- RDS Postgres 16 — Multi-AZ with automatic failover
    const db = new rds.DatabaseInstance(this, 'Postgres', {
      engine: rds.DatabaseInstanceEngine.postgres({
        version: rds.PostgresEngineVersion.VER_16,
      }),
      instanceType: new ec2.InstanceType(dbInstanceClass),
      instanceIdentifier: 'agser-postgres',
      vpc,
      vpcSubnets: { subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS },
      credentials: dbPassword
        ? rds.Credentials.fromPassword(
            'postgres', cdk.SecretValue.unsafePlainText(dbPassword),
          )
        : rds.Credentials.fromGeneratedSecret('postgres', {
            secretName: 'agser/rds-credentials',
          }),
      databaseName: 'langgraph',
      multiAz: dbMultiAz,
      allocatedStorage: 50,
      storageEncrypted: true,
      storageType: rds.StorageType.GP3,
      deletionProtection: true,
      removalPolicy: cdk.RemovalPolicy.RETAIN,
      backupRetention: cdk.Duration.days(7), // PITR window
      preferredBackupWindow: '01:00-02:00',
      preferredMaintenanceWindow: 'Sun:03:00-04:00',
      cloudwatchLogsExports: ['postgresql'],
    });

    // ---------------------------------------------------------------- ElastiCache Redis — replication group with automatic failover
    const redisSg = new ec2.SecurityGroup(this, 'RedisSg', {
      vpc,
      description: 'ElastiCache Redis for Agser',
      allowAllOutbound: false,
    });
    const redisSubnetGroup = new elasticache.CfnSubnetGroup(
      this,
      'RedisSubnetGroup',
      {
        description: 'Agser Redis subnet group',
        subnetIds: vpc.privateSubnets.map((s) => s.subnetId),
      },
    );
    // L1: no stable L2 exists for ElastiCache. Primary + replica, auto failover.
    const redis = new elasticache.CfnReplicationGroup(this, 'Redis', {
      replicationGroupDescription: 'Agser Redis (auto failover)',
      engine: 'redis',
      engineVersion: '7.1',
      cacheNodeType: redisNodeType,
      replicationGroupId: 'agser-redis',
      numCacheClusters: 2,
      automaticFailoverEnabled: true,
      multiAzEnabled: true,
      cacheSubnetGroupName: redisSubnetGroup.ref,
      securityGroupIds: [redisSg.securityGroupId],
    });

    // ---------------------------------------------------------------- ALB
    const albSg = new ec2.SecurityGroup(this, 'AlbSg', {
      vpc,
      description: 'Agser ALB',
      allowAllOutbound: true,
    });
    for (const cidr of props.allowedCidrs) {
      albSg.addIngressRule(
        ec2.Peer.ipv4(cidr),
        props.certificateArn ? ec2.Port.tcp(443) : ec2.Port.tcp(80),
        `from ${cidr}`,
      );
    }

    const alb = new elbv2.ApplicationLoadBalancer(this, 'Alb', {
      vpc,
      internetFacing: true,
      securityGroup: albSg,
    });
    // Keep SSE streams alive (agent responses can run long).
    alb.setAttribute('idle_timeout.timeout_seconds', '3600');

    let targetListener: elbv2.ApplicationListener;
    if (props.certificateArn) {
      alb.addListener('Http', {
        port: 80,
        defaultAction: elbv2.ListenerAction.redirect({
          port: '443',
          protocol: 'HTTPS',
          permanent: true,
        }),
      });
      targetListener = alb.addListener('Https', {
        port: 443,
        certificates: [elbv2.ListenerCertificate.fromArn(props.certificateArn)],
        open: false,
      });
    } else {
      targetListener = alb.addListener('Http', { port: 80, open: false });
    }

    // ---------------------------------------------------------------- ECS
    const cluster = new ecs.Cluster(this, 'Cluster', {
      vpc,
      clusterName: 'agser',
      containerInsightsV2: ecs.ContainerInsights.ENABLED,
    });
    this.cluster = cluster;

    const serverSg = new ec2.SecurityGroup(this, 'ServerSg', {
      vpc,
      description: 'Agent Server tasks',
      allowAllOutbound: true,
    });

    const taskDef = new ecs.FargateTaskDefinition(this, 'ServerTask', {
      cpu,
      memoryLimitMiB: memoryMiB,
      runtimePlatform: {
        cpuArchitecture: ecs.CpuArchitecture.ARM64,
        operatingSystemFamily: ecs.OperatingSystemFamily.LINUX,
      },
    });

    // Bedrock access via IAM — no static keys, inference stays in-account.
    taskDef.taskRole.attachInlinePolicy(
      new iam.Policy(this, 'BedrockInvoke', {
        statements: [
          new iam.PolicyStatement({
            actions: [
              'bedrock:InvokeModel',
              'bedrock:InvokeModelWithResponseStream',
              // agser (ours): backlog-metrics publisher (extensions/app.py)
              'cloudwatch:PutMetricData',
            ],
            resources: [
              'arn:aws:bedrock:*::foundation-model/*',
              `arn:aws:bedrock:${this.region}:${this.account}:inference-profile/*`,
            ],
          }),
        ],
      }),
    );

    const container = taskDef.addContainer('server', {
      image: imageOverride
        ? ecs.ContainerImage.fromRegistry(imageOverride)
        : ecs.ContainerImage.fromEcrRepository(repo, 'latest'),
      portMappings: [{ containerPort: 8123 }],
      // Our owned server core (server-core/ in this repo).
      command: [
        'python', '-m', 'uvicorn', 'aegra_api.main:app',
        '--host', '0.0.0.0', '--port', '8123',
      ],
      // ECS-managed health check — a hung container is killed and replaced.
      healthCheck: {
        command: [
          'CMD', 'python', '-c',
          'import urllib.request,sys; urllib.request.urlopen("http://127.0.0.1:8123/health", timeout=3); sys.exit(0)',
        ],
        interval: cdk.Duration.seconds(15),
        timeout: cdk.Duration.seconds(5),
        retries: 5,
        startPeriod: cdk.Duration.seconds(30),
      },
      logging: ecs.LogDriver.awsLogs({
        logGroup: new logs.LogGroup(this, 'ServerLogs', {
          logGroupName: '/agser/agent-server',
          retention: logs.RetentionDays.ONE_MONTH,
          removalPolicy: cdk.RemovalPolicy.DESTROY,
        }),
        streamPrefix: 'server',
      }),
      environment: {
        // Our owned server core (server-core/): aegra-api configuration.
        AEGRA_CONFIG: configFile,
        REDIS_BROKER_ENABLED: 'true',
        REDIS_URL: redisOverride || `redis://${redis.attrPrimaryEndPointAddress}:${redis.attrPrimaryEndPointPort}`,
        WORKER_COUNT: '3',
        N_JOBS_PER_WORKER: '10',
        RUN_MIGRATIONS_ON_STARTUP: 'true',
        // Port comes from the RDS endpoint (FloCI maps Postgres to a
        // proxy port; real AWS uses 5432).
        POSTGRES_PORT: cdk.Token.asString(db.instanceEndpoint.port),
        POSTGRES_DB: 'langgraph',
        ...(dbPassword
          ? {
              POSTGRES_HOST: db.instanceEndpoint.hostname,
              POSTGRES_USER: 'postgres',
              POSTGRES_PASSWORD: dbPassword,
            }
          : {}),
        // Privacy: no tracing, no telemetry to LangSmith or anywhere else.
        LANGSMITH_TRACING: 'false',
        // Inference provider is a deployment choice, not a code constant.
        MODEL_PROVIDER: modelProvider,
        AGENT_MODEL: agentModel,
        BEDROCK_MODEL_ID: bedrockModelId,
        AWS_REGION: this.region,
        SLEEPY_SECS: '45',
        // agser (ours): publish PendingRuns/RunningRuns to CloudWatch every
        // 60s; consumed by the step-scaling policy below (PDF §8 backlog
        // autoscaling). No-op locally (namespace unset).
        AGSER_CW_NAMESPACE: 'AgserPlatform',
        // OTEL tracing to any OTLP endpoint (Langfuse/Phoenix/etc.); off by
        // default — enable with context agser:otelEndpoint. Traces NEVER go
        // to LangSmith.
        ...(otelEndpoint
          ? {
              OTEL_EXPORTER_OTLP_ENDPOINT: otelEndpoint,
              OTEL_SERVICE_NAME: 'agser-platform',
            }
          : {}),
      },
      secrets: {
        ...(dbPassword
          ? {}
          : {
              POSTGRES_HOST: ecs.Secret.fromSecretsManager(db.secret!, 'host'),
              POSTGRES_USER: ecs.Secret.fromSecretsManager(db.secret!, 'username'),
              POSTGRES_PASSWORD: ecs.Secret.fromSecretsManager(db.secret!, 'password'),
            }),
        PLATFORM_API_KEY: ecs.Secret.fromSecretsManager(platformApiKey),
        ANTHROPIC_API_KEY: ecs.Secret.fromSecretsManager(anthropicKey),
        OPENROUTER_API_KEY: ecs.Secret.fromSecretsManager(openrouterKey),
        LANGGRAPH_AES_KEY: ecs.Secret.fromSecretsManager(aesKey),
      },
    });
    container.addUlimits({
      name: ecs.UlimitName.NOFILE,
      softLimit: 65536,
      hardLimit: 65536,
    });

    const service = new ecs.FargateService(this, 'ServerService', {
      cluster,
      taskDefinition: taskDef,
      desiredCount,
      securityGroups: [serverSg],
      assignPublicIp: false,
      vpcSubnets: { subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS },
      healthCheckGracePeriod: cdk.Duration.seconds(60),
      // Zero-downtime rolling deploys; failed rollout rolls back automatically.
      minHealthyPercent: 100,
      maxHealthyPercent: 200,
      circuitBreaker: { rollback: true },
    });
    this.service = service;

    const targetGroup = targetListener.addTargets('ServerTarget', {
      port: 8123,
      protocol: elbv2.ApplicationProtocol.HTTP,
      targets: [service],
      healthCheck: {
        path: '/ok',
        interval: cdk.Duration.seconds(15),
        healthyHttpCodes: '200',
      },
    });
    // Let long agent responses drain fully during redeploys.
    targetGroup.setAttribute('deregistration_delay.timeout_seconds', '3600');

    // Network wiring
    serverSg.addIngressRule(albSg, ec2.Port.tcp(8123), 'ALB → server');
    db.connections.allowFrom(serverSg, ec2.Port.tcp(5432), 'server → postgres');
    redisSg.addIngressRule(
      ec2.Peer.securityGroupId(serverSg.securityGroupId),
      ec2.Port.tcp(6379),
      'server → redis',
    );

    // Secrets access
    platformApiKey.grantRead(taskDef.taskRole);
    anthropicKey.grantRead(taskDef.taskRole);

    // ---------------------------------------------------------------- Auto scaling
    const scaling = service.autoScaleTaskCount({
      minCapacity: 2, // never below 2: rolling deploys + AZ failure tolerance
      maxCapacity,
    });
    // Scale on request load — the signal that matters for agent traffic —
    // and on CPU (graph execution is CPU-heavy).
    scaling.scaleOnRequestCount('RequestScaling', {
      targetGroup,
      requestsPerTarget: 50,
      scaleInCooldown: cdk.Duration.minutes(3),
      scaleOutCooldown: cdk.Duration.minutes(1),
    });
    scaling.scaleOnCpuUtilization('CpuScaling', {
      targetUtilizationPercent: 60,
      scaleInCooldown: cdk.Duration.minutes(3),
      scaleOutCooldown: cdk.Duration.minutes(1),
    });
    // agser (ours): backlog autoscaling — step-scale on pending runs
    // (published by extensions/app.py to the AgserPlatform namespace).
    // Whichever policy needs more replicas wins (PDF §8).
    scaling.scaleOnMetric('BacklogScaling', {
      metric: new cloudwatch.Metric({
        namespace: 'AgserPlatform',
        metricName: 'PendingRuns',
        statistic: 'Average',
        period: cdk.Duration.minutes(1),
      }),
      scalingSteps: [
        { change: +2, lower: 15 },   // >15 pending → add 2 tasks
        { change: +1, lower: 5 },    // >5 pending  → add 1 task
        { change: -1, upper: 1 },    // ≤1 pending  → remove 1 task
      ],
    });

    // ---------------------------------------------------------------- Alarms
    const alertTopic = new sns.Topic(this, 'Alerts', {
      displayName: 'agser-platform-alerts',
    });
    const alertEmail = this.node.tryGetContext('alertEmail') as string | undefined;
    if (alertEmail) {
      alertTopic.addSubscription(
        new subscriptions.EmailSubscription(alertEmail),
      );
    }

    const alarmProps = {
      alarmActions: [alertTopic],
      evaluationPeriods: 3,
    };

    new cloudwatch.Alarm(this, 'AlbTarget5xx', {
      ...alarmProps,
      metric: new cloudwatch.Metric({
        namespace: 'AWS/ApplicationELB',
        metricName: 'HTTPCode_Target_5XX_Count',
        dimensionsMap: {
          LoadBalancer: alb.loadBalancerFullName,
          TargetGroup: targetGroup.targetGroupFullName,
        },
        statistic: 'Sum',
        period: cdk.Duration.minutes(1),
      }),
      threshold: 10,
      alarmDescription: 'Agent Server returning 5xx through the ALB',
    });

    new cloudwatch.Alarm(this, 'UnhealthyHosts', {
      ...alarmProps,
      metric: new cloudwatch.Metric({
        namespace: 'AWS/ApplicationELB',
        metricName: 'UnHealthyHostCount',
        dimensionsMap: {
          LoadBalancer: alb.loadBalancerFullName,
          TargetGroup: targetGroup.targetGroupFullName,
        },
        statistic: 'Maximum',
        period: cdk.Duration.minutes(1),
      }),
      threshold: 1,
      alarmDescription: 'Agent Server target group has unhealthy hosts',
    });

    new cloudwatch.Alarm(this, 'TargetResponseTime', {
      ...alarmProps,
      metric: new cloudwatch.Metric({
        namespace: 'AWS/ApplicationELB',
        metricName: 'TargetResponseTime',
        dimensionsMap: {
          LoadBalancer: alb.loadBalancerFullName,
          TargetGroup: targetGroup.targetGroupFullName,
        },
        statistic: 'p95',
        period: cdk.Duration.minutes(5),
      }),
      threshold: 300,
      alarmDescription: 'p95 response time above 5 minutes (agents wedged?)',
    });

    new cloudwatch.Alarm(this, 'DbFailoverOrDown', {
      ...alarmProps,
      metric: db.metricDatabaseConnections({ statistic: 'Minimum' }),
      threshold: 1,
      comparisonOperator: cloudwatch.ComparisonOperator.LESS_THAN_THRESHOLD,
      alarmDescription: 'Postgres unreachable (failover or outage)',
    });

    // ---------------------------------------------------------------- Outputs
    new cdk.CfnOutput(this, 'AlbDns', { value: alb.loadBalancerDnsName });
    new cdk.CfnOutput(this, 'EcrRepoUri', {
      value: `${repo.repositoryUri}:latest`,
    });
    new cdk.CfnOutput(this, 'ClusterName', { value: cluster.clusterName });
    new cdk.CfnOutput(this, 'ServiceName', { value: service.serviceName });
    new cdk.CfnOutput(this, 'PlatformApiKeySecretArn', {
      value: platformApiKey.secretArn,
    });
    new cdk.CfnOutput(this, 'AnthropicKeySecretArn', {
      value: anthropicKey.secretArn,
    });
    new cdk.CfnOutput(this, 'AlertTopicArn', { value: alertTopic.topicArn });
  }
}
