# Durable fleet resources for baskingspot-bench (modules/bench-base).
#
# The bench profile (baskingspot-bench) applies this stack. The harness reads the
# outputs with `tofu -chdir=infra/base output -json`. infra/README.md is the
# runbook.
#
# terraform.tfstate and bench.pem hold the private SSH key. Both are
# gitignored.

terraform {
  required_version = ">= 1.12"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.66"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.4"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.9"
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
  # Keep equal to project.name and project.region in bench.toml. The harness
  # test suite checks that.
  project    = var.project
  region     = "us-west-2"
  account_id = var.account_id
}

# Credentials come from AWS_PROFILE in the environment. default_tags puts
# Project and ManagedBy on every resource, in the create request itself. The
# bench-iam policy requires that.
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
  image_version = "1"
  nixos_module  = file("${path.module}/image.nix")
  key_file      = "${path.module}/bench.pem"
}

# The resources were created at the root before the module existed.
moved {
  from = aws_security_group.ssh
  to   = module.bench.aws_security_group.ssh
}

moved {
  from = tls_private_key.ssh
  to   = module.bench.tls_private_key.ssh
}

moved {
  from = aws_key_pair.bench
  to   = module.bench.aws_key_pair.bench
}

moved {
  from = local_sensitive_file.ssh_key
  to   = module.bench.local_sensitive_file.ssh_key
}

moved {
  from = aws_launch_template.bench
  to   = module.bench.aws_launch_template.bench
}
