# Offline checks of the launch templates. The mock provider needs no AWS
# credentials.
# Run: tofu -chdir=infra/modules/bench-base test

variables {
  project = "baskingspot-bench"
  amis = {
    x86_64 = "ami-0e78db03e0a4e1eb0"
    arm64  = "ami-0b1109b091092c6fe"
  }
  image_version         = "7"
  nixos_module          = "{ pkgs, ... }: { environment.systemPackages = [ pkgs.jq ]; }"
  instance_profile_name = "baskingspot-bench-box"
}

mock_provider "aws" {
  mock_data "aws_vpc" {
    defaults = {
      id = "vpc-0123456789abcdef0"
    }
  }
}

# The mock cannot vary by instance, so both AMIs get the same values. The
# owner and architecture filters of data.aws_ami.pinned run only in AWS.
override_data {
  target = data.aws_ami.pinned
  values = {
    root_device_name = "/dev/xvda"
  }
}

run "launch_templates" {
  command = plan

  assert {
    condition     = toset(keys(aws_launch_template.bench)) == toset(["x86_64", "arm64"])
    error_message = "Expected one launch template for x86_64 and one for arm64."
  }

  assert {
    condition     = aws_launch_template.bench["x86_64"].name == "baskingspot-bench-x86_64" && aws_launch_template.bench["arm64"].name == "baskingspot-bench-arm64"
    error_message = "Launch template names must be <project>-<arch>."
  }

  assert {
    condition = alltrue([
      for lt in aws_launch_template.bench :
      lt.instance_initiated_shutdown_behavior == "terminate"
      && lt.instance_type == null
      && lt.metadata_options[0].http_tokens == "required"
      && lt.metadata_options[0].instance_metadata_tags == "enabled"
      && lt.user_data == base64encode(output.user_data)
    ])
    error_message = "A launch template lost terminate-on-shutdown, IMDSv2, metadata tags, or the user_data."
  }

  assert {
    condition = alltrue([
      for lt in aws_launch_template.bench :
      lt.block_device_mappings[0].device_name == "/dev/xvda"
      && lt.block_device_mappings[0].ebs[0].volume_type == "gp3"
      && lt.block_device_mappings[0].ebs[0].volume_size == 20
    ])
    error_message = "The root volume must be gp3, 20 GiB, on the AMI root device."
  }

  assert {
    condition = alltrue([
      for lt in aws_launch_template.bench :
      toset([for spec in lt.tag_specifications : spec.resource_type]) == toset(["instance", "volume", "network-interface"])
      && alltrue([for spec in lt.tag_specifications : spec.tags == tomap({ Project = "baskingspot-bench", ManagedBy = "ec2bench" })])
    ])
    error_message = "Instances, volumes, and network interfaces must get Project and ManagedBy from the launch template."
  }

  # Nothing can connect in. SSH arrives through SSM, from the box itself.
  assert {
    condition     = aws_security_group.box.name == "baskingspot-bench-box" && length(aws_security_group.box.ingress) == 0
    error_message = "The security group must be <project>-box, with no inbound rule."
  }

  # No key pair: the only SSH keys are the ones EC2 Instance Connect pushes.
  assert {
    condition = alltrue([
      for lt in aws_launch_template.bench :
      lt.key_name == null
      && lt.iam_instance_profile[0].name == "baskingspot-bench-box"
    ])
    error_message = "A launch template names a key pair or lost the box instance profile."
  }

  # The operator interface: these outputs, with these shapes.
  assert {
    condition = (
      keys(output.launch_template_ids) == ["arm64", "x86_64"]
      && output.launch_template_ids["x86_64"] == aws_launch_template.bench["x86_64"].id
      && output.launch_template_ids["arm64"] == aws_launch_template.bench["arm64"].id
    )
    error_message = "launch_template_ids must map exactly x86_64 and arm64 to launch template IDs."
  }

  assert {
    condition     = output.security_group_id == aws_security_group.box.id
    error_message = "security_group_id must be the ID of the box security group."
  }

  # The rendered box configuration carries the fleet contract and the
  # project module, and no unrendered template syntax.
  assert {
    condition = (
      strcontains(output.user_data, "environment.etc.\"bench-image\".text = \"7\\n\";")
      && strcontains(output.user_data, "pkgs.jq")
      && strcontains(output.user_data, "programs.nix-ld.enable = true;")
      && strcontains(output.user_data, "systemd.timers.bench-ttl-guard")
      && strcontains(output.user_data, "max_lifetime_seconds=$((24 * 3600))")
      && strcontains(output.user_data, "-w '%%{http_code}'")
      && strcontains(output.user_data, "services.openssh.authorizedKeysCommand = \"/etc/ssh/eic_run_authorized_keys %u %f\";")
      && strcontains(output.user_data, "exec $${ec2InstanceConnect}/bin/eic_run_authorized_keys")
      && !strcontains(output.user_data, "amazon-ssm-agent.enable")
      && !startswith(output.user_data, "#!")
      && length(regexall("(?m)^###", output.user_data)) == 0
    )
    error_message = "The rendered user_data lost part of the fleet contract."
  }
}

run "rejects_fractional_lifetime" {
  command = plan

  variables {
    max_lifetime_hours = 1.5
  }

  expect_failures = [var.max_lifetime_hours]
}
