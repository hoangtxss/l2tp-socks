# L2TP/IPsec VPN → local SOCKS5 proxy (Proxifier-style split tunnel)

English | [Tiếng Việt](README.vi.md)

Connect to the company L2TP/IPsec VPN **without** routing your whole PC through it.
The VPN runs inside a small Docker container and is exposed to Windows only as a
SOCKS5 proxy on `127.0.0.1:1080`. Proxifier then decides, per app / domain / IP / port,
what goes through the VPN and what goes direct.

![Windows apps go through Proxifier. Traffic that matches a rule goes to the Dante SOCKS5 proxy on 127.0.0.1:1080 inside the Docker container, then over ppp0 (L2TP) and strongSwan (IPsec) to the company VPN server. Everything else goes straight to the internet.](docs/network.svg)

Why this way:
- Windows routing, DNS and adapters are untouched — no "VPN hijacks all traffic".
- Turning the VPN on/off is just starting/stopping a container.
- You can run several VPNs side by side (one container + one port each).

## Files

| File | Purpose |
|---|---|
| `Dockerfile` | Alpine image with strongSwan (IPsec), xl2tpd + pppd (L2TP), Dante (SOCKS5) |
| `entrypoint.sh` | Reads settings + secrets, connects, sets routes/DNS, starts the proxy |
| `docker-compose.yml` | Runs the container, passes credentials as Docker secrets, publishes the proxy on `127.0.0.1:1080` only |
| `vpn.cmd` / `vpn.ps1` | Helper: `setup`, `start`, `stop`, `status`, `restart`, `reconnect`, `logs`, `apply` |
| `doh-apply.ps1` / `doh-rollback.ps1` | Optional: turn encrypted Windows DNS (Cloudflare DNS over HTTPS) on / off, see [Encrypted DNS](#optional-encrypted-dns-for-windows-dns-over-https) |
| `.env` | Created by `setup`: server IP + optional DNS. **No secrets.** |
| `vpn-secrets.xml` | Created by `setup`: username, password, PSK **encrypted** (see [Credentials & security](#credentials--security)) |
| `.env.example` | Shows what `.env` contains |
| `.github/workflows/gitleaks.yml` | Scans every push and pull request for committed secrets ([gitleaks](https://github.com/gitleaks/gitleaks)) |

`.env` and `vpn-secrets.xml` are personal and ignored by `.gitignore`. Don't share them.

## Prerequisites

- Windows 10/11 with **Docker Desktop** (WSL2 backend) — running.
  Tip: Docker Desktop → Settings → General → *Start Docker Desktop when you sign in*.
  Needs a recent Docker Compose (tested with Compose 5.6.0; check with `docker compose version`).
- **Proxifier** (Windows).
- From DevOps: **VPN server IP**, **pre-shared key (PSK)**, **username**, **password**.

## Quick setup (recommended)

1. **Get the folder** onto your PC (e.g. `D:\vpn`) and open PowerShell or CMD there.
2. **Run setup** and answer the questions (password and PSK input is hidden):
   ```powershell
   .\vpn.cmd setup
   ```
   It checks Docker (starts Docker Desktop if needed), saves your settings (credentials
   encrypted), builds the image, connects, and waits until the VPN is up:
   ```
   VPN server IP: 203.0.113.10
   Username: your.name
   Password: ********
   Pre-shared key (PSK): ********
   Internal DNS servers, comma separated (optional, Enter to skip):
   [OK]   Settings saved (.env) and credentials encrypted (vpn-secrets.xml)
   [..]   Connecting.........
   [..]   ppp0 up: 10.x.x.x/32
   [..]   DNS: 10.x.x.x
   [OK]   VPN connected. Proxy: SOCKS5 127.0.0.1:1080
   ```
   - Wrong username/password or PSK → it **stops automatically** (to avoid locking your account)
     and tells you what was wrong. Fix it by running `.\vpn.cmd setup` again
     (press Enter to keep values that were right).
   - "Cannot reach the VPN server" → check the server IP / your network.
3. **Configure Proxifier** (see [Proxifier configuration](#proxifier-configuration)).

Done. The VPN keeps running in the background, reconnects if it drops, and starts again
whenever Docker Desktop starts.

`vpn.cmd` runs `vpn.ps1` without changing the PowerShell execution policy. If your policy
already allows scripts, `.\vpn.ps1 <command>` works the same.

Always enter credentials through `setup`. Never put them in `.env`, and never type them
as PowerShell commands (`$env:VPN_PASSWORD=...`): PowerShell saves typed commands in a
plain-text history file. The script refuses to start if it finds credentials in `.env`.

## Proxifier configuration

1. **Profile → Proxy Servers → Add**
   - Address `127.0.0.1`, Port `1080`, Protocol **SOCKS Version 5**, no authentication.
   - Click *Check* to test.
2. **Profile → Name Resolution**
   - Enable **Resolve hostnames through proxy**.
     Without this, internal names (`*.company.local`) are resolved by Windows and fail.
3. **Profile → Proxification Rules** (top-down, first match wins):

   | Order | Name | Applications | Target hosts / ports | Action |
   |---|---|---|---|---|
   | 1 | VPN server bypass | Any | `<VPN_SERVER IP>` | **Direct** |
   | 2 | Docker bypass | `com.docker.*.exe; vpnkit.exe; wsl*.exe; Docker Desktop.exe` | Any | **Direct** |
   | 3 | Company | Any | e.g. `*.company.local; 10.99.*.*` or port `1433` | **Proxy SOCKS5 127.0.0.1** |
   | last | Default | Any | Any | **Direct** |

   Rules 1–2 stop the tunnel from being looped through itself if you add a broad rule later.
   Ask DevOps for the internal domains / IP ranges you need.
   Example: target `gitlab.company.local`, port Any → **VPN** (`127.0.0.1:1080`).
4. **Browser settings** (Chrome / Edge). Without these, the browser can skip Proxifier:
   - **Disable QUIC (HTTP/3):** open `chrome://flags/#enable-quic` (Edge: `edge://flags/#enable-quic`)
     → **Disabled** → restart. QUIC uses UDP, which Proxifier doesn't send through the proxy,
     so sites behind Cloudflare would go direct.
   - **Turn off Secure DNS:** Settings → Privacy and security → Security → *Use secure DNS* → Off.
     With it on, Proxifier never sees the hostname, so domain rules don't match.
   - After changing anything, **quit the browser completely** (also from the tray icon),
     or clear its cache: `chrome://net-internals/#dns` → *Clear host cache*, then
     `chrome://net-internals/#sockets` → *Flush socket pools*.

   Security note: disabling QUIC costs nothing (the browser falls back to HTTP/2 over TLS).
   Turning off Secure DNS sends DNS lookups for non-VPN sites unencrypted, so your ISP or a
   public Wi-Fi operator can see which domains you visit. Company names still resolve inside
   the tunnel. To fix this, encrypt Windows DNS (see [Encrypted DNS](#optional-encrypted-dns-for-windows-dns-over-https)),
   or use these settings only in a separate browser kept for company sites.

## Optional: encrypted DNS for Windows (DNS over HTTPS)

With Secure DNS off, the browser asks Windows to look up names, and by default Windows sends
those lookups unencrypted to your router / ISP. `doh-apply.ps1` makes Windows send them
encrypted to Cloudflare (`1.1.1.1`, `1.0.0.1`) instead. The VPN and Proxifier rules keep
working: Proxifier still sees every hostname, and company names still resolve inside the tunnel.

Needs Windows 11. Each script asks for admin rights (UAC prompt).

```powershell
# Turn on (uses the adapter you're online with; or add -Adapter "Wi-Fi")
powershell -ExecutionPolicy Bypass -File .\doh-apply.ps1
# Turn off: puts back the DNS servers you had before
powershell -ExecutionPolicy Bypass -File .\doh-rollback.ps1
```

`doh-apply.ps1`:
1. Saves your current DNS settings to `doh-logs\backup.xml` (rollback uses it).
2. Sets the adapter's DNS to `1.1.1.1`, `1.0.0.1` with DNS over HTTPS and **no fallback to plain DNS**.
3. Proves it: records DNS traffic (port 53) while looking up a random name, and prints
   `PASS` if the name resolved and never left the PC unencrypted. A control lookup sent as
   plain DNS on purpose must show up in the recording, so a `PASS` can't come from a broken capture.

Afterwards re-run the [`curl` tests](#daily-operations-runbook); they should still print `HTTP 200`.

Settings → Network → your adapter still lists the servers as *Unencrypted*. That's expected:
the script turns DoH on system-wide for Cloudflare's addresses (`Get-DnsClientDohServerAddress`
shows `AutoUpgrade True`), and that page only shows the per-adapter setting. The script's
`PASS` check is the proof that lookups are encrypted.

Good to know:
- **Other VPN clients** that change Windows DNS (FortiClient, Cisco, …): run both scripts while
  that VPN is **disconnected**. Those clients save the DNS list when they connect and put it back
  when they disconnect, so a change made while connected is lost. Applied while disconnected,
  it survives later connects and disconnects (tested with FortiClient).
- **Hotel / café Wi-Fi login pages** may not appear, because there is no plain-DNS fallback.
  Run `doh-rollback.ps1`, log in, then run `doh-apply.ps1` again.
- **Per adapter**: Wi-Fi and Ethernet are separate. Run with `-Adapter "<name>"` for the other one.
- **Privacy trade-off**: Cloudflare, instead of your ISP, now sees the names you look up.
- Logs, the backup and the recording go to `doh-logs\`, which git ignores.

## Daily operations (runbook)

Run these in the project folder. `start`, `restart`, `reconnect`, `apply` and `setup` wait
until the VPN is connected and report the result (they stop the VPN if your login is wrong).

| Task | Script | Plain Docker equivalent |
|---|---|---|
| First-time setup / change settings or credentials | `.\vpn.cmd setup` | script only |
| Start VPN | `.\vpn.cmd start` | script only (it decrypts the credentials) |
| Stop VPN | `.\vpn.cmd stop` | `docker compose down` |
| Status (container, VPN IP, proxy) | `.\vpn.cmd status` | `docker compose ps` (should be `Up`, not `Restarting`) |
| Quick restart | `.\vpn.cmd restart` | `docker compose restart` (when it's running) |
| Full reconnect (fresh container) | `.\vpn.cmd reconnect` | script only |
| Live logs (Ctrl-C to exit) | `.\vpn.cmd logs` | `docker compose logs -f` |
| Apply `.env` edits / updated files | `.\vpn.cmd apply` | script only |
| Show help | `.\vpn.cmd` | |
| Routes inside container | | `docker compose exec vpn ip route` (default should be `dev ppp0`) |

Which one when?
- Internal sites stop working → `restart`; still broken → `reconnect`; still broken → `logs`.
- Changed password / PSK / username → `setup` (press Enter to keep the values that didn't change).
- Changed server IP or DNS → `setup`, or edit `.env` + `apply`.
- Pulled a newer version of these files → `apply`.

**Test the proxy from Windows:**
```powershell
# Straight to the proxy (skips Proxifier rules)
curl.exe -sS -o NUL -w "HTTP %{http_code}`n" --socks5-hostname 127.0.0.1:1080 https://gitlab.company.local/users/sign_in
# Through Proxifier, the same way the browser goes (needs the rule for that host)
curl.exe -sS -o NUL -w "HTTP %{http_code}`n" https://gitlab.company.local/users/sign_in
# Exit IP through the VPN (should differ from your normal public IP)
curl.exe -s --socks5-hostname 127.0.0.1:1080 https://api.ipify.org
```
Both page tests print `HTTP 200` → VPN, proxy and Proxifier are fine; if the browser still fails,
see the browser row in Troubleshooting.

## Troubleshooting

| Symptom (log line / behaviour) | Likely cause → fix |
|---|---|
| `initiate failed: CHILD_SA 'l2tp' not established` with only `sending retransmit` lines | Server unreachable: wrong `VPN_SERVER`, or UDP 500/4500 blocked by your network. Try another network / ask DevOps. |
| `AUTHENTICATION_FAILED`, `decryption failed` or `invalid HASH` | Wrong **PSK**. Re-run `.\vpn.cmd setup`. |
| `NO_PROPOSAL_CHOSEN` | Server uses ciphers not in our list. Send the log to whoever maintains this repo (proposals are in `entrypoint.sh`). |
| `ppp0 did not come up (check user/password)` | Wrong username/password, or account locked (the log then shows `PAP/CHAP authentication failed`). The script stops the VPN for you; fix with `.\vpn.cmd setup`. |
| `Couldn't set tty to PPP discipline: Operation not permitted` | The Docker kernel's `ppp_async` module is not loaded and the container may not load it. Not a login problem. Make sure `docker-compose.yml` has `cap_add: [NET_ADMIN, SYS_MODULE]`, then `.\vpn.cmd apply`. |
| Container keeps `Restarting` | `.\vpn.cmd logs` and match a line above. |
| Proxy works for IPs but not hostnames | Enable *Resolve hostnames through proxy* in Proxifier; if still failing, set `VPN_DNS` in `.env`. |
| `cannot complete SOCKS5 connection ... (5)` / container resolves names to `127.112.x.x` | The container used Windows DNS, which Proxifier answers with fake IPs. Fixed in `entrypoint.sh`: if the VPN sends no DNS, it uses 1.1.1.1 / 8.8.8.8 through the tunnel. Run `.\vpn.cmd apply` after updating. |
| `curl` tests return `HTTP 200` but the browser can't open the site | Browser-side: disable QUIC, turn off Secure DNS, then quit the browser completely or clear its cache (see [Proxifier configuration](#proxifier-configuration) step 4). Try a private window. Proxifier's window should show the site's connections going through **VPN**. |
| Internal-only names (e.g. `*.company.local`) don't resolve | The VPN sends no DNS servers, so public DNS is used. Ask DevOps for the internal DNS IPs, put them in `VPN_DNS` (via `.\vpn.cmd setup`), then `.\vpn.cmd apply`. |
| Small requests work, HTTPS/large transfers hang | MTU issue. In `entrypoint.sh` change `mtu 1280` / `mru 1280` to `1200`, then `.\vpn.cmd apply`. |
| `port is already allocated` / 1080 in use | Change the port in `docker-compose.yml` to `"127.0.0.1:1081:1080"` and use 1081 in Proxifier. |
| Internal IPs are in `172.16.0.0`–`172.31.255.255` and don't work | Clash with Docker's network. Add a custom subnet to `docker-compose.yml` (e.g. `192.168.250.0/24`). |
| Nothing works after reboot | Docker Desktop not running — `.\vpn.cmd start` (starts Docker Desktop for you). |
| `docker: command not found` / engine errors | Start Docker Desktop and wait until it says *Engine running*. |
| `Cannot decrypt vpn-secrets.xml` | File came from another PC or Windows user (by design it only works for the account that created it). Run `.\vpn.cmd setup`. |
| `No saved credentials` | Run `.\vpn.cmd setup`. |
| `VPN_PASSWORD found in .env in plain text` (or USER / PSK) | Delete that line from `.env`, then run `.\vpn.cmd setup`. |
| `Secret vpn_psk is missing or empty` | Run `.\vpn.cmd setup`. |
| `environment variable "VPN_USER" required by secret ... is not set` | You ran `docker compose up` directly. Use `.\vpn.cmd start` instead. |
| No websites resolve after `doh-apply.ps1` (or a Wi-Fi login page won't open) | Cloudflare is blocked or the network needs a login first. Run `doh-rollback.ps1`. |

Logs never print your password or PSK; it is safe to share them with the team.

## Running a second VPN side by side

Copy the folder, then in the copy:
1. In `docker-compose.yml` change `container_name` (e.g. `l2tp-socks-2`) and the port (`"127.0.0.1:1081:1080"`).
2. Delete any `.env` / `vpn-secrets.xml` copied over, then run `.\vpn.cmd setup` in that folder.
3. In Proxifier add proxy `127.0.0.1:1081` and rules pointing to it.

## Credentials & security

How the username, password and PSK are handled:

| Where | Form |
|---|---|
| `vpn-secrets.xml` | Encrypted with **Windows DPAPI**. Only **your Windows account on this PC** can decrypt it. Copied to another PC or opened by another user, it's useless. |
| `.env` | Server IP and DNS only. No secrets. |
| PowerShell / CMD session | Decrypted only for the few seconds `docker compose up` runs, then cleared (also on errors). |
| Docker container | Passed as Docker secrets (files in `/run/secrets`). Not visible in `docker inspect` or the container's environment. |
| Logs | Never printed. Logs are safe to share. |

What this protects against: other Windows users on the PC, someone who gets a copy of the
folder (shared drive, zip, USB), and accidental commits to git.

What it does **not** protect against:
- An **administrator of the PC** or **malware running as you**. Anything that runs as your
  account can decrypt DPAPI data, the same way Windows does for your browser's saved passwords.
- **Docker access while the container exists.** The container holds a copy of the secrets so it
  can reconnect by itself. Anyone who can run `docker` commands on this PC (normally only you and
  admins) could read them with `docker exec`. `.\vpn.cmd stop` deletes the container and that copy.

Also keep in mind:
- The proxy has **no password**, so it listens on `127.0.0.1` only. Don't change it to `0.0.0.0`:
  that would open the company network to your whole LAN.
- To remove all stored credentials: `.\vpn.cmd stop`, then delete `vpn-secrets.xml`.

## Limitations

- **TCP only** through SOCKS. `ping`, most UDP, and apps that ignore proxies won't use the VPN.
- Only for VPNs using L2TP/IPsec with a pre-shared key + username/password.
  Check with DevOps/IT that using a non-official client is allowed by company policy.
