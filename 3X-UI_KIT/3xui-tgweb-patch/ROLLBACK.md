# ROLLBACK — TgWeb 3x-ui integration rollout

Статус: **DESIGN ONLY.** Все команды мутирующие — **DO NOT RUN YET**, выполнять только по триггеру отката.
Принцип: восстанавливаем **control plane** (бинарник + БД + legacy reconciler), runtime state (`/var/lib/tgwebproxy/clients.json`) **не трогаем** в нормальном откате — reconcile патченной версии менял только policy-поля (enabled/quota/expiry), secrets/counters сохранялись (доказано staging), старый reconciler восстановит прежнюю политику.

**Ключевое правило порядка (исправление FINAL):** legacy TgWeb reconciler (`kit-tgweb-reconcile.timer → kit-tgweb-reconcile.service → /usr/local/sbin/kit-tgweb-reconcile`) зависит от панели/API 3x-ui и TgWeb admin API. Поэтому **старый x-ui должен быть восстановлен и проверен ДО включения reconciler**. НИКОГДА не стартовать reconciler, пока x-ui остановлен или панель/API недоступна.

## Rollback triggers (немедленный откат при любом)

```text
x-ui не стартует / падает с panic
PRAGMA integrity_check != ok
Xray config содержит tgweb / web.maicraft.tech / tgweb-web / TgWeb-секрет
сломались существующие VPN-пользователи
runtime secrets rotated (fp != reference)
runtime counters reset
все TgWeb-пользователи неожиданно disabled
подписи падают / subscription page crash
client edit fail / detach портит VPN-связи
admin API auth непрерывно 401
```

## Процедура (порядок критичен — 10 шагов)

```bash
RB=/root/pre-tgweb-rollout-<TS>    # rollback bundle, созданный в Phase B; все reference-файлы — из него
```

### 1. Зафиксировать причину

```bash
journalctl -u x-ui -n 200 --no-pager > /root/rollback-cause.log    # DO NOT RUN YET
```

### 2. Остановить patched x-ui

```bash
systemctl stop x-ui                                                # DO NOT RUN YET
systemctl is-active x-ui                                           # → inactive (подтвердить)
```

### 3. Восстановить оригинальный бинарник (из бандла Phase B)

```bash
mv /usr/local/x-ui/x-ui /root/pre-tgweb-rollout-<TS>/x-ui.patched  # DO NOT RUN YET
cp -a /root/pre-tgweb-rollout-<TS>/x-ui.orig /usr/local/x-ui/x-ui # DO NOT RUN YET
chown 1001:1001 /usr/local/x-ui/x-ui; chmod 755 /usr/local/x-ui/x-ui   # DO NOT RUN YET
sha256sum /usr/local/x-ui/x-ui   # ожидание: 816420f7a6df3eb3272c3608767207b1ade81c3dcb7fed7b46c7949454a8a14c
```

### 4. Восстановить pre-rollout снапшот БД

Финальный снапшот `$RB2` — снят ПОСЛЕ остановки x-ui и ДО миграции `--apply` (Phase F). Если миграция не применялась — достаточно снапшота Phase B.

```bash
cp -a /root/pre-tgweb-rollout-<TS2>/x-ui.db /etc/x-ui/x-ui.db      # DO NOT RUN YET
```

### 5. Проверить целостность и ожидаемое pre-rollout состояние БД

Ожидаемые значения — из манифеста preflight (значения, захваченные во время preflight, **НЕ хардкодить в скриптах** — live-состояние может измениться до роллаута). На момент preflight 2026-10-07: clients 6, inbounds 7, client_inbounds 42, tgweb-inbound 0, tgweb-таблиц 0, migration marker 0.

```bash
python3 - <<'EOF'                       # DO NOT RUN YET
import sqlite3
db = sqlite3.connect("file:/etc/x-ui/x-ui.db?mode=ro", uri=True)
print("integrity:", db.execute("PRAGMA integrity_check").fetchone()[0])   # → ok
expect = {   # сверить с манифестом preflight, актуализировать перед окном
  "clients": ("SELECT COUNT(*) FROM clients", None),
  "inbounds": ("SELECT COUNT(*) FROM inbounds", 7),
  "client_inbounds": ("SELECT COUNT(*) FROM client_inbounds", None),
  "tgweb_inbounds": ("SELECT COUNT(*) FROM inbounds WHERE protocol='tgweb'", 0),
  "tgweb_tables": ("SELECT COUNT(*) FROM sqlite_master WHERE name LIKE 'tgweb%'", 0),
  "migration_marker": ("SELECT COUNT(*) FROM settings WHERE key LIKE '%tgweb%migration%'", 0),
}
for k, (q, want) in expect.items():
    got = db.execute(q).fetchone()[0]
    print(k, "→", got, "OK" if want is None or got == want else "MISMATCH")
EOF
```

Стоп-критерий: `integrity != ok` или любой MISMATCH → НЕ продолжать, разбираться вручную (БД не соответствует pre-rollout состоянию).

### 6. Старт оригинального x-ui

```bash
systemctl start x-ui                                               # DO NOT RUN YET
systemctl status x-ui --no-pager                                   # → active
```

### 7. Верификация x-ui ДО включения reconciler

Проверяем ВСЁ из списка — только после этого разрешается шаг 8:

```bash
systemctl is-active x-ui                                           # → active
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:2097/    # панель отвечает (200/302)
ss -ltnp | grep -q '127.0.0.1:2097'                                # listener поднят
ps aux | grep -E '[x]ray|[m]tg|[t]uic' | head -5                   # sidecar'ы Xray/VPN живы
# DB state загружен — повторить сверку из шага 5 (те же ожидания)
```

**Если панель/API не отвечает — reconciler НЕ включать.** Сначала вернуть x-ui в рабочее состояние.

### 8. Включить legacy reconciler

```bash
systemctl enable --now kit-tgweb-reconcile.timer                   # DO NOT RUN YET
systemctl start kit-tgweb-reconcile.service                        # DO NOT RUN YET (немедленный первый тик, не ждать таймер)
```

### 9. Верификация первого успешного тика reconciler (явная, не только «timer active»)

```bash
# дождаться завершения oneshot (обычно секунды)
systemctl show kit-tgweb-reconcile.service -p ExecMainStatus       # → 0 (exit success)
systemctl is-active kit-tgweb-reconcile.timer                      # → active
journalctl -u kit-tgweb-reconcile.service -n 100 --no-pager \
  | grep -Ei '401|403|auth.*fail|unauthor|error|denied'            # → пусто: нет panel API auth failure, нет TgWeb admin API auth failure
# runtime: нет secret rotation и counter reset против reference
python3 - "$RB/tgweb-runtime-before.json" <<'EOF'   # DO NOT RUN YET (read-only GET, sanitized сверка; reference из rollback-бандла)
import json, urllib.request, hashlib, pathlib, sys
ref = {r["name"]: r for r in json.load(open(sys.argv[1]))}
tok = pathlib.Path("/etc/tgwebproxy/admin.token").read_text().strip()
req = urllib.request.Request("http://127.0.0.1:9601/clients", headers={"Authorization": "Bearer " + tok})
ok = True
for dom in json.load(urllib.request.urlopen(req, timeout=10)):
    for c in dom.get("clients", []):
        r = ref.get(c["name"])
        if not r: continue
        m = (r["secret_sha256"] == hashlib.sha256(c["secret"].encode()).hexdigest()
             and c.get("bytes_up", 0) >= r["bytes_up"] and c.get("bytes_down", 0) >= r["bytes_down"])
        ok &= m
        print(c["name"], "OK" if m else "MISMATCH")
print("RECONCILER_TICK_VERIFY:", "PASS" if ok else "FAIL")
EOF
```

Любой FAIL здесь → reconciler работает некорректно (auth/rotation/reset) → STOP, разбираться до объявления отката завершённым.

### 10. Финальная верификация VPN + TgWeb

```bash
sha256sum /usr/local/x-ui/x-ui          # == 816420f7… (оригинал)
# VPN: 1–2 реальных пользовательских подключения (read-only просьба пользователям)
# tgweb: клиент `MV` открывает t.me/webproxy-ссылку (pre-migration формат из старой подписки) — proxy работает
# TgWeb runtime policy: GET /clients → все ожидаемые пользователи, enabled-политика соответствует pre-rollout
```

## KIT policy при откате (обновление FINAL)

- **`/usr/local/bin/kit` НЕ изменялся** ни при роллауте, ни при откате (live-правка KIT убрана из плана) — восстанавливать нечего.
- Бэкапы в бандле Phase B по-прежнему **обязательны** и **не удаляются**: `/usr/local/bin/kit`, `/usr/local/sbin/kit-tgweb-reconcile`, `/etc/kit/tgweb.env`.
- Операционный freeze `kit user web …` снимается владельцем только после шага 9 (первый успешный тик reconciler подтверждён).

## Emergency-only: runtime state restore

**Семантика (FIX-2, без изменений):** `$RB/tgweb-runtime-state.json` — raw backup runtime state (может содержать реальные секреты: chmod 600, только в root-бандле, не печатать, не копировать в отчёты/артефакты). Восстанавливать ТОЛЬКО при credential corruption / secret rotation / counter destruction. Нормальный откат этого НЕ делает: восстанавливаем старый x-ui + старую БД, стартуем x-ui, включаем старый reconciler — control plane сам восстановит runtime-политику (staging это доказал). Порядок emergency:

```bash
systemctl stop tgwebproxy                                       # DO NOT RUN YET
cp -a /var/lib/tgwebproxy/clients.json /root/clients.json.bad   # DO NOT RUN YET
cp -a "$RB/tgweb-runtime-state.json" /var/lib/tgwebproxy/clients.json  # снапшот создаётся в Phase B (PRODUCTION-ROLLOUT.md)
systemctl start tgwebproxy                                      # DO NOT RUN YET
```
