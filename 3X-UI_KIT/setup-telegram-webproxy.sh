#!/usr/bin/env bash
set -Eeuo pipefail

# EXPERIMENTAL / TEST FEATURE.
# Dedicated Ubuntu VPS only. Do not run on the existing MAIN or relay host.
TPROXY_REPO="https://github.com/telegramdesktop/tproxy-server.git"
TPROXY_COMMIT="c8adb8b7c6b7fc46c12ae3acb68be9070c26a8e8"

say()  { printf '==> %s\n' "$*"; }
warn() { printf '! %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
EXPERIMENTAL: Telegram WEB Proxy installer for a dedicated Ubuntu VPS.

Usage:
  setup-telegram-webproxy.sh \
    --hostname webproxy.example.com \
    --email admin@example.com \
    (--site-dir /path/to/site | --site-upstream http://127.0.0.1:3000 | --demo-site) \
    [--base-path SLUG|none] [--secret 32_HEX] [-y]

Requirements:
  * dedicated x86_64 Ubuntu 22.04+ VPS with systemd
  * public IPv4; DNS A record for --hostname pointing to this VPS
  * inbound TCP/80 and TCP/443; both ports free before installation

This feature is TEST/EXPERIMENTAL. Telegram upstream describes tproxy-server as
a proof-of-concept. The upstream installer owns Caddy on TCP/80 and TCP/443.
USAGE
}

[[ $EUID -eq 0 ]] || die "run as root"

HOSTNAME=""
EMAIL=""
SITE_DIR=""
SITE_UPSTREAM=""
DEMO_SITE=no
BASE_PATH=""
SECRET=""
ASSUME_YES=no

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hostname) HOSTNAME=$2; shift 2 ;;
    --email) EMAIL=$2; shift 2 ;;
    --site-dir) SITE_DIR=$2; shift 2 ;;
    --site-upstream) SITE_UPSTREAM=$2; shift 2 ;;
    --demo-site) DEMO_SITE=yes; shift ;;
    --base-path) BASE_PATH=$2; shift 2 ;;
    --secret) SECRET=$2; shift 2 ;;
    -y|--yes) ASSUME_YES=yes; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[[ -n $HOSTNAME ]] || die "--hostname is required"
[[ -n $EMAIL ]] || die "--email is required"
[[ $HOSTNAME == "$(printf %s "$HOSTNAME" | tr 'A-Z' 'a-z')" ]] || die "--hostname must be lowercase"
[[ $HOSTNAME =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ && $HOSTNAME == *.* ]] || die "invalid hostname"
[[ $EMAIL == *@*.* ]] || die "invalid --email"

site_modes=0
[[ -n $SITE_DIR ]] && site_modes=$((site_modes + 1))
[[ -n $SITE_UPSTREAM ]] && site_modes=$((site_modes + 1))
[[ $DEMO_SITE == yes ]] && site_modes=$((site_modes + 1))
((site_modes == 1)) || die "choose exactly one: --site-dir, --site-upstream, or --demo-site"

if [[ -n $SITE_DIR ]]; then
  [[ -d $SITE_DIR && -r $SITE_DIR/index.html ]] || die "--site-dir must contain a readable index.html"
  SITE_DIR=$(cd "$SITE_DIR" && pwd -P)
fi
if [[ -n $SITE_UPSTREAM ]]; then
  [[ $SITE_UPSTREAM =~ ^http://(127\.[0-9]+\.[0-9]+\.[0-9]+|\[::1\]):[1-9][0-9]{0,4}$ ]] \
    || die "--site-upstream must be a numeric loopback HTTP URL"
fi
if [[ -n $BASE_PATH && $BASE_PATH != none ]]; then
  [[ $BASE_PATH =~ ^[a-z0-9_-]{4,64}$ ]] || die "--base-path must be 4-64 chars: a-z, 0-9, _ or -"
fi
if [[ -n $SECRET ]]; then
  [[ $SECRET =~ ^([dD][dD])?[0-9a-fA-F]{32}$ ]] || die "--secret must be 32 hex chars, optionally prefixed with dd"
  SECRET=$(printf %s "$SECRET" | tr 'A-F' 'a-f')
fi

[[ $(uname -m) == x86_64 ]] || die "official MTProxy backend requires x86_64"
[[ -f /etc/os-release ]] || die "Ubuntu 22.04+ is required"
. /etc/os-release
[[ $ID == ubuntu ]] || die "this wrapper supports Ubuntu only"
major=$(printf %s "$VERSION_ID" | cut -d. -f1)
[[ $major =~ ^[0-9]+$ && $major -ge 22 ]] || die "Ubuntu 22.04+ is required"
command -v systemctl >/dev/null || die "systemd is required"

say "EXPERIMENTAL Telegram WEB Proxy"
warn "Use a dedicated VPS. This is separate from the production 3X-UI relay."

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends ca-certificates curl git iproute2 >/dev/null

resolved=$(getent ahostsv4 "$HOSTNAME" 2>/dev/null | awk 'NR==1{print $1}')
[[ -n $resolved ]] || die "$HOSTNAME has no IPv4 DNS record"
local_ips=$(ip -4 -o addr show scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]}')
if ! grep -Fxq "$resolved" <<<"$local_ips"; then
  warn "$HOSTNAME resolves to $resolved, not to an IPv4 assigned directly to this host."
  warn "This can be valid behind 1:1 NAT; verify the public address."
fi

for port in 80 443; do
  if ss -H -ltn "sport = :$port" 2>/dev/null | grep -q .; then
    die "TCP/$port is already in use; use a clean dedicated VPS"
  fi
done

[[ $DEMO_SITE == yes ]] && warn "--demo-site is for testing only; replace it before wider use."

if [[ $ASSUME_YES != yes ]]; then
  echo
  echo "TEST feature. Will install:"
  echo "  host: $HOSTNAME"
  echo "  upstream commit: $TPROXY_COMMIT"
  echo "  Caddy + tproxy-server + official MTProxy"
  echo "  public TCP ports: 80, 443"
  echo
  read -r -p "Continue? [y/N] " answer
  [[ $answer =~ ^[Yy]$ ]] || exit 0
fi

tmp=$(mktemp -d /tmp/kit-tproxy.XXXXXX)
trap 'rm -rf "$tmp"' EXIT

say "Fetching pinned upstream"
git -c advice.detachedHead=false clone -q "$TPROXY_REPO" "$tmp/tproxy-server"
git -C "$tmp/tproxy-server" checkout -q "$TPROXY_COMMIT"
actual=$(git -C "$tmp/tproxy-server" rev-parse HEAD)
[[ $actual == "$TPROXY_COMMIT" ]] || die "unexpected upstream commit: $actual"

[[ -n $SECRET ]] || SECRET=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')

set -- --hostname "$HOSTNAME" --email "$EMAIL"
[[ -n $BASE_PATH ]] && set -- "$@" --base-path "$BASE_PATH"

if [[ $DEMO_SITE == yes ]]; then
  demo="$tmp/demo-site"
  install -d -m 0755 "$demo"
  nonce=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
  cat >"$demo/index.html" <<HTML
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex,nofollow">
<title>Welcome</title>
<style>body{font-family:system-ui,sans-serif;max-width:44rem;margin:12vh auto;padding:0 1.5rem;line-height:1.6}small{opacity:.55}</style>
</head>
<body><h1>Welcome</h1><p>This service is currently being prepared.</p><small>$nonce</small></body>
</html>
HTML
  set -- "$@" --site-dir "$demo"
elif [[ -n $SITE_DIR ]]; then
  set -- "$@" --site-dir "$SITE_DIR"
else
  set -- "$@" --site-upstream "$SITE_UPSTREAM"
fi

say "Running official pinned installer"
printf '%s\n' "$SECRET" | "$tmp/tproxy-server/deploy/install.sh" "$@"

if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q 'Status: active'; then
  say "Opening TCP/80 and TCP/443 in UFW"
  ufw allow 80/tcp >/dev/null
  ufw allow 443/tcp >/dev/null
fi

say "Validating services"
systemctl is-active --quiet caddy || die "caddy is not active"
systemctl is-active --quiet mtproxy || die "mtproxy is not active"
systemctl is-active --quiet tproxy-server || die "tproxy-server is not active"
curl -fsS --max-time 5 http://127.0.0.1:8081/readyz >/dev/null || die "readiness check failed"

public_ok=no
for _ in $(seq 1 12); do
  if curl -4fsS --max-time 10 "https://$HOSTNAME/" >/dev/null 2>&1; then
    public_ok=yes
    break
  fi
  sleep 2
done
[[ $public_ok == yes ]] || warn "Public HTTPS check failed; verify DNS, provider firewall and ACME."

base_path=$(sed -n 's/.*"base_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' /etc/tproxy-server/config.json | head -n1)
if [[ -z $base_path ]]; then
  proxy_secret=$SECRET
  client_address=$HOSTNAME
else
  proxy_secret=$(
    {
      printf '\x70'
      printf "$(printf %s "$SECRET" | sed 's/../\\x&/g')"
    } | base64 | tr '+/' '-_' | tr -d '=\n'
  )
  client_address="$HOSTNAME/$base_path"
fi
server_encoded=$(printf %s "$client_address" | sed 's#/#%2F#g')

install -d -m 0700 /root/kit-webproxy
cat >/root/kit-webproxy/README.txt <<EOF
EXPERIMENTAL Telegram WEB Proxy
Upstream commit: $TPROXY_COMMIT

Hostname: $HOSTNAME
Server:   $client_address
Secret:   $proxy_secret
Link:
https://t.me/webproxy?server=$server_encoded&secret=$proxy_secret

Keep /etc/tproxy-server/token.key backed up and private.
Do not publish /etc/tproxy-server/profiles.json.
EOF
chmod 0600 /root/kit-webproxy/README.txt

echo
say "Telegram WEB Proxy installed (EXPERIMENTAL)"
echo "Server: $client_address"
echo "Secret: $proxy_secret"
echo "Link:   https://t.me/webproxy?server=$server_encoded&secret=$proxy_secret"
echo
echo "Checks:"
echo "  systemctl --no-pager --full status caddy mtproxy tproxy-server"
echo "  curl -f https://$HOSTNAME/"
echo "  curl -f http://127.0.0.1:8081/readyz"
echo
echo "Saved root-only: /root/kit-webproxy/README.txt"
echo "Provider firewall must allow inbound TCP/80 and TCP/443."
