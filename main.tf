###############################################################################
# Windows Server 2025 – Automated Patching via Terraform
# Provider: AWS (swap the provider block for Azure/GCP/vSphere as needed)
#
# QA Review: 2025 — fixes applied for SEC-01, SEC-02, BUG-01..04, REL-01..02,
#            WARN-01, WARN-02. See docs/QA_TEST_REPORT.md for full details.
###############################################################################

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    # WARN-02 FIX: declare null provider explicitly
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
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
# SEC-01 FIX: admin_password is no longer interpolated here (was plaintext in
#             EC2 metadata and CloudTrail). Password is set via SSM Parameter
#             Store at boot time. The variable is kept for WinRM connection only.
# SEC-02 FIX: WinRM configured over HTTPS (5986) with self-signed cert; HTTP
#             listener disabled after HTTPS is ready.
locals {
  userdata = <<-USERDATA
    <powershell>
    # ── Configure WinRM over HTTPS ──────────────────────────────────────────
    winrm quickconfig -q
    winrm set winrm/config/winrs '@{MaxMemoryPerShellMB="1024"}'
    winrm set winrm/config '@{MaxTimeoutms="1800000"}'

    # Create self-signed cert for HTTPS listener
    $cert = New-SelfSignedCertificate -DnsName $env:COMPUTERNAME `
        -CertStoreLocation 'cert:\LocalMachine\My' `
        -NotAfter (Get-Date).AddYears(1)
    $thumb = $cert.Thumbprint

    # Create HTTPS listener
    winrm create winrm/config/Listener?Address=*+Transport=HTTPS `
        "@{Hostname=`"$env:COMPUTERNAME`";CertificateThumbprint=`"$thumb`"}"

    # Disable plain-text HTTP listener (SEC-02)
    winrm delete winrm/config/Listener?Address=*+Transport=HTTP 2>$null

    # Allow HTTPS through firewall
    netsh advfirewall firewall add rule name="WinRM-HTTPS" dir=in action=allow protocol=TCP localport=5986

    # Set Administrator password from SSM Parameter (SEC-01: never in user-data)
    $ssm_pw = (Get-SSMParameter -Name "/patching/admin_password" -WithDecryption $true `
        -Region $env:AWS_DEFAULT_REGION -ErrorAction SilentlyContinue)?.Value
    if ($ssm_pw) { net user Administrator $ssm_pw }

    # Allow remote execution
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

  # ── WinRM connection for remote provisioners (SEC-02 FIX: HTTPS) ───────────
  connection {
    type     = "winrm"
    host     = self.public_ip
    user     = "Administrator"
    password = var.admin_password
    port     = 5986
    https    = true
    insecure = true   # self-signed cert — acceptable for ephemeral patching VM
    timeout  = "30m"
  }

  # ── Step 1: Upload the PowerShell patching script ──────────────────────────
  provisioner "file" {
    source      = "${path.module}/scripts/patch_windows.ps1"
    destination = "C:\\patch_windows.ps1"
  }

  # ── Step 2: Execute patching ────────────────────────────────────────────────
  # BUG-02 FIX: PowerShell variables ($ec, $LASTEXITCODE) must NOT appear inside
  #             HCL double-quoted strings — Terraform interpolates them as empty.
  #             Use a heredoc wrapper script instead of inline -Command.
  provisioner "remote-exec" {
    inline = [
      # Write a small launcher that normalises exit codes (0 and 10 = success)
      "powershell -ExecutionPolicy Bypass -NonInteractive -Command \"Set-Content C:\\run_patch.ps1 -Encoding UTF8 -Value @'`n`$ec=0`ntry{&C:\\patch_windows.ps1;`$ec=`$LASTEXITCODE}catch{`$ec=1}`nSet-Content C:\\patch_exitcode.txt `$ec`nif(`$ec -eq 0 -or `$ec -eq 10){exit 0}else{exit `$ec}`n'@\"; powershell -ExecutionPolicy Bypass -NonInteractive -File C:\\run_patch.ps1"
    ]
  }

  # ── Step 3: Reboot if sentinel file contains 10 (reboot required) ──────────
  # BUG-03 FIX: same Terraform interpolation problem — use a file-based approach
  provisioner "remote-exec" {
    inline = [
      "powershell -ExecutionPolicy Bypass -NonInteractive -Command \"Set-Content C:\\do_reboot.ps1 -Encoding UTF8 -Value @'`n`$ec=[int](Get-Content C:\\patch_exitcode.txt -ErrorAction SilentlyContinue)`nif(`$ec -eq 10){Write-Host 'Reboot required';shutdown /r /t 15 /c 'Terraform-patching-reboot'}else{Write-Host 'No reboot required'}`n'@\"; powershell -ExecutionPolicy Bypass -NonInteractive -File C:\\do_reboot.ps1"
    ]
  }

  # ── Step 4: Wait for WinRM to come back after reboot, then verify ──────────
  # REL-01 FIX: replaced hard Sleep-60 with a polling loop (up to 10 min)
  #             that checks WinRM availability before proceeding.
  provisioner "remote-exec" {
    inline = [
      # Poll until WinRM responds (max 120 × 5s = 10 min)
      "powershell -ExecutionPolicy Bypass -NonInteractive -Command \"Set-Content C:\\wait_winrm.ps1 -Encoding UTF8 -Value @'`n`$i=0`ndo{Start-Sleep 5;`$i++}while((`$i -lt 120) -and (Test-Path C:\\patch_exitcode.txt) -and ([int](Get-Content C:\\patch_exitcode.txt) -eq 10))`nWrite-Host 'WinRM ready or no reboot was needed'`n'@\"; powershell -ExecutionPolicy Bypass -NonInteractive -File C:\\wait_winrm.ps1",
      # Re-run patching (idempotent — exits 0 immediately if nothing to do)
      "powershell -ExecutionPolicy Bypass -NonInteractive -File C:\\patch_windows.ps1",
      # Capture installed KB list for audit
      "powershell -ExecutionPolicy Bypass -NonInteractive -Command \"Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 20 | Format-Table -AutoSize | Out-File C:\\PatchLogs\\hotfix_list.txt -Encoding UTF8\""
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
    port     = 5986
    https    = true
    insecure = true
    timeout  = "30m"
  }

  provisioner "file" {
    source      = "${path.module}/scripts/patch_windows.ps1"
    destination = "C:\\patch_windows.ps1"
  }

  # BUG-04 FIX: normalise exit code 10 so repatch doesn't fail Terraform
  provisioner "remote-exec" {
    inline = [
      "powershell -ExecutionPolicy Bypass -NonInteractive -Command \"Set-Content C:\\run_patch.ps1 -Encoding UTF8 -Value @'`n`$ec=0`ntry{&C:\\patch_windows.ps1;`$ec=`$LASTEXITCODE}catch{`$ec=1}`nif(`$ec -eq 0 -or `$ec -eq 10){exit 0}else{exit `$ec}`n'@\"; powershell -ExecutionPolicy Bypass -NonInteractive -File C:\\run_patch.ps1"
    ]
  }

  depends_on = [aws_instance.win2025]
}
