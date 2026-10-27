###############################################################################
# variables.tf — Windows Server 2025 Automated Patching
###############################################################################

# ── AWS ───────────────────────────────────────────────────────────────────────
variable "aws_region" {
  description = "AWS region where the instance will be created."
  type        = string
  default     = "us-east-1"
}

# ── Network ───────────────────────────────────────────────────────────────────
variable "vpc_id" {
  description = "ID of the VPC to place the instance in."
  type        = string
}

variable "subnet_id" {
  description = "ID of the subnet (must have a route to the internet for Windows Update)."
  type        = string
}

variable "allowed_cidr_blocks" {
  description = "CIDR blocks allowed to connect via WinRM (restrict to your CI/CD runner or bastion IP)."
  type        = list(string)
  default     = ["10.0.0.0/8"]
}

# ── Instance ──────────────────────────────────────────────────────────────────
variable "instance_name" {
  description = "Name tag applied to the EC2 instance."
  type        = string
  default     = "ws2025-patching"
}

variable "instance_type" {
  description = "EC2 instance type. t3.medium is the recommended minimum for patching workloads."
  type        = string
  default     = "t3.medium"
}

variable "key_name" {
  description = "Name of an existing EC2 Key Pair (used for emergency RDP access, not by Terraform)."
  type        = string
  default     = ""
}

variable "root_volume_size_gb" {
  description = "Size of the root EBS volume in GB."
  type        = number
  default     = 60
}

# ── Credentials ───────────────────────────────────────────────────────────────
variable "admin_password" {
  description = <<-EOT
    Local Administrator password for WinRM access.
    MUST be passed via TF_VAR_admin_password env var or an encrypted tfvars file.
    Never hardcode this value in source control.
  EOT
  type        = string
  sensitive   = true

  # WARN-01 FIX: enforce complexity (length + uppercase + digit + special char)
  validation {
    condition = (
      length(var.admin_password) >= 12 &&
      can(regex("[A-Z]", var.admin_password)) &&
      can(regex("[0-9]", var.admin_password)) &&
      can(regex("[^a-zA-Z0-9]", var.admin_password))
    )
    error_message = "admin_password must be ≥12 chars and contain uppercase, digit, and special character."
  }
}

# ── Patching control ──────────────────────────────────────────────────────────
variable "force_repatch" {
  description = <<-EOT
    Increment this value (e.g. \"2024-01\") to force the null_resource.repatch
    to re-run on an already-provisioned instance without destroying it.
  EOT
  type    = string
  default = "2025-01"
}

# ── Tags ──────────────────────────────────────────────────────────────────────
variable "common_tags" {
  description = "Map of tags applied to all resources."
  type        = map(string)
  default = {
    ManagedBy   = "Terraform"
    Environment = "patching"
    OS          = "WindowsServer2025"
  }
}
