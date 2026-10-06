#!/usr/bin/env bash
# Reconcile one shared traffic allowance across 3x-ui transports and TgWebProxy.
set -Eeuo pipefail
exec 9>/run/lock/kit-tgweb-reconcile.lock
flock -n 9 || exit 0

XUI_ENV=/etc/x-ui/install-result.env
KIT_ENV=/etc/kit/kit.env
TGWEB_ENV=/etc/kit/tgweb.env
[[ -f $XUI_ENV && -f $KIT_ENV && -f $TGWEB_ENV ]] || exit 0
# shellcheck disable=SC1090
. "$XUI_ENV"
# shellcheck disable=SC1090
. "$KIT_ENV"
# shellcheck disable=SC1090
. "$TGWEB_ENV"
[[ -s $TGWEB_TOKEN_FILE ]] || exit 0
TOKEN=$(cat "$TGWEB_TOKEN_FILE")

API=""
for scheme in https http; do
  candidate="$scheme://127.0.0.1:$XUI_PANEL_PORT/$XUI_WEB_BASE_PATH/panel/api"
  if curl -fsk -m 5 -o /dev/null -H "Authorization: Bearer $XUI_API_TOKEN" "$candidate/server/getNewUUID" 2>/dev/null; then
    API=$candidate
    break
  fi
done
[[ -n $API ]] || exit 1

xget() {
  curl -sSk -m 20 -H "Authorization: Bearer $XUI_API_TOKEN" "$API/$1" |
    jq -ce 'select(.success == true) | .obj'
}
xpost() {
  curl -sSk -m 20 -H "Authorization: Bearer $XUI_API_TOKEN" -H 'Content-Type: application/json' -X POST -d "$2" "$API/$1" |
    jq -e 'select(.success == true)' >/dev/null
}
wget_clients() {
  curl -fsS -m 10 -H "Authorization: Bearer $TOKEN" "$TGWEB_ADMIN/clients" |
    jq -c --arg d "$TGWEB_DOMAIN" 'map(select(.domain == $d))[0].clients // []'
}
wput_clients() {
  curl -fsS -m 10 -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -X PUT     -d "$(jq -nc --arg d "$TGWEB_DOMAIN" --argjson c "$1" '{domain:$d,clients:$c}')" "$TGWEB_ADMIN/clients" >/dev/null
}

xc=$(xget clients/list | jq -c 'if type == "array" then . else .clients end')
wc=$(wget_clients)
now_ms=$(($(date +%s) * 1000))
changed=no

# TgWeb clients are keyed by the primary kit email. AmneziaWG shadow records
# contribute usage but never get their own TgWeb capability.
while IFS= read -r name; do
  [[ -n $name ]] || continue
  primary=$(jq -c --arg n "$name" 'map(select(.email == $n))[0] // empty' <<<"$xc")
  [[ -n $primary ]] || continue

  total=$(jq -r '.totalGB // 0' <<<"$primary")
  expiry=$(jq -r '.expiryTime // 0' <<<"$primary")
  panel_enabled=$(jq -r '.enable // false' <<<"$primary")
  # New patched 3x-ui is the source of truth. During the transition only,
  # fall back to the legacy comment marker when externalInboundKeys is absent.
  attached=false
  if jq -e 'has("externalInboundKeys")' <<<"$primary" >/dev/null; then
    jq -e '(.externalInboundKeys // []) | index("tgweb") != null' <<<"$primary" >/dev/null && attached=true
  else
    comment=$(jq -r '.comment // ""' <<<"$primary")
    [[ $comment != *"[tgweb:off]"* ]] && attached=true
  fi
  vpn_used=$(jq -r --arg n "$name" '[.[] | select(.email == $n or (.email | test("^" + $n + "-awg[0-9]*$"))) | ((.traffic.up // 0) + (.traffic.down // 0))] | add // 0' <<<"$xc")
  existing=$(jq -c --arg n "$name" 'map(select(.name == $n))[0] // empty' <<<"$wc")
  web_used=$(jq -r --arg n "$name" 'map(select(.name == $n))[0] | ((.bytes_up // 0) + (.bytes_down // 0)) // 0' <<<"$wc")

  allowed=true
  [[ $panel_enabled == true ]] || allowed=false
  [[ $attached == true ]] || allowed=false
  ((expiry == 0 || expiry > now_ms)) || allowed=false
  if ((total > 0 && vpn_used + web_used >= total)); then
    allowed=false
  fi

  # TgWeb's own quota is absolute usage on that service. Set it to the
  # remaining shared allowance plus its already-consumed WEB bytes:
  # web_quota = total - vpn_used.
  web_quota=0
  if ((total > 0)); then
    web_quota=$((total - vpn_used))
    ((web_quota < 1)) && web_quota=1
  fi
  exp_s=0; ((expiry > 0)) && exp_s=$((expiry / 1000))
  if [[ -n $existing ]]; then
    # Keep the existing secret even when detached; detached means disabled.
    wc_new=$(jq -c --arg n "$name" --argjson e "$allowed" --argjson x "$exp_s" --argjson q "$web_quota" '
      map(if .name == $n then .enabled=$e | .expires_unix=$x | .quota_bytes=$q else . end)' <<<"$wc")
  elif [[ $attached == true ]]; then
    # Only an explicit desired attachment is allowed to mint a new credential.
    secret=$(openssl rand -hex 16)
    wc_new=$(jq -c --arg n "$name" --arg s "$secret" --argjson e "$allowed" --argjson x "$exp_s" --argjson q "$web_quota" '
      map(select(.name != "_bootstrap")) + [{name:$n,secret:$s,enabled:$e,expires_unix:$x,quota_bytes:$q}]' <<<"$wc")
  else
    wc_new=$wc
  fi
  if [[ $wc_new != "$wc" ]]; then wc=$wc_new; changed=yes; fi

  # If WEB usage exhausted the shared allowance, stop all 3x-ui transports too.
  if [[ $allowed == false && $panel_enabled == true && $total -gt 0 && $((vpn_used + web_used)) -ge $total ]]; then
    while IFS= read -r email; do
      [[ -n $email ]] || continue
      rec=$(jq -c --arg e "$email" 'map(select(.email == $e))[0]' <<<"$xc")
      body=$(jq -c '{email, subId, flow, totalGB, expiryTime, limitIp, enable, comment} | .enable=false' <<<"$rec")
      xpost "clients/update/$email" "$body"
    done < <(jq -r --arg n "$name" '.[] | select(.email == $n or (.email | test("^" + $n + "-awg[0-9]*$"))) | .email' <<<"$xc")
  fi
done < <(jq -r '.[] | select(.subId != null) | .email | select(test("-awg[0-9]*$") | not)' <<<"$xc" | sort -u)

# A TgWeb credential whose primary 3x-ui identity was deleted must not remain
# usable. Disable (never delete/rotate) such runtime entries so a transient
# TgWeb outage or later recovery cannot resurrect an orphaned secret.  This is
# intentionally conservative: migration should map every legitimate existing
# TgWeb client to a 3x-ui identity before the patched panel is deployed.
while IFS= read -r orphan; do
  [[ -n $orphan && $orphan != "_bootstrap" ]] || continue
  if ! jq -e --arg n "$orphan" '.[] | select(.subId != null and .email == $n)' <<<"$xc" >/dev/null; then
    wc_new=$(jq -c --arg n "$orphan" '
      map(if .name == $n then .enabled=false else . end)' <<<"$wc")
    if [[ $wc_new != "$wc" ]]; then wc=$wc_new; changed=yes; fi
  fi
done < <(jq -r '.[].name // empty' <<<"$wc")

[[ $changed == yes ]] && wput_clients "$wc"
