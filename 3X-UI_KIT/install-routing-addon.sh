#!/usr/bin/env bash
set -euo pipefail

ROUTING_URL="${ROUTING_URL:-https://raw.githubusercontent.com/MihailDenisov/roscomvpn-routing-custom/main/HAPP/DEFAULT-CUSTOM.DEEPLINK}"
KIT_SUB_URL="https://raw.githubusercontent.com/MihailDenisov/roscomvpn-routing-custom/main/3X-UI_KIT/kit-sub.py"
KIT_SUB="/usr/local/lib/kit-sub/kit_sub.py"
CONF="/etc/kit-sub/config.json"

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Запустите от root" >&2
  exit 1
fi
if [[ ! -f "$CONF" ]]; then
  echo "Не найден $CONF. Сначала установите 3X-UI_KIT с доверенным сертификатом/kit-sub." >&2
  exit 1
fi

command -v jq >/dev/null || { apt-get update -qq && apt-get install -y -qq jq; }
install -d -m 755 "$(dirname "$KIT_SUB")"
curl -fsSL --retry 3 -o "$KIT_SUB.tmp" "$KIT_SUB_URL"
python3 -c 'import ast,sys; ast.parse(open(sys.argv[1],encoding="utf-8").read())' "$KIT_SUB.tmp"
install -m 644 "$KIT_SUB.tmp" "$KIT_SUB"
rm -f "$KIT_SUB.tmp"

tmp=$(mktemp)
jq --arg url "$ROUTING_URL" '
  .routing_enable = true
  | .routing_url = $url
  | .routing_ttl = 600
' "$CONF" >"$tmp"
install -m 600 "$tmp" "$CONF"
rm -f "$tmp"

systemctl restart kit-sub
sleep 1
systemctl --no-pager --full status kit-sub || true
echo
echo "RoscomVPN routing включён для HAPP."
echo "Routing URL: $ROUTING_URL"
