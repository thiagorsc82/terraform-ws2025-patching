#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Automated Windows Server 2025 patching script.
    Installs all available Windows Updates without any human interaction.
    Designed to be invoked remotely by Terraform via WinRM.

.NOTES
    - Requires PSWindowsUpdate module (auto-installed if absent).
    - Exit code 0  = success, no reboot required.
    - Exit code 10 = success, reboot required (Terraform signals it as a scheduled reboot).
    - Exit code 1  = fatal error.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Logging ──────────────────────────────────────────────────────────────────
$LogDir  = 'C:\PatchLogs'
$LogFile = Join-Path $LogDir "patch_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $entry = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    $entry | Tee-Object -FilePath $LogFile -Append | Write-Host
}

# ── Ensure NuGet / PSWindowsUpdate ───────────────────────────────────────────
Write-Log "Checking NuGet provider..."
if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
    Write-Log "Installing NuGet provider..."
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Confirm:$false | Out-Null
}

Write-Log "Checking PSWindowsUpdate module..."
if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
    Write-Log "Installing PSWindowsUpdate module..."
    Install-Module -Name PSWindowsUpdate -Force -Confirm:$false -Scope AllUsers
}

Import-Module PSWindowsUpdate -Force
Write-Log "PSWindowsUpdate $(( Get-Module PSWindowsUpdate ).Version) loaded."

# ── Configure Windows Update service ─────────────────────────────────────────
Write-Log "Ensuring Windows Update service is running..."
$wuSvc = Get-Service -Name wuauserv
if ($wuSvc.StartType -eq 'Disabled') {
    Set-Service -Name wuauserv -StartupType Manual
}
if ($wuSvc.Status -ne 'Running') {
    Start-Service -Name wuauserv
}

# ── Scan for updates ──────────────────────────────────────────────────────────
Write-Log "Scanning for available updates..."
$updates = Get-WindowsUpdate -AcceptAll -IgnoreReboot -Verbose 2>&1 |
           Where-Object { $_ -is [Microsoft.Update.UpdateClass] -or
                          $_.GetType().Name -like '*Update*' }

# Re-run clean to get proper objects
$availableUpdates = Get-WindowsUpdate -AcceptAll -IgnoreReboot

if ($availableUpdates.Count -eq 0) {
    Write-Log "No updates available. System is up to date."
    exit 0
}

Write-Log "Found $($availableUpdates.Count) update(s):"
$availableUpdates | ForEach-Object { Write-Log "  - $($_.Title)" }

# ── Install updates ───────────────────────────────────────────────────────────
Write-Log "Starting update installation (no automatic reboot)..."

$result = Install-WindowsUpdate `
    -AcceptAll        `
    -IgnoreReboot     `
    -AutoReboot:$false `
    -Confirm:$false   `
    -Verbose

Write-Log "Installation complete. Results:"
$result | ForEach-Object {
    Write-Log ("  [{0}] {1} — Result: {2}" -f $_.KB, $_.Title, $_.Result)
}

# ── Evaluate reboot requirement ───────────────────────────────────────────────
$rebootNeeded = (Get-WURebootStatus -Silent) -or
                (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or
                (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\PendingFileRenameOperations')

if ($rebootNeeded) {
    Write-Log "A reboot is required to complete patching." 'WARN'
    exit 10   # Terraform interprets this and schedules reboot + re-run
} else {
    Write-Log "No reboot required. Patching finished successfully." 'INFO'
    exit 0
}
