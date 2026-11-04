#!/bin/sh
# L2TP/IPsec (PSK) client -> SOCKS5 proxy on :1080. Container exits if the tunnel drops; compose restarts it.
set -eu

# Strip CR in case .env was saved with Windows line endings
strip() { printf '%s' "$1" | tr -d '\r'; }
VPN_SERVER=$(strip "${VPN_SERVER:?VPN_SERVER missing in .env - run: vpn.cmd setup}")
VPN_DNS=$(strip "${VPN_DNS:-}")

# Credentials arrive as Docker secrets (files), never as env vars
for s in vpn_user vpn_password vpn_psk; do
  [ -s "/run/secrets/$s" ] || { echo "Secret $s is missing or empty - run: vpn.cmd setup"; exit 1; }
done
VPN_USER=$(tr -d '\r' < /run/secrets/vpn_user)
VPN_PASSWORD=$(tr -d '\r' < /run/secrets/vpn_password)
VPN_PSK=$(tr -d '\r' < /run/secrets/vpn_psk)

# pppd quoted strings: escape backslash and double quote
pppq() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# Stale pid files survive a Docker restart and block the daemons
rm -f /var/run/charon.pid /var/run/starter.charon.pid /var/run/xl2tpd.pid /var/run/sockd.pid /var/run/xl2tpd/l2tp-control

# --- IPsec (IKEv1, transport mode, L2TP port only). PSK base64-encoded so any characters are safe.
cat > /etc/swanctl/swanctl.conf <<EOF
connections {
  l2tp {
    version = 1
    remote_addrs = $VPN_SERVER
    encap = yes
    proposals = aes256-sha256-modp2048,aes256-sha1-modp2048,aes128-sha1-modp2048,aes256-sha1-modp1024,aes128-sha1-modp1024,3des-sha1-modp1024
    local { auth = psk }
    remote { auth = psk }
    children {
      l2tp {
        mode = transport
        local_ts = dynamic[udp/1701]
        remote_ts = dynamic[udp/1701]
        esp_proposals = aes256-sha256,aes256-sha1,aes128-sha1,3des-sha1
      }
    }
  }
}
secrets {
  ike-l2tp { secret = 0s$(printf '%s' "$VPN_PSK" | base64 | tr -d '\n') }
}
EOF

# --- L2TP + PPP
mkdir -p /var/run/xl2tpd
cat > /etc/xl2tpd/xl2tpd.conf <<EOF
[lac vpn]
lns = $VPN_SERVER
pppoptfile = /etc/ppp/options.l2tpd.client
length bit = yes
EOF
cat > /etc/ppp/options.l2tpd.client <<EOF
ipcp-accept-local
ipcp-accept-remote
refuse-eap
noccp
noauth
mtu 1280
mru 1280
noipdefault
usepeerdns
connect-delay 5000
lcp-echo-interval 30
lcp-echo-failure 4
name "$(pppq "$VPN_USER")"
password "$(pppq "$VPN_PASSWORD")"
EOF
chmod 600 /etc/ppp/options.l2tpd.client /etc/swanctl/swanctl.conf

# --- Connect
/usr/lib/strongswan/charon &
sleep 2
swanctl --load-all
swanctl --initiate --child l2tp --timeout 30

xl2tpd -c /etc/xl2tpd/xl2tpd.conf -C /var/run/xl2tpd/l2tp-control
sleep 1
echo "c vpn" > /var/run/xl2tpd/l2tp-control

i=0
until ip -4 addr show ppp0 2>/dev/null | grep -q inet; do
  # wait before exiting so restarts don't lock the account with repeated bad logins
  i=$((i+1)); [ "$i" -gt 30 ] && { echo "ppp0 did not come up (check user/password); retrying in 2 min"; sleep 120; exit 1; }
  sleep 1
done
echo "ppp0 up: $(ip -4 addr show ppp0 | awk '/inet/{print $2}')"

# --- Routes: keep VPN server via Docker gateway, send everything else into the tunnel
GW=$(ip route | awk '/^default/{print $3; exit}')
ip route add "$VPN_SERVER/32" via "$GW" dev eth0
ip route replace default dev ppp0

# --- DNS: server-pushed, or VPN_DNS override (comma/space separated)
if [ -n "$VPN_DNS" ]; then
  echo "$VPN_DNS" | tr ', ' '\n\n' | sed '/^$/d; s/^/nameserver /' > /etc/resolv.conf
elif [ -s /etc/ppp/resolv.conf ]; then
  cat /etc/ppp/resolv.conf > /etc/resolv.conf
else
  # No DNS from the VPN: use public resolvers through the tunnel. Docker's default DNS asks Windows,
  # where Proxifier ("Resolve hostnames through proxy") answers with fake 127.x IPs that fail here.
  printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/resolv.conf
fi
echo "DNS: $(grep nameserver /etc/resolv.conf | awk '{print $2}' | tr '\n' ' ')"

# --- SOCKS5 (no auth; only published on 127.0.0.1 by compose)
cat > /etc/sockd.conf <<EOF
logoutput: stderr
internal: eth0 port = 1080
external: ppp0
clientmethod: none
socksmethod: none
user.privileged: root
user.unprivileged: nobody
client pass { from: 0.0.0.0/0 to: 0.0.0.0/0 }
socks pass { from: 0.0.0.0/0 to: 0.0.0.0/0 }
EOF
sockd -f /etc/sockd.conf &
echo "SOCKS5 ready on 127.0.0.1:1080"

# Exit when the tunnel drops so Docker restarts a fresh connection
while ip link show ppp0 >/dev/null 2>&1; do sleep 10; done
echo "ppp0 gone, exiting"
exit 1
