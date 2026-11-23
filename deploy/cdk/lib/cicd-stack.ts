import * as cdk from 'aws-cdk-lib';
import * as codebuild from 'aws-cdk-lib/aws-codebuild';
import * as codepipeline from 'aws-cdk-lib/aws-codepipeline';
import * as codepipelineActions from 'aws-cdk-lib/aws-codepipeline-actions';
import * as ecr from 'aws-cdk-lib/aws-ecr';
import * as ecs from 'aws-cdk-lib/aws-ecs';
import * as iam from 'aws-cdk-lib/aws-iam';
import { Construct } from 'constructs';

export interface CicdStackProps extends cdk.StackProps {
  /** Existing ECS cluster from PlatformStack. */
  readonly cluster: ecs.ICluster;
  /** Existing ECS service from PlatformStack that the pipeline deploys to. */
  readonly service: ecs.IBaseService;
  /** Existing ECR repository from PlatformStack that receives the images. */
  readonly repository: ecr.IRepository;
}

/**
 * OPTIONAL AWS-native CI/CD pipeline for the platform (opt-in via context
 * `agser:cicd=true`; see deploy/cicd/README.md):
 *
 *   GitHub (CodeStar Connections source)
 *     → CodeBuild (privileged Docker): build the server image, push it to
 *       ECR by commit SHA, then run the full local compose stack and all
 *       four conformance suites (verify, features, HITL, failure-injection)
 *     → ECS rolling deploy of the freshly pushed image (imagedefinitions.json)
 *
 * The pipeline reuses the platform's existing ECR repository, ECS cluster and
 * service — nothing here (re)creates platform infrastructure.
 */
export class CicdStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: CicdStackProps) {
    super(scope, id, props);

    // Context (passed as -c agser:<key>=<value> at synth/deploy time).
    const ctx = (n: string, d: unknown) =>
      this.node.tryGetContext(`agser:${n}`) ?? d;
    const connectionArn = ctx('codestarConnectionArn', '') as string;
    const githubOwner = ctx('githubOwner', '') as string;
    const githubRepo = ctx('githubRepo', '') as string;
    const githubBranch = ctx('githubBranch', 'main') as string;

    if (!connectionArn || !githubOwner || !githubRepo) {
      throw new Error(
        'CicdStack requires the context values agser:codestarConnectionArn, ' +
        'agser:githubOwner and agser:githubRepo ' +
        '(see deploy/cicd/README.md). Pass -c agser:cicd=true plus these to enable the pipeline.',
      );
    }

    // ------------------------------------------------------------- Pipeline
    const pipeline = new codepipeline.Pipeline(this, 'Pipeline', {
      pipelineName: 'agser-platform',
      // Roll back-incompatible pipeline structure updates by restarting
      // executions — keeps deploys flowing after a stack update.
      restartExecutionOnUpdate: true,
    });

    const sourceOutput = new codepipeline.Artifact('Source');
    const buildOutput = new codepipeline.Artifact('Build');

    // ------------------------------------------------------------ CodeBuild
    // Privileged mode = Docker-in-Docker: builds the server image, pushes to
    // ECR, and runs the whole compose stack to execute the test suites.
    const project = new codebuild.PipelineProject(this, 'BuildAndTest', {
      projectName: 'agser-platform-build',
      environment: {
        // CDK 2.180 ships AL2023 images under versioned constants; _5 is
        // the newest non-EOL tag available in this library version.
        buildImage: codebuild.LinuxBuildImage.AMAZON_LINUX_2023_5,
        computeType: codebuild.ComputeType.SMALL,
        privileged: true,
      },
      environmentVariables: {
        ECR_REPO_URI: { value: props.repository.repositoryUri },
        AWS_REGION: { value: this.region },
      },
      // The pipeline source is the whole repository, so the buildspec can be
      // read straight from the checkout.
      buildSpec: codebuild.BuildSpec.fromSourceFilename(
        'deploy/cicd/buildspec.yml',
      ),
    });

    // ECR push/pull (BatchGet/GetDownloadUrl cover pulling base images from the
    // repo on cache hits; the PowerUser policy is a superset of the listed
    // ecr:* actions). CloudWatch Logs for build logs.
    project.role!.addManagedPolicy(
      iam.ManagedPolicy.fromAwsManagedPolicyName(
        'AmazonEC2ContainerRegistryPowerUser',
      ),
    );
    project.role!.addManagedPolicy(
      iam.ManagedPolicy.fromAwsManagedPolicyName('CloudWatchLogsFullAccess'),
    );

    // --------------------------------------------------------------- Stages
    pipeline.addStage({
      stageName: 'Source',
      actions: [
        new codepipelineActions.CodeStarConnectionsSourceAction({
          actionName: 'GitHubSource',
          connectionArn,
          owner: githubOwner,
          repo: githubRepo,
          branch: githubBranch,
          output: sourceOutput,
        }),
      ],
    });

    pipeline.addStage({
      stageName: 'Build',
      actions: [
        new codepipelineActions.CodeBuildAction({
          actionName: 'BuildAndTest',
          project,
          input: sourceOutput,
          // The post_build phase writes imagedefinitions.json to the repo
          // root; it ships with the build output artifact.
          outputs: [buildOutput],
        }),
      ],
    });

    pipeline.addStage({
      stageName: 'Deploy',
      actions: [
        new codepipelineActions.EcsDeployAction({
          actionName: 'DeployToEcs',
          input: buildOutput,
          service: props.service,
        }),
      ],
    });

    // ------------------------------------------------------------- Outputs
    new cdk.CfnOutput(this, 'PipelineName', { value: pipeline.pipelineName });
    new cdk.CfnOutput(this, 'TargetCluster', {
      value: props.cluster.clusterName,
    });
    new cdk.CfnOutput(this, 'TargetService', { value: props.service.serviceName });
    new cdk.CfnOutput(this, 'BuildProjectName', { value: project.projectName });
  }
}
