# Offline checks of the rendered bench role policies and the box role. The mock providers need
# no AWS credentials and write no files.
# Run: tofu -chdir=infra/modules/bench-iam test

variables {
  project           = "baskingspot-bench"
  region            = "us-west-2"
  account_id        = "123456789012"
  instance_families = ["c7i", "c8i", "c7a", "c8a", "c7g", "c8g", "c9g"]
}

mock_provider "archive" {}

mock_provider "aws" {
  # Resources that other resources validate as ARNs.
  mock_resource "aws_iam_policy" {
    defaults = {
      arn = "arn:aws:iam::123456789012:policy/baskingspot-bench-ec2"
    }
  }

  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/baskingspot-bench-reaper"
    }
  }

  mock_resource "aws_cloudwatch_log_group" {
    defaults = {
      arn = "arn:aws:logs:us-west-2:123456789012:log-group:/aws/lambda/baskingspot-bench-reaper"
    }
  }

  mock_resource "aws_lambda_function" {
    defaults = {
      arn = "arn:aws:lambda:us-west-2:123456789012:function:baskingspot-bench-reaper"
    }
  }

  mock_resource "aws_cloudwatch_event_rule" {
    defaults = {
      arn = "arn:aws:events:us-west-2:123456789012:rule/baskingspot-bench-reaper"
    }
  }
}

run "policy" {
  command = plan

  # IAM counts characters without white space. jsonencode emits none. If this
  # fails, split the policy into two managed policies on the user.
  assert {
    condition     = length(aws_iam_policy.bench.policy) <= 6144
    error_message = "The policy has ${length(aws_iam_policy.bench.policy)} characters. A managed policy can have 6,144."
  }

  assert {
    condition = (
      one([for s in local.policy.Statement : s.Condition.StringLike["ec2:InstanceType"] if s.Sid == "RunInstancesInstance"])
      == ["c7i.*", "c8i.*", "c7a.*", "c8a.*", "c7g.*", "c8g.*", "c9g.*"]
    )
    error_message = "The instance type allowlist changed."
  }

  # Every RunInstances statement, except the one for the launch template
  # itself, must require a launch template.
  assert {
    condition = alltrue([
      for s in local.policy.Statement :
      s.Condition.ArnLike["ec2:LaunchTemplate"] == "arn:aws:ec2:us-west-2:123456789012:launch-template/*"
      if try(s.Action, "") == "ec2:RunInstances" && s.Sid != "RunInstancesLaunchTemplate"
    ])
    error_message = "A RunInstances statement does not require a launch template."
  }

  # Every Allow statement except Read names ARNs in the fleet region.
  assert {
    condition = alltrue(flatten([
      for s in local.policy.Statement : [
        for r in flatten([s.Resource]) : startswith(r, "arn:aws:ec2:us-west-2:")
      ] if s.Effect == "Allow" && s.Sid != "Read"
    ]))
    error_message = "An Allow statement names a resource outside us-west-2."
  }

  # Only EC2 actions are allowed.
  assert {
    condition = alltrue(flatten([
      for s in local.policy.Statement : [
        for a in flatten([s.Action]) : startswith(a, "ec2:")
      ] if s.Effect == "Allow"
    ]))
    error_message = "The policy allows an action outside EC2."
  }

  # A person applies bench-base. The role cannot write the launch templates,
  # the security group, or a key pair, so it cannot change what boots on a
  # box or open a port.
  assert {
    condition = alltrue(flatten([
      for s in local.policy.Statement : [
        for a in flatten([s.Action]) : !anytrue([
          for prefix in [
            "ec2:CreateLaunchTemplate", "ec2:ModifyLaunchTemplate", "ec2:DeleteLaunchTemplate",
            "ec2:CreateSecurityGroup", "ec2:DeleteSecurityGroup", "ec2:AuthorizeSecurityGroup",
            "ec2:RevokeSecurityGroup", "ec2:ModifySecurityGroup", "ec2:ImportKeyPair", "ec2:CreateKeyPair",
            "ec2:DeleteKeyPair", "ec2:*",
          ] : startswith(a, prefix)
        ])
      ] if s.Effect == "Allow"
    ]))
    error_message = "The EC2 policy can change a launch template, a security group, or a key pair."
  }

  # No RunInstances statement allows a key-pair resource.
  assert {
    condition = alltrue(flatten([
      for s in local.policy.Statement : [
        for r in flatten([s.Resource]) : !strcontains(r, ":key-pair/")
      ] if s.Effect == "Allow"
    ]))
    error_message = "The EC2 policy allows a key pair."
  }

  # A stopped box does not run its TTL guard, and a start resets LaunchTime.
  assert {
    condition = alltrue(flatten([
      for s in local.policy.Statement : [
        for a in flatten([try(s.Action, [])]) : !contains(["ec2:StopInstances", "ec2:StartInstances", "ec2:*"], a)
      ] if s.Effect == "Allow"
    ]))
    error_message = "The policy allows StopInstances or StartInstances."
  }

  # Canonical tag keys: every Allow statement that creates tags (a
  # RunInstances statement that requires a request tag, a create action with
  # tags, or CreateTags) limits aws:TagKeys to the exact set. The default
  # tags of the root stacks (Project, ManagedBy) and the instance tags of the
  # harness are in the set.
  assert {
    condition = alltrue([
      for s in local.policy.Statement :
      try(s.Condition["ForAllValues:StringEquals"]["aws:TagKeys"], []) == ["Project", "ManagedBy", "Name", "Target", "ExpiresAt", "Owner"]
      if s.Effect == "Allow" && (
        contains(flatten([s.Action]), "ec2:CreateTags")
        || can(s.Condition.StringEquals["aws:RequestTag/Project"])
      )
    ])
    error_message = "A statement that creates tags does not limit aws:TagKeys to the canonical set."
  }

  assert {
    condition = toset([
      for s in local.policy.Statement : s.Sid
      if can(s.Condition["ForAllValues:StringEquals"]["aws:TagKeys"])
      ]) == toset([
      "RunInstancesInstance", "RunInstancesVolume", "RunInstancesNetworkInterface",
      "TagOnCreate", "TagProjectInstances",
    ])
    error_message = "The set of statements with the canonical tag key condition changed."
  }

  # Project and ExpiresAt stay: neither policy allows DeleteTags.
  assert {
    condition = !anytrue(flatten([
      for s in concat(local.policy.Statement, local.session_policy.Statement) : [
        for a in flatten([s.Action]) : a == "ec2:DeleteTags"
      ] if s.Effect == "Allow"
    ]))
    error_message = "A policy allows DeleteTags."
  }

  # EBS: gp3 baseline only, 100 GiB or smaller.
  assert {
    condition = (
      one([for s in local.policy.Statement : s.Condition.NumericLessThanEqualsIfExists if s.Sid == "RunInstancesVolume"])
      == { "ec2:VolumeSize" = "100", "ec2:VolumeIops" = "3000", "ec2:VolumeThroughput" = "125" }
      && one([for s in local.policy.Statement : s.Condition.StringEqualsIfExists["ec2:VolumeType"] if s.Sid == "RunInstancesVolume"]) == "gp3"
    )
    error_message = "The volume limits changed."
  }

  # On-demand only. EC2 sets the key on every launch, so no IfExists.
  assert {
    condition     = one([for s in local.policy.Statement : s.Condition.StringEquals["ec2:InstanceMarketType"] if s.Sid == "RunInstancesInstance"]) == "on-demand"
    error_message = "RunInstances does not require the on-demand market."
  }

  # Subnet and network interface are separate: a new network interface must
  # carry the project tag, and a subnet cannot.
  assert {
    condition = (
      one([for s in local.policy.Statement : s.Resource if s.Sid == "RunInstancesSubnet"]) == "arn:aws:ec2:us-west-2:123456789012:subnet/*"
      && one([for s in local.policy.Statement : s.Resource if s.Sid == "RunInstancesNetworkInterface"]) == "arn:aws:ec2:us-west-2:123456789012:network-interface/*"
      && one([for s in local.policy.Statement : s.Condition.StringEquals["aws:RequestTag/Project"] if s.Sid == "RunInstancesNetworkInterface"]) == "baskingspot-bench"
    )
    error_message = "Subnet and network-interface authorization must be split, and a new network interface must carry the project tag."
  }

  # Every resource that RunInstances creates must carry the project tag.
  assert {
    condition = alltrue([
      for type in ["instance", "volume", "network-interface"] :
      anytrue([
        for s in local.policy.Statement :
        try(s.Action, "") == "ec2:RunInstances"
        && s.Resource == "arn:aws:ec2:us-west-2:123456789012:${type}/*"
        && try(s.Condition.StringEquals["aws:RequestTag/Project"], "") == "baskingspot-bench"
      ])
    ])
    error_message = "RunInstances can create an instance, volume, or network interface without the project tag."
  }
}

run "session_policy" {
  command = plan

  override_resource {
    target = aws_iam_role.box
    values = {
      arn = "arn:aws:iam::123456789012:role/baskingspot-bench-box"
    }
  }

  assert {
    condition     = length(aws_iam_policy.session.policy) <= 6144
    error_message = "The session policy has ${length(aws_iam_policy.session.policy)} characters. A managed policy can have 6,144."
  }

  # Three actions and no more.
  assert {
    condition = toset(flatten([
      for s in local.session_policy.Statement : s.Action if s.Effect == "Allow"
    ])) == toset(["iam:PassRole", "ec2-instance-connect:SendSSHPublicKey", "ssm:StartSession"])
    error_message = "The session policy allows an action outside PassRole, SendSSHPublicKey, and StartSession."
  }

  # PassRole names the box role, for EC2 only.
  assert {
    condition = (
      one([for s in local.session_policy.Statement : s if s.Sid == "PassBoxRole"]).Resource == "arn:aws:iam::123456789012:role/baskingspot-bench-box"
      && one([for s in local.session_policy.Statement : s if s.Sid == "PassBoxRole"]).Condition == { StringEquals = { "iam:PassedToService" = "ec2.amazonaws.com" } }
    )
    error_message = "PassRole must name only the box role, and only for EC2."
  }

  # A pushed key is for root on a project instance.
  assert {
    condition = (
      one([for s in local.session_policy.Statement : s if s.Sid == "SendSSHPublicKey"]).Resource == "arn:aws:ec2:us-west-2:123456789012:instance/*"
      && one([for s in local.session_policy.Statement : s if s.Sid == "SendSSHPublicKey"]).Condition == { StringEquals = { "aws:ResourceTag/Project" = "baskingspot-bench", "ec2:osuser" = "root" } }
    )
    error_message = "SendSSHPublicKey must require the project tag and the root user."
  }

  # A session targets a project instance, and only with the SSH document.
  assert {
    condition = (
      one([for s in local.session_policy.Statement : s if s.Sid == "StartSessionOnProjectInstances"]).Condition == {
        StringEquals = { "ssm:resourceTag/Project" = "baskingspot-bench" }
        BoolIfExists = { "ssm:SessionDocumentAccessCheck" = "true" }
      }
      && toset([
        for s in local.session_policy.Statement : s.Resource
        if s.Action == "ssm:StartSession" && strcontains(s.Resource, ":document/")
      ]) == toset(["arn:aws:ssm:us-west-2::document/AWS-StartSSHSession"])
    )
    error_message = "StartSession must require the project tag, the document check, and only AWS-StartSSHSession."
  }

  # The DenyOtherRegions exceptions are global actions only.
  assert {
    condition     = one([for s in local.policy.Statement : s.NotAction if s.Sid == "DenyOtherRegions"]) == ["sts:GetCallerIdentity", "iam:PassRole"]
    error_message = "DenyOtherRegions exempts an action other than GetCallerIdentity and PassRole."
  }
}

run "box_role" {
  command = plan

  assert {
    condition     = jsondecode(aws_iam_role.box.assume_role_policy).Statement[0].Principal == { Service = "ec2.amazonaws.com" }
    error_message = "Only EC2 can assume the box role."
  }

  # Session Manager only: no EC2 action, so a box cannot terminate another.
  assert {
    condition = toset(jsondecode(aws_iam_role_policy.box.policy).Statement[0].Action) == toset([
      "ssm:UpdateInstanceInformation",
      "ssmmessages:CreateControlChannel",
      "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel",
      "ssmmessages:OpenDataChannel",
    ]) && length(jsondecode(aws_iam_role_policy.box.policy).Statement) == 1
    error_message = "The box role must allow the Session Manager actions and nothing else."
  }

  assert {
    condition     = aws_iam_instance_profile.box.name == "baskingspot-bench-box" && aws_iam_instance_profile.box.role == aws_iam_role.box.name
    error_message = "The instance profile must be <project>-box, with the box role."
  }
}
