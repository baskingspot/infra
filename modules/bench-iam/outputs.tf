output "role_arn" {
  description = "ARN of the bench IAM role that a person assumes"
  value       = aws_iam_role.bench.arn
}

output "policy_arn" {
  description = "ARN of the bench EC2 policy"
  value       = aws_iam_policy.bench.arn
}

output "session_policy_arn" {
  description = "ARN of the bench SSH session policy"
  value       = aws_iam_policy.session.arn
}

output "instance_profile_name" {
  description = "Instance profile of the boxes. Pass it to bench-base."
  value       = aws_iam_instance_profile.box.name
}

output "box_role_arn" {
  description = "ARN of the box role"
  value       = aws_iam_role.box.arn
}

output "reaper_function_name" {
  description = "Name of the reaper Lambda function"
  value       = aws_lambda_function.reaper.function_name
}

output "reaper_log_group" {
  description = "CloudWatch Logs group of the reaper"
  value       = aws_cloudwatch_log_group.reaper.name
}
