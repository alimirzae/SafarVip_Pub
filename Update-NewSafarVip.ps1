[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Repository = 'alimirzae/SafarVip_Pub',
    [string]$ReleaseTag = 'latest',
    [string]$IisSiteName = 'new.safar.vip',
    [string]$AppPoolName,
    [string]$ApplicationPath,
    [string]$BackupRoot = 'C:\SafarDeployBackups'
)

$ErrorActionPreference = 'Stop'
$allowedDlls = @('Safar.dll', 'Safar.Views.dll')
Import-Module WebAdministration -ErrorAction Stop

if ([string]::IsNullOrWhiteSpace($ApplicationPath)) {
    $site = Get-Website -Name $IisSiteName -ErrorAction Stop
    $ApplicationPath = [Environment]::ExpandEnvironmentVariables($site.PhysicalPath)
    if ([string]::IsNullOrWhiteSpace($AppPoolName)) { $AppPoolName = $site.ApplicationPool }
}
if ([string]::IsNullOrWhiteSpace($AppPoolName)) {
    $site = Get-Website -Name $IisSiteName -ErrorAction Stop
    $AppPoolName = $site.ApplicationPool
}

$ApplicationPath = [IO.Path]::GetFullPath($ApplicationPath)
if (-not (Test-Path -LiteralPath $ApplicationPath -PathType Container)) {
    throw "IIS application path does not exist: $ApplicationPath"
}

$tempRoot = Join-Path $env:TEMP ("SafarUpdate-" + [Guid]::NewGuid().ToString('N'))
$zipPath = Join-Path $tempRoot 'Safar-application-dlls.zip'
$extractPath = Join-Path $tempRoot 'package'
New-Item -ItemType Directory -Path $extractPath -Force | Out-Null

try {
    $releaseUri = "https://api.github.com/repos/$Repository/releases/tags/$ReleaseTag"
    $headers = @{ 'User-Agent' = 'Safar-IIS-Updater'; 'Accept' = 'application/vnd.github+json' }
    if ($env:GITHUB_TOKEN) { $headers.Authorization = "Bearer $($env:GITHUB_TOKEN)" }
    $release = Invoke-RestMethod -Uri $releaseUri -Headers $headers
    $asset = $release.assets | Where-Object name -eq 'Safar-application-dlls.zip' | Select-Object -First 1
    if (-not $asset) { throw 'Release asset Safar-application-dlls.zip was not found.' }

    Invoke-WebRequest -Uri $asset.browser_download_url -Headers $headers -OutFile $zipPath
    Expand-Archive -LiteralPath $zipPath -DestinationPath $extractPath -Force
    $packageDlls = Get-ChildItem -LiteralPath $extractPath -File -Filter '*.dll'
    $unexpected = $packageDlls | Where-Object Name -notin $allowedDlls
    if ($unexpected) { throw "Package contains an unauthorized DLL: $($unexpected.Name -join ', ')" }
    if (-not ($packageDlls | Where-Object Name -eq 'Safar.dll')) { throw 'Safar.dll is missing from package.' }

    $backupPath = Join-Path $BackupRoot (Get-Date -Format 'yyyyMMdd-HHmmss')
    New-Item -ItemType Directory -Path $backupPath -Force | Out-Null
    foreach ($dll in $packageDlls) {
        $current = Join-Path $ApplicationPath $dll.Name
        if (Test-Path -LiteralPath $current) { Copy-Item -LiteralPath $current -Destination $backupPath -Force }
    }

    if ($PSCmdlet.ShouldProcess("IIS AppPool '$AppPoolName'", 'Stop, replace Safar application DLLs only, and start')) {
        Stop-WebAppPool -Name $AppPoolName
        $deadline = (Get-Date).AddSeconds(30)
        while ((Get-WebAppPoolState -Name $AppPoolName).Value -ne 'Stopped') {
            if ((Get-Date) -ge $deadline) { throw "IIS AppPool '$AppPoolName' did not stop within 30 seconds." }
            Start-Sleep -Milliseconds 250
        }
        try {
            foreach ($dll in $packageDlls) {
                Copy-Item -LiteralPath $dll.FullName -Destination (Join-Path $ApplicationPath $dll.Name) -Force
            }
        }
        catch {
            foreach ($name in $allowedDlls) {
                $backup = Join-Path $backupPath $name
                if (Test-Path -LiteralPath $backup) { Copy-Item -LiteralPath $backup -Destination (Join-Path $ApplicationPath $name) -Force }
            }
            throw
        }
        finally { Start-WebAppPool -Name $AppPoolName }
    }

    Write-Host "Safar application DLLs updated successfully. Backup: $backupPath" -ForegroundColor Green
}
finally {
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}
