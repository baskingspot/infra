# bench-iam: the IAM role and the reaper of a tag-scoped EC2 benchmark fleet.
#
# The role can launch, tag, and terminate only the EC2 resources that carry
# Project = var.project, and it can apply the bench-base module for the same
# project. policy.tf holds the policy and explains each statement. Nothing
# holds a long-lived key: the role is assumed from an identity in the same
# account, and its credentials last one hour.
#
# The reaper (reaper.tf) is a scheduled Lambda function that terminates the
# project instances past their lifetime. It is the lifetime guarantee. The
# TTL guard on each box is only the fast path, because the user controls the
# launch templates.
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

# The default VPC is the only VPC that the user can create security groups in.
data "aws_vpc" "default" {
  default = true
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
