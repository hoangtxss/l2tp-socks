# AGENTS.md

Guidance for AI coding agents working in this repository. User-facing docs are in `README.md`.

## What this is

An L2TP/IPsec (PSK) VPN client in one Docker container. It exposes the VPN to Windows only as
a SOCKS5 proxy on `127.0.0.1:1080`, and Proxifier routes chosen hosts through it. Windows
routing stays untouched. Target platform: Windows 10/11 + Docker Desktop (WSL2) + Windows
PowerShell 5.1.

There is no build system, linter or test suite. The "build" is the Docker image; the
"tests" are manual checks with a fake server (below).

## Commands

```powershell
.\vpn.cmd setup | start | stop | status | restart | reconnect | logs | apply   # user entry point
docker compose build                                  # build the image only
docker compose logs -f vpn                            # raw logs
docker compose exec vpn ip route                      # default route must be `dev ppp0`
# Syntax-check vpn.ps1 without running it
$t = $e = $null; [void][System.Management.Automation.Language.Parser]::ParseFile("$PWD\vpn.ps1", [ref]$t, [ref]$e); $e.Count
# End-to-end proxy check (both should print HTTP 200)
curl.exe -sS -o NUL -w "HTTP %{http_code}`n" --socks5-hostname 127.0.0.1:1080 https://gitlab.company.local/users/sign_in
curl.exe -sS -o NUL -w "HTTP %{http_code}`n" https://gitlab.company.local/users/sign_in   # via Proxifier
```

`vpn.cmd` only wraps `powershell -ExecutionPolicy Bypass -File vpn.ps1`.

## Architecture (cross-file flows)

**Secrets path.** The three secrets (user, password, PSK) are never plain text on disk:
1. `vpn.ps1 setup` writes `.env` with `VPN_SERVER` and `VPN_DNS` only. It writes the secrets
   to `vpn-secrets.xml` with `Export-Clixml`, which encrypts SecureStrings with DPAPI
   (current Windows user + this PC).
2. `Up-WithSecrets` decrypts them into process env vars only for the `docker compose up` call.
   It clears them in a `finally` block before any `Fail`.
3. `docker-compose.yml` declares `secrets: { environment: VPN_* }`. Compose copies them into
   `/run/secrets/vpn_*` inside the container, where `docker inspect` can't see them.
4. `entrypoint.sh` reads `/run/secrets/*` and writes them into `swanctl.conf` (PSK base64 `0s…`)
   and the pppd options file (`name`/`password`, escaped by `pppq`).

Consequences:
- Only container creation (`up`) needs the env vars. `restart`, `ps`, `logs`, `down`, `exec`
  work without them. A raw `docker compose up` fails with `environment variable "VPN_USER"
  required by secret ... is not set`, which is expected.
- `Assert-Config` refuses to start if any `VPN_USER`/`VPN_PASSWORD`/`VPN_PSK` key appears in
  `.env`. Compose would pick it up from `.env` and leak it.

**Connection sequence** (`entrypoint.sh`):
1. charon, then `swanctl --initiate`: IKEv1, transport mode, udp/1701 only, `encap = yes`.
2. xl2tpd + pppd bring up `ppp0`.
3. Add a `/32` route to the VPN server via eth0's gateway, then replace the default route with `ppp0`.
4. Set DNS.
5. Start Dante `sockd`.
6. Poll `ppp0`. If it disappears, `exit 1`, and `restart: unless-stopped` reconnects from scratch.

There is no in-process reconnect logic.

**Log lines are an API.** `vpn.ps1` `Wait-Ready` regex-matches strings printed by
`entrypoint.sh` and strongSwan:
- `SOCKS5 ready`, `ppp0 up`, `DNS:`
- `ppp0 did not come up`, `Secret \S+ is missing`
- `initiate failed`, `AUTHENTICATION_FAILED|decryption failed|invalid HASH`, `NO_PROPOSAL_CHOSEN`

If you change any of these messages, update `Wait-Ready` and README Troubleshooting in the same change.

## Non-obvious constraints (each was hit in practice)

- **Docker Desktop kernel** (5.15 WSL2):
  - It has XFRM/ESP and PPP but no `PPPOL2TP`, so xl2tpd runs in userspace mode.
  - Docker Desktop's NAT only forwards TCP/UDP, not raw ESP, so `encap = yes` (NAT-T on UDP 4500) is required.
  - Legacy servers need `modp1024`/3DES in the proposals, which are not in strongSwan's defaults.
- **Alpine strongSwan 6:** use `swanctl` + `/usr/lib/strongswan/charon`, not `ipsec.conf`.
- **Restart safety:**
  - Delete stale pid files at start, because they survive `docker restart`.
  - `lcp-echo-*` makes a dead tunnel actually drop `ppp0`.
  - On a bad login the entrypoint sleeps 120 s before exiting, and `Wait-Ready` runs
    `docker compose down`. Both avoid locking the AD account with repeated retries.
- **DNS:** if the VPN pushes none, fall back to `1.1.1.1`/`8.8.8.8` *through the tunnel*.
  Docker's own DNS (127.0.0.11) asks Windows, and Proxifier with "Resolve hostnames through
  proxy" answers with fake `127.112.x.x` IPs. That broke every connection with SOCKS error 5.
- **Port binding:** keep the publish as `127.0.0.1:1080:1080`. The SOCKS proxy has no auth,
  and `0.0.0.0` would expose the company network to the LAN.
- **`vpn.ps1` must run on Windows PowerShell 5.1:**
  - Keep the file pure ASCII, because a BOM-less file is read as ANSI.
  - No `&&`, `??` or ternary operators.
  - Native stderr is not an error: check `$LASTEXITCODE`. `$ErrorActionPreference = 'Continue'` is deliberate.
  - Write `.env` as UTF-8 without BOM, with LF line endings. A BOM corrupts the first key.
- **`Wait-Ready --since`** uses the Docker VM clock (`docker info .SystemTime`), not Windows'.
  The WSL2 clock can drift.

## Testing without real credentials

- **Run tests that write `.env` / `vpn-secrets.xml` or recreate the container in a scratch
  copy** of the project, never in the working folder. The user keeps a live `.env`,
  `vpn-secrets.xml` and container (`l2tp-socks`, port 1080) here. Overwriting them destroys
  their settings and kills their VPN. Before testing, check whether `l2tp-socks` is running,
  because the container name and port are fixed and a test would collide with it.
- **Fake server:** use `VPN_SERVER=203.0.113.10` (TEST-NET). IKE times out and `Wait-Ready`
  reports "Cannot reach the VPN server". That proves the image builds, the configs parse and
  the script flow works.
- **`Read-Host` can't be fed from a pipe** in PS 5.1 `-File`. Mock it instead: define
  `function global:Read-Host { param($Prompt, [switch]$AsSecureString) ... }`, then call
  `& .\vpn.ps1 setup`. Global functions shadow cmdlets.
- **Leak check after `setup`/`start`:**
  - None of the plain-text values appear in `.env`, `vpn-secrets.xml` or `docker inspect l2tp-socks`.
  - `$env:VPN_PASSWORD` is empty in the calling session.
  - `/run/secrets/*` in the container byte-match the input. Use values with `' " $ \ #` and spaces.
- **Git Bash:** prefix `docker` with `MSYS_NO_PATHCONV=1`, or `/dev/ppp` gets mangled.
  For multi-line commands, pipe a script to `docker compose exec -T vpn sh` over stdin.
  PS 5.1 mangles quoted `sh -c` arguments.
- **Playwright MCP** writes `.playwright-mcp/` into the project. Delete it afterwards.
