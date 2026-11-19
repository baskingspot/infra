variables {
  account_id = "123456789012"
}

mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["us-west-2-lax-1a", "us-west-2a", "us-west-2b"]
    }
  }
}

# A Local Zone sorts first. It must not influence the shared subnet. A literal
# AZ and the availability precondition keep unrelated zone-set changes from
# replacing the network beneath existing launch templates.
run "subnet_zone_is_pinned" {
  command = plan

  assert {
    condition     = aws_subnet.public.availability_zone == "us-west-2a"
    error_message = "The shared subnet must stay in us-west-2a, independent of zone list order."
  }

  assert {
    condition     = output.availability_zones == ["us-west-2a"]
    error_message = "The availability_zones output must match the pinned subnet."
  }

  assert {
    condition = (
      aws_vpc.bench.cidr_block == "10.6.0.0/22"
      && aws_subnet.public.cidr_block == "10.6.0.0/24"
      && aws_subnet.public.map_public_ip_on_launch
    )
    error_message = "The shared CIDRs or public address behavior changed."
  }

  assert {
    condition = (
      aws_vpc.bench.tags.Name == "baskingspot-bench"
      && aws_vpc.bench.tags.Project == "baskingspot-bench"
      && aws_subnet.public.tags.Name == "baskingspot-bench-public"
    )
    error_message = "Consumers require these stable VPC and subnet tags."
  }

  assert {
    condition = (
      aws_internet_gateway.bench.vpc_id == aws_vpc.bench.id
      && one([for route in aws_route_table.public.route : route.gateway_id if route.cidr_block == "0.0.0.0/0"]) == aws_internet_gateway.bench.id
      && aws_route_table_association.public.subnet_id == aws_subnet.public.id
    )
    error_message = "The public subnet needs its internet gateway route and route table association."
  }
}
