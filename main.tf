###############################################################################
# Windows Server 2025 – Automated Patching via Terraform
# Provider: AWS (swap the provider block for Azure/GCP/vSphere as needed)
###############################################################################

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# ── Data: latest Windows Server 2025 AMI from AWS Marketplace ────────────────
data "aws_ami" "win2025" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["Windows_Server-2025-English-Full-Base-*"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

# ── Security group: WinRM (5985/5986) + RDP (optional, can be removed) ───────
resource "aws_security_group" "patching_sg" {
  name        = "${var.instance_name}-patching-sg"
  description = "Allow WinRM for Terraform remote-exec patching"
  vpc_id      = var.vpc_id

  ingress {
    description = "WinRM HTTP"
    from_port   = 5985
    to_port     = 5985
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
  }

  ingress {
    description = "WinRM HTTPS"
    from_port   = 5986
    to_port     = 5986
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.common_tags, { Name = "${var.instance_name}-patching-sg" })
}

# ── User-data: enable WinRM so Terraform can connect immediately ──────────────
locals {
  userdata = <<-USERDATA
    <powershell>
    # Enable WinRM for Terraform
    winrm quickconfig -q
    winrm set winrm/config/winrs '@{MaxMemoryPerShellMB="1024"}'
    winrm set winrm/config '@{MaxTimeoutms="1800000"}'
    winrm set winrm/config/service '@{AllowUnencrypted="true"}'
    winrm set winrm/config/service/auth '@{Basic="true"}'

    # Open WinRM in Windows Firewall
    netsh advfirewall firewall add rule name="WinRM-HTTP" dir=in action=allow protocol=TCP localport=5985
    netsh advfirewall firewall add rule name="WinRM-HTTPS" dir=in action=allow protocol=TCP localport=5986

    # Set Administrator password (from SSM or variable)
    $adminPass = "${var.admin_password}"
    net user Administrator $adminPass

    # Ensure remote execution is permitted
    Set-ExecutionPolicy RemoteSigned -Force
    </powershell>
    <persist>true</persist>
  USERDATA
}

# ── EC2 instance ──────────────────────────────────────────────────────────────
resource "aws_instance" "win2025" {
  ami                    = data.aws_ami.win2025.id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [aws_security_group.patching_sg.id]
  key_name               = var.key_name
  user_data              = local.userdata

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size_gb
    delete_on_termination = true
    encrypted             = true
  }

  tags = merge(var.common_tags, { Name = var.instance_name })

  # ── WinRM connection for remote provisioners ────────────────────────────────
  connection {
    type     = "winrm"
    host     = self.public_ip
    user     = "Administrator"
    password = var.admin_password
    port     = 5985
    https    = false
    insecure = true
    timeout  = "30m"
  }

  # ── Step 1: Upload the PowerShell patching script ──────────────────────────
  provisioner "file" {
    source      = "${path.module}/scripts/patch_windows.ps1"
    destination = "C:\\patch_windows.ps1"
  }

  # ── Step 2: Execute patching; normalise exit codes so Terraform never fails
  #            on exit 10 (reboot required). The script writes its result to a
  #            sentinel file so the next step can act on it.
  provisioner "remote-exec" {
    inline = [
      "powershell -ExecutionPolicy Bypass -NonInteractive -Command \"$ec = 0; try { & C:\\patch_windows.ps1; $ec = $LASTEXITCODE } catch { $ec = 1 }; Set-Content C:\\patch_exitcode.txt $ec; if ($ec -eq 0 -or $ec -eq 10) { exit 0 } else { exit $ec }\""
    ]
  }

  # ── Step 3: Reboot if sentinel file contains 10 (reboot required) ──────────
  provisioner "remote-exec" {
    inline = [
      "powershell -ExecutionPolicy Bypass -NonInteractive -Command \"$ec = [int](Get-Content C:\\patch_exitcode.txt -ErrorAction SilentlyContinue); if ($ec -eq 10) { Write-Host 'Reboot required — rebooting in 15s...'; shutdown /r /t 15 /c 'Terraform-patching-reboot' } else { Write-Host 'No reboot required.' }\""
    ]
  }

  # ── Step 4: Wait for WinRM to come back after reboot, then verify ──────────
  provisioner "remote-exec" {
    inline = [
      # Small sleep to ensure the reboot has started before Terraform polls
      "powershell -ExecutionPolicy Bypass -NonInteractive -Command Start-Sleep -Seconds 60",
      # Re-run patching to catch any updates released after reboot or missed
      "powershell -ExecutionPolicy Bypass -NonInteractive -File C:\\patch_windows.ps1",
      # Report installed KB list to the log
      "powershell -ExecutionPolicy Bypass -NonInteractive -Command Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 20 | Format-Table -AutoSize | Out-File C:\\PatchLogs\\hotfix_list.txt -Encoding UTF8"
    ]
  }
}

# ── Null resource: re-run patching on existing instance (drift remediation) ──
# Use: terraform apply -target=null_resource.repatch
resource "null_resource" "repatch" {
  triggers = {
    patch_script_hash = filemd5("${path.module}/scripts/patch_windows.ps1")
    force_run         = var.force_repatch
  }

  connection {
    type     = "winrm"
    host     = aws_instance.win2025.public_ip
    user     = "Administrator"
    password = var.admin_password
    port     = 5985
    https    = false
    insecure = true
    timeout  = "30m"
  }

  provisioner "file" {
    source      = "${path.module}/scripts/patch_windows.ps1"
    destination = "C:\\patch_windows.ps1"
  }

  provisioner "remote-exec" {
    inline = [
      "powershell -ExecutionPolicy Bypass -NonInteractive -File C:\\patch_windows.ps1"
    ]
  }

  depends_on = [aws_instance.win2025]
}
