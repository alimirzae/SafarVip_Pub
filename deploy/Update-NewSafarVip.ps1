[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Repository = 'alimirzae/SafarVip_Pub',
    [string]$ReleaseTag = 'latest',
    [string]$IisSiteName = 'new.safar.vip',
    [string]$AppPoolName,
    [string]$ApplicationPath,
    [string]$BackupRoot = 'C:\SafarDeployBackups',
    [switch]$Force,
    [switch]$CheckOnly,
    [switch]$Watch,
    [int]$IntervalMinutes = 5,
    [switch]$SkipSelfUpdate
)

$ErrorActionPreference = 'Stop'
$allowedDlls = @('Safar.dll', 'Safar.Views.dll', 'System.Drawing.Common.dll', 'Microsoft.Win32.SystemEvents.dll')

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $formatted = "[$timestamp] [$Level] $Message"
    Write-Host $formatted
    try {
        if (-not (Test-Path -LiteralPath $BackupRoot)) {
            New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null
        }
        $logPath = Join-Path $BackupRoot 'autoupdate.log'
        Add-Content -LiteralPath $logPath -Value $formatted -ErrorAction SilentlyContinue
    } catch {}
}

function Invoke-SelfUpdate {
    param([string]$ScriptPath)
    if ([string]::IsNullOrWhiteSpace($ScriptPath) -or -not (Test-Path -LiteralPath $ScriptPath)) { return }
    try {
        $candidateUrls = @(
            "https://github.com/alimirzae/SafarVip_Pub/releases/latest/download/Update-NewSafarVip.ps1",
            "https://raw.githubusercontent.com/alimirzae/SafarVip_Pub/main/deploy/Update-NewSafarVip.ps1",
            "https://raw.githubusercontent.com/alimirzae/SafarVip_Pub/main/Update-NewSafarVip.ps1",
            "https://raw.githubusercontent.com/alimirzae/safar/main/deploy/Update-NewSafarVip.ps1",
            "https://raw.githubusercontent.com/alimirzae/safar/master/deploy/Update-NewSafarVip.ps1",
            "https://github.com/alimirzae/safar/releases/latest/download/Update-NewSafarVip.ps1",
            "https://raw.githubusercontent.com/alimirzae/safar2/main/deploy/Update-NewSafarVip.ps1"
        )
        foreach ($url in $candidateUrls) {
            try {
                $remoteContent = (Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 10).Content
                if (-not [string]::IsNullOrWhiteSpace($remoteContent) -and $remoteContent.Contains('Invoke-SafarUpdateOnce')) {
                    $localContent = Get-Content -LiteralPath $ScriptPath -Raw
                    if ($remoteContent.Trim() -ne $localContent.Trim()) {
                        Set-Content -LiteralPath $ScriptPath -Value $remoteContent -Force
                        Write-Log "Update-NewSafarVip.ps1 script self-updated to latest version." "INFO"
                    }
                    break
                }
            } catch {}
        }
    } catch {
        # Non-blocking self-update check
    }
}

function Invoke-SafarUpdateOnce {
    param(
        [string]$Repository,
        [string]$ReleaseTag,
        [string]$IisSiteName,
        [string]$AppPoolName,
        [string]$ApplicationPath,
        [string]$BackupRoot,
        [bool]$ForceInstall,
        [bool]$CheckOnlyMode
    )

    # 1. Try environment variable SAFAR_IIS_PATH
    if ([string]::IsNullOrWhiteSpace($ApplicationPath) -and -not [string]::IsNullOrWhiteSpace($env:SAFAR_IIS_PATH)) {
        if (Test-Path -LiteralPath $env:SAFAR_IIS_PATH -PathType Container) {
            $ApplicationPath = $env:SAFAR_IIS_PATH
            Write-Log "Using ApplicationPath from SAFAR_IIS_PATH: $ApplicationPath" "INFO"
        }
    }

    # 2. Try native appcmd.exe (independent of PowerShell COM registration)
    $appcmd = Join-Path $env:SystemRoot 'System32\inetsrv\appcmd.exe'
    if (Test-Path -LiteralPath $appcmd) {
        try {
            if ([string]::IsNullOrWhiteSpace($ApplicationPath)) {
                $rawPath = & $appcmd list vdir "$IisSiteName/" /text:physicalPath 2>$null
                if (-not [string]::IsNullOrWhiteSpace($rawPath)) {
                    $ApplicationPath = [Environment]::ExpandEnvironmentVariables($rawPath.Trim())
                    Write-Log "Resolved ApplicationPath via appcmd.exe: $ApplicationPath" "INFO"
                }
            }
            if ([string]::IsNullOrWhiteSpace($AppPoolName)) {
                $rawPool = & $appcmd list app "$IisSiteName/" /text:apppool.name 2>$null
                if (-not [string]::IsNullOrWhiteSpace($rawPool)) {
                    $AppPoolName = $rawPool.Trim()
                    Write-Log "Resolved AppPoolName via appcmd.exe: $AppPoolName" "INFO"
                }
            }
        } catch {}
    }

    # 3. Try WebAdministration / Get-Website safely
    if ([string]::IsNullOrWhiteSpace($ApplicationPath) -or [string]::IsNullOrWhiteSpace($AppPoolName)) {
        try {
            Import-Module WebAdministration -ErrorAction Stop
            $site = Get-Website -Name $IisSiteName -ErrorAction Stop
            if ([string]::IsNullOrWhiteSpace($ApplicationPath)) {
                $ApplicationPath = [Environment]::ExpandEnvironmentVariables($site.PhysicalPath)
                Write-Log "Resolved ApplicationPath via Get-Website: $ApplicationPath" "INFO"
            }
            if ([string]::IsNullOrWhiteSpace($AppPoolName)) {
                $AppPoolName = $site.ApplicationPool
                Write-Log "Resolved AppPoolName via Get-Website: $AppPoolName" "INFO"
            }
        } catch {
            Write-Log "WebAdministration / Get-Website unavailable ($($_.Exception.Message))." "WARN"
        }
    }

    # 4. Fallback search in standard directories
    if ([string]::IsNullOrWhiteSpace($ApplicationPath)) {
        $searchRoots = @('C:\8.safar.vip', 'C:\new.safar.vip', 'C:\safar.vip', 'C:\inetpub', 'C:\Sites', 'D:\Sites', 'D:\Websites', 'D:\wwwroot') |
            Where-Object { Test-Path -LiteralPath $_ -PathType Container }
        $candidates = foreach ($root in $searchRoots) {
            Get-ChildItem -LiteralPath $root -Filter 'Safar.dll' -File -Recurse -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.FullName -notlike '*\SafarDeployBackups\*' -and
                    (Test-Path -LiteralPath (Join-Path $_.DirectoryName 'web.config'))
                } |
                ForEach-Object { $_.Directory }
        }
        $candidates = @($candidates | Select-Object -ExpandProperty FullName -Unique)
        if ($candidates.Count -eq 1) {
            $ApplicationPath = $candidates[0]
            Write-Log "Resolved ApplicationPath via directory discovery: $ApplicationPath" "INFO"
        } elseif ($candidates.Count -gt 1) {
            $best = $candidates | Where-Object { $_ -like "*$IisSiteName*" } | Select-Object -First 1
            if ($best) {
                $ApplicationPath = $best
                Write-Log "Resolved ApplicationPath from candidates: $ApplicationPath" "INFO"
            }
        }
    }

    # 5. Default AppPoolName to IisSiteName if still unknown
    if ([string]::IsNullOrWhiteSpace($AppPoolName)) {
        $AppPoolName = $IisSiteName
    }

    $ApplicationPath = [IO.Path]::GetFullPath($ApplicationPath)
    if (-not (Test-Path -LiteralPath $ApplicationPath -PathType Container)) {
        throw "IIS application path does not exist: $ApplicationPath"
    }

    if (-not (Test-Path -LiteralPath $BackupRoot)) {
        New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null
    }
    $stateFile = Join-Path $BackupRoot 'installed_version.json'

    $candidateRepos = @($Repository)
    if ($candidateRepos -notcontains 'alimirzae/SafarVip_Pub') { $candidateRepos += 'alimirzae/SafarVip_Pub' }
    if ($candidateRepos -notcontains 'alimirzae/safar') { $candidateRepos += 'alimirzae/safar' }

    $headers = @{
        'User-Agent' = 'Safar-IIS-Updater'
        'Accept'     = 'application/vnd.github+json'
    }
    if ($env:GITHUB_TOKEN) { $headers.Authorization = "Bearer $($env:GITHUB_TOKEN)" }

    $release = $null
    $lastError = $null

    foreach ($targetRepo in $candidateRepos) {
        $releaseUri = if ($ReleaseTag -eq 'latest') {
            "https://api.github.com/repos/$targetRepo/releases/latest"
        } else {
            "https://api.github.com/repos/$targetRepo/releases/tags/$ReleaseTag"
        }

        try {
            $candidateRelease = Invoke-RestMethod -Uri $releaseUri -Headers $headers -TimeoutSec 15
            if ($candidateRelease -and $candidateRelease.assets) {
                $hasAsset = $candidateRelease.assets | Where-Object name -eq 'Safar-application-dlls.zip' | Select-Object -First 1
                if ($hasAsset) {
                    $release = $candidateRelease
                    break
                }
            }
        } catch {
            if ($ReleaseTag -eq 'latest') {
                try {
                    $fallbackUri = "https://api.github.com/repos/$targetRepo/releases/tags/latest"
                    $candidateRelease = Invoke-RestMethod -Uri $fallbackUri -Headers $headers -TimeoutSec 15
                    if ($candidateRelease -and $candidateRelease.assets) {
                        $hasAsset = $candidateRelease.assets | Where-Object name -eq 'Safar-application-dlls.zip' | Select-Object -First 1
                        if ($hasAsset) {
                            $release = $candidateRelease
                            break
                        }
                    }
                } catch {
                    $lastError = $_
                }
            } else {
                $lastError = $_
            }
        }
    }

    if (-not $release) {
        if ($lastError) {
            $msg = $lastError.Exception.Message
            if ($msg -match '403' -or $msg -match 'rate limit') {
                Write-Log "GitHub API rate limit hit. Will retry on next check cycle." "WARNING"
                return $false
            }
            throw $lastError
        }
        throw "Could not retrieve release from candidate repositories: $($candidateRepos -join ', ')"
    }
    $asset = $release.assets | Where-Object name -eq 'Safar-application-dlls.zip' | Select-Object -First 1
    if (-not $asset) {
        throw 'Release asset Safar-application-dlls.zip was not found in release.'
    }

    $currentSignature = [PSCustomObject]@{
        ReleaseId   = $release.id
        ReleaseName = $release.name
        AssetId     = $asset.id
        AssetUpdate = $asset.updated_at
        AssetSize   = $asset.size
        Digest      = $asset.digest
    }

    $isNewVersion = $true
    if (Test-Path -LiteralPath $stateFile) {
        try {
            $saved = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
            if ($saved.AssetId -eq $currentSignature.AssetId -and
                $saved.AssetUpdate -eq $currentSignature.AssetUpdate -and
                $saved.AssetSize -eq $currentSignature.AssetSize) {
                $isNewVersion = $false
            }
        } catch {
            $isNewVersion = $true
        }
    }

    if (-not $isNewVersion -and -not $ForceInstall) {
        Write-Log "No new version found. Current version ($($currentSignature.AssetUpdate)) is already installed. Skipping IIS restart." "INFO"
        return $false
    }

    if ($CheckOnlyMode) {
        Write-Log "A new version is available: $($release.name) ($($currentSignature.AssetUpdate)). CheckOnly mode active; not installing." "INFO"
        return $true
    }

    Write-Log "New version detected: $($release.name) ($($currentSignature.AssetUpdate)). Beginning deployment..." "INFO"

    $tempRoot = Join-Path $env:TEMP ("SafarUpdate-" + [Guid]::NewGuid().ToString('N'))
    $zipPath = Join-Path $tempRoot 'Safar-application-dlls.zip'
    $extractPath = Join-Path $tempRoot 'package'
    New-Item -ItemType Directory -Path $extractPath -Force | Out-Null

    try {
        Write-Log "Downloading package from $($asset.browser_download_url)..." "INFO"
        Invoke-WebRequest -Uri $asset.browser_download_url -Headers $headers -OutFile $zipPath
        Expand-Archive -LiteralPath $zipPath -DestinationPath $extractPath -Force

        $packageDlls = Get-ChildItem -LiteralPath $extractPath -File -Filter '*.dll'
        $unexpected = $packageDlls | Where-Object Name -notin $allowedDlls
        if ($unexpected) {
            throw "Package contains an unauthorized DLL: $($unexpected.Name -join ', ')"
        }
        if (-not ($packageDlls | Where-Object Name -eq 'Safar.dll')) {
            throw 'Safar.dll is missing from package.'
        }

        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $backupPath = Join-Path $BackupRoot $stamp
        New-Item -ItemType Directory -Path $backupPath -Force | Out-Null
        foreach ($dll in $packageDlls) {
            $current = Join-Path $ApplicationPath $dll.Name
            if (Test-Path -LiteralPath $current) {
                Copy-Item -LiteralPath $current -Destination $backupPath -Force
            }
        }
        Write-Log "Current DLLs backed up to: $backupPath" "INFO"

        $stoppedAppPool = $false
        Write-Log "Stopping IIS AppPool '$AppPoolName'..." "INFO"
        if (Test-Path -LiteralPath $appcmd) {
            try {
                & $appcmd stop apppool /apppool.name:"$AppPoolName" 2>$null
                $stoppedAppPool = $true
            } catch {}
        }
        if (-not $stoppedAppPool) {
            try {
                Stop-WebAppPool -Name $AppPoolName -ErrorAction Stop
                $deadline = (Get-Date).AddSeconds(20)
                while ((Get-WebAppPoolState -Name $AppPoolName).Value -ne 'Stopped') {
                    if ((Get-Date) -ge $deadline) { break }
                    Start-Sleep -Milliseconds 250
                }
            } catch {
                Write-Log "Could not stop AppPool via WebAdministration ($($_.Exception.Message)). Using app_offline.htm." "WARN"
            }
        }

        $offlineFile = Join-Path $ApplicationPath 'app_offline.htm'
        try {
            Set-Content -LiteralPath $offlineFile -Value '<html><body>Safar is updating...</body></html>' -Encoding UTF8
            Start-Sleep -Seconds 2

            Write-Log "Overwriting application DLLs in '$ApplicationPath'..." "INFO"
            foreach ($dll in $packageDlls) {
                $dest = Join-Path $ApplicationPath $dll.Name
                $copied = $false
                for ($retry = 1; $retry -le 6; $retry++) {
                    try {
                        Copy-Item -LiteralPath $dll.FullName -Destination $dest -Force
                        $copied = $true
                        break
                    } catch {
                        if ($retry -lt 6) {
                            Start-Sleep -Seconds 2
                        } else {
                            throw
                        }
                    }
                }
            }
        }
        catch {
            Write-Log "Error during DLL overwrite. Rolling back from backup..." "ERROR"
            foreach ($name in $allowedDlls) {
                $backup = Join-Path $backupPath $name
                if (Test-Path -LiteralPath $backup) {
                    Copy-Item -LiteralPath $backup -Destination (Join-Path $ApplicationPath $name) -Force
                }
            }
            throw
        }
        finally {
            if (Test-Path -LiteralPath $offlineFile) {
                Remove-Item -LiteralPath $offlineFile -Force -ErrorAction SilentlyContinue
            }

            Write-Log "Starting IIS AppPool '$AppPoolName'..." "INFO"
            if (Test-Path -LiteralPath $appcmd) {
                try {
                    & $appcmd start apppool /apppool.name:"$AppPoolName" 2>$null
                } catch {}
            } else {
                try {
                    Start-WebAppPool -Name $AppPoolName -ErrorAction SilentlyContinue
                } catch {}
            }
        }

        $currentSignature | ConvertTo-Json | Set-Content -LiteralPath $stateFile -Force
        Write-Log "Safar application DLLs updated and verified successfully! Backup: $backupPath" "SUCCESS"
        return $true
    }
    finally {
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

if (-not $SkipSelfUpdate -and $PSCommandPath) {
    Invoke-SelfUpdate -ScriptPath $PSCommandPath
}

if ($Watch) {
    Write-Log "Starting Safar Auto-Update Daemon (checking every $IntervalMinutes minute(s))..." "INFO"
    while ($true) {
        try {
            if (-not $SkipSelfUpdate -and $PSCommandPath) {
                Invoke-SelfUpdate -ScriptPath $PSCommandPath
            }
            Invoke-SafarUpdateOnce -Repository $Repository `
                                   -ReleaseTag $ReleaseTag `
                                   -IisSiteName $IisSiteName `
                                   -AppPoolName $AppPoolName `
                                   -ApplicationPath $ApplicationPath `
                                   -BackupRoot $BackupRoot `
                                   -ForceInstall $Force `
                                   -CheckOnlyMode $CheckOnly
        } catch {
            Write-Log "Error during update check: $($_.Exception.Message)" "ERROR"
        }
        Start-Sleep -Seconds ($IntervalMinutes * 60)
    }
} else {
    Invoke-SafarUpdateOnce -Repository $Repository `
                           -ReleaseTag $ReleaseTag `
                           -IisSiteName $IisSiteName `
                           -AppPoolName $AppPoolName `
                           -ApplicationPath $ApplicationPath `
                           -BackupRoot $BackupRoot `
                           -ForceInstall $Force `
                           -CheckOnlyMode $CheckOnly
}
