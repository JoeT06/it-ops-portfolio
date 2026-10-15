<#
  Install-OEEDisplay.ps1
  Run once per NUC in an ELEVATED PowerShell, from the folder containing Start-OEEDisplay.ps1.
  - Copies the script to C:\OEEDisplay
  - Disables sleep / screen off
  - Creates the "OEE Display" scheduled task that runs at logon of the display account
#>
param(
  [string]$DisplayUser = 'LineTV1',
  [string]$Domain      = $env:COMPUTERNAME # local account; use domain NetBIOS name if the display account is a domain account
)

$BaseDir = 'C:\OEEDisplay'
New-Item -ItemType Directory -Path $BaseDir -Force | Out-Null
Copy-Item (Join-Path $PSScriptRoot 'Start-OEEDisplay.ps1') $BaseDir -Force
Copy-Item (Join-Path $PSScriptRoot 'Set-OEECredential.ps1') $BaseDir -Force

# Let the display user write logs / browser profile
icacls $BaseDir /grant "$($Domain)\$($DisplayUser):(OI)(CI)M" | Out-Null

# Keep the screen on
powercfg /change monitor-timeout-ac 0
powercfg /change standby-timeout-ac 0
powercfg /change hibernate-timeout-ac 0

$user      = "$Domain\$DisplayUser"
$action    = New-ScheduledTaskAction -Execute 'powershell.exe' `
             -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$BaseDir\Start-OEEDisplay.ps1`""
$trigger   = New-ScheduledTaskTrigger -AtLogOn -User $user
$trigger.Delay = 'PT30S'
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
$settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) `
             -RestartCount 5 -RestartInterval (New-TimeSpan -Minutes 1) `
             -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew

Register-ScheduledTask -TaskName 'OEE Display' -Action $action -Trigger $trigger `
  -Principal $principal -Settings $settings -Force | Out-Null

Write-Host "Installed OEE Display task for $user."
