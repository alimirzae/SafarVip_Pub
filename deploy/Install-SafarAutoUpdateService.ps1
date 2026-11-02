# ==============================================================================
# Safar Auto-Update Service Installer for Windows Server (IIS)
# Installs a background Scheduled Task running every 5 minutes to automatically
# check for and apply new Safar releases from SafarVip_Pub for new.safar.vip.
# ==============================================================================

[CmdletBinding()]
param(
    [ValidateSet('Install', 'Uninstall', 'Status', 'RunNow', 'Restart')]
    [string]$Action = 'Install',

    [string]$TaskName = 'Safar-AutoUpdate-Service',
    [string]$InstallDir,
    [string]$IisSiteName = 'new.safar.vip',
    [string]$ApplicationPath,
    [string]$AppPoolName,
    [string]$BackupRoot = 'C:\\SafarDeployBackups',
    [int]$IntervalMinutes = 5,
    [string]$Repository = 'alimirzae/SafarVip_Pub'
)

$ErrorActionPreference = 'Stop'

# Ensure running as Administrator
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    throw "This script must be run as Administrator in PowerShell."
}

if ([string]::IsNullOrWhiteSpace($InstallDir)) {
    if (Test-Path -LiteralPath 'C:\runner') {
        $InstallDir = 'C:\runner'
    } else {
        $InstallDir = 'C:\Safar\AutoUpdate'
    }
}

switch ($Action) {
    'Install' {
        Write-Host ">>> Installing Safar Auto-Update Service (checking every $IntervalMinutes minute(s) for site '$IisSiteName')..." -ForegroundColor Cyan

        # Create installation directory
        if (-not (Test-Path -LiteralPath $InstallDir)) {
            New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
        }

        # Copy local script if present, or download latest from GitHub
        $targetScriptPath = Join-Path $InstallDir 'Update-NewSafarVip.ps1'
        $localScript = Join-Path $PSScriptRoot 'Update-NewSafarVip.ps1'
        if (Test-Path -LiteralPath $localScript) {
            Copy-Item -LiteralPath $localScript -Destination $targetScriptPath -Force
            Write-Host "Copied Update-NewSafarVip.ps1 from local package to $targetScriptPath" -ForegroundColor Green
        } else {
            $downloadUrls = @(
                "https://github.com/alimirzae/SafarVip_Pub/releases/latest/download/Update-NewSafarVip.ps1",
                "https://raw.githubusercontent.com/alimirzae/SafarVip_Pub/main/deploy/Update-NewSafarVip.ps1",
                "https://raw.githubusercontent.com/alimirzae/SafarVip_Pub/main/Update-NewSafarVip.ps1",
                "https://raw.githubusercontent.com/alimirzae/safar/main/deploy/Update-NewSafarVip.ps1",
                "https://raw.githubusercontent.com/alimirzae/safar/master/deploy/Update-NewSafarVip.ps1",
                "https://github.com/alimirzae/safar/releases/latest/download/Update-NewSafarVip.ps1"
            )
            $downloaded = $false
            foreach ($url in $downloadUrls) {
                try {
                    Write-Host "Downloading latest Update-NewSafarVip.ps1 from $url..." -ForegroundColor Yellow
                    Invoke-WebRequest -Uri $url -OutFile $targetScriptPath -UseBasicParsing -TimeoutSec 15
                    if (Test-Path -LiteralPath $targetScriptPath) {
                        $content = Get-Content -LiteralPath $targetScriptPath -Raw
                        if ($content -and $content.Contains('Invoke-SafarUpdateOnce')) {
                            $downloaded = $true
                            Write-Host "Downloaded script successfully to $targetScriptPath" -ForegroundColor Green
                            break
                        }
                    }
                } catch {
                    Write-Host "Attempt from $url failed, trying next source..." -ForegroundColor DarkGray
                }
            }
            if (-not $downloaded) {
                throw "Failed to download Update-NewSafarVip.ps1 from GitHub releases or repository mirrors."
            }
        }

        # Unregister existing task if present
        if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
            Write-Host "Removing previous task '$TaskName'..." -ForegroundColor Yellow
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        }

        # Configure action: run powershell.exe with the update script
        $psPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
        $arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$targetScriptPath`" -IisSiteName `"$IisSiteName`" -Repository `"$Repository`""
        if (-not [string]::IsNullOrWhiteSpace($ApplicationPath)) {
            if (-not (Test-Path -LiteralPath $ApplicationPath -PathType Container)) {
                throw "ApplicationPath not found: $ApplicationPath"
            }
            $arguments += " -ApplicationPath `"$ApplicationPath`""
        }
        if (-not [string]::IsNullOrWhiteSpace($AppPoolName)) {
            $arguments += " -AppPoolName `"$AppPoolName`""
        }
        $arguments += " -BackupRoot `"$BackupRoot`" -SkipSelfUpdate"
        $taskAction = New-ScheduledTaskAction -Execute $psPath -Argument $arguments

        # Trigger: Run at system startup AND repeat every 1 minute indefinitely
        $triggerStartup = New-ScheduledTaskTrigger -AtStartup
        $triggerRepeat = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(15) `
            -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes) `
            -RepetitionDuration (New-TimeSpan -Days 3650)

        # Principal: Run with SYSTEM account and highest elevation
        $principal = New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest

        # Settings
        $settings = New-ScheduledTaskSettingsSet `
            -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries `
            -StartWhenAvailable `
            -MultipleInstances IgnoreNew `
            -ExecutionTimeLimit (New-TimeSpan -Minutes 10) `
            -RestartCount 3 `
            -RestartInterval (New-TimeSpan -Minutes 1)

        # Register Scheduled Task
        Register-ScheduledTask -TaskName $TaskName `
                               -Action $taskAction `
                               -Trigger @($triggerStartup, $triggerRepeat) `
                               -Principal $principal `
                               -Settings $settings `
                               -Description "Checks for and automatically applies new Safar DLL releases for $IisSiteName from $Repository every $IntervalMinutes minute(s)." | Out-Null

        Write-Host ">>> Service installed successfully!" -ForegroundColor Green
        Write-Host "Task Name     : $TaskName"
        Write-Host "Interval      : Every $IntervalMinutes minute(s)"
        Write-Host "Script Target : $targetScriptPath"
        Write-Host "IIS Site Name : $IisSiteName"
        Write-Host "Log File      : $BackupRoot\autoupdate.log"
        Write-Host ""

        # Trigger first execution immediately
        Write-Host "Triggering initial update check..." -ForegroundColor Cyan
        Start-ScheduledTask -TaskName $TaskName
        Write-Host "Initial check initiated in background." -ForegroundColor Green
        Write-Host ""
        Write-Host "To check status: .\Install-SafarAutoUpdateService.ps1 -Action Status" -ForegroundColor Gray
        Write-Host "To run immediately: .\Install-SafarAutoUpdateService.ps1 -Action RunNow" -ForegroundColor Gray
        Write-Host "To uninstall: .\Install-SafarAutoUpdateService.ps1 -Action Uninstall" -ForegroundColor Gray
    }

    'Uninstall' {
        Write-Host ">>> Uninstalling Safar Auto-Update Service..." -ForegroundColor Cyan
        if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
            Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
            Write-Host "Scheduled Task '$TaskName' has been removed." -ForegroundColor Green
        } else {
            Write-Host "Scheduled Task '$TaskName' was not found." -ForegroundColor Yellow
        }
    }

    'Status' {
        Write-Host ">>> Status of ${TaskName}:" -ForegroundColor Cyan
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if (-not $task) {
            Write-Host "Task '$TaskName' is not installed." -ForegroundColor Red
            return
        }
        $info = Get-ScheduledTaskInfo -TaskName $TaskName
        [PSCustomObject]@{
            TaskName       = $task.TaskName
            State          = $task.State
            LastRunTime    = $info.LastRunTime
            LastTaskResult = $info.LastTaskResult
            NextRunTime    = $info.NextRunTime
        } | Format-List

        $versionFile = 'C:\SafarDeployBackups\installed_version.json'
        if (Test-Path -LiteralPath $versionFile) {
            Write-Host "--- Current Installed Version ---" -ForegroundColor Cyan
            Get-Content -LiteralPath $versionFile -Raw
        }

        $logPath = 'C:\SafarDeployBackups\autoupdate.log'
        if (Test-Path -LiteralPath $logPath) {
            Write-Host "--- Last 15 log entries (from $logPath) ---" -ForegroundColor Yellow
            Get-Content -LiteralPath $logPath -Tail 15
        }
    }

    'RunNow' {
        Write-Host ">>> Triggering '$TaskName' immediately..." -ForegroundColor Cyan
        Start-ScheduledTask -TaskName $TaskName
        Write-Host "Task started. Check log in C:\SafarDeployBackups\autoupdate.log." -ForegroundColor Green
    }

    'Restart' {
        Write-Host ">>> Restarting '$TaskName'..." -ForegroundColor Cyan
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        Start-ScheduledTask -TaskName $TaskName
        Write-Host "Task restarted." -ForegroundColor Green
    }
}
