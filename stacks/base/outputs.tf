# An operator reads these. The harness finds the launch templates in AWS.

output "launch_template_ids" {
  description = "Launch template ID by architecture (x86_64, arm64)"
  value       = module.bench.launch_template_ids
}

output "security_group_id" {
  description = "ID of the egress-only security group"
  value       = module.bench.security_group_id
}
