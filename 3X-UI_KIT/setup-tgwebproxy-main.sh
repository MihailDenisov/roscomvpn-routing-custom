#!/usr/bin/env bash
# Install TgWebProxy beside an existing 3X-UI KIT single-port deployment.
# It does not change MTProto/MTG, kit-stream.conf, x-ui inbounds or public ports.
set -Eeuo pipefail

TGWP_REPO=${TGWP_REPO:-https://github.com/MihailDenisov/tgwebproxy-multi.git}
TGWP_REF=${TGWP_REF:-feature/3xui-integration}
TGWP_LISTEN=127.0.0.1:4600
TGWP_ADMIN=127.0.0.1:9601
TGWP_DIR=/etc/tgwebproxy
TGWP_STATE=/var/lib/tgwebproxy/clients.json
TGWP_BIN=/usr/local/bin/tgwebproxy
NGINX_FILE=/etc/nginx/conf.d/kit-tgweb.conf

die() { echo "ERROR: $*" >&2; exit 1; }
say() { echo "==> $*"; }

[[ $EUID -eq 0 ]] || die "run as root"
DOMAIN=${1:-}
CERT=${2:-}
KEY=${3:-}
[[ $DOMAIN =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ && $DOMAIN == *.* ]] ||
  die "usage: $0 web.example.com /path/fullchain.pem /path/privkey.pem"
[[ -s $CERT && -s $KEY ]] || die "certificate/key not found"
openssl x509 -in "$CERT" -noout -checkhost "$DOMAIN" >/dev/null 2>&1 ||
  die "certificate does not cover $DOMAIN"

command -v nginx >/dev/null || die "nginx is required"
[[ -f /etc/nginx/kit-stream.conf ]] ||
  die "3X-UI KIT single-port nginx config not found"
grep -q '127.0.0.1:10445' /etc/nginx/kit-stream.conf ||
  echo "WARN: MTProto :10445 route was not found; continuing without modifying it" >&2
grep -q 'default 127.0.0.1:10446' /etc/nginx/kit-stream.conf ||
  die "expected HTTPS fallback 127.0.0.1:10446 not found"

if ss -H -ltn "sport = :4600" | grep -q . && ! systemctl is-active --quiet tgwebproxy; then
  die "$TGWP_LISTEN is already occupied by another service"
fi
if ss -H -ltn "sport = :9601" | grep -q . && ! systemctl is-active --quiet tgwebproxy; then
  die "$TGWP_ADMIN is already occupied by another service"
fi

say "building TgWebProxy $TGWP_REF"
apt-get update -qq
apt-get install -y -qq git golang-go ca-certificates >/dev/null
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
git clone -q --depth 1 --branch "$TGWP_REF" "$TGWP_REPO" "$tmp/src"
(cd "$tmp/src" && go test ./... && go build -trimpath -o "$tmp/tgwebproxy" ./cmd/tgwebproxy)
install -m 0755 "$tmp/tgwebproxy" "$TGWP_BIN"

id tgwebproxy >/dev/null 2>&1 || useradd --system --home /var/lib/tgwebproxy --shell /usr/sbin/nologin tgwebproxy
install -d -o root -g tgwebproxy -m 0750 "$TGWP_DIR"
install -d -o tgwebproxy -g tgwebproxy -m 0700 /var/lib/tgwebproxy

TOKEN_FILE=$TGWP_DIR/admin.token
if [[ ! -s $TOKEN_FILE ]]; then
  openssl rand -hex 32 >"$TOKEN_FILE"
  chown root:tgwebproxy "$TOKEN_FILE"
  chmod 0640 "$TOKEN_FILE"
fi
TOKEN=$(cat "$TOKEN_FILE")

# A disabled bootstrap entry keeps the keyring structurally valid before 3x-ui
# creates the first real user. API-managed state takes over after that.
BOOTSTRAP_FILE=$TGWP_DIR/bootstrap.secret
if [[ ! -s $BOOTSTRAP_FILE ]]; then
  openssl rand -hex 16 >"$BOOTSTRAP_FILE"
  chown root:tgwebproxy "$BOOTSTRAP_FILE"
  chmod 0640 "$BOOTSTRAP_FILE"
fi
BOOTSTRAP=$(cat "$BOOTSTRAP_FILE")

cat >"$TGWP_DIR/relay.toml" <<EOF
domain = "$DOMAIN"
listen = "$TGWP_LISTEN"
plain_listen = ""
behind_proxy = true
log_level = "info"
max_streams = 64

[admin]
listen = "$TGWP_ADMIN"
token = "$TOKEN"
state_file = "$TGWP_STATE"

[[secret]]
value = "$BOOTSTRAP"
label = "_bootstrap"
disabled = true
EOF
chown root:tgwebproxy "$TGWP_DIR/relay.toml"
chmod 0640 "$TGWP_DIR/relay.toml"

cat >/etc/systemd/system/tgwebproxy.service <<EOF
[Unit]
Description=TgWebProxy WEB relay
After=network-online.target
Wants=network-online.target

[Service]
User=tgwebproxy
Group=tgwebproxy
ExecStart=$TGWP_BIN -config $TGWP_DIR/relay.toml
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/tgwebproxy
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true

[Install]
WantedBy=multi-user.target
EOF

# This is a second TLS vhost on the existing internal HTTPS listener. Public
# TCP/443 and stream routing remain owned by the existing 3X-UI KIT nginx.
cat >"$NGINX_FILE" <<EOF
server {
    listen 127.0.0.1:10446 ssl http2 proxy_protocol;
    server_name $DOMAIN;

    ssl_certificate $CERT;
    ssl_certificate_key $KEY;
    ssl_protocols TLSv1.2 TLSv1.3;

    set_real_ip_from 127.0.0.1;
    real_ip_header proxy_protocol;
    server_tokens off;
    access_log off;

    location / {
        proxy_pass http://$TGWP_LISTEN;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$proxy_protocol_addr;
        proxy_set_header X-Forwarded-For \$proxy_protocol_addr;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 1h;
        proxy_send_timeout 1h;
        client_max_body_size 0;
    }
}
EOF

nginx -t
systemctl daemon-reload
systemctl enable --now tgwebproxy
systemctl reload nginx

for _ in $(seq 1 20); do
  curl -fsS -m 2 -H "Authorization: Bearer $TOKEN" "http://$TGWP_ADMIN/healthz" >/dev/null 2>&1 && break
  sleep 1
done
curl -fsS -m 2 "http://$TGWP_ADMIN/healthz" >/dev/null ||
  die "TgWebProxy health check failed; see: journalctl -u tgwebproxy -n 50"

say "installed without changing MTProto/MTG"
echo "public: https://$DOMAIN:443"
echo "backend: $TGWP_LISTEN"
echo "admin: $TGWP_ADMIN (loopback only)"
echo "admin token: $TOKEN_FILE"
