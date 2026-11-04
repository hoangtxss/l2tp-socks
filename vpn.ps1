<#
  L2TP/IPsec VPN -> local SOCKS5 proxy helper.
  Usage: .\vpn.cmd <command>   (or .\vpn.ps1 <command>)

  setup      First-time setup / change settings: check Docker, ask for VPN details, save, build, connect
  start      Start the VPN (if not already running)
  stop       Stop the VPN and remove the container
  status     Show container state, VPN IP and proxy port
  restart    Restart the container (quick)
  reconnect  Recreate the container from scratch (use when restart doesn't help)
  logs       Follow logs (Ctrl-C to exit)
  apply      Apply .env / file changes: rebuild + recreate + reconnect

  Username, password and PSK are stored encrypted in vpn-secrets.xml (Windows DPAPI:
  only your Windows account on this PC can decrypt them). .env holds no secrets.
#>
param(
  [Parameter(Position = 0)]
  [ValidateSet('setup', 'start', 'stop', 'status', 'restart', 'reconnect', 'logs', 'apply', 'help')]
  [string]$Command = 'help'
)
$ErrorActionPreference = 'Continue'   # native tools write progress to stderr; we check $LASTEXITCODE instead
$EnvFile = Join-Path $PSScriptRoot '.env'
$SecretFile = Join-Path $PSScriptRoot 'vpn-secrets.xml'
$SecretKeys = 'VPN_USER', 'VPN_PASSWORD', 'VPN_PSK'

function Ok($m)   { Write-Host "[OK]   $m" -ForegroundColor Green }
function Info($m) { Write-Host "[..]   $m" -ForegroundColor Cyan }
function Warn($m) { Write-Host "[WARN] $m" -ForegroundColor Yellow }
function Fail($m) { Write-Host "[FAIL] $m" -ForegroundColor Red; Pop-Location; exit 1 }

function Compose {
  & docker compose @args
  if ($LASTEXITCODE -ne 0) { Fail "docker compose $args failed (see output above)" }
}

function Ensure-Docker {
  if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Fail 'Docker not found. Install Docker Desktop: https://www.docker.com/products/docker-desktop/'
  }
  docker info *> $null
  if ($LASTEXITCODE -eq 0) { return }
  $exe = Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'
  if (Test-Path $exe) { Info 'Starting Docker Desktop...'; Start-Process $exe }
  for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep 3
    docker info *> $null
    if ($LASTEXITCODE -eq 0) { Ok 'Docker engine running'; return }
  }
  Fail 'Docker engine is not running. Start Docker Desktop, wait for "Engine running", then retry.'
}

# --- settings: .env (non-secret) + vpn-secrets.xml (DPAPI-encrypted) --------
function Read-EnvFile {
  $vals = @{}
  if (-not (Test-Path $EnvFile)) { return $vals }
  foreach ($line in Get-Content $EnvFile) {
    if ($line -match '^\s*([A-Z0-9_]+)\s*=\s*[''"]?(.*?)[''"]?\s*$') { $vals[$Matches[1]] = $Matches[2] }
  }
  return $vals
}

function Is-IPv4([string]$s) {
  $ip = $null
  return [Net.IPAddress]::TryParse($s, [ref]$ip) -and $ip.AddressFamily -eq 'InterNetwork'
}

# Returns @{ VPN_USER; VPN_PASSWORD; VPN_PSK } as SecureStrings, or $null
function Read-Secrets([switch]$Quiet) {
  if (-not (Test-Path $SecretFile)) {
    if ($Quiet) { return $null }
    Fail 'No saved credentials (vpn-secrets.xml). Run: .\vpn.cmd setup'
  }
  try { return Import-Clixml $SecretFile -ErrorAction Stop }
  catch {
    if ($Quiet) { return $null }
    Fail 'Cannot decrypt vpn-secrets.xml (saved by another Windows user or PC). Run: .\vpn.cmd setup'
  }
}

function Plain([Security.SecureString]$s) {
  return (New-Object System.Management.Automation.PSCredential 'x', $s).GetNetworkCredential().Password
}

function Assert-Config {
  if (-not (Test-Path $EnvFile)) { Fail '.env not found. Run: .\vpn.cmd setup' }
  $vals = Read-EnvFile
  foreach ($k in $SecretKeys) {
    if ($vals.ContainsKey($k)) { Fail "$k found in .env in plain text. Delete that line and run: .\vpn.cmd setup" }
  }
  if (-not (Is-IPv4 $vals['VPN_SERVER'])) { Fail "VPN_SERVER in .env must be an IPv4 address (got '$($vals['VPN_SERVER'])'). Run: .\vpn.cmd setup" }
  $null = Read-Secrets
}

function Ask([string]$Prompt, [string]$Current) {
  $hint = ''; if ($Current) { $hint = " [$Current]" }
  $v = Read-Host "$Prompt$hint"
  if (-not $v) { $v = $Current }
  return $v
}

# Hidden input; Enter keeps the current value
function Ask-Secret([string]$Prompt, $Current) {
  $hint = ''; if ($Current -and $Current.Length) { $hint = ' [Enter = keep current]' }
  $s = Read-Host "$Prompt$hint" -AsSecureString
  if ($s.Length -eq 0) { return $Current }
  return $s
}

function Write-Settings {
  $cur = Read-EnvFile
  $sec = Read-Secrets -Quiet
  if (-not $sec) { $sec = @{} }
  $curUser = ''; if ($sec['VPN_USER']) { $curUser = Plain $sec['VPN_USER'] }
  Write-Host ''
  Write-Host 'Enter the VPN details from DevOps (password and PSK input is hidden).'
  while ($true) {
    $server = Ask 'VPN server IP' $cur['VPN_SERVER']
    if (Is-IPv4 $server) { break }
    Warn 'Please enter an IPv4 address, e.g. 203.0.113.10'
  }
  $user = Ask 'Username' $curUser
  $pass = Ask-Secret 'Password' $sec['VPN_PASSWORD']
  $psk  = Ask-Secret 'Pre-shared key (PSK)' $sec['VPN_PSK']
  $dns  = Ask 'Internal DNS servers, comma separated (optional, Enter to skip)' $cur['VPN_DNS']
  if (-not $user) { Fail 'Username cannot be empty' }
  if (-not $pass -or $pass.Length -eq 0) { Fail 'Password cannot be empty' }
  if (-not $psk -or $psk.Length -eq 0) { Fail 'PSK cannot be empty' }

  # Export-Clixml encrypts SecureStrings with DPAPI (current Windows user + this PC)
  @{
    VPN_USER     = ConvertTo-SecureString $user -AsPlainText -Force
    VPN_PASSWORD = $pass
    VPN_PSK      = $psk
  } | Export-Clixml $SecretFile
  # .env: non-secret settings only (overwrites any old file that had secrets in it)
  $text = "# Created by vpn.ps1 setup. No secrets here (see vpn-secrets.xml).`nVPN_SERVER=$server`nVPN_DNS=$dns`n"
  [IO.File]::WriteAllText($EnvFile, $text, (New-Object Text.UTF8Encoding $false))
  Ok 'Settings saved (.env) and credentials encrypted (vpn-secrets.xml)'
}

# Create/recreate the container. Secrets live in this process's env only for the
# duration of `docker compose up`, then are cleared even if it fails.
function Up-WithSecrets([string[]]$Extra = @()) {
  $sec = Read-Secrets
  try {
    foreach ($k in $SecretKeys) { Set-Item "Env:$k" (Plain $sec[$k]) }
    & docker compose up -d @Extra
    $code = $LASTEXITCODE
  } finally {
    foreach ($k in $SecretKeys) { Remove-Item "Env:$k" -ErrorAction SilentlyContinue }
  }
  if ($code -ne 0) { Fail 'docker compose up failed (see output above)' }
}

# --- connection helpers ----------------------------------------------------
# Use the Docker VM clock, not Windows', so --since never misses lines
function Now-Docker { (docker info --format '{{.SystemTime}}' 2>$null | Select-Object -First 1) }

function Proxy-Addr {
  $p = docker compose port vpn 1080 2>$null | Select-Object -First 1
  if ($p) { return $p } else { return '127.0.0.1:1080' }
}

function Is-Running { [bool](docker compose ps --status running -q vpn 2>$null) }

function Wait-Ready([string]$Since) {
  Write-Host '[..]   Connecting' -NoNewline -ForegroundColor Cyan
  for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep 2
    Write-Host '.' -NoNewline -ForegroundColor Cyan
    $log = (docker compose logs --no-color --since $Since vpn 2>$null) -join "`n"
    if ($log -match 'SOCKS5 ready') {
      Write-Host ''
      ($log -split "`n") | Where-Object { $_ -match 'ppp0 up|DNS:' } | ForEach-Object { Info ($_ -replace '^.*?\|\s*', '') }
      Ok "VPN connected. Proxy: SOCKS5 $(Proxy-Addr)"
      return
    }
    # On a bad login, remove the container (and its copy of the secrets) so it can't retry and lock the account
    if ($log -match 'ppp0 did not come up') {
      Write-Host ''; docker compose down *> $null
      Fail 'Login failed (username/password). Stopped to avoid locking your account. Fix: .\vpn.cmd setup'
    }
    if ($log -match 'AUTHENTICATION_FAILED|decryption failed|invalid HASH') {
      Write-Host ''; docker compose down *> $null
      Fail 'Pre-shared key (PSK) looks wrong. Stopped. Fix: .\vpn.cmd setup'
    }
    if ($log -match 'NO_PROPOSAL_CHOSEN') {
      Write-Host ''; docker compose down *> $null
      Fail 'VPN server rejected our ciphers. Stopped. Send ".\vpn.cmd logs" output to the maintainer.'
    }
    if ($log -match 'Secret \S+ is missing') {
      Write-Host ''; docker compose down *> $null
      Fail 'Credentials missing in the container. Run: .\vpn.cmd setup'
    }
    if ($log -match 'initiate failed') {
      Write-Host ''
      Warn 'Cannot reach the VPN server (IPsec timeout). Check VPN_SERVER and your network (UDP 500/4500).'
      Warn 'Docker keeps retrying in the background. Watch: .\vpn.cmd logs   Stop: .\vpn.cmd stop'
      return
    }
  }
  Write-Host ''
  Warn 'Not connected after 2 minutes. Check: .\vpn.cmd logs'
}

function Show-ProxifierHint {
  $server = (Read-EnvFile)['VPN_SERVER']
  $addr = (Proxy-Addr) -split ':'
  Write-Host ''
  Write-Host 'Next: configure Proxifier (details in README.md):' -ForegroundColor White
  Write-Host "  1. Profile > Proxy Servers > Add: $($addr[0])  port $($addr[1])  SOCKS Version 5"
  Write-Host '  2. Profile > Name Resolution: enable "Resolve hostnames through proxy"'
  Write-Host "  3. Rules (top-down): $server -> Direct | company hosts/IPs -> proxy | Default -> Direct"
}

# --- commands --------------------------------------------------------------
Push-Location $PSScriptRoot
switch ($Command) {
  'setup' {
    Ensure-Docker
    $haveAll = (Test-Path $EnvFile) -and (Read-Secrets -Quiet)
    if ($haveAll) {
      $a = Read-Host 'Settings already exist. Change them? (y/N)'
      if ($a -match '^[yY]') { Write-Settings }
    } else {
      Write-Settings
    }
    Assert-Config
    Info 'Building image and starting the VPN (first build takes ~1 min)...'
    $since = Now-Docker
    Up-WithSecrets @('--build', '--force-recreate')
    Wait-Ready $since
    Show-ProxifierHint
  }
  'start' {
    Ensure-Docker; Assert-Config
    if (Is-Running) { Ok "Already running. Proxy: SOCKS5 $(Proxy-Addr)  (use 'status' or 'reconnect')"; break }
    $since = Now-Docker
    Up-WithSecrets
    Wait-Ready $since
  }
  'stop' {
    Ensure-Docker
    Compose down
    Ok 'VPN stopped'
  }
  'status' {
    Ensure-Docker
    docker compose ps -a vpn
    if (Is-Running) {
      $vpnIp = docker compose exec -T vpn sh -c "ip -4 addr show ppp0 2>/dev/null | awk '/inet/{print `$2}'" 2>$null
      if ($vpnIp) { Ok "Tunnel up, VPN IP $vpnIp. Proxy: SOCKS5 $(Proxy-Addr)" }
      else { Warn 'Container running but tunnel not up yet (see: .\vpn.cmd logs)' }
    } else {
      Warn 'VPN is not running. Start: .\vpn.cmd start'
    }
  }
  'restart' {
    Ensure-Docker; Assert-Config
    $since = Now-Docker
    if (Is-Running) { Compose restart } else { Up-WithSecrets }
    Wait-Ready $since
  }
  'reconnect' {
    Ensure-Docker; Assert-Config
    $since = Now-Docker
    Compose down
    Up-WithSecrets
    Wait-Ready $since
  }
  'logs' {
    Ensure-Docker
    docker compose logs -f --tail 100 vpn
  }
  'apply' {
    Ensure-Docker; Assert-Config
    Info 'Applying .env and file changes (rebuild + recreate)...'
    $since = Now-Docker
    Up-WithSecrets @('--build', '--force-recreate')
    Wait-Ready $since
  }
  default {
    if ((Get-Content $PSCommandPath -Raw) -match '(?s)<#\s*(.*?)\s*#>') { Write-Host $Matches[1] }
  }
}
Pop-Location
