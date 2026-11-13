# The policies of the bench role: EC2 (local.policy) and the SSH session
# (local.session_policy).
#
# The Project tag is the security boundary. The role can change only the
# resources that carry Project = var.project, and every resource that it
# creates must carry that tag. The EC2 policy grants no other service. The
# session policy grants iam:PassRole for the box role only, and that role
# grants nothing beyond Session Manager, so the role cannot escalate its own
# privileges.
#
# The role launches from the launch templates that a person applies with
# bench-base, and it cannot write them. So the user_data, the TTL guard, the
# shutdown behavior, and the metadata options come from that person. The
# role can still set ExpiresAt to any value, which is why the reaper
# (reaper.tf) is the lifetime guarantee. This policy keeps each resource
# visible to the reaper: exact tag keys, a Project tag that cannot change,
# no DeleteTags, and no StopInstances or StartInstances.
#
# RunInstances authorizes one ARN for each resource in the request: instance,
# volume, network-interface, security-group, subnet, image, key-pair, and
# launch-template. Each resource type supports different condition keys, and
# a condition key that does not apply to a resource type is absent for it,
# which makes a plain StringEquals fail. So each RunInstances statement below
# covers only the resource types that support its condition keys.
#
# Condition keys come from the Service Authorization Reference for EC2:
# https://docs.aws.amazon.com/service-authorization/latest/reference/list_amazonec2.html

locals {
  # ARN prefix for the EC2 resources of this account and region. Image ARNs
  # have no account field, so they do not use this prefix.
  ec2 = "arn:aws:ec2:${var.region}:${var.account_id}"

  launch_templates = "${local.ec2}:launch-template/*"

  # ec2:LaunchTemplate is present on every resource type of a RunInstances
  # request that uses a launch template, and absent when the request uses no
  # launch template. Each RunInstances statement (except the one for the
  # launch template itself) requires it, so a request without a launch
  # template matches no statement.
  uses_launch_template = { "ec2:LaunchTemplate" = local.launch_templates }

  # The tag keys that the role can write, with exact case. IAM compares the
  # tag key in aws:RequestTag/<key> and aws:ResourceTag/<key> without case,
  # so a request with PROJECT=<project> passes a Project condition, but the
  # tag:Project filter of DescribeInstances (the harness, the reaper) does
  # not find the resource. aws:TagKeys with StringEquals compares with case.
  # Every statement that creates tags carries this condition. The launch
  # template tags (Project, ManagedBy) are in the set.
  canonical_tag_keys = {
    "aws:TagKeys" = ["Project", "ManagedBy", "Name", "Target", "ExpiresAt", "Owner"]
  }

  policy = {
    Version = "2012-10-17"
    Statement = [
      {
        # Read-only. Most Describe actions do not support resource-level
        # permissions, so the resource is "*". The harness calls
        # DescribeInstances and DescribeLaunchTemplates. Get* adds
        # GetConsoleOutput for boot debugging.
        Sid      = "Read"
        Effect   = "Allow"
        Action   = ["ec2:Describe*", "ec2:Get*"]
        Resource = "*"
      },
      {
        # The instance. aws:RequestTag/Project requires the request to tag
        # the instance with the project. The Null test requires an ExpiresAt
        # tag, which the TTL guard on the box reads. ec2:InstanceType limits
        # the families:
        # "c7i.*" matches c7i.xlarge and c7i.metal-48xl, but not
        # c7i-flex.large or c7gn.xlarge, because the family name must end at
        # the dot. ec2:InstanceMarketType blocks Spot and Capacity Blocks;
        # EC2 sets it to "on-demand" on a plain launch. ec2:Tenancy blocks
        # dedicated tenancy, which costs extra. IfExists: the key can be
        # absent when the request does not set it.
        Sid      = "RunInstancesInstance"
        Effect   = "Allow"
        Action   = "ec2:RunInstances"
        Resource = "${local.ec2}:instance/*"
        Condition = {
          StringEquals = {
            "aws:RequestTag/Project" = var.project
            "ec2:InstanceMarketType" = "on-demand"
          }
          Null                        = { "aws:RequestTag/ExpiresAt" = "false" }
          StringLike                  = { "ec2:InstanceType" = [for family in var.instance_families : "${family}.*"] }
          ArnLike                     = local.uses_launch_template
          StringEqualsIfExists        = { "ec2:Tenancy" = "default" }
          "ForAllValues:StringEquals" = local.canonical_tag_keys
        }
      },
      {
        # The EBS volumes. They must carry the project tag too. The limits
        # stop a request that overrides the launch template volume with a
        # large volume or with paid IOPS or throughput: 3000 IOPS and
        # 125 MiB/s are the gp3 baseline that the volume price includes.
        # IfExists: EC2 omits a key that the request and the launch template
        # do not set. The reaper deletes volumes that outlive their instance.
        Sid      = "RunInstancesVolume"
        Effect   = "Allow"
        Action   = "ec2:RunInstances"
        Resource = "${local.ec2}:volume/*"
        Condition = {
          StringEquals         = { "aws:RequestTag/Project" = var.project }
          ArnLike              = local.uses_launch_template
          StringEqualsIfExists = { "ec2:VolumeType" = "gp3" }
          NumericLessThanEqualsIfExists = {
            "ec2:VolumeSize"       = tostring(var.max_volume_gib)
            "ec2:VolumeIops"       = "3000"
            "ec2:VolumeThroughput" = "125"
          }
          "ForAllValues:StringEquals" = local.canonical_tag_keys
        }
      },
      {
        # The launch template. It must be one of the project templates. This
        # resource is optional in RunInstances, so this statement alone does
        # not force a launch template. uses_launch_template does that.
        Sid       = "RunInstancesLaunchTemplate"
        Effect    = "Allow"
        Action    = "ec2:RunInstances"
        Resource  = local.launch_templates
        Condition = { StringEquals = { "aws:ResourceTag/Project" = var.project } }
      },
      {
        # The AMI. ec2:Owner allows only the NixOS publisher, which blocks
        # AMIs with license or Marketplace fees. ec2:IsLaunchTemplateResource
        # requires the AMI to come from the launch template, not from an
        # ImageId override in the request.
        Sid      = "RunInstancesImage"
        Effect   = "Allow"
        Action   = "ec2:RunInstances"
        Resource = "arn:aws:ec2:${var.region}::image/*"
        Condition = {
          StringEquals = { "ec2:Owner" = var.image_owners }
          Bool         = { "ec2:IsLaunchTemplateResource" = "true" }
          ArnLike      = local.uses_launch_template
        }
      },
      {
        # The security group. It must be a project resource, and it must come
        # from the launch template. No statement allows a key-pair resource,
        # so a request that names a key pair fails: SSH keys come only from
        # EC2 Instance Connect.
        Sid      = "RunInstancesSecurityGroup"
        Effect   = "Allow"
        Action   = "ec2:RunInstances"
        Resource = "${local.ec2}:security-group/*"
        Condition = {
          StringEquals = { "aws:ResourceTag/Project" = var.project }
          Bool         = { "ec2:IsLaunchTemplateResource" = "true" }
          ArnLike      = local.uses_launch_template
        }
      },
      {
        # The subnet. The launch template sets no subnet, so EC2 selects a
        # default subnet, and ec2:IsLaunchTemplateResource would be false.
        # The security group statement above already keeps the instance in
        # the default VPC, because a security group works only in its own VPC.
        Sid       = "RunInstancesSubnet"
        Effect    = "Allow"
        Action    = "ec2:RunInstances"
        Resource  = "${local.ec2}:subnet/*"
        Condition = { ArnLike = local.uses_launch_template }
      },
      {
        # The new network interface. It must carry the project tag, so that
        # the reaper can find it if it outlives its instance. The tag comes
        # from the request or from the launch template.
        Sid      = "RunInstancesNetworkInterface"
        Effect   = "Allow"
        Action   = "ec2:RunInstances"
        Resource = "${local.ec2}:network-interface/*"
        Condition = {
          StringEquals                = { "aws:RequestTag/Project" = var.project }
          ArnLike                     = local.uses_launch_template
          "ForAllValues:StringEquals" = local.canonical_tag_keys
        }
      },
      {
        # Tags in a create request. EC2 authorizes ec2:CreateTags for each
        # resource that RunInstances tags, with ec2:CreateAction set to
        # RunInstances. Without this statement, RunInstances with
        # TagSpecifications (or with tags from the launch template) fails.
        # A Project tag, if present, must have the project value. Tag keys
        # must be canonical.
        Sid      = "TagOnCreate"
        Effect   = "Allow"
        Action   = "ec2:CreateTags"
        Resource = "${local.ec2}:*/*"
        Condition = {
          StringEquals = {
            "ec2:CreateAction" = "RunInstances"
          }
          StringEqualsIfExists        = { "aws:RequestTag/Project" = var.project }
          "ForAllValues:StringEquals" = local.canonical_tag_keys
        }
      },
      {
        # Tags on existing project instances: `bench extend` rewrites
        # ExpiresAt. The instance must already carry the project tag, so the
        # role cannot pull a foreign resource into the boundary. The request
        # cannot change the Project value, and it cannot add a tag key
        # outside the canonical set. No statement allows DeleteTags, so
        # Project and ExpiresAt stay on every resource.
        Sid      = "TagProjectInstances"
        Effect   = "Allow"
        Action   = "ec2:CreateTags"
        Resource = "${local.ec2}:instance/*"
        Condition = {
          StringEquals                = { "aws:ResourceTag/Project" = var.project }
          StringEqualsIfExists        = { "aws:RequestTag/Project" = var.project }
          "ForAllValues:StringEquals" = local.canonical_tag_keys
        }
      },
      {
        # Instance termination for the harness: down, reap. No
        # StopInstances or StartInstances: a stopped box does not run its
        # TTL guard, and a start resets LaunchTime, which the reaper uses.
        Sid       = "TerminateInstances"
        Effect    = "Allow"
        Action    = "ec2:TerminateInstances"
        Resource  = "${local.ec2}:instance/*"
        Condition = { StringEquals = { "aws:ResourceTag/Project" = var.project } }
      },
      {
        # Deny every action outside the fleet region. This catches the
        # Describe and Get actions, which have no region in their resource.
        # sts:GetCallerIdentity is global, and AWS allows it even with an
        # explicit deny. iam:PassRole is global too: it is checked inside a
        # RunInstances request, and the session policy limits it to the box
        # role. The exceptions keep a regional deny off global actions.
        Sid       = "DenyOtherRegions"
        Effect    = "Deny"
        NotAction = ["sts:GetCallerIdentity", "iam:PassRole"]
        Resource  = "*"
        Condition = { StringNotEquals = { "aws:RequestedRegion" = var.region } }
      },
    ]
  }

  # The SSH path. A person or agent reaches a box in three steps:
  # RunInstances passes the box role, SendSSHPublicKey puts a public key in
  # the instance metadata for 60 seconds, and StartSession opens an SSM
  # session that tunnels SSH to localhost:22. The box has no inbound rule.
  session_policy = {
    Version = "2012-10-17"
    Statement = [
      {
        # The box role, and only to EC2. RunInstances checks this when the
        # launch template names the instance profile.
        Sid       = "PassBoxRole"
        Effect    = "Allow"
        Action    = "iam:PassRole"
        Resource  = aws_iam_role.box.arn
        Condition = { StringEquals = { "iam:PassedToService" = "ec2.amazonaws.com" } }
      },
      {
        # A 60-second key for root on a project instance. ec2:osuser limits
        # the user that the key is for.
        Sid      = "SendSSHPublicKey"
        Effect   = "Allow"
        Action   = "ec2-instance-connect:SendSSHPublicKey"
        Resource = "${local.ec2}:instance/*"
        Condition = {
          StringEquals = {
            "aws:ResourceTag/Project" = var.project
            "ec2:osuser"              = "root"
          }
        }
      },
      {
        # An SSM session to a project instance. ssm:resourceTag is the tag
        # key that Session Manager evaluates for an instance target.
        # SessionDocumentAccessCheck makes Session Manager check the session
        # document too, so a request without a document (a plain shell, the
        # SSM-SessionManagerRunShell default) fails. The next statement
        # allows the one document.
        Sid      = "StartSessionOnProjectInstances"
        Effect   = "Allow"
        Action   = "ssm:StartSession"
        Resource = "${local.ec2}:instance/*"
        Condition = {
          StringEquals = { "ssm:resourceTag/Project" = var.project }
          BoolIfExists = { "ssm:SessionDocumentAccessCheck" = "true" }
        }
      },
      {
        # The AWS-owned document that forwards a session to the SSH port. An
        # AWS-owned document ARN has no account.
        Sid      = "StartSSHSessionDocument"
        Effect   = "Allow"
        Action   = "ssm:StartSession"
        Resource = "arn:aws:ssm:${var.region}::document/AWS-StartSSHSession"
      },
    ]
  }
}
