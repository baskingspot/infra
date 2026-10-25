output "role_arn" {
  description = "ARN of the bench IAM role that a person assumes"
  value       = aws_iam_role.bench.arn
}

output "policy_arn" {
  description = "ARN of the bench EC2 policy"
  value       = aws_iam_policy.bench.arn
}

output "reaper_function_name" {
  description = "Name of the reaper Lambda function"
  value       = aws_lambda_function.reaper.function_name
}

output "reaper_log_group" {
  description = "CloudWatch Logs group of the reaper"
  value       = aws_cloudwatch_log_group.reaper.name
}
