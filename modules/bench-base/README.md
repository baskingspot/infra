# bench-base

This module creates one fleet's egress-only security group and launch templates. The caller supplies the network. The module performs no VPC or subnet lookup.

## Shared network

Every benchmark fleet shares one VPC named `baskingspot-bench`. `stacks/bench-network/` creates it once in `us-west-2` with both `Name` and `Project` set to `baskingspot-bench`.

The VPC uses `10.6.0.0/22`. This range starts above the account's supplied ranges through `10.5.64.0/18`. One public subnet uses `10.6.0.0/24`. Three `/24` blocks remain available.

The shared stack creates one subnet in the first available AZ. The harness fixes one subnet in each launch template, so another AZ adds no failover. Pass exactly one subnet ID in `subnet_ids`. Fleets own security groups and launch templates. They do not own the network.

Boxes get public addresses for outbound traffic. The internet gateway and default route reach the internet directly. No NAT gateway is necessary. The security group accepts no inbound traffic. SSH uses SSM and EC2 Instance Connect.

## Connect a fleet

Find the shared VPC by its `Name` tag. Do not read another root's state. The roots use local state, and a consumer can apply from a different checkout.

This example replaces the network assumptions in tls's `infra/bench/main.tf`. Keep the existing provider configuration. Replace `<full-commit-sha>` with a commit that contains this module contract.

```hcl
data "aws_vpc" "bench" {
  filter {
    name   = "tag:Name"
    values = ["baskingspot-bench"]
  }
}

data "aws_subnets" "bench" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.bench.id]
  }
}

module "bench" {
  source = "git::https://github.com/baskingspot/infra//modules/bench-base?ref=<full-commit-sha>"

  project    = "tls-bench"
  vpc_id     = data.aws_vpc.bench.id
  subnet_ids = data.aws_subnets.bench.ids

  amis = {
    x86_64 = "ami-0e78db03e0a4e1eb0"
    arm64  = "ami-0b1109b091092c6fe"
  }

  image_version         = "1"
  nixos_module          = file("${path.module}/image.nix")
  instance_profile_name = "tls-bench-box"
}
```

Apply `stacks/bench-network/` before this consumer. The `aws_vpc` data source returns an error if the named VPC is absent. Multiple matching VPCs also return an error.

The caller owns the AWS provider. Its `default_tags` must set `Project` to the fleet name. The IAM policy and reaper use that tag as the fleet boundary.
