# Stack outputs. The harness finds the launch templates by name and project
# tag and does not read these; an operator reads them, and the runbook's
# dry-run commands use the template IDs.

output "launch_template_ids" {
  description = "Launch template ID by architecture. The keys match the arch field of a target in bench.toml."
  value       = { for arch, template in aws_launch_template.bench : arch => template.id }
}

output "security_group_id" {
  description = "ID of the egress-only security group of the boxes"
  value       = aws_security_group.box.id
}

output "user_data" {
  description = "The rendered NixOS configuration of the boxes"
  value       = local.user_data
}
