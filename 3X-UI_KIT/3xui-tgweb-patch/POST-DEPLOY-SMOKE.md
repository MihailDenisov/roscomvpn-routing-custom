# POST-DEPLOY SMOKE — TgWeb production rollout

Выполняется немедленно после Phase G (первый старт patched x-ui).
Каждый блок: при FAIL критерия → **IMMEDIATE ROLLBACK** (ROLLBACK.md), если не помечено иначе.

## 1. Сервис и журнал (первые 2 минуты)

```bash
systemctl status x-ui --no-pager                    # active, без restart-loop
journalctl -u x-ui -n 100 --no-pager | grep -iE "panic|fatal|error|reconcile"
# ожидание: DB migration success, TgWeb job startup, admin API auth ok, Xray startup; reconcile errors отсутствуют
systemctl is-active kit-tgweb-reconcile.timer       # inactive (disabled)
```

```text
[ ] x-ui active (не более 1 авто-restart)
[ ] в журнале нет panic / repeated retries / token auth errors
[ ] tgwebproxy.service active (не перезапускался)
```

## 2. Немедленная проверка БД

```bash
python3 - <<'EOF'
import sqlite3
db = sqlite3.connect("file:/etc/x-ui/x-ui.db?mode=ro", uri=True)
print("integrity:", db.execute("PRAGMA integrity_check").fetchone()[0])
print("tgweb inbound:", db.execute("SELECT id, protocol, port, enable FROM inbounds WHERE protocol='tgweb'").fetchall())
print("tgweb attachments:", db.execute("SELECT COUNT(*) FROM client_inbounds WHERE inbound_id=8").fetchone()[0])
print("vpn attachments:", db.execute("SELECT COUNT(*) FROM client_inbounds WHERE inbound_id!=8").fetchone()[0])
print("marker:", db.execute("SELECT value FROM settings WHERE key='tgweb_client_inbounds_migration_v1'").fetchone())
for t in ("tgweb_traffic_baselines", "tgweb_reset_epochs"):
    print(t, "exists:", db.execute("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?", (t,)).fetchone()[0] == 1)
EOF
```

```text
[ ] integrity ok
[ ] tgweb inbound exists (protocol=tgweb, port=0, enable=1)
[ ] 6 TgWeb attachments; 42 VPN attachments unchanged (counts сверить с pre-flight!)
[ ] migration marker complete
[ ] tgweb_traffic_baselines + tgweb_reset_epochs существуют
[ ] tgweb settings.clients == []
```

## 3. Xray isolation (IMMEDIATE ROLLBACK при FAIL)

```bash
# Xray config через panel API / файл bin/config.json (read-only)
grep -iE "tgweb|web.maicraft.tech|tgweb-web" /usr/local/x-ui/bin/config.json && echo POLLUTION || echo CLEAN
# либо через GetXrayConfig; секреты не печатать: проверить только отсутствие меток
```

```text
[ ] Xray config НЕ содержит tgweb / web.maicraft.tech / tgweb-web / TgWeb secrets
[ ] существующие VPN-inbounds на месте (7 инбаундов панели: api + 6 VPN)
```

## 4. Reconcile vs pre-rollout reference (IMMEDIATE ROLLBACK при FAIL)

Дать reconcile 1–2 тика (~60–90с, job периодический), затем read-only GET /clients и сверка с `tgweb-runtime-before.json`:

```bash
python3 - "$RB/tgweb-runtime-before.json" <<'EOF'   # read-only; сверяет secret_sha256, counters, enabled по политике БД; reference из rollback-бандла (FIX-1)
import json, urllib.request, hashlib, pathlib, sqlite3, sys
ref = {r["name"]: r for r in json.load(open(sys.argv[1]))}
tok = pathlib.Path("/etc/tgwebproxy/admin.token").read_text().strip()
req = urllib.request.Request("http://127.0.0.1:9601/clients",
    headers={"Authorization": "Bearer " + tok})
db = sqlite3.connect("file:/etc/x-ui/x-ui.db?mode=ro", uri=True)
pol = {e: (en == 1) for e, en in db.execute("SELECT email, enable FROM clients")}
ok = True
seen = set()
for dom in json.load(urllib.request.urlopen(req, timeout=10)):
    for c in dom.get("clients", []):
        name = c["name"]; seen.add(name)
        r = ref.get(name)
        if not r:
            print(name, "UNEXPECTED"); ok = False; continue
        m = (r["secret_sha256"] == hashlib.sha256(c["secret"].encode()).hexdigest()
             and r["bytes_up"] == c.get("bytes_up", 0)
             and r["bytes_down"] == c.get("bytes_down", 0))
        if not m: print(name, "SECRET/COUNTER MISMATCH"); ok = False
for name, r in ref.items():
    if name not in seen: print(name, "MISSING"); ok = False
print("RECONCILE_VERIFY:", "PASS" if ok else "FAIL")
EOF
```

```text
[ ] secret fingerprints: все 6 unchanged
[ ] counters: все unchanged (admin up=793301/down=12856796)
[ ] enabled-state соответствует политике БД (все enable=1 → все enabled=true)
```

## 5. Primary user MV

```text
[ ] VPN-ссылки MV в подписке на месте (не пересозданы)
[ ] TgWeb attached (client_inbounds row inbound 8)
[ ] runtime credential same secret (fp 9b0b772af8a5…)
[ ] runtime enabled; quota == f(total_gb − usage); expiry соответствует БД
```

## 6. Subscription + QR

```text
[ ] страница подписки MV: карточка «Telegram WebProxy» в «Other links / Остальные ссылки»
[ ] ссылка: https://t.me/webproxy?secret=<existing-secret>&server=web.maicraft.tech (fp == runtime)
[ ] QR кодирует ту же ссылку
[ ] secret отсутствует в generic links[] / subJson / clients API / inbounds API
```

## 7. Telegram functional (owner/admin account, минимальный трафик)

```text
[ ] Telegram Desktop распознаёт WEB proxy по ссылке
[ ] соединение работает
[ ] counters сдвинулись на тестовый трафик (небольшой!)
```

## 8. CRUD smoke (через панель/API — те же service-пути)

Update: временно поменять comment у тестового клиента → save succeeds → TgWeb relation remains → VPN relations remain → **restore**.

Detach/reattach (только тестовый/безопасный аккаунт, НЕ критичный): detach → relation removed, runtime enabled=false, VPN работает, subcard исчезает → reattach → same secret, runtime enabled=true, subcard вернулась.

```text
[ ] client edit works (comment update + restore)
[ ] detach/reattach works на тестовом аккаунте (или пропуск с фиксацией причины)
```

## 9. Global enable smoke (тестовый аккаунт; НЕ owner/admin без approve)

```text
[ ] disable → runtime enabled=false, relation remains
[ ] enable → runtime enabled=true
```

## 10. Не выполнять при initial rollout (отложенные контроли)

```text
[!] quota reset — только после появления designated test user (post-rollout controlled test)
[!] intentional runtime outage — подтверждено staging-доказательствами; production: admin API reachable + reconcile successful
[!] old reconciler удаление — не раньше стабилизации (Phase J завершён)
[!] landing page web.maicraft.tech — отдельный post-rollout change
```

## 11. Итоги окна

```text
[ ] все пункты 1–9 отмечены
[ ] pre-/post-хэши и сверки приложены к отчёту окна (без секретов)
[ ] kit-tgweb-reconcile остаётся stopped+disabled (НЕ удалён)
[ ] ROLLBACK-бандл на месте, не повреждён
```
