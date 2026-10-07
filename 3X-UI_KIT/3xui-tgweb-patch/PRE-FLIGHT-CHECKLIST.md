# PRE-FLIGHT CHECKLIST — TgWeb production rollout

Выполняется НЕПОСРЕДСТВЕННО перед окном. Всё read-only до явного approve.
Отмечать `[x]` только по факту наблюдения.

## Идентификация (read-only)

```text
[ ] hostname == connect.maicraft.tech; date/time корректны
[ ] systemctl status x-ui → active; ExecStart=/usr/local/x-ui/x-ui (systemctl cat)
[ ] systemctl status tgwebproxy → active (-config /etc/tgwebproxy/relay.toml)
[ ] systemctl list-timers | grep kit-tgweb-reconcile → timer активен (legacy reconciler подтверждён)
[ ] systemctl cat kit-tgweb-reconcile.service → ExecStart=/usr/local/sbin/kit-tgweb-reconcile
[ ] ps aux | grep -E "x-ui|tgwebproxy" → xray/mtg/tuic — дети x-ui
[ ] df -h / → ≥ 2G свободно
[ ] nginx -t → ok (без изменений конфигов!)
```

## Хэши и референсы (read-only)

```text
[ ] sha256 /usr/local/x-ui/x-ui == 816420f7a6df3eb3272c3608767207b1ade81c3dcb7fed7b46c7949454a8a14c
[ ] sha256 /etc/tgwebproxy/relay.toml == 040bc19ef8bc24e1c996b8ae03c6ec674f81d49b5f70c55dec2fb1e840682ea3
[ ] sha256 /etc/tgwebproxy/admin.token == cd22cf686e9734d34dbd2e324e2b14473fa97b20677400efc963680a6145c765 (raw; НЕ печатать содержимое)
[ ] stripped(token file) == token in relay.toml (python-сверка, без печати)
[ ] sha256 nginx kit.conf == fc6e2d80461e80f517055de5c54a08ade1bca71d195d34b11d92eb93a655b2c2
[ ] sha256 nginx kit-tgweb.conf == 57289b41d8aa7df8e292d885d177367eea37b85f9873f94a7727e47a9db2ba68
```

## Текущее состояние (read-only; НЕ хардкодить — перепроверить!)

```text
[ ] DB: clients 6 (admin, vlados, MV, Vlad, d2ieytntgp, galya)
[ ] DB: inbounds 7, client_inbounds 42, tgweb-inbound 0
[ ] DB: tgweb-таблиц 0, migration marker 0, [tgweb:off] 0, AWG-теней 0
[ ] runtime GET /clients → HTTP 200, 6 пользователей, все enabled=true
[ ] runtime fingerprints (sha256): MV 9b0b772af8a5…, Vlad c3e6641a0d65…, admin 0ed991da8112…,
    d2ieytntgp 897fb210aae0…, galya 78034b7d1c46…, vlados 81e0bd3b029e…
[ ] admin counters: up=793301 down=12856796 (сверить с ранее зафиксированными)
```

## Бэкапы (mutation — только после approve на Phase B)

```text
[ ] rollback-каталог /root/pre-tgweb-rollout-<TS> создан, 700
[ ] DB-снапшот через sqlite3 backup API (НЕ cp живого файла); integrity_check = ok
[ ] оригинальный бинарник скопирован в бандл
[ ] x-ui.service, relay.toml, admin.token.sha256, nginx-конфиги, kit, kit-tgweb-reconcile, tgweb.env(600) — в бандле
[ ] $RB/tgweb-runtime-before.json exists, chmod 600 — sanitized reference (name/enabled/up/down/expiry/quota/secret_sha256);
      valid JSON; содержит ожидаемых runtime-пользователей; secret_sha256 only; НЕТ plaintext-секретов
[ ] $RB/tgweb-runtime-state.json exists, chmod 600 — raw state backup; sensitive: только root-бандл,
      не включать в отчёты/артефакты, не печатать
[ ] $RB/runtime-names.json exists, chmod 600 — из fresh GET /clients, только domain web.maicraft.tech;
      без дублей и case-insensitive коллизий; печатались только имена
[ ] $RB/MANIFEST.txt — timestamp + sha256 (old/new x-ui, DB snapshot, migrate script, три reference-файла); без токенов
```

## Артефакты и сухой прогон

```text
[ ] новый бинарник на /usr/local/x-ui/x-ui.tgweb.new; sha256 == f625eac057b32b6868bfa43fdb8cdb000efc1617136838fc18edf75690aa87dd
[ ] владелец/права нового бинарника == 1001:1001 755
```

## Binary ABI/glibc compatibility (read-only, НЕ запускать бинарник)

Проверки `file` / `ldd` / `readelf` / `sha256sum` — read-only и разрешены. Проверено 2026-10-07 на staged-бинарнике; **переподтвердить непосредственно перед окном** (значения ниже — ожидания).

```text
[ ] новый бинарник SHA256 matches validated artifact
      f625eac057b32b6868bfa43fdb8cdb000efc1617136838fc18edf75690aa87dd
[ ] новый бинарник architecture matches production host (x86-64)
[ ] ldd compatibility checked
      бинарник DYNAMIC (интерпретатор /lib64/ld-linux-x86-64.so.2) —
      сравнить max GLIBC_ symbol vs production glibc
[ ] no missing dynamic libraries
      ожидание: все зависимости resolve, "not found" недопустим → иначе STOP
[ ] required GLIBC <= production glibc (2.39) OR binary is statically linked
      max required: GLIBC_2.34 (проверено readelf --version-info 2026-10-07)
      production glibc: 2.39 (ldd (Ubuntu GLIBC 2.39-0ubuntu8.9) 2.39)
      → 2.34 <= 2.39 → PASS (если при перепроверке max > 2.39 → STOP)
[ ] current production binary: /usr/local/x-ui/x-ui STATICALLY linked
      (reference для сравнения; новый бинарник статическим необязателен)
```

Decision rules: `ldd → not a dynamic executable` → PASS по glibc. Dynamic → max GLIBC ≤ installed, иначе STOP (пересборка в совместимом окружении). Любая пропавшая библиотека → STOP (никаких ad-hoc установок пакетов в окне).

```text
[ ] миграция dry-run (БЕЗ --apply) на копии свежего снапшота: --names-json "$(cat $RB/runtime-names.json)";
      ожидание attach=6, detach=0 — доверять live-результату; без markers/теней/дублей
[ ] dry-run и apply используют РОВНО один и тот же $RB/runtime-names.json (FIX-3)
[ ] drift-check именён read-only непосредственно перед apply: свежий GET /clients == $RB/runtime-names.json, иначе STOP
[ ] schema-check на копии: additive-only (tgweb_traffic_baselines, tgweb_reset_epochs), существующие таблицы без изменений
[ ] migrate_legacy_v2.py sha256 == f83cfe2820c863ea85e39973939d6ae07ad3db00ac0a2475142881d1ca4e1b1d
[ ] runtime-names.json сгенерирован свежим GET /clients (не из документа!), только domain web.maicraft.tech
```

## Организационное

```text
[ ] окно maintenance согласовано (короткое, explicit)
[ ] ROLLBACK.md открыт, команды готовы к копипасте
[ ] владелец на связи на время окна
[ ] legacy reconciler timer/service идентифицированы
      kit-tgweb-reconcile.timer → kit-tgweb-reconcile.service → /usr/local/sbin/kit-tgweb-reconcile
[ ] KIT legacy TgWeb mutation command административно заморожен на окно:
      DO NOT USE LEGACY KIT TgWeb MUTATION COMMANDS (`kit user web …`)
      до валидации нового control plane; /usr/local/bin/kit НЕ модифицируется
[ ] post-deploy smoke чек-лист открыт
```

Обязательные бэкапы KIT в бандл (без изменения файлов): `/usr/local/bin/kit`, `/usr/local/sbin/kit-tgweb-reconcile`, `/etc/kit/tgweb.env`.
