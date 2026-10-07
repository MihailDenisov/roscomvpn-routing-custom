# REPORT-STAGING-PHASE2

Дата: 2026-10-07. Среда: WSL1 (`~/3xui-tgweb-test/staging`), production доступ — только read-only.
Сценарий: migration --apply → idempotency → schema upgrade → isolated runtime → reconcile → subscription/QR → quota/reset → disable/enable → detach/reattach → delete → runtime outage → production 401 diagnostics.

## MIGRATION APPLY

first apply: **PASS**
`{"tgwebInboundId": 8, "tgwebInboundCreated": true, "attached": 6, "migrationCompleted": true, "dryRun": false}`, EXIT=0.

second apply idempotent: **PASS**
`{"alreadyMigrated": true}`; sha256 БД до/после не изменился (`b6a0ceb5…`); снапшоты counts/rows/clients/traffics/settings идентичны (DIFF_KEYS: NONE).

tgweb inbound: **PASS**
id=8, protocol=tgweb, port=0, enable=1, remark `Telegram WebProxy`, tag `tgweb-web`,
publicHost=web.maicraft.tech, publicPort=443, node_id=NULL, `share_addr_strategy='listen'` (колонка inbounds).

6 attachments: **PASS** — MV, Vlad, admin, d2ieytntgp, galya, vlados (через client_inbounds, точный регистр).

VPN attachments unchanged: **PASS** — 42 VPN rows без изменений; итого 48 client_inbounds.

migration marker: **PASS** — `settings.key='tgweb_client_inbounds_migration_v1'`, value=`complete` (settings.id=157).

integrity: **PASS** — `PRAGMA integrity_check` = ok после apply и после второго apply.

## SCHEMA UPGRADE

Чистый source: `git worktree @ 6be3c438` + `git apply 0001..0004`; дерево идентично upstream HEAD `0afa43f8` (verified `diff -rq`, искл. `.husky/_`). Schema init — штатный `database.InitDB` (harness `cmd/phase2schemainit`).

tgweb_traffic_baselines: **PASS** — PK id, UNIQUE(email,domain), index domain, defaults (reset_seq/seen_reset_seq=0).
tgweb_reset_epochs: **PASS** — PK(email), reset_seq default 0.
existing schema preserved: **PASS** — counts/хэши clients(6)/inbounds(8)/client_inbounds(48)/client_traffics(6) без изменений; additive-колонки upstream (`reset_weekday`, `cipher_suites`, `exclude_from_sub`) и таблицы `node_pending_resets`, `tuic_traffic_receipts` — штатный AutoMigrate drift; `client_external_inbounds` отсутствует (корректно).
Schema diff: `staging/schema-before-upgrade.sql` → `schema-after-upgrade.sql` (артефакты).

## ISOLATED RUNTIME

test runtime startup: **PASS** — бинарник `tgwebproxy-multi` скопирован read-only с production (`/usr/local/bin/tgwebproxy`), изолированный config: listen `127.0.0.1:14600`, admin `127.0.0.1:19601`, state `runtime/test-clients.json`, behind_proxy=true, отдельный токен (600). Seeded из `tgweb-runtime-state-raw.json` (sha256 совпал).

secrets preserved: **PASS** — все 6 fingerprints совпали с `tgweb-runtime-reference.json` до и после reconcile.

counters preserved: **PASS** — admin up=793301/down=12856796 сохранены; нулевые counters не тронуты.

initial reconcile: **PASS** — все 6 в runtime, enabled=true, expiry/quota синхронизированы из DB (vlados expires=1793548006, d2ieytntgp=1791579600); baselines созданы для всех 6; Xray listener не создан.

## FUNCTIONAL

subscription card: **PASS** — sub page MV содержит `tgweb: {name:"Telegram WebProxy", link:"https://t.me/webproxy?secret=…&server=web.maicraft.tech", domain:…}`; secret соответствует runtime (fingerprint); в `links[]` и subJson secret отсутствует.

QR: **PASS** — `SubQrButton value={tgweb.link}` (antd QRCode) кодирует ту же ссылку; подтверждено кодом `frontend/src/pages/sub/SubLinksTab.tsx`.

quota reset: **PASS** (real test runtime)
1. MV counters выставлены 5MB/3MB (state-file seed);
2. reconcile — effective usage 8MB против baseline 0;
3. штатный `ClientService.ResetAllTraffics()` → `tgweb_reset_epochs`: все 6 клиентов seq=1, client_traffics обнулён;
4. следующий reconcile — baseline захвачен (MV 5MB/3MB, admin 793301/12856796), `seen_reset_seq=1`, effective_web_usage=0;
5. counters +2MB → reconcile: effective только delta (2MB/0). Исторические runtime counters не сброшены.

TgWeb-only ResetAll: **PASS** — временный клиент `ph2tgwebonly` (attachment только к tgweb, ct row удалён вручную для эмуляции legacy): `ResetAllTraffics()` поднял его epoch (0→1) без client_traffics row; reconcile применил baseline; клиент удалён штатным `DeleteByEmail` (clients 6, ci 48), leftover runtime credential отключён (enabled=false).

disable/enable: **PASS** (с оговоркой DEFECT-C) — `BulkSetEnable(Vlad,false)` → VPN settings enable=false, record enable=0, reconcile → runtime enabled=false, subcard ABSENT; обратный enable → subcard PRESENT, fingerprint прежний.

detach/reattach: **FAIL** — **DEFECT-B**: `DetachByEmail(d2ieytntgp, 8)` — silent no-op (`ok:false`, client_inbounds row осталась, runtime credential остался enabled=true). Причина: `DelInboundClientByEmail` ищет клиента в tgweb settings JSON (`clients: []`), не находит → `ErrClientNotInInbound`, который `Detach` проглатывает. Штатно отключить клиента от TgWeb невозможно; reattach не тестируется (detach не отработал). Secret при этом сохраняется (не ротируется).

delete inbound: **PASS** — `InboundService.DelInbound(8)`: tgweb client_inbounds очищены (42 VPN остались), все 6 credentials fail-closed (enabled=false), secrets (fp match) и counters сохранены, Xray restart не требуется (tgweb не push'ится в xray; лог «skipping runtime push for disabled local inbound id: 8»).

runtime unavailable: **PASS** — при остановленном test runtime: VPN edit/save (`ClientService.Update` для galya, tgweb inbound уже удалён) — ok; reconcile логирует `reconcile deferred: connection refused`, процесс не падает (EXIT=0); возврат runtime — recovery ok.

Xray isolation: **PASS** — `GetXrayConfig()` против staging: 7 inbounds (api + 6 VPN), отсутствуют tgweb/web.maicraft.tech/tgweb-web/все TgWeb secrets.

## DEFECTS (требуют правки patchset до rollout)

- **DEFECT-A (критично)**: `ClientService.Update/UpdateByEmail` (панель: редактирование клиента, `/update/:email`) падает с `inbound 8: empty client ID` для любого клиента, attached к tgweb-inbound. Причина: Update-фанout зовёт `UpdateInboundClient` для tgweb-inbound; там `clientIndex == -1` (клиентов в tgweb settings JSON нет) → ошибка. Панель не может сохранить правки клиента (expiry/quota/comment), пока он attached к TgWeb.
- **DEFECT-B (критично)**: `Detach/DetachByEmail` для tgweb-inbound — silent no-op (см. выше). Отключение от TgWeb штатно невозможно; доступ продолжает действовать.
- **DEFECT-C (средне)**: `BulkSetEnable`/`applyClientFieldByEmail` для tgweb-inbound сообщают `Client Not Found In Inbound`. Для клиентов с VPN-attachments итог достигается через SyncInbound side-effect (проверено), но для чисто TgWeb-attached клиента глобальный enable не изменится. Стоит сделать tgweb-aware ветку (обновлять ClientRecord напрямую).

Общая причина A/B/C: штатные пути ищут клиента в tgweb settings JSON, который всегда `clients: []` (attachment — только через client_inbounds). В `AddInboundClient`/`DelInboundClientByEmail`/`DelInbound` tgweb-ветки есть, в `UpdateInboundClient`-ветках (Update/Detach/Bulk) — нет.

## PRODUCTION ADMIN 401

- root cause: ранний 401 (Phase 1b) **не воспроизводится**. Текущее состояние: все варианты токена (raw file, stripped, toml) дают `GET /clients → HTTP 200`. Файл `admin.token` (64 hex + `\n`) по stripped-hash совпадает с токеном `relay.toml`; mtime файла/конфига (2026-10-06 12:55/13:48) предшествует Phase 1b — токен с тех пор не менялся. Вероятная причина раннего 401 — способ передачи токена в Phase 1b (raw файл с newline через curl); runtime и x-ui client оба tolerant к newline.
- admin token file matches runtime: **YES** (sha256 stripped file == sha256 toml token; raw-file hash отличается только из-за trailing `\n`).
- authenticated GET works: **YES (HTTP 200)**, `GET http://127.0.0.1:9601/clients` (read-only probe).
- recommended production fix: не требуется. Опционально: записать токен без trailing newline (косметика; все потребители trim'ают).

## SECURITY AUDIT

- token не попал во frontend dist (grep `19601|admin.token` — чисто), не в логи panel/runtime WSL.
- TgWeb secret не в generic API: links[], subJson, Xray config — чисто; secret только в sub/share-контексте.
- production runtime не получил PUT: финальная сверка `/var/lib/tgwebproxy/clients.json` — все 6 fingerprints/counters совпадают с reference, enabled=true, test-имён нет. Свежее mtime — штатная периодическая перезапись state runtime'ом.
- test runtime полностью изолирован: loopback-only порты 14600/19601, отдельный state-file и токен, `XUI_TGWEB_ADMIN` направлен только туда. Никаких обращений к production 9601 из patched-кода (env-override; default отсутствует → errorAPI fail-closed).
- raw secrets/tokens в отчёт и артефакты не включены (только sha256 fingerprints).

## RESTORE / REPRODUCIBILITY

**PASS** — `cp -f tgweb-staging-before-phase2.db tgweb-staging.db` (важно: удалить stale `-wal/-shm` при живом WAL; в каталоге их не было, но при наличии — удалить). Hash совпал с backup (`d74681b…`), integrity ok, pre-migration состояние (8 inbounds? нет — 7, marker отсутствует). Migration воспроизводима (прогнана 3 раза суммарно).

## DoD

1. migration apply — PASS; 2. idempotent — PASS; 3. 6 users attached — PASS; 4. 42 VPN unchanged — PASS; 5. schema upgrade — PASS; 6. secrets/counters preserved — PASS; 7. reconcile — PASS; 8. subscription+QR — PASS; 9. quota reset — PASS; 10. TgWeb-only ResetAll — PASS; 11. disable/enable — PASS; 12. **detach/reattach — FAIL (DEFECT-B)**; 13. delete fail-closed — PASS; 14. runtime outage — PASS; 15. Xray isolation — PASS; 16. причина 401 понятна — PASS (не воспроизводится; token соответствует конфигу); 17. production не изменён — PASS (verified state+401 read-only only).

**Итог: 16/17.** Phase 2 не признавать полностью готовым до исправления DEFECT-A/B/C. Production rollout не выполнялся.

## Artifacts

В `~/3xui-tgweb-test/staging/phase2-artifacts/` и копия в workspace `phase2-artifacts/`:
schema-before/after-upgrade.sql, phase2-migration-verify.json, snapshot-initial.json, snapshot-first-reconcile.json, sub-page-mv-parsed.json, panel-wsl.log, idempotency snapshots. Тестовый runtime config без токена: `staging/runtime/test-relay.toml` (token заменён при переносе; живой конфиг в WSL, 600). Raw secrets/tokens отсутствуют в артефактах.
