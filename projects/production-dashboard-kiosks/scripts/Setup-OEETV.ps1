<#
  Setup-OEETV.ps1
  One-shot setup for an OEE TV NUC. Run ELEVATED (admin PowerShell or a remote admin shell)
  from the folder that contains all four OEE scripts.

  Does everything:
    1. Sets the local display account password to never expire
    2. Allows password auto-logon (turns off "Windows Hello only")
    3. Configures Sysinternals Autologon for the display account
    4. Installs the OEE Display script + scheduled task (Install-OEEDisplay.ps1)
    5. Saves the Aptean login (Set-OEECredential.ps1)
    6. Reboots
#>
param(
  [string]$TVName      = 'LineTV1',
  [string]$ExpectedPC  = 'OEE-NUC-01',
  [string]$DisplayUser = 'LineTV1',
  [string]$AppteanUser = ''
)
$ErrorActionPreference = 'Stop'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
  [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw 'Run this in an elevated PowerShell.' }

if ($env:COMPUTERNAME -ne $ExpectedPC) { throw "This is the $TVName script for $ExpectedPC, but this PC is $env:COMPUTERNAME." }
if (-not $AppteanUser) { $AppteanUser = Read-Host 'Aptean OEE username for this TV' }
Write-Host "=== $TVName setup on $env:COMPUTERNAME ===" -ForegroundColor Cyan

# 1. Local display account (created if missing)
$s       = Read-Host "Windows password for local account $DisplayUser" -AsSecureString
$winPass = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s))
if (-not (Get-LocalUser $DisplayUser -ErrorAction SilentlyContinue)) {
  New-LocalUser -Name $DisplayUser -Password $s -FullName "$DisplayUser OEE Display" -Description 'OEE TV kiosk account' | Out-Null
  Add-LocalGroupMember -Group 'Users' -Member $DisplayUser -ErrorAction SilentlyContinue
  Write-Host "Created local account $DisplayUser"
}
Set-LocalUser $DisplayUser -PasswordNeverExpires $true
if (Get-LocalGroupMember Administrators | Where-Object { $_.Name -like "*\$DisplayUser" }) {
  Write-Warning "$DisplayUser is a local admin. Remove it from Administrators when possible."
}
Write-Host "[1/6] $DisplayUser password set to never expire"

# 2. Allow password auto-logon
$pl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\PasswordLess\Device'
New-Item $pl -Force | Out-Null
Set-ItemProperty $pl -Name DevicePasswordLessBuildVersion -Value 0
# Skip the "Choose privacy settings" screen on a new account's first sign-in
$oobe = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE'
New-Item $oobe -Force | Out-Null
Set-ItemProperty $oobe -Name DisablePrivacyExperience -Value 1 -Type DWord
Write-Host '[2/6] Password auto-logon allowed'

# 3. Autologon
$alDir = 'C:\Tools\AutoLogon'
$al    = Join-Path $alDir 'Autologon64.exe'
if (-not (Test-Path $al)) {
  New-Item $alDir -ItemType Directory -Force | Out-Null
  $zip = 'C:\Tools\AutoLogon.zip'
  Invoke-WebRequest https://download.sysinternals.com/files/AutoLogon.zip -OutFile $zip -UseBasicParsing
  Expand-Archive $zip $alDir -Force
}
Start-Process $al -ArgumentList $DisplayUser, '.', "`"$winPass`"", '/accepteula' -Wait
$winPass = $null
$wl = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
if ($wl.AutoAdminLogon -ne '1' -or $wl.DefaultUserName -ne $DisplayUser) { throw 'Autologon did not apply. Check the password and run again.' }
Write-Host "[3/6] Autologon set for $DisplayUser"

# 4. Install display script + scheduled task
& (Join-Path $PSScriptRoot 'Install-OEEDisplay.ps1') -DisplayUser $DisplayUser -Domain $env:COMPUTERNAME
Write-Host '[4/6] OEE Display task installed'

# 5. Aptean login
& (Join-Path $PSScriptRoot 'Set-OEECredential.ps1') -AppteanUser $AppteanUser -DisplayUser $DisplayUser
Remove-Item 'C:\OEEDisplay\STOP' -Force -ErrorAction SilentlyContinue
Write-Host '[5/6] Aptean login saved'

# 6. Reboot
Write-Host '[6/6] Rebooting in 10 seconds (Ctrl+C to cancel)' -ForegroundColor Yellow
Start-Sleep 10
shutdown /r /t 0 /f
