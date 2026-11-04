# Undo doh-apply.ps1: put back the adapter's previous DNS servers and Cloudflare DoH settings.
# Without a backup it resets DNS to automatic (from the router). Asks for admin rights (UAC).
# Windows PowerShell 5.1: keep this file pure ASCII.
param([string]$Adapter)

$ErrorActionPreference = 'Stop'
$LogDir = Join-Path $PSScriptRoot 'doh-logs'
$LogFile = Join-Path $LogDir 'doh-rollback.log'
$Backup = Join-Path $LogDir 'backup.xml'
$Servers = '1.1.1.1', '1.0.0.1'

$saved = $null
if (Test-Path $Backup) { $saved = Import-Clixml $Backup }
if (-not $Adapter -and $saved) { $Adapter = $saved.Adapter }
if (-not $Adapter) {
  $route = Get-NetRoute -DestinationPrefix 0.0.0.0/0 -ErrorAction SilentlyContinue |
    Sort-Object { $_.RouteMetric + (Get-NetIPInterface -InterfaceIndex $_.ifIndex -AddressFamily IPv4).InterfaceMetric } |
    Select-Object -First 1
  if (-not $route) { Write-Host 'No network connection found. Pass -Adapter "<name>".'; exit 1 }
  $Adapter = (Get-NetAdapter -InterfaceIndex $route.ifIndex).Name
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
  [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
  Write-Host "Asking for admin rights (UAC) to change DNS on '$Adapter'..."
  try {
    $p = Start-Process powershell.exe -Verb RunAs -Wait -PassThru -ArgumentList @(
      '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-Adapter', "`"$Adapter`"")
  } catch { Write-Host 'Cancelled: admin rights are required.'; exit 1 }
  if (Test-Path $LogFile) { Get-Content $LogFile }
  exit $p.ExitCode
}

New-Item -ItemType Directory -Force $LogDir | Out-Null
[IO.File]::WriteAllText($LogFile, '')
function Say([string]$m) { Write-Host $m; Add-Content -Path $LogFile -Value $m }

try {
  if ($saved -and $saved.NameServer) {
    Set-DnsClientServerAddress -InterfaceAlias $Adapter -ServerAddresses ($saved.NameServer -split '[, ]+' | Where-Object { $_ })
    Say "Restored DNS servers on '$Adapter': $($saved.NameServer)"
  } else {
    Set-DnsClientServerAddress -InterfaceAlias $Adapter -ResetServerAddresses
    Say "DNS on '$Adapter' reset to automatic (from the router)."
  }

  foreach ($s in $Servers) {
    $old = $null
    if ($saved) { $old = $saved.Doh | Where-Object { $_.ServerAddress -eq $s } }
    if ($old) { Set-DnsClientDohServerAddress -ServerAddress $s -AutoUpgrade $old.AutoUpgrade -AllowFallbackToUdp $old.AllowFallbackToUdp }
    else { Set-DnsClientDohServerAddress -ServerAddress $s -AutoUpgrade $false -AllowFallbackToUdp $false }
  }
  Clear-DnsClientCache
  if (Test-Path $Backup) { Remove-Item $Backup }

  $now = (Get-DnsClientServerAddress -InterfaceAlias $Adapter -AddressFamily IPv4).ServerAddresses -join ', '
  Say "DNS over HTTPS is off. '$Adapter' now uses: $now"
} catch {
  Say "ERROR: $($_.Exception.Message)"
  exit 1
}
