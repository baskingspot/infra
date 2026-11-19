output "vpc_id" {
  description = "ID of the shared benchmark VPC"
  value       = aws_vpc.bench.id
}

output "subnet_ids" {
  description = "IDs of the public subnets available to benchmark fleets"
  value       = [aws_subnet.public.id]
}

output "availability_zones" {
  description = "Availability zones of the subnets, in the same order as subnet_ids"
  value       = [aws_subnet.public.availability_zone]
}
