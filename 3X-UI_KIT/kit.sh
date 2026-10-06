#!/usr/bin/env bash
# kit — пользователи 3X-UI KIT: один пользователь сразу на всех протоколах.
# https://github.com/itsnotkubrick/3X-UI_KIT
#
#   kit user add имя [--gb 50] [--days 30] [--devices 3]
#   kit user list | link имя | limit имя [--gb N] [--days N] | off имя | on имя | del имя

set -Eeuo pipefail
export LC_ALL=C.UTF-8  # ширина колонок по символам, а не байтам

XUI_ENV=/etc/x-ui/install-result.env
KIT_ENV=/etc/kit/kit.env
ROUTING_DEFAULT="https://raw.githubusercontent.com/MihailDenisov/roscomvpn-routing-custom/main/HAPP/DEFAULT-CUSTOM.DEEPLINK"

if [[ -t 1 ]]; then
  G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; B=$'\e[1m'; D=$'\e[2m'; N=$'\e[0m'
else
  G=; Y=; R=; B=; D=; N=
fi
say()  { printf '%s\n' "${G}==>${N} $*"; }
die()  { printf '%s\n' "${R}✗${N}  $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Запустите от root: sudo -i, затем команду ещё раз."
[[ -f $XUI_ENV && -f $KIT_ENV ]] || die "Не найдена установка — сначала поставьте сервер скриптом 3x-ui.sh."
# shellcheck disable=SC1090
. "$XUI_ENV"; . "$KIT_ENV"

TGWEB_ENV=/etc/kit/tgweb.env
TGWEB_ENABLED=no
if [[ -f $TGWEB_ENV ]]; then
  # shellcheck disable=SC1090
  . "$TGWEB_ENV"
  if [[ -n ${TGWEB_DOMAIN:-} && -n ${TGWEB_ADMIN:-} && -s ${TGWEB_TOKEN_FILE:-/nonexistent} ]]; then
    TGWEB_TOKEN=$(cat "$TGWEB_TOKEN_FILE")
    TGWEB_ENABLED=yes
  fi
fi

tgweb_api() { # GET | PUT [json]
  [[ $TGWEB_ENABLED == yes ]] || return 0
  if [[ $1 == GET ]]; then
    curl -fsS -m 10 -H "Authorization: Bearer $TGWEB_TOKEN" "$TGWEB_ADMIN/clients"
  else
    curl -fsS -m 10 -H "Authorization: Bearer $TGWEB_TOKEN" -H 'Content-Type: application/json' -X PUT -d "$2" "$TGWEB_ADMIN/clients" >/dev/null
  fi
}

tgweb_clients() {
  [[ $TGWEB_ENABLED == yes ]] || { echo '[]'; return; }
  tgweb_api GET | jq -c --arg d "$TGWEB_DOMAIN" 'map(select(.domain == $d))[0].clients // []'
}

tgweb_sync_user() { # name; preserve secret if it already exists
  [[ $TGWEB_ENABLED == yes ]] || return 0
  local name=$1 rec all used total exp enabled quota payload
  rec=$(client "$name"); [[ -n $rec ]] || return 0
  all=$(tgweb_clients | jq -c 'map(select(.name != "_bootstrap"))')
  used=$(jq -r '(.traffic.up // 0) + (.traffic.down // 0)' <<<"$rec")
  total=$(jq -r '.totalGB // 0' <<<"$rec")
  exp=$(jq -r '.expiryTime // 0' <<<"$rec")
  enabled=$(jq -r '.enable // false' <<<"$rec")
  ((exp > 0)) && exp=$((exp / 1000))
  quota=0
  if ((total > 0)); then
    quota=$((total - used))
    ((quota < 1)) && quota=1
  fi
  if jq -e --arg n "$name" 'any(.[]; .name == $n)' <<<"$all" >/dev/null; then
    all=$(jq -c --arg n "$name" --argjson e "$enabled" --argjson x "$exp" --argjson q "$quota" '
      map(if .name == $n then .enabled=$e | .expires_unix=$x | .quota_bytes=$q else . end)' <<<"$all")
  else
    local sec
    sec=$(openssl rand -hex 16)
    all=$(jq -c --arg n "$name" --arg s "$sec" --argjson e "$enabled" --argjson x "$exp" --argjson q "$quota" '
      . + [{name:$n,secret:$s,enabled:$e,expires_unix:$x,quota_bytes:$q}]' <<<"$all")
  fi
  payload=$(jq -nc --arg d "$TGWEB_DOMAIN" --argjson c "$all" '{domain:$d,clients:$c}')
  (
    flock -x 9
    # Re-read under the lock so concurrent kit invocations cannot overwrite one another.
    local fresh existing
    fresh=$(tgweb_clients)
    existing=$(jq -c --arg n "$name" 'map(select(.name == $n))[0] // empty' <<<"$all")
    fresh=$(jq -c --arg n "$name" --argjson v "$existing" 'map(select(.name != $n)) + [$v]' <<<"$fresh")
    tgweb_api PUT "$(jq -nc --arg d "$TGWEB_DOMAIN" --argjson c "$fresh" '{domain:$d,clients:$c}')"
  ) 9>/run/lock/kit-tgweb.lock
}

tgweb_delete_user() {
  [[ $TGWEB_ENABLED == yes ]] || return 0
  local name=$1
  (
    flock -x 9
    local all
    all=$(tgweb_clients | jq -c --arg n "$name" 'map(select(.name != $n))')
    # TgWebProxy requires at least one keyring entry. The installer creates
    # _bootstrap disabled; keep it when the last real user is removed.
    if [[ $(jq length <<<"$all") -eq 0 ]]; then
      local sec
      sec=$(cat /etc/tgwebproxy/bootstrap.secret)
      all=$(jq -nc --arg s "$sec" '[{name:"_bootstrap",secret:$s,enabled:false}]')
    fi
    tgweb_api PUT "$(jq -nc --arg d "$TGWEB_DOMAIN" --argjson c "$all" '{domain:$d,clients:$c}')"
  ) 9>/run/lock/kit-tgweb.lock
}

tgweb_link() {
  [[ $TGWEB_ENABLED == yes ]] || return 0
  local name=$1 sec
  sec=$(tgweb_clients | jq -r --arg n "$name" 'map(select(.name == $n))[0].secret // empty')
  [[ -n $sec ]] && printf 'tg://webproxy?server=%s&secret=%s\n' "$TGWEB_DOMAIN" "$sec"
}

API=""
for scheme in https http; do
  API="$scheme://127.0.0.1:$XUI_PANEL_PORT/$XUI_WEB_BASE_PATH/panel/api"
  curl -fsk -m 5 -o /dev/null -H "Authorization: Bearer $XUI_API_TOKEN" "$API/server/getNewUUID" 2>/dev/null && break
done

api() { # METHOD path [json]
  local out
  if [[ $1 == GET ]]; then
    out=$(curl -sSk -m 20 -H "Authorization: Bearer $XUI_API_TOKEN" "$API/$2")
  else
    out=$(curl -sSk -m 20 -H "Authorization: Bearer $XUI_API_TOKEN" -H 'Content-Type: application/json' -X "$1" -d "${3:-{\}}" "$API/$2")
  fi
  [[ $(jq -r '.success' <<<"$out" 2>/dev/null) == true ]] || die "Панель ответила ошибкой: $(jq -r '.msg // .' <<<"$out" 2>/dev/null | head -c 300)"
  jq -c '.obj' <<<"$out"
}

# В 3X-UI 3.x у клиента одна запись и в ней одна пара ключей WireGuard и один адрес. Если
# клиент подключён к двум AmneziaWG, в подписку для обоих уходят ключ и адрес одного из них,
# и второй сервер клиента не узнаёт (проверено 2026-09-27). Поэтому к первому AmneziaWG
# подключаем основную запись, а ко второму — запись-«двойник» «имя-awg» с подпиской «<id>-awg»
# (subId в 3X-UI обязан быть уникальным) и теми же лимитами; kit-sub подмешивает её в Clash.
awg_ids() { api GET inbounds/list | jq -r '[.[] | select(.protocol == "amneziawg") | .id] | sort | .[]'; }
non_awg_ids() { api GET inbounds/list | jq -c '[.[] | select(.protocol != "amneziawg") | .id]'; }

awg_attach() { # имя subId [лимит-байт] [срок-мс] [устройств]
  local name=$1 sid=$2 total=${3:-0} exp=${4:-0} lim=${5:-0} n=1 id email have
  have=$(api GET clients/list | jq -c 'if type == "array" then . else .clients end')
  for id in $(awg_ids); do
    local esid=$sid
    if ((n == 1)); then email=$name
    elif ((n == 2)); then email="$name-awg"; esid="$sid-awg"
    else email="$name-awg$n"; esid="$sid-awg$n"; fi
    n=$((n + 1))
    if jq -e --arg e "$email" --argjson i "$id" 'any(.[]; .email == $e and ((.inboundIds // []) | index($i)))' <<<"$have" >/dev/null; then
      continue
    elif jq -e --arg e "$email" 'any(.[]; .email == $e)' <<<"$have" >/dev/null; then
      api POST "clients/$email/attach" "$(jq -nc --argjson i "$id" '{inboundIds: [$i]}')" >/dev/null
    else
      api POST clients/add "$(jq -nc --arg e "$email" --arg s "$esid" --argjson t "$total" --argjson x "$exp" --argjson l "$lim" --argjson i "$id" \
        '{client: {email: $e, subId: $s, flow: "xtls-rprx-vision", totalGB: $t, expiryTime: $x, limitIp: $l, enable: true, comment: "kit"}, inboundIds: [$i]}')" >/dev/null
    fi
  done
}

clients() { api GET clients/list | jq -c 'if type == "array" then . else .clients end'; }
client() { clients | jq -c --arg e "$1" 'map(select(.email == $e))[0] // empty'; }
# Все записи пользователя: основная и «двойники» для AmneziaWG («имя-awgN»).
emails_of() { clients | jq -r --arg e "$1" '.[] | select(.email == $e or (.email | test("^" + $e + "-awg[0-9]*$"))) | .email'; }
valid_name() { [[ $1 =~ ^[A-Za-z0-9_.-]{1,32}$ ]] || die "Имя: латиница, цифры, _ . - (до 32 символов)."; }
rand_id() { openssl rand -base64 48 | tr -dc 'a-z0-9' | head -c 16; }

gb_bytes() { [[ $1 =~ ^[0-9]+$ ]] || die "--gb: целое число гигабайт"; echo $(($1 * 1073741824)); }
days_ms() { [[ $1 =~ ^[0-9]+$ ]] || die "--days: целое число дней"; ((${1} == 0)) && { echo 0; return; }; echo $((($(date +%s) + $1 * 86400) * 1000)); }

human() { # байты → «1.2 ГБ»
  awk -v b="$1" 'BEGIN { split("Б КБ МБ ГБ ТБ", u, " "); i = 1; while (b >= 1024 && i < 5) { b /= 1024; i++ }
    printf (i == 1 ? "%d %s" : "%.1f %s"), b, u[i] }'
}

sub_url() { echo "${SUB_BASE}$1"; }

show_link() { # имя subId
  local url
  url=$(sub_url "$2")
  echo
  echo "Подписка ${B}$1${N} — все протоколы одной ссылкой. Вставьте в Happ, Hiddify, Karing,"
  echo "v2rayN, Clash Verge или FlClash:"
  echo
  echo "$url"
  echo
  command -v qrencode >/dev/null && qrencode -t ANSIUTF8 -m 1 "$url"
  echo "${D}AmneziaVPN и Telegram: kit user link $1 --all — отдельные ссылки vpn:// и tg://${N}"
}

cmd_add() {
  local name=${1:-} gb=0 days=0 devices=0
  valid_name "$name"; shift
  while [[ $# -gt 0 ]]; do
    case $1 in
      --gb) gb=$2; shift 2 ;;
      --days) days=$2; shift 2 ;;
      --devices) devices=$2; shift 2 ;;
      *) die "Неизвестный параметр: $1" ;;
    esac
  done
  [[ -z $(client "$name") ]] || die "Пользователь $name уже есть. Ссылка: kit user link $name"
  local ids sid body
  ids=$(non_awg_ids)
  [[ $ids != "[]" ]] || die "На сервере нет подключений."
  sid=$(rand_id)
  body=$(jq -nc --arg e "$name" --arg s "$sid" --argjson t "$(gb_bytes "$gb")" --argjson x "$(days_ms "$days")" \
    --argjson ip "$devices" --argjson ids "$ids" '{client: {email: $e, subId: $s, flow: "xtls-rprx-vision", totalGB: $t, expiryTime: $x,
    limitIp: $ip, enable: true, comment: "kit"}, inboundIds: $ids}')
  api POST clients/add "$body" >/dev/null
  awg_attach "$name" "$sid" "$(gb_bytes "$gb")" "$(days_ms "$days")" "$devices"
  tgweb_sync_user "$name"
  say "Пользователь $name добавлен во все протоколы ($(api GET inbounds/list | jq length))$( ((gb)) && echo ", лимит $gb ГБ")$( ((days)) && echo ", на $days дн")."
  show_link "$name" "$sid"
}

cmd_link() {
  local name=${1:-} all=${2:-} c
  valid_name "$name"
  c=$(client "$name"); [[ -n $c ]] || die "Нет пользователя $name"
  show_link "$name" "$(jq -r '.subId' <<<"$c")"
  if [[ $all == --all ]]; then
    local sid raw out="" suffix
    sid=$(jq -r '.subId' <<<"$c")
    for suffix in "" -awg; do
      raw=$(curl -fsSk -m 10 -A "v2rayN/7" -H "Host: $HOST" "http://127.0.0.1:$SUB_INTERNAL$SUB_PATH$sid$suffix" 2>/dev/null || true)
      grep -q '://' <<<"$raw" || raw=$(base64 -d <<<"$raw" 2>/dev/null || true)
      out+=$(grep -E '^(vpn|tg)://' <<<"$raw" || true)$'\n'
    done
    # В SINGLE-режиме MTProto снаружи всегда приходит на общий TCP/443.
    # Не полагаемся на внутренний порт inbound: 3x-ui/externalProxy мог вернуть
    # любое сохранённое значение.
    if [[ ${SINGLE:-no} == yes ]]; then
      out=$(sed -E '/^tg:\/\/proxy\?/ s/([?&]port=)[0-9]+/\\1443/' <<<"$out")
    fi
    out+=$(tgweb_link "$name")
}

cmd_list() {
  local now
  now=$(($(date +%s) * 1000))
  clients | jq -r --argjson now "$now" '
    map(select(.subId != null)) | group_by(.subId | sub("-awg[0-9]*$"; "")) | map(sort_by(.email | length) as $g | $g[0] + {used: ([$g[] | (.traffic.up // 0) + (.traffic.down // 0)] | add),
      seen: ([$g[] | .traffic.lastOnline // 0] | max)}) | sort_by(.email)[]
    | [.email, .used, (.totalGB // 0), (.expiryTime // 0), .enable, .seen] | @tsv' |
  {
    printf "${B}%-18s %-22s %-14s %-10s %s${N}\n" "Пользователь" "Трафик" "До" "Статус" "Был в сети"
    while IFS=$'\t' read -r email used total exp en last; do
      local tr till st seen
      tr="$(human "$used")"; ((total > 0)) && tr="$tr / $(human "$total")"
      if ((exp > 0)); then till=$(date -d "@$((exp / 1000))" +%d.%m.%Y); else till="бессрочно"; fi
      if [[ $en != true ]]; then st="${R}выключен${N}"
      elif ((exp > 0 && exp < $(date +%s) * 1000)); then st="${Y}истёк${N}"
      elif ((total > 0 && used >= total)); then st="${Y}лимит${N}"
      else st="${G}активен${N}"; fi
      if ((last > 0)); then seen=$(date -d "@$((last / 1000))" '+%d.%m %H:%M'); else seen="—"; fi
      printf "%-18s %-22s %-14s %-19s %s\n" "$email" "$tr" "$till" "$st" "$seen"
    done
  }
}

# Меняет все записи пользователя (основную и «двойников» AmneziaWG), каждую — от её собственных данных.
update_user() { # имя jq-фильтр [аргументы jq...]
  local name=$1 filter=$2 e rec body
  shift 2
  for e in $(emails_of "$name"); do
    rec=$(client "$e")
    body=$(jq -c "$@" "{email, subId, flow, totalGB, expiryTime, limitIp, enable, comment} | $filter" <<<"$rec")
    api POST "clients/update/$e" "$body" >/dev/null
  done
}

cmd_repair() {
  local name=${1:-} e rec body
  valid_name "$name"
  [[ -n $(client "$name") ]] || die "Нет пользователя $name"
  for e in $(emails_of "$name"); do
    rec=$(client "$e")
    body=$(jq -c '{email, subId, flow, totalGB, expiryTime, limitIp, enable, comment}
      | .flow = "xtls-rprx-vision"' <<<"$rec")
    api POST "clients/update/$e" "$body" >/dev/null
  done
  say "Для $name восстановлен flow xtls-rprx-vision. Обновите подписку в клиенте."
}

cmd_limit() {
  local name=${1:-} f="." gb="" days="" dev=""
  valid_name "$name"; shift
  [[ -n $(client "$name") ]] || die "Нет пользователя $name"
  while [[ $# -gt 0 ]]; do
    case $1 in
      --gb) gb=$(gb_bytes "$2"); f+=" | .totalGB = \$gb"; shift 2 ;;
      --days) days=$(days_ms "$2"); f+=" | .expiryTime = \$days"; shift 2 ;;
      --devices) [[ $2 =~ ^[0-9]+$ ]] || die "--devices: целое число"; dev=$2; f+=" | .limitIp = \$dev"; shift 2 ;;
      *) die "Неизвестный параметр: $1" ;;
    esac
  done
  update_user "$name" "$f" --argjson gb "${gb:-0}" --argjson days "${days:-0}" --argjson dev "${dev:-0}"
  tgweb_sync_user "$name"
  say "Лимиты $name обновлены (0 — без ограничений)."
}

cmd_toggle() { # имя true|false
  valid_name "$1"
  [[ -n $(client "$1") ]] || die "Нет пользователя $1"
  update_user "$1" ".enable = \$v" --argjson v "$2"
  tgweb_sync_user "$1"
  if [[ $2 == true ]]; then say "Пользователь $1 включён."; else say "Пользователь $1 выключен — подписка и подключения не работают."; fi
}

cmd_del() {
  local name=${1:-} ans=""
  valid_name "$name"
  [[ -n $(client "$name") ]] || die "Нет пользователя $name"
  if [[ ${2:-} != -y && -t 0 ]]; then
    read -rp "Удалить $name со всех протоколов? [y/N] " ans
    [[ $ans =~ ^[yYдД]$ ]] || { echo "Отменено."; return; }
  fi
  local e
  tgweb_delete_user "$name"
  for e in $(emails_of "$name"); do api POST "clients/del/$e" >/dev/null; done
  say "Пользователь $name удалён, его подписка больше не работает."
}


cmd_paths() {
  local panel_host="${DOMAIN:-${HOST:-}}"
  local panel_path="/${XUI_WEB_BASE_PATH#/}"
  panel_path="${panel_path%/}/"

  local panel_url
  if [[ ${SINGLE:-no} == yes ]]; then
    panel_url="https://$panel_host$panel_path"
  elif [[ -n ${XUI_PANEL_PORT:-} ]]; then
    panel_url="https://$panel_host:$XUI_PANEL_PORT$panel_path"
  else
    panel_url="$panel_path"
  fi

  local sub_base="${SUB_BASE:-}"
  local routing="${ROUTING_URL:-$ROUTING_DEFAULT}"
  local fallback="${FALLBACK_URL:-}"

  echo
  printf '%-18s %s\n' "Panel URL:" "$panel_url"
  [[ -n $sub_base ]] && printf '%-18s %s\n' "Subscription base:" "$sub_base"
  [[ -n ${SUB_PATH:-} ]] && printf '%-18s %s\n' "Subscription path:" "$SUB_PATH"
  printf '%-18s %s\n' "Routing URL:" "$routing"
  if [[ -n $fallback ]]; then
    printf '%-18s %s\n' "Fallback:" "$fallback"
  else
    printf '%-18s %s\n' "Fallback:" "local landing page"
  fi
  [[ -n ${DOMAIN:-} ]] && printf '%-18s %s\n' "Domain:" "$DOMAIN"
  echo
}

usage() {
  cat <<EOF
${B}kit${N} — управление 3X-UI KIT

  kit paths                                               показать пути панели/подписки и routing

  kit user add имя [--gb 50] [--days 30] [--devices 3]   добавить и показать подписку
  kit user list                                           трафик, срок, статус
  kit user link имя [--all]                               подписка и QR; --all — ещё vpn:// и tg://
  kit user limit имя [--gb N] [--days N] [--devices N]    изменить лимиты (0 — без ограничений)
  kit user repair имя                                      восстановить REALITY flow у старого пользователя
  kit user off имя  /  kit user on имя                    выключить и включить
  kit user del имя                                        удалить
EOF
}

case "${1:-} ${2:-}" in
  "paths ") cmd_paths ;;
  "user add") shift 2; cmd_add "$@" ;;
  "user list") cmd_list ;;
  "user link") shift 2; cmd_link "$@" ;;
  "user limit") shift 2; cmd_limit "$@" ;;
  "user repair") shift 2; cmd_repair "$@" ;;
  "user off") cmd_toggle "${3:-}" false ;;
  "user on") cmd_toggle "${3:-}" true ;;
  "user del") shift 2; cmd_del "$@" ;;
  *) usage ;;
esac
\n'
    echo; grep . <<<"$out" || echo "Отдельных ссылок нет."
  fi
}

cmd_list() {
  local now
  now=$(($(date +%s) * 1000))
  clients | jq -r --argjson now "$now" '
    map(select(.subId != null)) | group_by(.subId | sub("-awg[0-9]*$"; "")) | map(sort_by(.email | length) as $g | $g[0] + {used: ([$g[] | (.traffic.up // 0) + (.traffic.down // 0)] | add),
      seen: ([$g[] | .traffic.lastOnline // 0] | max)}) | sort_by(.email)[]
    | [.email, .used, (.totalGB // 0), (.expiryTime // 0), .enable, .seen] | @tsv' |
  {
    printf "${B}%-18s %-22s %-14s %-10s %s${N}\n" "Пользователь" "Трафик" "До" "Статус" "Был в сети"
    while IFS=$'\t' read -r email used total exp en last; do
      local tr till st seen
      tr="$(human "$used")"; ((total > 0)) && tr="$tr / $(human "$total")"
      if ((exp > 0)); then till=$(date -d "@$((exp / 1000))" +%d.%m.%Y); else till="бессрочно"; fi
      if [[ $en != true ]]; then st="${R}выключен${N}"
      elif ((exp > 0 && exp < $(date +%s) * 1000)); then st="${Y}истёк${N}"
      elif ((total > 0 && used >= total)); then st="${Y}лимит${N}"
      else st="${G}активен${N}"; fi
      if ((last > 0)); then seen=$(date -d "@$((last / 1000))" '+%d.%m %H:%M'); else seen="—"; fi
      printf "%-18s %-22s %-14s %-19s %s\n" "$email" "$tr" "$till" "$st" "$seen"
    done
  }
}

# Меняет все записи пользователя (основную и «двойников» AmneziaWG), каждую — от её собственных данных.
update_user() { # имя jq-фильтр [аргументы jq...]
  local name=$1 filter=$2 e rec body
  shift 2
  for e in $(emails_of "$name"); do
    rec=$(client "$e")
    body=$(jq -c "$@" "{email, subId, flow, totalGB, expiryTime, limitIp, enable, comment} | $filter" <<<"$rec")
    api POST "clients/update/$e" "$body" >/dev/null
  done
}

cmd_repair() {
  local name=${1:-} e rec body
  valid_name "$name"
  [[ -n $(client "$name") ]] || die "Нет пользователя $name"
  for e in $(emails_of "$name"); do
    rec=$(client "$e")
    body=$(jq -c '{email, subId, flow, totalGB, expiryTime, limitIp, enable, comment}
      | .flow = "xtls-rprx-vision"' <<<"$rec")
    api POST "clients/update/$e" "$body" >/dev/null
  done
  say "Для $name восстановлен flow xtls-rprx-vision. Обновите подписку в клиенте."
}

cmd_limit() {
  local name=${1:-} f="." gb="" days="" dev=""
  valid_name "$name"; shift
  [[ -n $(client "$name") ]] || die "Нет пользователя $name"
  while [[ $# -gt 0 ]]; do
    case $1 in
      --gb) gb=$(gb_bytes "$2"); f+=" | .totalGB = \$gb"; shift 2 ;;
      --days) days=$(days_ms "$2"); f+=" | .expiryTime = \$days"; shift 2 ;;
      --devices) [[ $2 =~ ^[0-9]+$ ]] || die "--devices: целое число"; dev=$2; f+=" | .limitIp = \$dev"; shift 2 ;;
      *) die "Неизвестный параметр: $1" ;;
    esac
  done
  update_user "$name" "$f" --argjson gb "${gb:-0}" --argjson days "${days:-0}" --argjson dev "${dev:-0}"
  say "Лимиты $name обновлены (0 — без ограничений)."
}

cmd_toggle() { # имя true|false
  valid_name "$1"
  [[ -n $(client "$1") ]] || die "Нет пользователя $1"
  update_user "$1" ".enable = \$v" --argjson v "$2"
  if [[ $2 == true ]]; then say "Пользователь $1 включён."; else say "Пользователь $1 выключен — подписка и подключения не работают."; fi
}

cmd_del() {
  local name=${1:-} ans=""
  valid_name "$name"
  [[ -n $(client "$name") ]] || die "Нет пользователя $name"
  if [[ ${2:-} != -y && -t 0 ]]; then
    read -rp "Удалить $name со всех протоколов? [y/N] " ans
    [[ $ans =~ ^[yYдД]$ ]] || { echo "Отменено."; return; }
  fi
  local e
  for e in $(emails_of "$name"); do api POST "clients/del/$e" >/dev/null; done
  say "Пользователь $name удалён, его подписка больше не работает."
}


cmd_paths() {
  local panel_host="${DOMAIN:-${HOST:-}}"
  local panel_path="/${XUI_WEB_BASE_PATH#/}"
  panel_path="${panel_path%/}/"

  local panel_url
  if [[ ${SINGLE:-no} == yes ]]; then
    panel_url="https://$panel_host$panel_path"
  elif [[ -n ${XUI_PANEL_PORT:-} ]]; then
    panel_url="https://$panel_host:$XUI_PANEL_PORT$panel_path"
  else
    panel_url="$panel_path"
  fi

  local sub_base="${SUB_BASE:-}"
  local routing="${ROUTING_URL:-$ROUTING_DEFAULT}"
  local fallback="${FALLBACK_URL:-}"

  echo
  printf '%-18s %s\n' "Panel URL:" "$panel_url"
  [[ -n $sub_base ]] && printf '%-18s %s\n' "Subscription base:" "$sub_base"
  [[ -n ${SUB_PATH:-} ]] && printf '%-18s %s\n' "Subscription path:" "$SUB_PATH"
  printf '%-18s %s\n' "Routing URL:" "$routing"
  if [[ -n $fallback ]]; then
    printf '%-18s %s\n' "Fallback:" "$fallback"
  else
    printf '%-18s %s\n' "Fallback:" "local landing page"
  fi
  [[ -n ${DOMAIN:-} ]] && printf '%-18s %s\n' "Domain:" "$DOMAIN"
  echo
}

usage() {
  cat <<EOF
${B}kit${N} — управление 3X-UI KIT

  kit paths                                               показать пути панели/подписки и routing

  kit user add имя [--gb 50] [--days 30] [--devices 3]   добавить и показать подписку
  kit user list                                           трафик, срок, статус
  kit user link имя [--all]                               подписка и QR; --all — ещё vpn:// и tg://
  kit user limit имя [--gb N] [--days N] [--devices N]    изменить лимиты (0 — без ограничений)
  kit user repair имя                                      восстановить REALITY flow у старого пользователя
  kit user off имя  /  kit user on имя                    выключить и включить
  kit user del имя                                        удалить
EOF
}

case "${1:-} ${2:-}" in
  "paths ") cmd_paths ;;
  "user add") shift 2; cmd_add "$@" ;;
  "user list") cmd_list ;;
  "user link") shift 2; cmd_link "$@" ;;
  "user limit") shift 2; cmd_limit "$@" ;;
  "user repair") shift 2; cmd_repair "$@" ;;
  "user off") cmd_toggle "${3:-}" false ;;
  "user on") cmd_toggle "${3:-}" true ;;
  "user del") shift 2; cmd_del "$@" ;;
  *) usage ;;
esac
\n'
    echo; grep . <<<"$out" || echo "Отдельных ссылок нет."
  fi
}

cmd_list() {
  local now
  now=$(($(date +%s) * 1000))
  clients | jq -r --argjson now "$now" '
    map(select(.subId != null)) | group_by(.subId | sub("-awg[0-9]*$"; "")) | map(sort_by(.email | length) as $g | $g[0] + {used: ([$g[] | (.traffic.up // 0) + (.traffic.down // 0)] | add),
      seen: ([$g[] | .traffic.lastOnline // 0] | max)}) | sort_by(.email)[]
    | [.email, .used, (.totalGB // 0), (.expiryTime // 0), .enable, .seen] | @tsv' |
  {
    printf "${B}%-18s %-22s %-14s %-10s %s${N}\n" "Пользователь" "Трафик" "До" "Статус" "Был в сети"
    while IFS=$'\t' read -r email used total exp en last; do
      local tr till st seen
      tr="$(human "$used")"; ((total > 0)) && tr="$tr / $(human "$total")"
      if ((exp > 0)); then till=$(date -d "@$((exp / 1000))" +%d.%m.%Y); else till="бессрочно"; fi
      if [[ $en != true ]]; then st="${R}выключен${N}"
      elif ((exp > 0 && exp < $(date +%s) * 1000)); then st="${Y}истёк${N}"
      elif ((total > 0 && used >= total)); then st="${Y}лимит${N}"
      else st="${G}активен${N}"; fi
      if ((last > 0)); then seen=$(date -d "@$((last / 1000))" '+%d.%m %H:%M'); else seen="—"; fi
      printf "%-18s %-22s %-14s %-19s %s\n" "$email" "$tr" "$till" "$st" "$seen"
    done
  }
}

# Меняет все записи пользователя (основную и «двойников» AmneziaWG), каждую — от её собственных данных.
update_user() { # имя jq-фильтр [аргументы jq...]
  local name=$1 filter=$2 e rec body
  shift 2
  for e in $(emails_of "$name"); do
    rec=$(client "$e")
    body=$(jq -c "$@" "{email, subId, flow, totalGB, expiryTime, limitIp, enable, comment} | $filter" <<<"$rec")
    api POST "clients/update/$e" "$body" >/dev/null
  done
}

cmd_repair() {
  local name=${1:-} e rec body
  valid_name "$name"
  [[ -n $(client "$name") ]] || die "Нет пользователя $name"
  for e in $(emails_of "$name"); do
    rec=$(client "$e")
    body=$(jq -c '{email, subId, flow, totalGB, expiryTime, limitIp, enable, comment}
      | .flow = "xtls-rprx-vision"' <<<"$rec")
    api POST "clients/update/$e" "$body" >/dev/null
  done
  say "Для $name восстановлен flow xtls-rprx-vision. Обновите подписку в клиенте."
}

cmd_limit() {
  local name=${1:-} f="." gb="" days="" dev=""
  valid_name "$name"; shift
  [[ -n $(client "$name") ]] || die "Нет пользователя $name"
  while [[ $# -gt 0 ]]; do
    case $1 in
      --gb) gb=$(gb_bytes "$2"); f+=" | .totalGB = \$gb"; shift 2 ;;
      --days) days=$(days_ms "$2"); f+=" | .expiryTime = \$days"; shift 2 ;;
      --devices) [[ $2 =~ ^[0-9]+$ ]] || die "--devices: целое число"; dev=$2; f+=" | .limitIp = \$dev"; shift 2 ;;
      *) die "Неизвестный параметр: $1" ;;
    esac
  done
  update_user "$name" "$f" --argjson gb "${gb:-0}" --argjson days "${days:-0}" --argjson dev "${dev:-0}"
  tgweb_sync_user "$name"
  say "Лимиты $name обновлены (0 — без ограничений)."
}

cmd_toggle() { # имя true|false
  valid_name "$1"
  [[ -n $(client "$1") ]] || die "Нет пользователя $1"
  update_user "$1" ".enable = \$v" --argjson v "$2"
  tgweb_sync_user "$1"
  if [[ $2 == true ]]; then say "Пользователь $1 включён."; else say "Пользователь $1 выключен — подписка и подключения не работают."; fi
}

cmd_del() {
  local name=${1:-} ans=""
  valid_name "$name"
  [[ -n $(client "$name") ]] || die "Нет пользователя $name"
  if [[ ${2:-} != -y && -t 0 ]]; then
    read -rp "Удалить $name со всех протоколов? [y/N] " ans
    [[ $ans =~ ^[yYдД]$ ]] || { echo "Отменено."; return; }
  fi
  local e
  tgweb_delete_user "$name"
  for e in $(emails_of "$name"); do api POST "clients/del/$e" >/dev/null; done
  say "Пользователь $name удалён, его подписка больше не работает."
}


cmd_paths() {
  local panel_host="${DOMAIN:-${HOST:-}}"
  local panel_path="/${XUI_WEB_BASE_PATH#/}"
  panel_path="${panel_path%/}/"

  local panel_url
  if [[ ${SINGLE:-no} == yes ]]; then
    panel_url="https://$panel_host$panel_path"
  elif [[ -n ${XUI_PANEL_PORT:-} ]]; then
    panel_url="https://$panel_host:$XUI_PANEL_PORT$panel_path"
  else
    panel_url="$panel_path"
  fi

  local sub_base="${SUB_BASE:-}"
  local routing="${ROUTING_URL:-$ROUTING_DEFAULT}"
  local fallback="${FALLBACK_URL:-}"

  echo
  printf '%-18s %s\n' "Panel URL:" "$panel_url"
  [[ -n $sub_base ]] && printf '%-18s %s\n' "Subscription base:" "$sub_base"
  [[ -n ${SUB_PATH:-} ]] && printf '%-18s %s\n' "Subscription path:" "$SUB_PATH"
  printf '%-18s %s\n' "Routing URL:" "$routing"
  if [[ -n $fallback ]]; then
    printf '%-18s %s\n' "Fallback:" "$fallback"
  else
    printf '%-18s %s\n' "Fallback:" "local landing page"
  fi
  [[ -n ${DOMAIN:-} ]] && printf '%-18s %s\n' "Domain:" "$DOMAIN"
  echo
}

usage() {
  cat <<EOF
${B}kit${N} — управление 3X-UI KIT

  kit paths                                               показать пути панели/подписки и routing

  kit user add имя [--gb 50] [--days 30] [--devices 3]   добавить и показать подписку
  kit user list                                           трафик, срок, статус
  kit user link имя [--all]                               подписка и QR; --all — ещё vpn:// и tg://
  kit user limit имя [--gb N] [--days N] [--devices N]    изменить лимиты (0 — без ограничений)
  kit user repair имя                                      восстановить REALITY flow у старого пользователя
  kit user off имя  /  kit user on имя                    выключить и включить
  kit user del имя                                        удалить
EOF
}

case "${1:-} ${2:-}" in
  "paths ") cmd_paths ;;
  "user add") shift 2; cmd_add "$@" ;;
  "user list") cmd_list ;;
  "user link") shift 2; cmd_link "$@" ;;
  "user limit") shift 2; cmd_limit "$@" ;;
  "user repair") shift 2; cmd_repair "$@" ;;
  "user off") cmd_toggle "${3:-}" false ;;
  "user on") cmd_toggle "${3:-}" true ;;
  "user del") shift 2; cmd_del "$@" ;;
  *) usage ;;
esac
\n'
    echo; grep . <<<"$out" || echo "Отдельных ссылок нет."
  fi
}

cmd_list() {
  local now
  now=$(($(date +%s) * 1000))
  clients | jq -r --argjson now "$now" '
    map(select(.subId != null)) | group_by(.subId | sub("-awg[0-9]*$"; "")) | map(sort_by(.email | length) as $g | $g[0] + {used: ([$g[] | (.traffic.up // 0) + (.traffic.down // 0)] | add),
      seen: ([$g[] | .traffic.lastOnline // 0] | max)}) | sort_by(.email)[]
    | [.email, .used, (.totalGB // 0), (.expiryTime // 0), .enable, .seen] | @tsv' |
  {
    printf "${B}%-18s %-22s %-14s %-10s %s${N}\n" "Пользователь" "Трафик" "До" "Статус" "Был в сети"
    while IFS=$'\t' read -r email used total exp en last; do
      local tr till st seen
      tr="$(human "$used")"; ((total > 0)) && tr="$tr / $(human "$total")"
      if ((exp > 0)); then till=$(date -d "@$((exp / 1000))" +%d.%m.%Y); else till="бессрочно"; fi
      if [[ $en != true ]]; then st="${R}выключен${N}"
      elif ((exp > 0 && exp < $(date +%s) * 1000)); then st="${Y}истёк${N}"
      elif ((total > 0 && used >= total)); then st="${Y}лимит${N}"
      else st="${G}активен${N}"; fi
      if ((last > 0)); then seen=$(date -d "@$((last / 1000))" '+%d.%m %H:%M'); else seen="—"; fi
      printf "%-18s %-22s %-14s %-19s %s\n" "$email" "$tr" "$till" "$st" "$seen"
    done
  }
}

# Меняет все записи пользователя (основную и «двойников» AmneziaWG), каждую — от её собственных данных.
update_user() { # имя jq-фильтр [аргументы jq...]
  local name=$1 filter=$2 e rec body
  shift 2
  for e in $(emails_of "$name"); do
    rec=$(client "$e")
    body=$(jq -c "$@" "{email, subId, flow, totalGB, expiryTime, limitIp, enable, comment} | $filter" <<<"$rec")
    api POST "clients/update/$e" "$body" >/dev/null
  done
}

cmd_repair() {
  local name=${1:-} e rec body
  valid_name "$name"
  [[ -n $(client "$name") ]] || die "Нет пользователя $name"
  for e in $(emails_of "$name"); do
    rec=$(client "$e")
    body=$(jq -c '{email, subId, flow, totalGB, expiryTime, limitIp, enable, comment}
      | .flow = "xtls-rprx-vision"' <<<"$rec")
    api POST "clients/update/$e" "$body" >/dev/null
  done
  say "Для $name восстановлен flow xtls-rprx-vision. Обновите подписку в клиенте."
}

cmd_limit() {
  local name=${1:-} f="." gb="" days="" dev=""
  valid_name "$name"; shift
  [[ -n $(client "$name") ]] || die "Нет пользователя $name"
  while [[ $# -gt 0 ]]; do
    case $1 in
      --gb) gb=$(gb_bytes "$2"); f+=" | .totalGB = \$gb"; shift 2 ;;
      --days) days=$(days_ms "$2"); f+=" | .expiryTime = \$days"; shift 2 ;;
      --devices) [[ $2 =~ ^[0-9]+$ ]] || die "--devices: целое число"; dev=$2; f+=" | .limitIp = \$dev"; shift 2 ;;
      *) die "Неизвестный параметр: $1" ;;
    esac
  done
  update_user "$name" "$f" --argjson gb "${gb:-0}" --argjson days "${days:-0}" --argjson dev "${dev:-0}"
  say "Лимиты $name обновлены (0 — без ограничений)."
}

cmd_toggle() { # имя true|false
  valid_name "$1"
  [[ -n $(client "$1") ]] || die "Нет пользователя $1"
  update_user "$1" ".enable = \$v" --argjson v "$2"
  if [[ $2 == true ]]; then say "Пользователь $1 включён."; else say "Пользователь $1 выключен — подписка и подключения не работают."; fi
}

cmd_del() {
  local name=${1:-} ans=""
  valid_name "$name"
  [[ -n $(client "$name") ]] || die "Нет пользователя $name"
  if [[ ${2:-} != -y && -t 0 ]]; then
    read -rp "Удалить $name со всех протоколов? [y/N] " ans
    [[ $ans =~ ^[yYдД]$ ]] || { echo "Отменено."; return; }
  fi
  local e
  for e in $(emails_of "$name"); do api POST "clients/del/$e" >/dev/null; done
  say "Пользователь $name удалён, его подписка больше не работает."
}


cmd_paths() {
  local panel_host="${DOMAIN:-${HOST:-}}"
  local panel_path="/${XUI_WEB_BASE_PATH#/}"
  panel_path="${panel_path%/}/"

  local panel_url
  if [[ ${SINGLE:-no} == yes ]]; then
    panel_url="https://$panel_host$panel_path"
  elif [[ -n ${XUI_PANEL_PORT:-} ]]; then
    panel_url="https://$panel_host:$XUI_PANEL_PORT$panel_path"
  else
    panel_url="$panel_path"
  fi

  local sub_base="${SUB_BASE:-}"
  local routing="${ROUTING_URL:-$ROUTING_DEFAULT}"
  local fallback="${FALLBACK_URL:-}"

  echo
  printf '%-18s %s\n' "Panel URL:" "$panel_url"
  [[ -n $sub_base ]] && printf '%-18s %s\n' "Subscription base:" "$sub_base"
  [[ -n ${SUB_PATH:-} ]] && printf '%-18s %s\n' "Subscription path:" "$SUB_PATH"
  printf '%-18s %s\n' "Routing URL:" "$routing"
  if [[ -n $fallback ]]; then
    printf '%-18s %s\n' "Fallback:" "$fallback"
  else
    printf '%-18s %s\n' "Fallback:" "local landing page"
  fi
  [[ -n ${DOMAIN:-} ]] && printf '%-18s %s\n' "Domain:" "$DOMAIN"
  echo
}

usage() {
  cat <<EOF
${B}kit${N} — управление 3X-UI KIT

  kit paths                                               показать пути панели/подписки и routing

  kit user add имя [--gb 50] [--days 30] [--devices 3]   добавить и показать подписку
  kit user list                                           трафик, срок, статус
  kit user link имя [--all]                               подписка и QR; --all — ещё vpn:// и tg://
  kit user limit имя [--gb N] [--days N] [--devices N]    изменить лимиты (0 — без ограничений)
  kit user repair имя                                      восстановить REALITY flow у старого пользователя
  kit user off имя  /  kit user on имя                    выключить и включить
  kit user del имя                                        удалить
EOF
}

case "${1:-} ${2:-}" in
  "paths ") cmd_paths ;;
  "user add") shift 2; cmd_add "$@" ;;
  "user list") cmd_list ;;
  "user link") shift 2; cmd_link "$@" ;;
  "user limit") shift 2; cmd_limit "$@" ;;
  "user repair") shift 2; cmd_repair "$@" ;;
  "user off") cmd_toggle "${3:-}" false ;;
  "user on") cmd_toggle "${3:-}" true ;;
  "user del") shift 2; cmd_del "$@" ;;
  *) usage ;;
esac
