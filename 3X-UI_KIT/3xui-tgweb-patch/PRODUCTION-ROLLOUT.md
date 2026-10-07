# PRODUCTION ROLLOUT — TgWeb 3x-ui integration

Статус: **DESIGN ONLY — ничего не выполнять без явного approve владельца.**
Все команды, мутирующие production, помечены **DO NOT RUN YET**.
Кандидат: integration commit `63068b8438a89ffddeeeba8603c323e07b26b8fd`
= upstream `6be3c438e1420f24dd10060f8a1dd620b2d0e73b` + 0001 + 0002(iter5) + 0003 + 0004.

## 0. Зафиксированные факты production (read-only рекогносцировка 2026-10-07)

- MAIN = `connect.maicraft.tech`, hostname подтверждён, uptime 5 дней.
- `x-ui.service`: enabled, active, `ExecStart=/usr/local/x-ui/x-ui`, `WorkingDirectory=/usr/local/x-ui/`, Restart=on-failure. Дочерние процессы: xray, mtg, tuic — sidecar'ы x-ui.
- `tgwebproxy.service`: active, `/usr/local/bin/tgwebproxy -config /etc/tgwebproxy/relay.toml`.
- **Legacy reconciler (точно идентифицирован):** `kit-tgweb-reconcile.timer` (OnBootSec=30s, OnUnitActiveSec=30s) → oneshot `kit-tgweb-reconcile.service` → `/usr/local/sbin/kit-tgweb-reconcile` (bash, flock, читает `/etc/x-ui/install-result.env`, `/etc/kit/kit.env`, `/etc/kit/tgweb.env`, пишет через panel API и PUT /clients).
- **Legacy mutation path:** `/usr/local/bin/kit` → `kit user web NAME on|off` → `tgweb_sync_user()` → прямой `PUT /clients` (вторая независимая точка управления desired state — §30 GOAL).
- `kit-sub.service` active (`/usr/local/lib/kit-sub/kit_sub.py`) — подписи; не трогать.
- Хэши (point-in-time): x-ui binary `816420f7…a14c`; DB `0f1991c2…58b` (живой WAL — хэш меняется, только как референс); relay.toml `040bc19e…`; admin.token sha256(raw) `cd22cf68…` (stripped == toml token — фикс токена не нужен); nginx `fc6e2d80…` (kit.conf), `57289b41…` (kit-tgweb.conf).
- Состояние БД: clients 6 (admin, vlados, MV, Vlad, d2ieytntgp, galya), inbounds 7, client_inbounds 42, tgweb-inbound 0, tgweb-таблиц 0, marker 0, `[tgweb:off]` 0, AWG-теней 0.
- Runtime admin API: GET /clients = 200; 6 пользователей, все enabled=true; fp (sha256/12): MV `9b0b772af8a5`, Vlad `c3e6641a0d65`, admin `0ed991da8112`, d2ieytntgp `897fb210aae0`, galya `78034b7d1c46`, vlados `81e0bd3b029e`; admin counters up=793301/down=12856796.
- Диск: 9.7G свободно из 19G — достаточно.
- tgwebproxy dir: `/etc/tgwebproxy/` root:tgwebproxy 750, admin.token 640.

## Phase A — Preflight (read-only, NO restart)

```bash
ssh root@connect.maicraft.tech
hostname; date; uptime
systemctl status x-ui --no-pager          # active
systemctl cat x-ui                        # ExecStart=/usr/local/x-ui/x-ui
systemctl status tgwebproxy --no-pager    # active
systemctl list-timers --all | grep kit-tgweb-reconcile   # таймер активен
ps aux | grep -E "x-ui|tgwebproxy|kit" | grep -v grep
df -h /
ls -la /usr/local/x-ui/x-ui /etc/x-ui/x-ui.db
nginx -t                                  # конфиг валиден (read-only проверка)
```

## Phase B — Fresh backups (mutation: создание файлов, обратимо)

Каталог роллбэка (на MAIN):

```bash
RB=/root/pre-tgweb-rollout-$(date +%Y%m%d-%H%M%S)
mkdir -p "$RB" && chmod 700 "$RB"
```

Свежий консистентный снапшот БД — только SQLite backup API (x-ui НЕ останавливать, `cp` живого файла запрещён):

```bash
python3 - "$RB" <<'EOF'                      # DO NOT RUN YET
import sqlite3, sys, pathlib
rb = pathlib.Path(sys.argv[1])
src = sqlite3.connect("file:/etc/x-ui/x-ui.db?mode=ro", uri=True)
dst = sqlite3.connect(rb / "x-ui.db")
src.backup(dst)
dst.execute("PRAGMA integrity_check")
print("integrity:", dst.execute("PRAGMA integrity_check").fetchone()[0])
dst.close(); src.close()
EOF
sha256sum "$RB/x-ui.db"
```

Бандл роллбэка:

```bash
cp -a /usr/local/x-ui/x-ui "$RB/x-ui.orig"                    # DO NOT RUN YET
cp -a /etc/systemd/system/x-ui.service "$RB/"                 # DO NOT RUN YET
cp -a /etc/tgwebproxy/relay.toml "$RB/"                       # DO NOT RUN YET
sha256sum /etc/tgwebproxy/admin.token > "$RB/admin.token.sha256"   # DO NOT RUN YET, без сырых токенов
cp -a /usr/local/bin/kit "$RB/kit.orig"                       # DO NOT RUN YET (бэкап; KIT не модифицируется)
cp -a /usr/local/sbin/kit-tgweb-reconcile "$RB/"              # DO NOT RUN YET
cp -a /etc/kit/tgweb.env "$RB/tgweb.env" && chmod 600 "$RB/tgweb.env"   # DO NOT RUN YET
```

**Три TgWeb reference-артефакта бандла** (все с явными путями, права 600; FIX-1/FIX-2/FIX-3):

```text
$RB/tgweb-runtime-before.json  → sanitized comparison reference (только secret_sha256, БЕЗ plaintext-секретов)
$RB/tgweb-runtime-state.json   → raw emergency-only backup runtime state (МОЖЕТ содержать реальные секреты:
                                 только в root-бандле, не печатать, не копировать в артефакты/отчёты)
$RB/runtime-names.json         → migration input, валидируется dry-run (Phase C) и переиспользуется в Phase F
```

Sanitized reference (FIX-1: единый explicit output path — без shell-redirection + внутреннего хардкода):

```bash
python3 - "$RB/tgweb-runtime-before.json" <<'EOF'   # DO NOT RUN YET (read-only GET)
import json, urllib.request, hashlib, pathlib, sys
out_path = sys.argv[1]
tok = pathlib.Path("/etc/tgwebproxy/admin.token").read_text().strip()
req = urllib.request.Request("http://127.0.0.1:9601/clients",
    headers={"Authorization": "Bearer " + tok})
out = []
for dom in json.load(urllib.request.urlopen(req, timeout=10)):
    for c in dom.get("clients", []):
        out.append({"name": c["name"], "enabled": c.get("enabled"),
                    "bytes_up": c.get("bytes_up", 0), "bytes_down": c.get("bytes_down", 0),
                    "expiry": c.get("expiry"), "quota": c.get("quota_bytes"),
                    "secret_sha256": hashlib.sha256(c["secret"].encode()).hexdigest()})
with open(out_path, "w") as f:
    json.dump(out, f, indent=1)
EOF
chmod 600 "$RB/tgweb-runtime-before.json"
```

Raw emergency-only runtime state snapshot (FIX-2; backup-only, live state не модифицируется):

```bash
cp -a /var/lib/tgwebproxy/clients.json "$RB/tgweb-runtime-state.json"   # DO NOT RUN YET
chmod 600 "$RB/tgweb-runtime-state.json"
```

Migration names — fresh GET /clients, только домен `web.maicraft.tech` (FIX-3):

```bash
python3 - "$RB/runtime-names.json" <<'EOF'   # DO NOT RUN YET (read-only GET)
import json, urllib.request, pathlib, sys
out_path = sys.argv[1]
tok = pathlib.Path("/etc/tgwebproxy/admin.token").read_text().strip()
req = urllib.request.Request("http://127.0.0.1:9601/clients",
    headers={"Authorization": "Bearer " + tok})
names = []
for dom in json.load(urllib.request.urlopen(req, timeout=10)):
    if dom.get("domain") != "web.maicraft.tech":
        continue
    for c in dom.get("clients", []):
        names.append(c["name"])
with open(out_path, "w") as f:
    json.dump(names, f)
print("runtime users:", len(names))
EOF
chmod 600 "$RB/runtime-names.json"
```

Валидация имён перед dry-run (печатать только имена, не секреты): домен `web.maicraft.tech` присутствует; неожиданные домены — рассмотреть (пользователей из них молча не мержить — репорт, при влиянии на семантику миграции → STOP); дубликатов нет; case-insensitive коллизий нет; AWG-теней нет (если не ожидаются явно). Материальное расхождение с валидированными staging-допущениями → **STOP**. Ожидаемое состояние — 6 пользователей, но доверять только live-наблюдению.

Манифест бандла (хэши, без токенов/секретов):

```bash
{   # DO NOT RUN YET
  echo "timestamp: $(date -Is)"
  echo "old x-ui sha256: $(sha256sum /usr/local/x-ui/x-ui | cut -d' ' -f1)"
  echo "new x-ui sha256: $(sha256sum /usr/local/x-ui/x-ui.tgweb.new | cut -d' ' -f1)"
  echo "DB snapshot sha256: $(sha256sum "$RB/x-ui.db" | cut -d' ' -f1)"
  echo "migration script sha256: $(sha256sum "$RB/migrate_legacy_v2.py" | cut -d' ' -f1)"
  echo "runtime-names.json sha256: $(sha256sum "$RB/runtime-names.json" | cut -d' ' -f1)"
  echo "tgweb-runtime-before.json sha256: $(sha256sum "$RB/tgweb-runtime-before.json" | cut -d' ' -f1)"
  echo "tgweb-runtime-state.json sha256: $(sha256sum "$RB/tgweb-runtime-state.json" | cut -d' ' -f1)"
} > "$RB/MANIFEST.txt"
chmod 600 "$RB"/* 2>/dev/null; chmod 700 "$RB"
```

(Копия `migrate_legacy_v2.py` в `$RB` — sha256 `f83cfe28…b1d` — зафиксировать в манифесте до Phase C.)

## Phase C — Final dry-run на свежей копии (без --apply)

Dry-run использует РОВНО тот же файл имён, что и apply:

```bash
python3 migrate_legacy_v2.py --db "$RB/x-ui.db" \
  --names-json "$(cat "$RB/runtime-names.json")"    # DO NOT RUN YET (копия скрипта в $RB)
```

Стоп-условия: ожидается attach=6, detach=0 (историческое значение, не гарантия) — доверять live dry-run результату, без неожиданных пользователей / case mismatch / markers / дублей / AWG-теней. Отличие от ожиданий → **STOP**. Результат dry-run записать (в т.ч. attach/detach-план) — он эталон для Phase F.

## Phase D — Binary/schema preparation (артефакты готовы)

Сборка выполнена вне production (WSL1, чистое repro-дерево upstream+0001..0004, байт-в-байт == валидированное дерево итерации 5):

```text
go1.27.1 linux/amd64, node v26.10.0
binary sha256: f625eac057b32b6868bfa43fdb8cdb000efc1617136838fc18edf75690aa87dd  (x-ui.it5.bin)
0001 sha256: d0dd80f8a7b05e724e733c68db8d1d574d2e240f616bdf701dd17bf755b69b5e
0002 sha256: 9b79c1ed655d7a60da152398f5fe11dbb2171e8b64ab2af5f973ebe5d162a0fb  (iteration 5)
0003 sha256: 7c0a3dcddbd76d114c8bf6f53a5a46058f8e1f66e3c949c0277977c020c20f7c
0004 sha256: c8e6b810ebbd76501d213c238319a05f35ab8ceb324520008b5a24bfbe4a846e
migrate_legacy_v2.py sha256: f83cfe2820c863ea85e39973939d6ae07ad3db00ac0a2475142881d1ca4e1b1d
integration commit: 63068b8438a89ffddeeeba8603c323e07b26b8fd
```

Staging binary на MAIN (временный путь, НЕ перезаписывая live):

```bash
scp x-ui.it5.bin root@connect.maicraft.tech:/usr/local/x-ui/x-ui.tgweb.new   # DO NOT RUN YET
ssh root@connect.maicraft.tech "sha256sum /usr/local/x-ui/x-ui.tgweb.new; \
  chown 1001:1001 /usr/local/x-ui/x-ui.tgweb.new; chmod 755 /usr/local/x-ui/x-ui.tgweb.new"   # DO NOT RUN YET
```

**ABI/glibc preflight — ПРОВЕРЕНО 2026-10-07 (read-only, бинарник НЕ запускался):**

```text
staged sha256:  f625eac057b32b6868bfa43fdb8cdb000efc1617136838fc18edf75690aa87dd  == validated artifact → PASS
file:           ELF 64-bit LSB executable, x86-64, dynamically linked → arch совпадает → PASS
ldd:            libc.so.6, /lib64/ld-linux-x86-64.so.2, linux-vdso — все resolve, "not found" нет → PASS
max GLIBC:      2.34  (readelf --version-info)
production:     Ubuntu 24.04.5, glibc 2.39 (ldd (Ubuntu GLIBC 2.39-0ubuntu8.9) 2.39)
                2.34 <= 2.39 → PASS (если при перепроверке в окне max > 2.39 → STOP)
reference:      текущий /usr/local/x-ui/x-ui — STATICALLY linked, sha256 816420f7…a14c
```

Переподтвердить `sha256sum` + `ldd` + `readelf` непосредственно перед окном (чек-лист PRE-FLIGHT §Binary ABI).

Schema compatibility (на копии свежего снапшота, live DB не трогать):

```bash
cp "$RB/x-ui.db" /tmp/schema-check.db
./x-ui.tgweb.new  # времянка: поднять с XUI_DB_FOLDER=/tmp … либо harness InitDB   # DO NOT RUN YET
# ожидание: additive-only — таблицы tgweb_traffic_baselines, tgweb_reset_epochs появляются; clients/inbounds/client_inbounds не изменяются
```

## Phase E — Maintenance window

Подтверждённые владельцем окно и последовательность (детали — ниже, cutover-блок):
подтверждение freeze legacy KIT-команд → остановка legacy-реконсилера → остановка x-ui → финальный снапшот → миграция --apply → атомарная замена бинарника → старт → смоук.

**Шаг 0 окна (организационный):** владелец подтверждает, что в окно и observation-период **никто не использует** `kit user web …` (administrative freeze, см. Phase I). `/usr/local/bin/kit` при этом не модифицируется.

## Phase F — Production migration

```bash
systemctl stop kit-tgweb-reconcile.timer kit-tgweb-reconcile.service   # DO NOT RUN YET
systemctl disable kit-tgweb-reconcile.timer                            # DO NOT RUN YET
systemctl stop x-ui                                                    # DO NOT RUN YET
# финальный снапшот (как Phase B) в $RB2
```

**Drift-check именён НЕПОСРЕДСТВЕННО перед apply** (read-only, пока x-ui остановлен — runtime API живёт отдельно): свежий GET /clients → сравнить с `$RB/runtime-names.json`. Расхождение → **STOP**: (1) регенерировать runtime-names.json; (2) повторить dry-run; (3) переоценить attach/detach-план; только затем продолжать. Apply со stale names запрещён.

```bash
python3 migrate_legacy_v2.py --db /etc/x-ui/x-ui.db \
  --names-json "$(cat "$RB/runtime-names.json")" --apply              # DO NOT RUN YET — тот же файл, что валидировал Phase C
# ожидание: tgwebInboundCreated, attached N == результату dry-run, migrationCompleted; затем:
python3 -c "import sqlite3; print(sqlite3.connect('file:/etc/x-ui/x-ui.db?mode=ro', uri=True).execute('PRAGMA integrity_check').fetchone())"   # DO NOT RUN YET → ok
```

## Phase G — Patched x-ui startup (атомарная замена)

```bash
mv /usr/local/x-ui/x-ui "$RB/x-ui.replaced.$(date +%H%M%S)"            # DO NOT RUN YET
mv /usr/local/x-ui/x-ui.tgweb.new /usr/local/x-ui/x-ui                 # DO NOT RUN YET
systemctl start x-ui                                                   # DO NOT RUN YET
systemctl status x-ui --no-pager; journalctl -u x-ui -n 100 --no-pager
```

## Phase H — Smoke tests

`POST-DEPLOY-SMOKE.md` — немедленно после старта: DB-проверки, Xray isolation, reconcile vs runtime-before reference, MV, подписка/QR, Telegram WEB-proxy, CRUD-смоук, enable-смоук. Каждый FAIL-критерий → ROLLBACK.

## Phase I — Old control-plane retirement (обновление FINAL: без live-правки KIT)

- `kit-tgweb-reconcile.timer/service` остаются stopped+disabled (не удалять).
- `/usr/local/bin/kit`, `/etc/kit/tgweb.env`, `/usr/local/sbin/kit-tgweb-reconcile` — **не изменять**; сохранить до стабилизации. Их бэкапы в бандле Phase B обязательны.
- **Операционный guard (не кодовая модификация):** на время окна и observation-периода действует административный запрет:

```text
DO NOT USE LEGACY KIT TgWeb MUTATION COMMANDS
(`kit user web NAME on|off`, tgweb_sync_user → PUT /clients)
до валидации нового control plane
```

  Live `sed`/script-правки `/usr/local/bin/kit` из initial cutover **убраны** (лишний риск human-error). Единый source of truth на период окна обеспечивается остановленным legacy reconciler + freeze команд.

- **Post-rollout cleanup — отдельная задача после стабилизации** (не смешивать с initial deployment): либо (A) мигрировать `kit user web NAME on|off` на новый client_inbounds control path, либо (B) вывести legacy-команду из эксплуатации.

## Phase J — Post-deploy observation

Мониторинг 24–72ч: `journalctl -u x-ui -f`, tgwebproxy log, nginx error log, admin API health, reconcile retries; сигналы: Xray restarts, DB errors, token auth errors, PUT-loops, quota-аномалии, неожиданные disable, изменение secret/counter fingerprints.

## Phase K — Rollback

`ROLLBACK.md` — команды и верификация. Триггеры — см. REPORT §ROLLBACK TRIGGERS.
