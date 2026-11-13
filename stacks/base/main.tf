# Durable fleet resources for baskingspot-bench (modules/bench-base).
#
# A person applies this stack with the bootstrap profile, after stacks/iam.
# The bench role cannot: it can launch from the launch templates but not
# change them. The harness finds the launch templates by name and project tag
# and reads no state from here. docs/runbook.md is the operator documentation.

terraform {
  required_version = ">= 1.12"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.66"
    }
  }
}

variable "project" {
  description = "The fleet name. It names every resource and is the value of the Project tag. The bench-iam policy pins this tag. Keep it equal to the project name that the harness is configured with."
  type        = string
  default     = "baskingspot-bench"
}

variable "account_id" {
  description = "The AWS account ID. The provider refuses every other account. Set it in .envrc.local as TF_VAR_account_id. It is not a secret, and it stays out of the repo."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be 12 digits."
  }
}

locals {
  # Keep equal to project.name and project.region in bench.toml. The policy
  # refuses a launch whose Project tag has another value, so a mismatch fails
  # at the first launch instead of creating a box that the reaper ignores.
  project    = var.project
  region     = "us-west-2"
  account_id = var.account_id
}

# Credentials come from AWS_PROFILE in the environment. default_tags puts
# Project and ManagedBy on every resource. The reaper and the bench-iam policy
# find resources by the Project tag.
provider "aws" {
  region              = local.region
  allowed_account_ids = [local.account_id]

  default_tags {
    tags = {
      Project   = local.project
      ManagedBy = "tofu"
    }
  }
}

module "bench" {
  source = "../../modules/bench-base"

  project = local.project

  # Official NixOS 25.11.12484.b6018f87da91 AMIs in us-west-2. A new AMI
  # takes effect for new instances only.
  amis = {
    x86_64 = "ami-0e78db03e0a4e1eb0"
    arm64  = "ami-0b1109b091092c6fe"
  }

  # Keep equal to project.image_version in bench.toml.
  image_version = "2"
  nixos_module  = file("${path.module}/image.nix")

  # Created by stacks/iam (module bench-iam), which names it <project>-box.
  instance_profile_name = "${local.project}-box"
}
