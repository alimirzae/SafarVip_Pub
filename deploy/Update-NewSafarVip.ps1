# Production Safar updater; Windows PowerShell 5.1
[CmdletBinding()]
param(
 [string]$Repository='alimirzae/SafarVip_Pub',
 [string]$ReleaseTag='latest',
 [string]$IisSiteName='safar.vip',
 [string]$AppPoolName,
 [string]$ApplicationPath,
 [string]$BackupRoot='C:\SafarDeployBackups\Legacy',
 [switch]$Force,
 [switch]$CheckOnly,
 [switch]$Watch,
 [ValidateRange(1,1440)][int]$IntervalMinutes=5,
 [switch]$SkipSelfUpdate
)
$ErrorActionPreference='Stop'
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
function Log($message,$level='INFO') {
 $line="[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$level] $message"
 Write-Host $line
 if(-not(Test-Path -LiteralPath $BackupRoot)){New-Item -ItemType Directory -Path $BackupRoot -Force|Out-Null}
 Add-Content -LiteralPath (Join-Path $BackupRoot 'autoupdate.log') -Value $line
}
function Run-Update {
 $appcmd=Join-Path $env:SystemRoot 'System32\inetsrv\appcmd.exe'
 if(-not(Test-Path -LiteralPath $appcmd)){throw 'IIS appcmd.exe missing'}
 $sitePath=((& $appcmd list vdir "$IisSiteName/" /text:physicalPath 2>$null)|Out-String).Trim()
 $pool=((& $appcmd list app "$IisSiteName/" /text:apppool.name 2>$null)|Out-String).Trim()
 if(-not $sitePath -or -not $pool){throw "IIS site $IisSiteName not found"}
 $sitePath=[IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($sitePath)).TrimEnd('\')
 if($ApplicationPath){
  $requested=[IO.Path]::GetFullPath($ApplicationPath).TrimEnd('\')
  if($requested -ine $sitePath){throw "Path mismatch: IIS=$sitePath requested=$requested"}
 }
 if($AppPoolName -and $AppPoolName -ne $pool){throw "AppPool mismatch: IIS=$pool requested=$AppPoolName"}
 if(-not(Test-Path -LiteralPath (Join-Path $sitePath 'Safar.dll')) -or -not(Test-Path -LiteralPath (Join-Path $sitePath 'web.config'))){throw "Unverified application at $sitePath"}
 Log "Verified IIS $IisSiteName at $sitePath with AppPool $pool"
 $temp=Join-Path $env:TEMP ('SafarUpdate-'+[Guid]::NewGuid().ToString('N'))
 $zip=Join-Path $temp 'release.zip'
 $stage=Join-Path $temp 'stage'
 New-Item -ItemType Directory -Path $stage -Force|Out-Null
 try{
  $sources=@($Repository,'alimirzae/SafarVip_Pub','alimirzae/safar')|Select-Object -Unique
  $downloaded=$false
  foreach($source in $sources){
   if($ReleaseTag -eq 'latest'){$url="https://github.com/$source/releases/latest/download/Safar-application-dlls.zip"}
   else{$url="https://github.com/$source/releases/download/$ReleaseTag/Safar-application-dlls.zip"}
   for($attempt=1;$attempt -le 2;$attempt++){
    try{
     if(Test-Path -LiteralPath $zip){Remove-Item -LiteralPath $zip -Force}
     Log "Downloading $url (attempt $attempt)"
     Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing -TimeoutSec 90 -MaximumRedirection 10
     if((Get-Item -LiteralPath $zip).Length -lt 1024){throw 'Release ZIP is unexpectedly small'}
     $downloaded=$true
     break
    }catch{
     Log "Download failed: $($_.Exception.Message)" 'WARN'
     Start-Sleep -Seconds 2
    }
   }
   if($downloaded){break}
  }
  if(-not $downloaded){throw 'All release download sources failed. Test GitHub connectivity or proxy/firewall.'}
  $hash=(Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
  $state=Join-Path $BackupRoot 'installed_version.json'
  $previousHash=''
  if(Test-Path -LiteralPath $state){try{$previousHash=(Get-Content -LiteralPath $state -Raw|ConvertFrom-Json).SHA256}catch{}}
  if($hash -eq $previousHash -and -not $Force){Log 'No new package; IIS was not interrupted.';return}
  if($CheckOnly){Log "Update available: $hash (check only).";return}
  Expand-Archive -LiteralPath $zip -DestinationPath $stage -Force
  if(-not(Test-Path -LiteralPath (Join-Path $stage 'Safar.dll'))){throw 'Invalid package: Safar.dll missing at root'}
  $files=@(Get-ChildItem -LiteralPath $stage -File -Recurse)
  $root=[IO.Path]::GetFullPath($stage).TrimEnd('\')+'\'
  $copyList=@()
  foreach($file in $files){
   $rel=$file.FullName.Substring($root.Length)
   $rootDll=($rel -notmatch '[\\/]' -and @('Safar.dll','Safar.Views.dll','System.Drawing.Common.dll','Microsoft.Win32.SystemEvents.dll') -contains $rel)
   $webFile=($rel -like 'Views\*' -or $rel -like 'wwwroot\css\*' -or $rel -like 'wwwroot\js\*' -or $rel -like 'wwwroot\fonts\*')
   if(-not($rootDll -or $webFile)){throw "Unexpected package entry: $rel"}
   $dest=[IO.Path]::GetFullPath((Join-Path $sitePath $rel))
   if(-not $dest.StartsWith($sitePath+'\',[StringComparison]::OrdinalIgnoreCase)){throw "Unsafe path $rel"}
   $copyList+= [PSCustomObject]@{Rel=$rel;Src=$file.FullName;Dest=$dest}
  }
  $backup=Join-Path $BackupRoot ('Backup-'+(Get-Date -Format 'yyyyMMdd-HHmmss'))
  New-Item -ItemType Directory -Path $backup -Force|Out-Null
  foreach($item in $copyList){
   if(Test-Path -LiteralPath $item.Dest){
    $target=Join-Path $backup $item.Rel
    New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force|Out-Null
    Copy-Item -LiteralPath $item.Dest -Destination $target -Force
   }
  }
  Log "Backup completed: $backup; package files=$($copyList.Count)"
  $offline=Join-Path $sitePath 'app_offline.htm'
  $siteWasRunning=$false
  $poolWasRunning=$false
  $stopped=$false
  $copied=@()
  try{
   $siteState=((& $appcmd list site "$IisSiteName" /text:state 2>$null)|Out-String).Trim()
   $poolState=((& $appcmd list apppool "$pool" /text:state 2>$null)|Out-String).Trim()
   $siteWasRunning=($siteState -eq 'Started')
   $poolWasRunning=($poolState -eq 'Started')
   Log "Stopping IIS site $IisSiteName and AppPool $pool"
   $stopped=$true
   if($siteWasRunning){& $appcmd stop site /site.name:"$IisSiteName" |Out-Null}
   if($poolWasRunning){& $appcmd stop apppool /apppool.name:"$pool" |Out-Null}
   $until=(Get-Date).AddSeconds(45)
   do{
    $status=((& $appcmd list apppool "$pool" /text:state 2>$null)|Out-String).Trim()
    if($status -eq 'Stopped'){break}
    Start-Sleep -Milliseconds 500
   }while((Get-Date) -lt $until)
   if($status -ne 'Stopped'){throw "AppPool did not stop ($status)"}
   Set-Content -LiteralPath $offline -Value '<html>Safar updating</html>' -Encoding UTF8
   foreach($item in $copyList){
    $parent=Split-Path -Parent $item.Dest
    if(-not(Test-Path -LiteralPath $parent)){New-Item -ItemType Directory -Path $parent -Force|Out-Null}
    $copied+=$item
    Copy-Item -LiteralPath $item.Src -Destination $item.Dest -Force
   }
  }catch{
   Log "Copy failed, rolling back: $($_.Exception.Message)" 'ERROR'
   foreach($item in $copied){
    $old=Join-Path $backup $item.Rel
    if(Test-Path -LiteralPath $old){Copy-Item -LiteralPath $old -Destination $item.Dest -Force}
    elseif(Test-Path -LiteralPath $item.Dest){Remove-Item -LiteralPath $item.Dest -Force}
   }
   throw
  }finally{
   if(Test-Path -LiteralPath $offline){Remove-Item -LiteralPath $offline -Force}
   if($stopped){
    if($poolWasRunning){Log "Starting AppPool $pool"; & $appcmd start apppool /apppool.name:"$pool"|Out-Null}
    if($siteWasRunning){Log "Starting IIS site $IisSiteName"; & $appcmd start site /site.name:"$IisSiteName"|Out-Null}
   }
  }
  [PSCustomObject]@{SHA256=$hash;Repository=$source;UpdatedAt=(Get-Date).ToString('o')}|ConvertTo-Json|Set-Content -LiteralPath $state -Encoding UTF8
  Log "Updated successfully. SHA256=$hash" 'SUCCESS'
 }finally{
  if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue}
 }
}
if($Watch){
 while($true){
  try{Run-Update}catch{Log $_.Exception.Message 'ERROR'}
  Start-Sleep -Seconds ($IntervalMinutes*60)
 }
}else{Run-Update}
