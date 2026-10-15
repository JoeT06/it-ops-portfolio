<#
  Set-OEECredential.ps1
  Saves (or changes) the Aptean OEE login on this NUC. Run ELEVATED (admin PowerShell or a remote admin shell).
  Encrypted with machine-scope DPAPI: only works on this PC; file is readable only by SYSTEM, Administrators, and the display account.
  After changing the password, reboot the NUC.
#>
param(
  [string]$AppteanUser = '',
  [string]$DisplayUser = 'LineTV1'
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security
if (-not $AppteanUser) { $AppteanUser = Read-Host 'Aptean OEE username' }

$BaseDir = 'C:\OEEDisplay'
$File    = Join-Path $BaseDir 'oee-cred.json'
New-Item -ItemType Directory -Path $BaseDir -Force | Out-Null

$s     = Read-Host "Aptean OEE password for $AppteanUser" -AsSecureString
$plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s))
$enc   = [Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes($plain), $null, 'LocalMachine')
$plain = $null

@{ User = $AppteanUser; Pass = [Convert]::ToBase64String($enc) } | ConvertTo-Json | Set-Content $File -Force

# Lock the file down: SYSTEM + Administrators full, display user read
icacls $File /inheritance:r /grant:r "*S-1-5-18:F" "*S-1-5-32-544:F" "$($env:COMPUTERNAME)\$($DisplayUser):R" | Out-Null

# Remove the old per-user file if present
Remove-Item (Join-Path $BaseDir 'oee-cred.xml') -Force -ErrorAction SilentlyContinue

Write-Host "Saved Aptean login for $AppteanUser to $File. Reboot to apply."
