###############################################################################
# outputs.tf — Windows Server 2025 Automated Patching
###############################################################################

output "instance_id" {
  description = "EC2 instance ID of the patched Windows Server 2025."
  value       = aws_instance.win2025.id
}

output "instance_public_ip" {
  description = "Public IP address (used by Terraform WinRM provisioner)."
  value       = aws_instance.win2025.public_ip
}

output "instance_private_ip" {
  description = "Private IP address."
  value       = aws_instance.win2025.private_ip
}

output "ami_id_used" {
  description = "AMI ID resolved at apply time (useful for audit/drift tracking)."
  value       = data.aws_ami.win2025.id
}

output "ami_name_used" {
  description = "Human-readable AMI name for audit records."
  value       = data.aws_ami.win2025.name
}

output "patch_log_path" {
  description = "Path inside the VM where patching logs are written."
  value       = "C:\\PatchLogs\\"
}

output "security_group_id" {
  description = "ID of the security group created for WinRM access."
  value       = aws_security_group.patching_sg.id
}
