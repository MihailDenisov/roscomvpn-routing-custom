# REPORT — Итерация 5: TgWeb CRUD (DEFECT-A/B/C)

Дата: 2026-10-07. Среда: WSL1 (`~/3xui-tgweb-test/staging`), production не тронут (read-only диагностика закрыта в Phase 2).
Сценарий: исправление трёх дефектов CRUD из Staging Phase 2 → unit/service тесты → clean reproduction патчсета → backend/frontend/build валидация → сокращённый staging E2E по CRUD.

## Исправления (минимальный патч, все в 0002)

1. **DEFECT-A** — `UpdateInboundClient` для `protocol == tgweb` теперь no-op (не ищет клиента в `settings.clients`, не пишет JSON, не запрашивает restart). `ClientService.Update` пропускает TgWeb-инбаунды в fan-out и, если ни один JSON-apply не выполнялся (`len(applies)==0`, включая «только TgWeb»-клиентов), сам пишет канонический `ClientRecord` (один раз, без двойных записей — см. §10 goal).
2. **DEFECT-B** — `DelInboundClientByEmail` для tgweb удаляет **только** строку `client_inbounds` (через тот же `ApplyInboundClientDelta`, что и обычный путь): без lookup в JSON, без трогания `ClientRecord.Enable`, статистики и VPN-attachments; reconciler отключает runtime-credential с сохранением secret/counters.
3. **DEFECT-C** — `bulkSetEnableInboundClients` для tgweb помечает все запрошенные email обработанными (пустой `perEmailSkipped`), не трогая JSON: канонический `clients.enable` пишется `BulkSetEnable` после fan-out, reconciler применяет в runtime.
4. Дополнительно к инварианту §1: `AddInboundClient` больше не вписывает клиента в JSON tgweb-инбаунда (settings остаётся `{"clients":[]}` при attach — иначе reattach оставлял бы «призраков», которых новая detach-ветка не чистит).

Затронуты только `internal/web/service/{client_crud,client_inbound_apply,client_bulk}.go` + новый тестовый файл. `0005` не создавался.

## DEFECT-A

UpdateByEmail attached TgWeb: **PASS** (staging: `edit MV` → `save ok: true`; раньше — `inbound 8: empty client ID`)

comment update: **PASS** (`it5 temp comment` persisted, восстановлено после)

expiry update: **PASS** (unit `TestUpdateTgWebAttachedClient`: ExpiryTime 1893456000000 persisted; staging-expiry не меняли — restore-обязательство)

quota update: **PASS** (total_gb 50→40GB persisted; runtime quota после reconcile 37761853569 = 40GB − usage; восстановлено до 48499271809)

TgWeb relation preserved: **PASS** (6 tgweb attachments до/после; settings.clients пуст)

VPN relations preserved: **PASS** (42 VPN rows; vless JSON клиента MV: uuid `223ea13e…` без изменений, изменился только totalGB)

no unnecessary Xray restart caused by TgWeb: **PASS** (`TestTgWebCrudDoesNotRequestXrayRestart` — update/detach/reattach/bulk на TgWeb-only клиенте: needRestart=false; tgweb-ветки в Add/Update/Del вообще не запрашивают restart)

## DEFECT-B

DetachByEmail: **PASS** (`detach d2ieytntgp 8` — раньше silent no-op с `ErrClientNotInInbound`, теперь чистое выполнение)

relation removed: **PASS** (tgweb row 0; counts 5 tgweb / 42 VPN)

runtime disabled: **PASS** (после reconcile: credential present, enabled=false)

subcard hidden: **PASS** (`subcard: ABSENT`)

secret preserved: **PASS** (sha256 fp `897fb210…` идентичен до detach и после reattach; counters 0/0 сохранены)

reattach: **PASS** (`attach d2ieytntgp 8` → row восстановлена, counts 6/42)

same secret after reattach: **PASS** (fp совпал с оригинальным; settings JSON tgweb остался `{"clients":[]}`)

VPN attachments untouched: **PASS** (`TestDetachTgWebDoesNotTouchVPNAttachments` + staging: d2 сохранил 7 VPN rows, enable в JSON не изменён)

## DEFECT-C

TgWeb-only BulkDisable: **PASS** (`set-enable it5tgwebonly false` → `changed=1 skipped=[]`, раньше — `Client Not Found In Inbound`)

ClientRecord enable false: **PASS** (record enable=0; relation сохранена — global disable ≠ detach)

runtime disabled: **PASS** (enabled=false, subcard ABSENT)

BulkEnable: **PASS** (`changed=1 skipped=[]`)

runtime enabled: **PASS** (record enable=1, runtime enabled=true, subcard PRESENT)

Временный клиент удалён штатно: record+relations удалены, leftover credential disabled (fail-closed).

## REGRESSIONS

migration: **PASS** (apply → 6 attached; повторный apply `alreadyMigrated`; marker complete)

quota/reset: **PASS** (unit: `TestTgWebJob…`/reset/e2e/epoch зелёные; staging counters/базelines не сброшены — admin up=793301/down=12856796 сохранены)

subscription/QR: **PASS** (sub package tests ok; subcard link с тем же secret fp, `links[]`/subJson без секрета — Phase-2 поведение не изменено, sub-код не тронут)

delete: **PASS** (delete-client it5tgwebonly → record/relations удалены, credential fail-closed; `tgweb_delete_test`/`xray_tgweb_test` зелёные)

Xray isolation: **PASS** (`GetXrayConfig`: 7 инбаундов api+6 VPN, нет tgweb/web.maicraft.tech/secrets; `XRAY_ISOLATION_OK`)

Полный `go test ./...`: 47 ok; FAIL только `amneziawgnet`/`tuic` — тот же набор, что на pristine upstream (WSL1-ограничения), +1 timing-flake discord-gateway (зелёный при изолированном прогоне на обоих деревьях). Регрессий от патча нет.

## BUILD

0001: **PASS** (`git apply --check` + apply на свежем worktree 6be3c438)

0002: **PASS** (обновлён: полные секции изменённых файлов + дельта; repro-дерево байт-в-байт совпало с рабочим)

0003: **PASS**

0004: **PASS**

backend tests: **PASS** (service `-run 'TgWeb|Tgweb|Detach|Update|Bulk'` ok; tgweb/job/sub ok; `go test ./internal/web/... -run '^$'` compile-check ok; `go build ./...` ok)

frontend: **PASS** (`npm ci` exit 0; vitest 1707 passed; typecheck; lint 0/0; format:check)

make build: **PASS** (EXIT=0)

## Staging replay (restore → migration → schema init → reconcile → A–D → outage → security)

DB восстановлена из бэкапа (sha256 `d74681b1…` совпал), runtime-state из сида (`e5252de4…`), 6/6 fingerprints совпали с reference. Initial reconcile: 6/6 enabled, quota synced. Все сценарии A–D, outage (detach при лежащем runtime → desired state в DB → возврат → reconciler применил disable), security (секреты отсутствуют в generic inbounds API, логах, ответах; subcard redacted) и idempotency миграции — по transcripts `staging-crud-transcript.log` / `staging-crud-runtime.log`. Финал: clients 6, tgweb_ci 6, vpn_ci 42, все fingerprints = reference.

## Definition of Done §31

Update attached TgWeb client works — **YES**. Detach removes client_inbounds relation — **YES**. Runtime disabled after detach — **YES**. Reattach preserves secret — **YES**. TgWeb-only global disable/enable works — **YES**. VPN attachments unchanged — **YES**. TgWeb CRUD does not pollute Xray — **YES**. Fresh upstream + 0001..0004 passes clean build/tests — **YES**.

**Итог: все критерии DoD выполнены. STOP.**
Production rollout не выполнялся; следующий этап — Production Rollout Design (backup, migration, deploy, smoke, rollback).

## Artifacts (workspace `…/tasks/2026-10-07/02-02-17-815182e6/`)

- `0002-tgweb-runtime-reconciler.patch` — обновлённый патч (md5 `4fffa16f…` в KIT)
- `iteration5-integration.diff` — дифф integration-репозитория 9bc5484→63068b8
- `iteration5-upstream.diff` — материализованный дифф против upstream (3 исходных файла + новый тест)
- `iteration5-full.diff` / `iteration5-delta.diff` — дельта итерации 5 (та, что добавлена в 0002)
- `tgweb_crud_test.go` — 7 обязательных тестов; `crud_fixes.py` — применение правок
- `staging-crud-transcript.log`, `staging-crud-runtime.log` — staging CRUD логи
- `staging-crud-fingerprints.json` — sanitized fingerprints (sha256, без сырых секретов)
- git commit: `63068b8438a89ffddeeeba8603c323e07b26b8fd` (branch `feature/tgwebproxy-integration`, repo 3X-UI_KIT)

Raw secrets/tokens в отчёт и артефакты не включены (только sha256 fingerprints).
