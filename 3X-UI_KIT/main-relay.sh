#!/usr/bin/env bash
set -Eeuo pipefail

say() { printf '==> %s\n' "$*"; }
warn() { printf '! %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
Usage:
  main-relay.sh prepare  --relay-domain ru.connect.example.com --relay-ip A.B.C.D [--origin-domain connect.example.com]
  main-relay.sh activate --relay-domain ru.connect.example.com --relay-ip A.B.C.D [--origin-domain connect.example.com] [--lockdown]
  main-relay.sh status   --relay-domain ru.connect.example.com [--origin-domain connect.example.com]

prepare:
  * backs up x-ui/nginx/kit state
  * expands the existing Let's Encrypt certificate with relay-domain
  * makes nginx accept both host names

activate:
  * changes 3x-ui subscription/share endpoints to relay-domain
  * changes existing externalProxy.dest values to relay-domain
  * updates kit/kit-sub public subscription host
  * with --lockdown, limits MAIN VPN ports to relay-ip via UFW

Run relay setup first, because HTTP-01 for relay-domain must traverse RELAY:80 -> MAIN:80.
USAGE
}

[[ $EUID -eq 0 ]] || die "run as root"
ACTION=${1:-}
[[ $ACTION =~ ^(prepare|activate|status)$ ]] || { usage; exit 1; }
shift || true
RELAY_DOMAIN=""
RELAY_IP=""
ORIGIN_DOMAIN=""
LOCKDOWN=no
while [[ $# -gt 0 ]]; do
  case "$1" in
    --relay-domain) RELAY_DOMAIN=${2:-}; shift 2 ;;
    --relay-ip) RELAY_IP=${2:-}; shift 2 ;;
    --origin-domain) ORIGIN_DOMAIN=${2:-}; shift 2 ;;
    --lockdown) LOCKDOWN=yes; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done
[[ -n $RELAY_DOMAIN ]] || die "--relay-domain is required"
[[ $RELAY_DOMAIN =~ ^[A-Za-z0-9.-]+$ && $RELAY_DOMAIN == *.* ]] || die "invalid relay domain"
if [[ $ACTION != status ]]; then
  [[ $RELAY_IP =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "--relay-ip is required and must be IPv4"
fi

XUI_ENV=/etc/x-ui/install-result.env
KIT_ENV=/etc/kit/kit.env
[[ -f $XUI_ENV ]] || die "missing $XUI_ENV"
[[ -f $KIT_ENV ]] || die "missing $KIT_ENV"
# shellcheck disable=SC1090
. "$XUI_ENV"
# shellcheck disable=SC1090
. "$KIT_ENV"
ORIGIN_DOMAIN=${ORIGIN_DOMAIN:-${DOMAIN:-${HOST:-}}}
[[ -n $ORIGIN_DOMAIN ]] || die "could not determine origin domain; pass --origin-domain"
[[ $ORIGIN_DOMAIN != "$RELAY_DOMAIN" ]] || die "origin and relay domains must differ"

API=""
for scheme in http https; do
  candidate="$scheme://127.0.0.1:$XUI_PANEL_PORT/$XUI_WEB_BASE_PATH/panel/api"
  if curl -fsk -m 5 -o /dev/null -H "Authorization: Bearer $XUI_API_TOKEN" "$candidate/server/getNewUUID" 2>/dev/null; then API=$candidate; break; fi
done
[[ -n $API ]] || die "3x-ui API is unavailable"

api() {
  local method=$1 path=$2 data=${3:-} out
  if [[ $method == GET ]]; then
    out=$(curl -fsSk -m 20 -H "Authorization: Bearer $XUI_API_TOKEN" "$API/$path")
  else
    out=$(curl -fsSk -m 20 -H "Authorization: Bearer $XUI_API_TOKEN" -H 'Content-Type: application/json' -X "$method" -d "$data" "$API/$path")
  fi
  [[ $(jq -r '.success' <<<"$out") == true ]] || die "3x-ui API error at $path: $(jq -r '.msg // .' <<<"$out" | head -c 300)"
  jq -c '.obj' <<<"$out"
}

backup_state() {
  local dir="/root/kit-relay-backup/$(date +%Y%m%d-%H%M%S)"
  install -d -m 700 "$dir"
  cp -a /etc/x-ui/x-ui.db "$dir/" 2>/dev/null || true
  cp -a /etc/nginx "$dir/nginx" 2>/dev/null || true
  cp -a /etc/kit "$dir/kit" 2>/dev/null || true
  cp -a /etc/kit-sub "$dir/kit-sub" 2>/dev/null || true
  cp -a /root/3x-ui.txt "$dir/" 2>/dev/null || true
  echo "$dir"
}

resolved_relay_ip() {
  getent ahostsv4 "$RELAY_DOMAIN" 2>/dev/null | awk 'NR==1{print $1}'
}

prepare() {
  command -v certbot >/dev/null || die "certbot is not installed"
  local dns_ip backup cert cert_name
  dns_ip=$(resolved_relay_ip)
  [[ -n $dns_ip ]] || die "$RELAY_DOMAIN has no IPv4 DNS record"
  [[ $dns_ip == "$RELAY_IP" ]] || die "$RELAY_DOMAIN resolves to $dns_ip, expected $RELAY_IP"

  backup=$(backup_state)
  say "Backup: $backup"

  cert_name=$ORIGIN_DOMAIN
  cert="/etc/letsencrypt/live/$cert_name/fullchain.pem"
  [[ -s $cert ]] || die "certificate $cert not found; use --origin-domain matching the KIT certificate name"

  if openssl x509 -in "$cert" -noout -ext subjectAltName 2>/dev/null | grep -Fq "DNS:$RELAY_DOMAIN"; then
    say "Certificate already contains $RELAY_DOMAIN"
  else
    if ss -H -ltn 'sport = :80' 2>/dev/null | grep -q .; then
      die "port 80 on MAIN is busy; standalone certbot needs it during HTTP-01"
    fi
    say "Expanding Let's Encrypt certificate: $ORIGIN_DOMAIN + $RELAY_DOMAIN"
    if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
      ufw allow 80/tcp >/dev/null
    fi
    certbot certonly --standalone --non-interactive --agree-tos --register-unsafely-without-email \
      --cert-name "$cert_name" --expand -d "$ORIGIN_DOMAIN" -d "$RELAY_DOMAIN"
  fi

  if [[ -f /etc/nginx/conf.d/kit.conf ]]; then
    sed -Ei "s|^[[:space:]]*server_name[[:space:]]+[^;]*;|    server_name $ORIGIN_DOMAIN $RELAY_DOMAIN;|" /etc/nginx/conf.d/kit.conf
    nginx -t
    systemctl reload nginx
  fi

  install -d -m 755 /etc/letsencrypt/renewal-hooks/deploy
  cat >/etc/letsencrypt/renewal-hooks/deploy/3x-ui-kit-nginx <<'HOOK'
#!/bin/sh
systemctl is-active --quiet nginx && systemctl reload nginx || true
HOOK
  chmod 755 /etc/letsencrypt/renewal-hooks/deploy/3x-ui-kit-nginx
  systemctl enable --now certbot.timer >/dev/null 2>&1 || true

  say "Certificate SANs:"
  openssl x509 -in "$cert" -noout -ext subjectAltName
  say "HTTPS via relay:"
  curl -4fsSI --connect-timeout 7 "https://$RELAY_DOMAIN/" | head -n 1 || warn "HTTPS check failed; verify relay 443/tcp and provider firewall"
}

update_kit_env() {
  local sub_path=$1 tmp
  tmp=$(mktemp)
  awk -v h="$RELAY_DOMAIN" -v b="https://$RELAY_DOMAIN$sub_path" '
    BEGIN{seen_h=0;seen_b=0}
    /^HOST=/{print "HOST=" h; seen_h=1; next}
    /^SUB_BASE=/{print "SUB_BASE=" b; seen_b=1; next}
    {print}
    END{if(!seen_h) print "HOST=" h; if(!seen_b) print "SUB_BASE=" b}
  ' "$KIT_ENV" >"$tmp"
  install -m 600 "$tmp" "$KIT_ENV"
  rm -f "$tmp"
}

update_inbounds() {
  local list id payload
  list=$(api GET inbounds/list)
  while read -r id; do
    payload=$(jq -c --argjson id "$id" --arg relay "$RELAY_DOMAIN" '
      .[] | select(.id == $id)
      | (.protocol == "mtproto") as $is_mtproto
      | .shareAddrStrategy = "custom"
      | .shareAddr = $relay
      | if (.streamSettings|type) == "object" then
          if (.streamSettings.externalProxy|type) == "array" then
            .streamSettings.externalProxy |= map(.dest = $relay | if $is_mtproto then .port = 443 else . end)
          elif $is_mtproto then
            .streamSettings.externalProxy = [{forceTls:"same", dest:$relay, port:443, remark:""}]
          else . end
        elif (.streamSettings|type) == "string" and (.streamSettings|length) > 0 then
          .streamSettings = ((.streamSettings|fromjson)
            | if (.externalProxy|type) == "array" then
                .externalProxy |= map(.dest = $relay | if $is_mtproto then .port = 443 else . end)
              elif $is_mtproto then
                .externalProxy = [{forceTls:"same",dest:$relay,port:443,remark:""}]
              else . end
            | tojson)
        elif $is_mtproto then
          .streamSettings = ({externalProxy:[{forceTls:"same",dest:$relay,port:443,remark:""}]}|tojson)
        else . end
    ' <<<"$list")
    api POST "inbounds/update/$id" "$payload" >/dev/null
  done < <(jq -r '.[] | select(.enable == true) | .id' <<<"$list")
}

ensure_mtproto_relay_host() {
  local list id groups gid payload old_gid remaining
  list=$(api GET inbounds/list)
  while read -r id; do
    [[ -n $id ]] || continue
    groups=$(api GET "hosts/byInbound/$id")
    gid=$(jq -r '.[] | select(.remark == "KIT relay MTProto") | .groupId' <<<"$groups" | head -n1)

    # MTProto share links are generated from Host groups. A legacy host with port=0
    # inherits the inbound's local listener port (e.g. 10445), producing a second,
    # unusable public link. Detach this MTProto inbound from every non-canonical
    # group; delete a group only when it belongs exclusively to this inbound.
    while read -r old_gid; do
      [[ -n $old_gid && $old_gid != "$gid" ]] || continue
      payload=$(jq -c --arg gid "$old_gid" '.[] | select(.groupId == $gid)' <<<"$groups")
      remaining=$(jq -c --argjson id "$id" '[.inboundIds[] | select(. != $id)]' <<<"$payload")
      if [[ $remaining == "[]" ]]; then
        api POST "hosts/del/$old_gid" '{}' >/dev/null
      else
        payload=$(jq -c --argjson ids "$remaining" '.inboundIds=$ids' <<<"$payload")
        api POST "hosts/update/$old_gid" "$payload" >/dev/null
      fi
    done < <(jq -r '.[].groupId' <<<"$groups")

    if [[ -n $gid ]]; then
      payload=$(jq -c --arg gid "$gid" --arg relay "$RELAY_DOMAIN" --argjson id "$id" '
        .[] | select(.groupId == $gid)
        | .inboundIds=[$id]
        | .remark="KIT relay MTProto"
        | .hosts=[$relay]
        | .port=443
        | .security="same"
        | .isDisabled=false
      ' <<<"$groups")
      api POST "hosts/update/$gid" "$payload" >/dev/null
    else
      payload=$(jq -nc --arg relay "$RELAY_DOMAIN" --argjson id "$id" '{
        inboundIds:[$id],
        remark:"KIT relay MTProto",
        hosts:[$relay],
        port:443,
        security:"same",
        isDisabled:false
      }')
      api POST "hosts/add" "$payload" >/dev/null
    fi
  done < <(jq -r '.[] | select(.enable == true and .protocol == "mtproto") | .id' <<<"$list")
}

lockdown_ufw() {
  command -v ufw >/dev/null || die "ufw is not installed"
  local nums n
  # Keep 80/tcp public for Let's Encrypt renewal of the origin name.
  nums=$(ufw status numbered | awk '
    /\[[[:space:]]*[0-9]+\]/ && ($0 ~ /443\/tcp/ || $0 ~ /443\/udp/ || $0 ~ /8443\/udp/ || $0 ~ /8444\/udp/) {
      s=$0; sub(/^\[[[:space:]]*/,"",s); sub(/\].*/,"",s); gsub(/[[:space:]]/,"",s); print s
    }' | sort -rn)
  for n in $nums; do ufw --force delete "$n" >/dev/null; done
  ufw allow from "$RELAY_IP" to any port 443 proto tcp >/dev/null
  ufw allow from "$RELAY_IP" to any port 443 proto udp >/dev/null
  ufw allow from "$RELAY_IP" to any port 8443 proto udp >/dev/null
  ufw allow from "$RELAY_IP" to any port 8444 proto udp >/dev/null
  ufw --force enable >/dev/null
}

activate() {
  local backup all sub_path sub_uri updated
  backup=$(backup_state)
  say "Backup: $backup"
  say "Updating inbound share/external addresses to $RELAY_DOMAIN"
  update_inbounds
  say "Ensuring MTProto public Host endpoint is $RELAY_DOMAIN:443"
  ensure_mtproto_relay_host

  all=$(api POST setting/all '{}')
  sub_path=$(jq -r '.subPath // "/sub/"' <<<"$all")
  [[ $sub_path == /* ]] || sub_path="/$sub_path"
  sub_uri="https://$RELAY_DOMAIN$sub_path"
  local mihomo_rules_url="https://raw.githubusercontent.com/MihailDenisov/roscomvpn-routing-custom/main/MIHOMO/3x-ui-routing.yaml"
  local sub_theme_dir="/etc/3x-ui/sub_templates/kit"
  install -d -m 755 "$sub_theme_dir"
  curl -fsSL --retry 3 \
    https://raw.githubusercontent.com/MihailDenisov/roscomvpn-routing-custom/main/3X-UI_KIT/sub-theme/index.html \
    -o "$sub_theme_dir/index.html"
  curl -fsSL --retry 3 \
    https://cdn.jsdelivr.net/npm/qrcode-generator@2.0.4/dist/qrcode.js \
    -o "$sub_theme_dir/qrcode.js"
  chmod 644 "$sub_theme_dir/index.html" "$sub_theme_dir/qrcode.js"
  say "3x-ui profile page: built-in URL + custom KIT subscription theme"

  updated=$(jq -c \
    --arg d "$RELAY_DOMAIN" \
    --arg u "$sub_uri" \
    --arg mr "$mihomo_rules_url" \
    --arg td "$sub_theme_dir" \
    '.subDomain=$d
     | .subURI=$u
     | .subClashEnable=true
     | .subClashAutoDetect=true
     | .subClashEnableRouting=true
     | .subClashRules=$mr
     | .subProfileMode="builtin"
     | .subThemeDir=$td' <<<"$all")
  api POST setting/update "$updated" >/dev/null
  systemctl restart x-ui

  # Harden public subscription/profile responses. The subscription URL is a bearer secret.
  if [[ -f /etc/nginx/conf.d/kit.conf ]]; then
    python3 - "$sub_path" <<'PY'
from pathlib import Path
import re, sys
p = Path("/etc/nginx/conf.d/kit.conf")
sub_path = sys.argv[1]
text = p.read_text()
pattern = re.compile(r'(location\s+' + re.escape(sub_path) + r'\s*\{.*?proxy_set_header\s+Host\s+\$host;)(.*?\n\s*\})', re.S)
m = pattern.search(text)
if not m:
    raise SystemExit(0)
head = m.group(1)
tail = m.group(2)
headers = '''
        add_header Cache-Control "no-store, no-cache, must-revalidate, private" always;
        add_header Pragma "no-cache" always;
        add_header Expires "0" always;
        add_header X-Robots-Tag "noindex, nofollow, noarchive" always;
        add_header Referrer-Policy "no-referrer" always;
        add_header X-Content-Type-Options "nosniff" always;'''
block = head
for line in headers.strip("\n").splitlines():
    key = line.strip().split(" ", 2)[1] if line.strip().startswith("add_header ") else ""
    if key and re.search(r'(?m)^\s*add_header\s+' + re.escape(key) + r'\b', m.group(0)):
        continue
    block += "\n" + line
block += tail
p.write_text(text[:m.start()] + block + text[m.end():])
PY
    nginx -t >/dev/null
    systemctl reload nginx
  fi

  update_kit_env "$sub_path"
  if [[ -f /etc/kit-sub/config.json ]]; then
    jq --arg h "$RELAY_DOMAIN" '.host=$h' /etc/kit-sub/config.json >/etc/kit-sub/config.json.tmp
    install -m 600 /etc/kit-sub/config.json.tmp /etc/kit-sub/config.json
    rm -f /etc/kit-sub/config.json.tmp
    # Always refresh the public subscription shim: it enforces relay endpoint
    # addresses while deliberately preserving SNI/Reality/TLS parameters.
    if [[ -d /usr/local/lib/kit-sub ]]; then
      curl -fsSL --retry 3 \
        https://raw.githubusercontent.com/MihailDenisov/roscomvpn-routing-custom/main/3X-UI_KIT/kit-sub.py \
        -o /usr/local/lib/kit-sub/kit_sub.py
      python3 -m py_compile /usr/local/lib/kit-sub/kit_sub.py
    fi
    systemctl restart kit-sub || true
  fi

  if [[ $LOCKDOWN == yes ]]; then
    say "Restricting MAIN VPN ports to relay IP $RELAY_IP"
    lockdown_ufw
  else
    warn "Direct MAIN access is still open. Re-run activate with --lockdown after clients are verified through relay."
  fi

  say "Subscription base is now: https://$RELAY_DOMAIN$sub_path"
  say "Mihomo routing: RoscomVPN + category-ads -> REJECT-DROP"
  say "Refresh FlClash/Mihomo subscription to receive routing and ad filtering."
}

status() {
  local cert="/etc/letsencrypt/live/$ORIGIN_DOMAIN/fullchain.pem"
  echo "Origin: $ORIGIN_DOMAIN"
  echo "Relay:  $RELAY_DOMAIN"
  echo "DNS:    $(resolved_relay_ip || true)"
  if [[ -s $cert ]]; then
    openssl x509 -in "$cert" -noout -dates -ext subjectAltName
  fi
  echo
  local inbounds mtid
  inbounds=$(api GET inbounds/list)
  jq '[.[] | {id,remark,protocol,port,shareAddrStrategy,shareAddr,externalProxy:(if (.streamSettings|type)=="object" then (.streamSettings.externalProxy // null) elif (.streamSettings|type)=="string" and (.streamSettings|length)>0 then ((.streamSettings|fromjson).externalProxy // null) else null end)}]' <<<"$inbounds"
  while read -r mtid; do
    [[ -n $mtid ]] || continue
    echo
    echo "MTProto Hosts (inbound $mtid):"
    api GET "hosts/byInbound/$mtid" | jq '[.[] | {groupId,remark,hosts,port,security,isDisabled}]'
  done < <(jq -r '.[] | select(.protocol == "mtproto") | .id' <<<"$inbounds")
  echo
  command -v ufw >/dev/null && ufw status numbered || true
}

case "$ACTION" in
  prepare) prepare ;;
  activate) activate ;;
  status) status ;;
esac
