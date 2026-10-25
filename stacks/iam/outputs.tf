# The profile block in ~/.aws/config uses this ARN.

output "role_arn" {
  description = "ARN of the bench role to assume (role_arn in the ~/.aws/config profile)"
  value       = module.bench.role_arn
}

output "region" {
  description = "Fleet region"
  value       = local.region
}

output "policy_arn" {
  description = "ARN of the bench EC2 policy"
  value       = module.bench.policy_arn
}

output "reaper_function_name" {
  description = "Name of the reaper Lambda function"
  value       = module.bench.reaper_function_name
}

output "reaper_log_group" {
  description = "CloudWatch Logs group of the reaper"
  value       = module.bench.reaper_log_group
}
