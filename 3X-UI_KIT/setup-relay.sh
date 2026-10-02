#!/usr/bin/env bash
set -Eeuo pipefail

say() { printf '==> %s\n' "$*"; }
warn() { printf '! %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
Usage:
  setup-relay.sh --main-ip MAIN_IPV4 [--relay-domain NAME] [--ssh-port PORT] [--keep-ipv6]

Configures a plain Linux L3/L4 relay with iptables only. No VPN/proxy software is installed.
Forwarded ports:
  80/tcp    -> MAIN:80      (Let's Encrypt HTTP-01)
  443/tcp   -> MAIN:443     (REALITY/XHTTP/MTProto/HTTPS/subscription/panel)
  443/udp   -> MAIN:443     (Hysteria2)
  8443/udp  -> MAIN:8443    (AmneziaWG 3.1)
  8444/udp  -> MAIN:8444    (TUIC)
USAGE
}

[[ $EUID -eq 0 ]] || die "run as root"
MAIN_IP=""
RELAY_DOMAIN=""
SSH_PORT=""
DISABLE_IPV6=yes
while [[ $# -gt 0 ]]; do
  case "$1" in
    --main-ip) MAIN_IP=${2:-}; shift 2 ;;
    --relay-domain) RELAY_DOMAIN=${2:-}; shift 2 ;;
    --ssh-port) SSH_PORT=${2:-}; shift 2 ;;
    --keep-ipv6) DISABLE_IPV6=no; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[[ $MAIN_IP =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "--main-ip must be an IPv4 address"
if [[ -n $RELAY_DOMAIN ]]; then
  [[ $RELAY_DOMAIN =~ ^[A-Za-z0-9.-]+$ && $RELAY_DOMAIN == *.* ]] || die "invalid --relay-domain"
fi

command -v apt-get >/dev/null || die "Ubuntu/Debian with apt is required"
export DEBIAN_FRONTEND=noninteractive
say "Installing minimal networking tools"
apt-get update -qq
apt-get install -y -qq iptables iproute2 curl ca-certificates >/dev/null

WAN_IF=$(ip -4 route get "$MAIN_IP" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
[[ -n $WAN_IF ]] || WAN_IF=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
[[ -n $WAN_IF ]] || die "could not detect public interface"
RELAY_IP=$(ip -4 addr show dev "$WAN_IF" scope global | awk '/inet / {sub(/\/.*/,"",$2); print $2; exit}')
[[ -n $RELAY_IP ]] || die "could not detect relay IPv4 on $WAN_IF"
[[ $MAIN_IP != "$RELAY_IP" ]] || die "MAIN_IP equals relay IP"

if [[ -z $SSH_PORT ]]; then
  SSH_PORT=$(ss -H -lntp 2>/dev/null | awk '/sshd/ {sub(/.*:/,"",$4); print $4; exit}')
  SSH_PORT=${SSH_PORT:-22}
fi
[[ $SSH_PORT =~ ^[0-9]+$ ]] && ((SSH_PORT>=1 && SSH_PORT<=65535)) || die "invalid SSH port"

if [[ -n $RELAY_DOMAIN ]]; then
  RESOLVED=$(getent ahostsv4 "$RELAY_DOMAIN" 2>/dev/null | awk 'NR==1{print $1}')
  if [[ -n $RESOLVED && $RESOLVED != "$RELAY_IP" ]]; then
    warn "$RELAY_DOMAIN currently resolves to $RESOLVED, relay IPv4 is $RELAY_IP"
  elif [[ -z $RESOLVED ]]; then
    warn "$RELAY_DOMAIN has no IPv4 DNS record yet"
  fi
fi

say "Applying kernel forwarding/hardening settings"
cat >/etc/sysctl.d/99-kit-relay.conf <<SYSCTL
net.ipv4.ip_forward=1
net.ipv4.conf.all.accept_source_route=0
net.ipv4.conf.default.accept_source_route=0
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.default.send_redirects=0
net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.default.rp_filter=1
SYSCTL
if [[ $DISABLE_IPV6 == yes ]]; then
  cat >>/etc/sysctl.d/99-kit-relay.conf <<'SYSCTL'
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
net.ipv6.conf.lo.disable_ipv6=1
SYSCTL
fi
sysctl --system >/dev/null

install -d -m 700 /etc/kit-relay
cat >/etc/kit-relay/config <<EOF_CFG
MAIN_IP=$MAIN_IP
WAN_IF=$WAN_IF
SSH_PORT=$SSH_PORT
RELAY_IP=$RELAY_IP
RELAY_DOMAIN=$RELAY_DOMAIN
EOF_CFG
chmod 600 /etc/kit-relay/config

cat >/usr/local/sbin/kit-relay-firewall <<'EOF_FW'
#!/usr/bin/env bash
set -Eeuo pipefail
. /etc/kit-relay/config
IPT="iptables -w 10"

ensure_chain() {
  local table=$1 chain=$2
  $IPT -t "$table" -N "$chain" 2>/dev/null || true
  $IPT -t "$table" -F "$chain"
}
ensure_jump() {
  local table=$1 from=$2 to=$3
  $IPT -t "$table" -C "$from" -j "$to" 2>/dev/null || $IPT -t "$table" -I "$from" 1 -j "$to"
}

ensure_chain nat KIT_RELAY_DNAT
ensure_chain nat KIT_RELAY_SNAT
ensure_chain filter KIT_RELAY_INPUT
ensure_chain filter KIT_RELAY_FORWARD
ensure_jump nat PREROUTING KIT_RELAY_DNAT
ensure_jump nat POSTROUTING KIT_RELAY_SNAT
ensure_jump filter INPUT KIT_RELAY_INPUT
ensure_jump filter FORWARD KIT_RELAY_FORWARD

# Only SSH/ICMP are local services. Relayed ports are DNATed before INPUT.
$IPT -A KIT_RELAY_INPUT -i lo -j ACCEPT
$IPT -A KIT_RELAY_INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
$IPT -A KIT_RELAY_INPUT -p tcp --dport "$SSH_PORT" -j ACCEPT
# Keep DHCP renewal working on VPSes whose public NIC is configured by DHCP.
$IPT -A KIT_RELAY_INPUT -i "$WAN_IF" -p udp --sport 67 --dport 68 -j ACCEPT
$IPT -A KIT_RELAY_INPUT -p icmp -j ACCEPT
$IPT -A KIT_RELAY_INPUT -j DROP

for port in 80 443; do
  $IPT -t nat -A KIT_RELAY_DNAT -i "$WAN_IF" -p tcp --dport "$port" -j DNAT --to-destination "$MAIN_IP:$port"
  $IPT -t nat -A KIT_RELAY_SNAT -p tcp -d "$MAIN_IP" --dport "$port" -j MASQUERADE
  $IPT -A KIT_RELAY_FORWARD -i "$WAN_IF" -p tcp -d "$MAIN_IP" --dport "$port" -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT
done
for port in 443 8443 8444; do
  $IPT -t nat -A KIT_RELAY_DNAT -i "$WAN_IF" -p udp --dport "$port" -j DNAT --to-destination "$MAIN_IP:$port"
  $IPT -t nat -A KIT_RELAY_SNAT -p udp -d "$MAIN_IP" --dport "$port" -j MASQUERADE
  $IPT -A KIT_RELAY_FORWARD -i "$WAN_IF" -p udp -d "$MAIN_IP" --dport "$port" -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT
done
$IPT -A KIT_RELAY_FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
$IPT -A KIT_RELAY_FORWARD -j DROP
EOF_FW
chmod 700 /usr/local/sbin/kit-relay-firewall

cat >/etc/systemd/system/kit-relay-firewall.service <<'EOF_UNIT'
[Unit]
Description=3X-UI KIT plain iptables relay
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/kit-relay-firewall
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF_UNIT

systemctl daemon-reload
systemctl enable --now kit-relay-firewall.service >/dev/null

say "Relay configured: $RELAY_IP -> $MAIN_IP via $WAN_IF"
echo "TCP: 80, 443"
echo "UDP: 443, 8443, 8444"
echo "SSH: $SSH_PORT/tcp"
[[ $DISABLE_IPV6 == yes ]] && echo "IPv6: disabled"
if [[ -n $RELAY_DOMAIN ]]; then
  echo "Domain: $RELAY_DOMAIN"
  echo
  echo "Basic HTTPS transit check (certificate may not contain relay name yet):"
  curl -4ksSI --connect-timeout 5 --resolve "$RELAY_DOMAIN:443:$RELAY_IP" "https://$RELAY_DOMAIN/" | head -n 1 || true
fi

echo
echo "Check rules:"
echo "  iptables -t nat -S KIT_RELAY_DNAT"
echo "  iptables -S KIT_RELAY_FORWARD"
echo "  systemctl status kit-relay-firewall --no-pager"
echo
echo "Provider firewall must also allow: 80/tcp, 443/tcp, 443/udp, 8443/udp, 8444/udp and SSH $SSH_PORT/tcp."
