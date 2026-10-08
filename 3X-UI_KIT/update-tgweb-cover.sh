#!/usr/bin/env bash
# Update the TgWeb cover site from https://maicraft.tech/.
# Safe flow: download -> validate -> backup -> install -> SIGHUP -> smoke test.
set -Eeuo pipefail

SOURCE_URL="${SOURCE_URL:-https://maicraft.tech}"
SITE_DIR="${SITE_DIR:-/srv/tgweb-cover}"
SERVICE="${SERVICE:-tgwebproxy}"
OWNER="${OWNER:-tgwebproxy}"
GROUP="${GROUP:-tgwebproxy}"
BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/tgweb-cover}"

say() { printf '==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run as root"
command -v curl >/dev/null || die "curl is required"
command -v grep >/dev/null || die "grep is required"
command -v sha256sum >/dev/null || die "sha256sum is required"
id "$OWNER" >/dev/null 2>&1 || die "user $OWNER does not exist"

tmp=$(mktemp -d /tmp/tgweb-cover.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
install -d -m 0755 "$tmp/site/assets"

fetch() {
  local url=$1 out=$2
  curl -fsSL --retry 3 --retry-delay 1 --connect-timeout 10 --max-time 60     "$url" -o "$out"
}

say "Downloading main files from $SOURCE_URL"
fetch "$SOURCE_URL/" "$tmp/site/index.html"
fetch "$SOURCE_URL/style.css?v=8" "$tmp/site/style.css"
fetch "$SOURCE_URL/script.js?v=8" "$tmp/site/script.js"
fetch "$SOURCE_URL/site.webmanifest" "$tmp/site/site.webmanifest"
fetch "$SOURCE_URL/favicon.ico" "$tmp/site/favicon.ico"

say "Discovering local assets"
{
  grep -Eo '/assets/[A-Za-z0-9._/-]+' "$tmp/site/index.html" || true
  grep -Eo '/assets/[A-Za-z0-9._/-]+' "$tmp/site/style.css" || true
  grep -Eo '/assets/[A-Za-z0-9._/-]+' "$tmp/site/script.js" || true
} | sort -u >"$tmp/assets.txt"

while IFS= read -r path; do
  [[ -n $path ]] || continue
  dest="$tmp/site$path"
  install -d -m 0755 "$(dirname "$dest")"
  fetch "$SOURCE_URL$path" "$dest"
done <"$tmp/assets.txt"

say "Validating downloaded site"
[[ -s "$tmp/site/index.html" ]] || die "index.html is empty"
[[ -s "$tmp/site/style.css" ]] || die "style.css is empty"
[[ -s "$tmp/site/script.js" ]] || die "script.js is empty"
grep -q 'MAICraft.TECH' "$tmp/site/index.html" || die "unexpected landing page"
grep -q '<!doctype html>' "$tmp/site/index.html" || die "index.html does not look like HTML"

# Sanity guard against accidentally replacing the cover site with an error page.
size=$(stat -c %s "$tmp/site/index.html")
(( size >= 10000 )) || die "index.html is suspiciously small: $size bytes"

chown -R "$OWNER:$GROUP" "$tmp/site"
find "$tmp/site" -type d -exec chmod 0755 {} +
find "$tmp/site" -type f -exec chmod 0644 {} +

new_hash=$(sha256sum "$tmp/site/index.html" | awk '{print $1}')
old_hash=""
[[ -f "$SITE_DIR/index.html" ]] && old_hash=$(sha256sum "$SITE_DIR/index.html" | awk '{print $1}')

if [[ -n $old_hash && $new_hash == "$old_hash" ]]; then
  say "Cover site is already current ($new_hash)"
  exit 0
fi

stamp=$(date +%Y%m%d-%H%M%S)
install -d -m 0700 "$BACKUP_ROOT"

if [[ -d $SITE_DIR ]]; then
  say "Backing up current site"
  cp -a "$SITE_DIR" "$BACKUP_ROOT/$stamp"
fi

say "Installing new cover site"
install -d -o "$OWNER" -g "$GROUP" -m 0755 "$SITE_DIR"
find "$SITE_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
cp -a "$tmp/site"/. "$SITE_DIR"/
chown -R "$OWNER:$GROUP" "$SITE_DIR"

say "Reloading $SERVICE"
systemctl kill -s HUP "$SERVICE"
sleep 1
systemctl is-active --quiet "$SERVICE" || die "$SERVICE is not active after reload"

say "Local validation"
sudo -u "$OWNER" test -r "$SITE_DIR/index.html" || die "service user cannot read index.html"

say "Updated successfully"
printf 'old index sha256: %s\n' "${old_hash:-none}"
printf 'new index sha256: %s\n' "$new_hash"
printf 'backup: %s\n' "$BACKUP_ROOT/$stamp"
