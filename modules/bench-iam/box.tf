# The box role: the instance profile of every box.
#
# The SSM agent on a box needs it to register with Systems Manager and to
# open the data channel that carries an SSH session. The policy is the
# minimal Session Manager policy from the AWS documentation, not
# AmazonSSMManagedInstanceCore: that managed policy also allows
# ssm:GetParameter on every parameter in the account.
#
# The role grants no EC2 action. A box ends its own life with poweroff,
# which terminates it because the launch template sets the shutdown behavior
# to terminate. That needs no permission.

locals {
  box_name = "${var.project}-box"
}

resource "aws_iam_role" "box" {
  name        = local.box_name
  description = "Instance role of ${var.project} boxes: SSM Session Manager only"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "box" {
  name = "session-manager"
  role = aws_iam_role.box.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "SessionManager"
      Effect = "Allow"
      Action = [
        "ssm:UpdateInstanceInformation",
        "ssmmessages:CreateControlChannel",
        "ssmmessages:CreateDataChannel",
        "ssmmessages:OpenControlChannel",
        "ssmmessages:OpenDataChannel",
      ]
      Resource = "*"
    }]
  })
}

resource "aws_iam_instance_profile" "box" {
  name = local.box_name
  role = aws_iam_role.box.name
}
