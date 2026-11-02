# Run as Administrator ON THE OLD safar.vip Windows server.
# Only the legacy site's application is updated. The new.safar.vip site is untouched.
[CmdletBinding()]
param(
    [ValidateSet('Install','Status','RunNow','Restart','Uninstall')]
    [string]$Action = 'Install',
    [string]$IisSiteName = 'safar.vip',
    [string]$ApplicationPath = 'C:\new.safar.vip',
    [string]$AppPoolName,
    [int]$IntervalMinutes = 5
)
$ErrorActionPreference = 'Stop'
$taskName = 'Safar-Legacy-AutoUpdate'
$installDir = 'C:\Safar\LegacyAutoUpdate'
$backupRoot = 'C:\SafarDeployBackups\Legacy'
$repository = 'alimirzae/SafarVip_Pub'
if ($Action -eq 'Install') {
    $appcmd = Join-Path $env:SystemRoot 'System32\inetsrv\appcmd.exe'
    if (-not (Test-Path -LiteralPath $appcmd)) { throw 'IIS appcmd.exe not found.' }
    $sitePath = (& $appcmd list vdir "$IisSiteName/" /text:physicalPath 2>$null | Out-String).Trim()
    if (-not $sitePath) { throw "IIS site '$IisSiteName' not found. Verify its actual binding/site name." }
    $sitePath = [Environment]::ExpandEnvironmentVariables($sitePath)
    $expected = [IO.Path]::GetFullPath($ApplicationPath).TrimEnd('\')
    $actual = [IO.Path]::GetFullPath($sitePath).TrimEnd('\')
    if (-not [string]::Equals($expected,$actual,[StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to install: site '$IisSiteName' points to '$actual', not '$expected'."
    }
    if (-not (Test-Path -LiteralPath (Join-Path $expected 'Safar.dll'))) {
        throw "Safar.dll not found in '$expected'; refusing to update an unverified site."
    }
    if (-not (Test-Path -LiteralPath (Join-Path $expected 'web.config'))) {
        throw "web.config not found in '$expected'."
    }
    $actualPool = (& $appcmd list app "$IisSiteName/" /text:apppool.name 2>$null | Out-String).Trim()
    if (-not $actualPool) { throw "Cannot discover AppPool for $IisSiteName." }
    if ($AppPoolName -and $AppPoolName -ne $actualPool) {
        throw "Specified AppPoolName '$AppPoolName' does not match IIS '$actualPool'."
    }
    $AppPoolName = $actualPool
    Write-Host "Verified IIS site '$IisSiteName' -> '$expected', AppPool '$AppPoolName'."
}
$installer = Join-Path $PSScriptRoot 'Install-SafarAutoUpdateService.ps1'
if (-not (Test-Path -LiteralPath $installer)) { throw "Missing installer at $installer" }
& $installer -Action $Action -TaskName $taskName -InstallDir $installDir `
    -IisSiteName $IisSiteName -ApplicationPath $ApplicationPath -AppPoolName $AppPoolName `
    -BackupRoot $backupRoot -IntervalMinutes $IntervalMinutes -Repository $repository
