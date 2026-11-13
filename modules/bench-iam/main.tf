# bench-iam: the IAM roles and the reaper of a tag-scoped EC2 benchmark fleet.
#
# The bench role can launch instances from the project launch templates,
# tag and terminate the project instances, and open SSH to them through SSM
# with a key that EC2 Instance Connect pushes for 60 seconds. It cannot
# change the launch templates or the security group: a person applies
# bench-base. policy.tf holds the policies and explains each statement.
# Nothing holds a long-lived key: a person assumes the role from an SSO
# session in the same account, and its credentials last one hour.
#
# The box role (box.tf) is the instance profile of every box. It lets the SSM
# agent register and grants nothing else, so a box cannot act on EC2.
#
# The reaper (reaper.tf) is a scheduled Lambda function that terminates the
# project instances past their lifetime. It is the lifetime guarantee. The
# TTL guard on each box is the fast path. The guard cannot run when the
# first boot fails, and the bench role can rewrite ExpiresAt.
#
# A human applies this module with an IAM-capable profile. The caller owns
# the provider configuration (region, account guard, default tags).

terraform {
  required_version = ">= 1.12"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.66"
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.8"
    }
  }
}

# Anyone in the account who is allowed sts:AssumeRole on this role can use it.
# That is the SSO role a person already holds, so the bench identity inherits
# the SSO gate: MFA at login and a session that expires. No key exists.
resource "aws_iam_role" "bench" {
  name        = var.project
  description = "Assume this role to operate the ${var.project} fleet"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "SameAccount"
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { AWS = "arn:aws:iam::${var.account_id}:root" }
    }]
  })
}

# A customer managed policy, not an inline policy, so that the reaper and this
# role can share it and the size limit is 6,144 characters.
resource "aws_iam_policy" "bench" {
  name        = "${var.project}-ec2"
  description = "EC2 access for the ${var.project} fleet, scoped by the Project tag"
  policy      = jsonencode(local.policy)
}

resource "aws_iam_role_policy_attachment" "bench" {
  role       = aws_iam_role.bench.name
  policy_arn = aws_iam_policy.bench.arn
}

# A second managed policy for the SSH path: PassRole for the box role, SSM
# sessions, and EC2 Instance Connect. It is separate so that the EC2 policy
# stays EC2-only and both stay under the size limit.
resource "aws_iam_policy" "session" {
  name        = "${var.project}-session"
  description = "SSH to the ${var.project} fleet through SSM and EC2 Instance Connect"
  policy      = jsonencode(local.session_policy)
}

resource "aws_iam_role_policy_attachment" "session" {
  role       = aws_iam_role.bench.name
  policy_arn = aws_iam_policy.session.arn
}
