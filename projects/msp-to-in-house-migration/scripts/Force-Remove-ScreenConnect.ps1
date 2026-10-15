# Force-Remove-ScreenConnect.ps1
# Requires: Run as Administrator
#
# Finds ScreenConnect / ConnectWise Control by NAME (not a hardcoded GUID -
# ScreenConnect issues a unique product code per install/instance, which is
# almost certainly why a hardcoded-GUID one-liner silently did nothing) and
# removes every trace: service, processes, MSI registration, files, registry,
# scheduled tasks.
#
# Usage:
#   .\Force-Remove-ScreenConnect.ps1                               # list installed instances, remove nothing
#   .\Force-Remove-ScreenConnect.ps1 -InstanceId 0123456789abcdef  # remove only that instance
#   .\Force-Remove-ScreenConnect.ps1 -AllInstances                 # remove every ScreenConnect instance
#
# The instance ID is the hex value in parentheses in the service and program
# name, e.g. "ScreenConnect Client (0123456789abcdef)". Run with no parameters
# first to see the IDs on a machine.
#
# If your RMM can't pass parameters, set the default for $InstanceId below.
#
# With -AllInstances, don't run this from a ScreenConnect session or Backstage:
# step 2 stops the service that session runs through. With -InstanceId, any
# session works except one running through the instance being removed.

param(
    [ValidatePattern('^[0-9A-Fa-f]*$')]
    [string]$InstanceId = '',
    [switch]$AllInstances
)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

function Invoke-Safe {
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter(Mandatory)][string]$Description
    )
    try {
        & $Action
    } catch {
        Write-Host "  (non-fatal) $Description failed: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

$namePattern    = 'ScreenConnect|ConnectWise Control'
$idPattern      = [regex]::Escape("($InstanceId)")
$uninstallRoots = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
)

# True when $Text names ScreenConnect and, unless -AllInstances, contains "(<InstanceId>)"
function Test-Target([string]$Text) {
    if (-not $Text -or $Text -notmatch $namePattern) { return $false }
    if ($AllInstances) { return $true }
    return $Text -match $idPattern
}

# Lists installed instances from the uninstall registry and the service list
function Get-ScreenConnectInstance {
    $names = @(
        foreach ($root in $uninstallRoots) {
            Get-ChildItem $root -ErrorAction SilentlyContinue |
                ForEach-Object { (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).DisplayName } |
                Where-Object { $_ -match $namePattern }
        }
        Get-Service -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match $namePattern } |
            ForEach-Object { $_.Name }
    )
    $names | ForEach-Object {
        if ($_ -match '\(([0-9A-Fa-f]+)\)') {
            [PSCustomObject]@{ InstanceId = $Matches[1].ToLower(); Name = $_ }
        }
    } | Sort-Object InstanceId, Name -Unique
}

# 0. Decide what to remove. No parameters = list only.
if ($InstanceId -and $AllInstances) { throw 'Use -InstanceId or -AllInstances, not both.' }

if (-not $InstanceId -and -not $AllInstances) {
    Write-Host "`n=== INSTALLED SCREENCONNECT INSTANCES (nothing removed) ===" -ForegroundColor Cyan
    $instances = @(Get-ScreenConnectInstance)
    if ($instances.Count) { $instances | Format-Table InstanceId, Name -AutoSize | Out-String -Width 200 | Write-Host }
    else { Write-Host 'No ScreenConnect instances found.' }
    Write-Host 'Run again with -InstanceId <id> to remove one instance, or -AllInstances to remove every instance.' -ForegroundColor Yellow
    return
}

if ($AllInstances) {
    $target = 'ALL INSTANCES'
    $paths  = @(
        'C:\Program Files (x86)\ScreenConnect Client*',
        'C:\Program Files\ScreenConnect Client*',
        'C:\ProgramData\ScreenConnect*',
        "$env:LOCALAPPDATA\Apps\2.0\*ScreenConnect*",
        'C:\Windows\Temp\ScreenConnect*'
    )
} else {
    $target = "INSTANCE $InstanceId"
    $paths  = @(
        "C:\Program Files (x86)\*($InstanceId)",
        "C:\Program Files\*($InstanceId)",
        "C:\ProgramData\*($InstanceId)"
    )
}

Write-Host "`n=== FORCE REMOVING SCREENCONNECT / CONNECTWISE CONTROL CLIENT: $target ===" -ForegroundColor Cyan

# 1. Find every matching ScreenConnect product by name (replaces the hardcoded GUID)
Write-Host "[1/8] Searching registry for installed ScreenConnect products..."
$foundProducts = @()
foreach ($root in $uninstallRoots) {
    Invoke-Safe -Description "scan $root" -Action {
        Get-ChildItem $root -ErrorAction SilentlyContinue | ForEach-Object {
            $props = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
            if (Test-Target $props.DisplayName) {
                Write-Host "Found: $($props.DisplayName)  [$($_.PSChildName)]"
                $script:foundProducts += [PSCustomObject]@{
                    ProductCode     = $_.PSChildName
                    DisplayName     = $props.DisplayName
                    UninstallString = $props.UninstallString
                }
            }
        }
    }
}
if (-not $foundProducts -or $foundProducts.Count -eq 0) {
    Write-Host "No matching ScreenConnect entries found in the uninstall registry - it may already be MSI-orphaned. Continuing to file/service cleanup anyway." -ForegroundColor Yellow
}

# 2. Stop the ScreenConnect service(s) - service name includes the instance ID
Write-Host "`n[2/8] Stopping ScreenConnect services..."
Invoke-Safe -Description "stop services" -Action {
    Get-Service -ErrorAction SilentlyContinue |
        Where-Object { (Test-Target $_.Name) -or (Test-Target $_.DisplayName) } |
        ForEach-Object {
            Write-Host "Stopping: $($_.Name)"
            Stop-Service -Name $_.Name -Force -ErrorAction SilentlyContinue
        }
}

# 3. Kill ScreenConnect processes (process names don't carry the instance ID, so match on the exe path)
Write-Host "`n[3/8] Killing ScreenConnect processes..."
Invoke-Safe -Description "kill processes" -Action {
    Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessName -match 'ScreenConnect' -and ($AllInstances -or (Test-Target $_.Path)) } |
        ForEach-Object {
            Write-Host "Killing: $($_.ProcessName)"
            Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
        }
}
Start-Sleep -Seconds 2

# 4. Delete the services (sc.exe), then run msiexec for every product code actually found
Write-Host "`n[4/8] Removing services and running msiexec against each found product code..."
Invoke-Safe -Description "sc.exe delete services" -Action {
    Get-Service -ErrorAction SilentlyContinue |
        Where-Object { (Test-Target $_.Name) -or (Test-Target $_.DisplayName) } |
        ForEach-Object {
            Write-Host "Deleting service: $($_.Name)"
            & sc.exe delete "$($_.Name)" | Out-Null
        }
}
foreach ($prod in $foundProducts) {
    Invoke-Safe -Description "msiexec uninstall $($prod.DisplayName)" -Action {
        $msiLog = "$env:TEMP\ScreenConnect_uninstall_$($prod.ProductCode -replace '[{}]','').log"
        $proc = Start-Process msiexec.exe -ArgumentList "/x $($prod.ProductCode) /qn /norestart /l*v `"$msiLog`"" -Wait -PassThru -ErrorAction SilentlyContinue
        Write-Host "msiexec exit code for $($prod.DisplayName): $($proc.ExitCode)  (log: $msiLog)"
    }
}

# 5. Clean orphaned Add/Remove Programs entries regardless of msiexec result
Write-Host "`n[5/8] Cleaning orphaned uninstall registry entries..."
foreach ($root in $uninstallRoots) {
    Invoke-Safe -Description "scan $root" -Action {
        Get-ChildItem $root -ErrorAction SilentlyContinue | ForEach-Object {
            $props = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
            if (Test-Target $props.DisplayName) {
                Write-Host "Removing orphaned uninstall key: $($_.PSChildName) ($($props.DisplayName))"
                Remove-Item $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
Invoke-Safe -Description "remove Installer\Products cache key" -Action {
    Get-ChildItem 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Classes\Installer\Products' -ErrorAction SilentlyContinue |
        Where-Object {
            Test-Target (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).ProductName
        } | ForEach-Object {
            Write-Host "Removing Installer\Products cache: $($_.PSChildName)"
            Remove-Item $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue
        }
}

# 6. Remove scheduled tasks (ScreenConnect can register one for update-checking)
Write-Host "`n[6/8] Removing scheduled tasks..."
Invoke-Safe -Description "remove scheduled tasks" -Action {
    Get-ScheduledTask -ErrorAction SilentlyContinue |
        Where-Object {
            $actions = ($_.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -join ' '
            Test-Target "$($_.TaskName) $actions"
        } |
        ForEach-Object {
            Write-Host "Unregistering scheduled task: $($_.TaskName)"
            Unregister-ScheduledTask -TaskName $_.TaskName -TaskPath $_.TaskPath -Confirm:$false -ErrorAction SilentlyContinue
        }
}

# 6b. Remove leftover service registry keys (in case sc.exe delete needs a reboot to finish)
Invoke-Safe -Description "remove leftover service registry keys" -Action {
    Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services' -ErrorAction SilentlyContinue |
        Where-Object { Test-Target $_.PSChildName } |
        ForEach-Object {
            Write-Host "Removing service registry key: $($_.PSChildName)"
            Remove-Item $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue
        }
}

# 7. Remove remaining files/folders (folder names include the instance ID)
Write-Host "`n[7/8] Removing ScreenConnect files..."
foreach ($pattern in $paths) {
    Invoke-Safe -Description "resolve $pattern" -Action {
        Get-Item -Path $pattern -ErrorAction SilentlyContinue |
            Where-Object { Test-Target $_.Name } |
            ForEach-Object {
                Write-Host "Deleting: $($_.FullName)"
                Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
                if (Test-Path $_.FullName) {
                    Start-Sleep -Seconds 2
                    Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
    }
}

# 8. Verification
Write-Host "`n[8/8] VERIFYING..." -ForegroundColor Cyan

Write-Host "`n=== REMAINING SERVICES ==="
Get-Service -ErrorAction SilentlyContinue |
    Where-Object { (Test-Target $_.Name) -or (Test-Target $_.DisplayName) } |
    Format-Table Status,Name,DisplayName -AutoSize

Write-Host "`n=== REMAINING UNINSTALL REGISTRY ENTRIES ==="
foreach ($root in $uninstallRoots) {
    Get-ChildItem $root -ErrorAction SilentlyContinue | ForEach-Object {
        $props = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
        if (Test-Target $props.DisplayName) {
            $props | Select-Object DisplayName, DisplayVersion, PSChildName
        }
    }
}

Write-Host "`n=== REMAINING FOLDERS ==="
foreach ($pattern in $paths) {
    $leftover = Get-Item -Path $pattern -ErrorAction SilentlyContinue | Where-Object { Test-Target $_.Name }
    if ($leftover) { $leftover | ForEach-Object { Write-Host "$($_.FullName) : STILL PRESENT" } }
    else { Write-Host "$pattern : none found" }
}

Write-Host "`n=== SCREENCONNECT CLEANUP FINISHED ===" -ForegroundColor Green
Write-Host "Recommended: reboot this box before installing the new RMM's remote-access client," -ForegroundColor Yellow
Write-Host "so any locked driver/service handles from the old client are fully released." -ForegroundColor Yellow
