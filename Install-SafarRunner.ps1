[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$RegistrationToken,
    [string]$RepositoryUrl = 'https://github.com/alimirzae/safar',
    [string]$RunnerName = 'new.safar.vip',
    [string]$InstallPath = 'C:\actions-runner',
    [string]$Labels = 'safar-production'
)

$ErrorActionPreference = 'Stop'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'PowerShell must be run as Administrator.'
}
if (Get-Service 'actions.runner.*' -ErrorAction SilentlyContinue) {
    throw 'A GitHub Actions runner service is already installed.'
}
if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) { throw '.NET 8 SDK is not installed or is not available in PATH.' }
if ([int]((& dotnet --version).Split('.')[0]) -lt 8) { throw '.NET 8 SDK or newer is required.' }

New-Item -ItemType Directory -Path $InstallPath -Force | Out-Null
$release = Invoke-RestMethod -Uri 'https://api.github.com/repos/actions/runner/releases/latest' -Headers @{ 'User-Agent' = 'Safar-Runner-Installer' }
$asset = $release.assets | Where-Object name -Match '^actions-runner-win-x64-.*\.zip$' | Select-Object -First 1
if (-not $asset) { throw 'The latest Windows x64 runner package was not found.' }
$zipPath = Join-Path $env:TEMP $asset.name
try {
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath
    Expand-Archive -LiteralPath $zipPath -DestinationPath $InstallPath -Force
}
finally {
    if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
}

Push-Location $InstallPath
try {
    & .\config.cmd --unattended --url $RepositoryUrl --token $RegistrationToken --name $RunnerName --labels $Labels --work '_work' --runasservice --replace
    if ($LASTEXITCODE -ne 0) { throw "Runner configuration failed with exit code $LASTEXITCODE." }
}
finally { Pop-Location }

$service = Get-Service 'actions.runner.*' | Select-Object -First 1
if (-not $service) { throw 'Runner service was not created.' }
Set-Service -Name $service.Name -StartupType Automatic
Start-Service -Name $service.Name
$service.WaitForStatus('Running', [TimeSpan]::FromSeconds(30))
Write-Host "GitHub runner '$RunnerName' is installed and running as a Windows service." -ForegroundColor Green
