# The one shared network for every baskingspot benchmark fleet.
#
# Apply this stack once for the account and region. Fleets find the VPC by
# its Name tag and read no state from this stack. Each fleet owns its own
# security group and launch templates through modules/bench-base.
#
# Boxes use public subnets for outbound traffic and SSM. No NAT gateway is
# necessary because the boxes are ephemeral and accept no inbound traffic.

terraform {
  required_version = ">= 1.12"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.66"
    }
  }
}

variable "account_id" {
  description = "The AWS account ID. The provider refuses every other account. Set it in .envrc.local as TF_VAR_account_id."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be 12 digits."
  }
}

locals {
  project = "baskingspot-bench"
  region  = "us-west-2"

  # This range starts above every supplied us-west-2 range through
  # 10.5.64.0/18. One /24 is active. Three more /24 blocks remain available.
  cidr        = "10.6.0.0/22"
  subnet_cidr = "10.6.0.0/24"
}

provider "aws" {
  region              = local.region
  allowed_account_ids = [var.account_id]

  default_tags {
    tags = {
      Project   = local.project
      ManagedBy = "tofu"
    }
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

# One AZ is deliberate. The harness exposes one launch template per
# architecture and does not choose a subnet, so another AZ adds no failover.
resource "aws_vpc" "bench" {
  cidr_block           = local.cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name    = local.project
    Project = local.project
  }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.bench.id
  availability_zone       = sort(data.aws_availability_zones.available.names)[0]
  cidr_block              = local.subnet_cidr
  map_public_ip_on_launch = true

  tags = {
    Name = "${local.project}-public"
  }
}

resource "aws_internet_gateway" "bench" {
  vpc_id = aws_vpc.bench.id

  tags = {
    Name = local.project
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.bench.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.bench.id
  }

  tags = {
    Name = "${local.project}-public"
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}
