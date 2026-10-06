#!/usr/bin/env bash
# Minimal dedicated edge for web.maicraft.tech.
# It forwards only TCP/80 and TCP/443 to MAIN and does not terminate TLS.
set -Eeuo pipefail

say()  { printf '==> %s\n' "$*"; }
warn() { printf '! %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
Usage:
  setup-tgweb-edge.sh (--main-ip MAIN_IPV4 | --main-host MAIN_HOST) --domain web.example.com [--ssh-port PORT]

The edge:
  TCP/443 -> MAIN:443  (raw TLS; SNI and certificate stay on MAIN)
  TCP/80  -> MAIN:80   (Let's Encrypt HTTP-01 / renewals)

It does NOT install TgWebProxy, 3x-ui, MTProto/MTG or any UDP forwarding.
USAGE
}

[[ $EUID -eq 0 ]] || die "run as root"
MAIN_IP=""
MAIN_HOST=""
DOMAIN=""
SSH_PORT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --main-ip) MAIN_IP=${2:-}; shift 2 ;;
    --main-host) MAIN_HOST=${2:-}; shift 2 ;;
    --domain) DOMAIN=${2:-}; shift 2 ;;
    --ssh-port) SSH_PORT=${2:-}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

if [[ -n $MAIN_HOST ]]; then
  [[ $MAIN_HOST =~ ^[A-Za-z0-9.-]+$ && $MAIN_HOST == *.* ]] || die "--main-host is invalid"
  resolved=$(getent ahostsv4 "$MAIN_HOST" 2>/dev/null | awk 'NR==1{print $1}')
  [[ $resolved =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "cannot resolve IPv4 for $MAIN_HOST"
  if [[ -n $MAIN_IP && $MAIN_IP != "$resolved" ]]; then
    die "--main-ip $MAIN_IP does not match $MAIN_HOST ($resolved)"
  fi
  MAIN_IP=$resolved
fi
[[ $MAIN_IP =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "pass --main-ip or --main-host"
[[ $DOMAIN =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ && $DOMAIN == *.* ]] || die "--domain is invalid"
command -v apt-get >/dev/null || die "Ubuntu/Debian with apt is required"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq haproxy curl ca-certificates iproute2 iptables >/dev/null

WAN_IF=$(ip -4 route get "$MAIN_IP" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1);exit}}')
[[ -n $WAN_IF ]] || WAN_IF=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1);exit}}')
[[ -n $WAN_IF ]] || die "cannot detect public interface"
EDGE_IP=$(ip -4 addr show dev "$WAN_IF" scope global | awk '/inet / {sub(/\/.*/,"",$2);print $2;exit}')
[[ -n $EDGE_IP ]] || die "cannot detect edge IPv4"
[[ $EDGE_IP != "$MAIN_IP" ]] || die "MAIN IP equals edge IP"

if [[ -z $SSH_PORT ]]; then
  SSH_PORT=$(ss -H -lntp 2>/dev/null | awk '/sshd/ {sub(/.*:/,"",$4);print $4;exit}')
  SSH_PORT=${SSH_PORT:-22}
fi
if [[ ! $SSH_PORT =~ ^[0-9]+$ ]] || ((SSH_PORT < 1 || SSH_PORT > 65535)); then
  die "invalid SSH port"
fi

DNS_IP=$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk 'NR==1{print $1}')
if [[ -z $DNS_IP ]]; then
  warn "$DOMAIN has no A record yet; expected $EDGE_IP"
elif [[ $DNS_IP != "$EDGE_IP" ]]; then
  die "$DOMAIN resolves to $DNS_IP, but this edge is $EDGE_IP"
fi

for port in 80 443; do
  if ss -H -ltn "sport = :$port" | grep -q .; then
    owner=$(ss -H -lntp "sport = :$port" 2>/dev/null || true)
    if ! grep -q haproxy <<<"$owner"; then
      die "TCP/$port is already occupied: $owner"
    fi
  fi
done

install -d -m 700 /etc/tgweb-edge
cat >/etc/tgweb-edge/config <<EOF
MAIN_IP=$MAIN_IP
MAIN_HOST=$MAIN_HOST
EDGE_IP=$EDGE_IP
DOMAIN=$DOMAIN
SSH_PORT=$SSH_PORT
WAN_IF=$WAN_IF
EOF
chmod 600 /etc/tgweb-edge/config

cp -a /etc/haproxy/haproxy.cfg "/etc/haproxy/haproxy.cfg.pre-tgweb.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
cat >/etc/haproxy/haproxy.cfg <<EOF
global
    log /dev/log local0
    log /dev/log local1 notice
    daemon
    maxconn 32768

defaults
    log global
    mode tcp
    option tcplog
    option tcpka
    timeout connect 10s
    timeout client 1h
    timeout server 1h

frontend tgweb_http_80
    bind 0.0.0.0:80
    default_backend tgweb_main_80

backend tgweb_main_80
    server main $MAIN_IP:80

frontend tgweb_tls_443
    bind 0.0.0.0:443
    default_backend tgweb_main_443

backend tgweb_main_443
    server main $MAIN_IP:443
EOF

haproxy -c -f /etc/haproxy/haproxy.cfg >/dev/null

cat >/usr/local/sbin/tgweb-edge-firewall <<'EOF_FW'
#!/usr/bin/env bash
set -Eeuo pipefail
. /etc/tgweb-edge/config
IPT="iptables -w 10"

$IPT -N TGWEB_EDGE_INPUT 2>/dev/null || true
$IPT -F TGWEB_EDGE_INPUT
$IPT -C INPUT -j TGWEB_EDGE_INPUT 2>/dev/null || $IPT -I INPUT 1 -j TGWEB_EDGE_INPUT

$IPT -A TGWEB_EDGE_INPUT -i lo -j ACCEPT
$IPT -A TGWEB_EDGE_INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
$IPT -A TGWEB_EDGE_INPUT -p tcp --dport "$SSH_PORT" -j ACCEPT
$IPT -A TGWEB_EDGE_INPUT -p tcp --dport 80 -j ACCEPT
$IPT -A TGWEB_EDGE_INPUT -p tcp --dport 443 -j ACCEPT
$IPT -A TGWEB_EDGE_INPUT -p udp --sport 67 --dport 68 -j ACCEPT
$IPT -A TGWEB_EDGE_INPUT -p icmp -j ACCEPT
$IPT -A TGWEB_EDGE_INPUT -j DROP
EOF_FW
chmod 700 /usr/local/sbin/tgweb-edge-firewall

cat >/etc/systemd/system/tgweb-edge-firewall.service <<'EOF_UNIT'
[Unit]
Description=TgWeb dedicated edge firewall
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/tgweb-edge-firewall
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF_UNIT

systemctl daemon-reload
systemctl enable tgweb-edge-firewall.service >/dev/null
systemctl restart tgweb-edge-firewall.service
systemctl enable haproxy >/dev/null 2>&1
systemctl restart haproxy

say "edge configured: $DOMAIN ($EDGE_IP) -> MAIN $MAIN_IP"
echo "TCP/80  -> MAIN:80"
echo "TCP/443 -> MAIN:443 (TLS/SNI unchanged)"
echo "SSH      $SSH_PORT/tcp"
echo
echo "Provider firewall/security group should allow only TCP 80, TCP 443 and SSH $SSH_PORT."
echo
echo "Checks:"
echo "  systemctl status haproxy --no-pager"
echo "  ss -lntp | grep -E ':(80|443) '"
echo "  curl -4ksSI --connect-timeout 5 --resolve '$DOMAIN:443:$EDGE_IP' https://$DOMAIN/ | head -n1"
