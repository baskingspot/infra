# bench-base: the durable resources of a tag-scoped EC2 benchmark fleet.
#
# It creates an egress-only security group and one launch template for each
# architecture. A harness (ec2bench) finds the launch templates by name and
# project tag, and launches and terminates instances from them. A person
# applies this module. The bench role of the bench-iam module can launch from
# these templates but cannot change them, so the TTL guard in the user_data
# stays on every box.
#
# No port is open to the internet and no key pair exists. SSH reaches a box
# through an SSM session, with a key that EC2 Instance Connect pushes for 60
# seconds. The instance profile from bench-iam lets the SSM agent register.
#
# The caller owns the provider configuration. Its default_tags must put
# Project = var.project on every resource: the bench-iam policy and the
# reaper find resources by that tag.

terraform {
  required_version = ">= 1.12"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.66"
    }
  }
}

locals {
  user_data = templatefile("${path.module}/image.nix.tftpl", {
    image_version      = var.image_version
    max_lifetime_hours = var.max_lifetime_hours
    nixos_module       = var.nixos_module
  })
}

data "aws_vpc" "default" {
  default = true
}

# Look up each pinned AMI. The owner and architecture filters make a wrong
# or swapped ID fail at plan time, before it reaches a launch template.
data "aws_ami" "pinned" {
  for_each = var.amis

  owners = [var.image_owner]

  filter {
    name   = "image-id"
    values = [each.value]
  }

  filter {
    name   = "architecture"
    values = [each.key]
  }
}

# Egress only. The boxes keep a public IP for outbound traffic (the NixOS
# cache, the SSM endpoints), and nothing can connect in.
resource "aws_security_group" "box" {
  name        = "${var.project}-box"
  description = "Egress only for ${var.project} boxes"
  vpc_id      = data.aws_vpc.default.id

  egress {
    description = "All outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

locals {
  # Tags for the instances, volumes, and network interfaces that a launch
  # template creates. The harness sends the same Project and ManagedBy tags,
  # plus Name, Target, ExpiresAt, and Owner, in its RunInstances request.
  # The bench-iam policy requires Project on all three resource types (from
  # the request or from here) and ExpiresAt on the instance. The reaper
  # finds orphan volumes and network interfaces by the Project tag.
  box_tags = {
    Project   = var.project
    ManagedBy = "ec2bench"
  }
}

# No instance type: the harness sets it in each RunInstances request.
resource "aws_launch_template" "bench" {
  for_each = var.amis

  name        = "${var.project}-${each.key}"
  description = "${var.project} box (${each.key})"

  image_id               = data.aws_ami.pinned[each.key].id
  vpc_security_group_ids = [aws_security_group.box.id]

  # The box role grants the SSM agent its registration and nothing else.
  iam_instance_profile {
    name = var.instance_profile_name
  }

  # The TTL guard on the box runs poweroff. Terminate, not stop, so that an
  # expired box costs nothing.
  instance_initiated_shutdown_behavior = "terminate"

  # amazon-init applies this file with nixos-rebuild on first boot.
  user_data = base64encode(local.user_data)

  # The harness launches the latest version. Keep the default version equal
  # to it for people who launch from the console.
  update_default_version = true

  # IMDSv2 only. Instance metadata tags let the TTL guard read ExpiresAt.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  # The root device of the AMI. A different device name would add a second
  # volume and leave the root volume at its AMI size.
  block_device_mappings {
    device_name = data.aws_ami.pinned[each.key].root_device_name

    ebs {
      volume_type           = "gp3"
      volume_size           = var.root_volume_gib
      delete_on_termination = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags          = local.box_tags
  }

  tag_specifications {
    resource_type = "volume"
    tags          = local.box_tags
  }

  tag_specifications {
    resource_type = "network-interface"
    tags          = local.box_tags
  }
}
