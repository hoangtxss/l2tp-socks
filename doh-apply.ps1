# Optional: turn on DNS over HTTPS (Cloudflare 1.1.1.1 / 1.0.0.1) for one network adapter,
# then prove it with a packet capture. Asks for admin rights (UAC). Undo with doh-rollback.ps1.
# Windows PowerShell 5.1: keep this file pure ASCII.
param([string]$Adapter)

$ErrorActionPreference = 'Stop'
$LogDir = Join-Path $PSScriptRoot 'doh-logs'
$LogFile = Join-Path $LogDir 'doh-apply.log'
$Backup = Join-Path $LogDir 'backup.xml'
$Servers = '1.1.1.1', '1.0.0.1'

if (-not (Get-Command Set-DnsClientDohServerAddress -ErrorAction SilentlyContinue)) {
  Write-Host 'DNS over HTTPS needs Windows 11 (or Windows Server 2022).'; exit 1
}

if (-not $Adapter) {
  # The adapter you are online with: lowest-metric default route
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
  $nic = Get-NetAdapter -Name $Adapter
  $key = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$($nic.InterfaceGuid)"
  $static = (Get-ItemProperty $key).NameServer   # DNS servers set by hand; empty = from the router (DHCP)

  # Backup for doh-rollback.ps1. Skip when already applied, so a re-run doesn't save our own settings.
  if ((Test-Path $Backup) -or $static -eq ($Servers -join ',')) {
    Say 'Previous settings already saved (or DoH already on); not overwriting the backup.'
  } else {
    @{
      Adapter    = $Adapter
      NameServer = $static
      Doh        = @(Get-DnsClientDohServerAddress | Where-Object { $Servers -contains $_.ServerAddress } |
                     Select-Object ServerAddress, AutoUpgrade, AllowFallbackToUdp)
    } | Export-Clixml $Backup
    Say "Saved previous settings to $Backup"
    if ($static) {
      Say "WARNING: '$Adapter' had DNS servers set by hand or by another VPN client ($static)."
      Say '         If a VPN client such as FortiClient is connected, disconnect it, run doh-rollback.ps1, then run this again.'
    }
  }

  # Use DoH whenever these servers are used, and never fall back to plain DNS
  foreach ($s in $Servers) { Set-DnsClientDohServerAddress -ServerAddress $s -AutoUpgrade $true -AllowFallbackToUdp $false }
  Set-DnsClientServerAddress -InterfaceAlias $Adapter -ServerAddresses $Servers
  Clear-DnsClientCache
  Say "DNS on '$Adapter' is now $($Servers -join ', ') with DNS over HTTPS (no plain-DNS fallback)."

  $v6 = (Get-DnsClientServerAddress -InterfaceAlias $Adapter -AddressFamily IPv6).ServerAddresses |
    Where-Object { $_ -notlike 'fec0:*' }
  if ($v6) { Say "WARNING: '$Adapter' also has IPv6 DNS servers ($($v6 -join ', ')); lookups sent there are not encrypted." }

  # Verify: record port-53 traffic while resolving a unique name. It must not show up in plain text.
  # The control lookup is sent as plain DNS on purpose and must show up, proving the capture works.
  $label = 'dohcheck' + (Get-Random -Minimum 100000 -Maximum 999999)
  $etl = Join-Path $LogDir 'dns.etl'
  $pcap = Join-Path $LogDir 'dns.pcapng'
  pktmon filter remove | Out-Null
  pktmon filter add DohCheck -p 53 | Out-Null
  pktmon start --capture --pkt-size 0 --file-name $etl | Out-Null
  Start-Sleep 1
  Resolve-DnsName "$label.example.com" -Type A -ErrorAction SilentlyContinue | Out-Null
  Resolve-DnsName "control$label.example.com" -Server 8.8.8.8 -DnsOnly -ErrorAction SilentlyContinue | Out-Null
  $ok = Resolve-DnsName 'github.com' -Type A -ErrorAction SilentlyContinue | Where-Object IPAddress | Select-Object -First 1
  Start-Sleep 1
  pktmon stop | Out-Null
  pktmon filter remove | Out-Null
  pktmon etl2pcap $etl --out $pcap | Out-Null
  $text = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($pcap))
  $leaks = [regex]::Matches($text, "(?<!control)$label").Count
  $control = [regex]::Matches($text, "control$label").Count

  if (-not $ok) { Say 'FAIL: names do not resolve. Run doh-rollback.ps1 to undo.'; exit 1 }
  if ($leaks -gt 0) { Say 'FAIL: lookups still leave as plain DNS. Run doh-rollback.ps1 to undo.'; exit 1 }
  if ($control -eq 0) {
    Say 'UNSURE: names resolve, but the capture saw no DNS traffic at all, so it proves nothing.'
    Say '        Run this script again to repeat the check.'
    exit 0
  }
  Say "PASS: names resolve (github.com -> $($ok.IPAddress)) and the test lookup never left as plain DNS."
} catch {
  Say "ERROR: $($_.Exception.Message)"
  exit 1
}
