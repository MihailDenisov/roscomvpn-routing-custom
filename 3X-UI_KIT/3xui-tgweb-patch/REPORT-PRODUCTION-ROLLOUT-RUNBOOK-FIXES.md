# REPORT — PRODUCTION ROLLOUT RUNBOOK FIXES (FIX-1/2/3)

Дата: 2026-10-07. Задача: documentation/runbook correction only — **роллаут НЕ выполнялся**, production не мутировал (ниже §DoD п.10).
Кандидат без изменений: integration commit `63068b8438a89ffddeeeba8603c323e07b26b8fd` = upstream `6be3c438e1420f24dd10060f8a1dd620b2d0e73b` + 0001 + 0002(iter5) + 0003 + 0004.
Все прочие решения (порядок отката, ABI/glibc, KIT freeze, nginx, smoke) — без изменений (GOAL §20).

## FIX-1 — tgweb-runtime-before.json path inconsistency

| Проверка | Результат |
|---|---|
| runtime-before stored inside RB | **PASS** — PRODUCTION-ROLLOUT.md Phase B: генерация через `python3 - "$RB/tgweb-runtime-before.json"` с `out_path = sys.argv[1]` и `open(out_path, "w")`; единый explicit path, без одновременного shell-redirection и внутреннего хардкода; `chmod 600` |
| rollback reads same file | **PASS** — ROLLBACK.md: `RB=/root/pre-tgweb-rollout-<TS>` задан в шапке процедуры; шаг 9 читает `sys.argv[1]` == `$RB/tgweb-runtime-before.json` |
| no duplicate /root standalone reference | **PASS** — POST-DEPLOY-SMOKE.md §4 сверка переведена на `$RB/tgweb-runtime-before.json` (argv); паттерн `/root/tgweb-runtime-before.json` в активных документах отсутствует (audit § ниже) |

## FIX-2 — emergency runtime state snapshot

| Проверка | Результат |
|---|---|
| runtime-state snapshot added to Phase B | **PASS** — PRODUCTION-ROLLOUT.md Phase B: `cp -a /var/lib/tgwebproxy/clients.json "$RB/tgweb-runtime-state.json"` (+ chmod 600); backup-only, live state не модифицируется. Команды задокументированы, НЕ выполнялись (GOAL §21) |
| chmod 600 | **PASS** — явно в Phase B; чувствительность задокументирована: raw state может содержать реальные секреты — только root-бандл, не печатать, не копировать в отчёты/артефакты |
| emergency-only semantics documented | **PASS** — ROLLBACK.md: нормальный откат = old x-ui + old DB + reconciler, control plane восстанавливает политику; restore clients.json — только credential corruption / secret rotation / counter destruction; семантика явно сохранена |
| preflight requires file | **PASS** — PRE-FLIGHT-CHECKLIST.md §Бэкапы: `[ ] $RB/tgweb-runtime-state.json exists, chmod 600 …` |

## FIX-3 — hardcoded migration names

| Проверка | Результат |
|---|---|
| hardcoded names removed from Phase C | **PASS** — `--names-json "$(cat "$RB/runtime-names.json")"`; dry-run результат фиксируется как эталон |
| hardcoded names removed from Phase F | **PASS** — тот же вызов с `--apply`; литеральный список пользователей из executable-команд удалён (audit § ниже) |
| runtime-names generated from GET /clients | **PASS** — Phase B: fresh GET /clients → `$RB/runtime-names.json` (chmod 600); печатается только count и имена |
| domain filtered to web.maicraft.tech | **PASS** — генератор пропускает только `dom.get("domain") == "web.maicraft.tech"`; чужие домены не мержатся молча → репорт/STOP (Phase B валидация + GOAL §12 отражён) |
| same file used for dry-run and apply | **PASS** — обе фазы читают `"$(cat "$RB/runtime-names.json")"`; правило «не регенерировать между dry-run и apply без изменения state» задокументировано |
| drift check before apply | **PASS** — Phase F: read-only свежий GET /clients vs `$RB/runtime-names.json` НЕПОСРЕДСТВЕННО перед apply; mismatch → STOP → regenerate → повторный dry-run → переоценка плана; apply со stale names запрещён |

## Consistency audit (GOAL §24)

```text
паттерн ["MV","Vlad",...] в executable migration commands → НЕ НАЙДЕН (осталось только упоминание
  «ожидается 6 пользователей» как историческое ожидание, не команда)
паттерн /root/tgweb-runtime-before.json в активных документах → НЕ НАЙДЕН
  (GOAL-файлы не считаются; FINAL2 — сохранённый предыдущий снимок отчёта)
tgweb-runtime-state.json присутствует: Phase B backup (PRODUCTION-ROLLOUT.md) ✓
  emergency rollback (ROLLBACK.md) ✓ preflight checklist ✓
```

(Контрольные grep'ы выполнены по workspace после правок.)

## DoD §25 — сверка

1. sanitized runtime reference stored inside rollback bundle — **PASS** (FIX-1)
2. rollback reads that same reference — **PASS** (FIX-1)
3. raw runtime state backup actually created in Phase B — **PASS** (команды Phase B; выполнение — в окне, GOAL §21)
4. raw runtime state remains emergency-only — **PASS** (ROLLBACK.md semantics)
5. migration names generated from fresh admin API state — **PASS** (FIX-3)
6. only web.maicraft.tech users included — **PASS** (domain filter + валидация)
7. Phase C and Phase F use the exact same runtime-names.json — **PASS**
8. runtime-name drift checked immediately before apply — **PASS**
9. no hardcoded production usernames in executable migration commands — **PASS** (audit)
10. no production rollout action executed — **PASS** — только правки локальных документов; ни одной ssh-команды в этой задаче

**DoD 10/10. STOP — ждём финального approve владельца перед роллаутом.**

## Обновлённые артефакты

- `PRODUCTION-ROLLOUT.md` — Phase B (три reference-артефакта + валидация имён + MANIFEST.txt), Phase C (runtime-names.json), Phase F (drift-check + тот же файл)
- `ROLLBACK.md` — RB-переменная, reference по `$RB`, emergency-секция актуализирована
- `POST-DEPLOY-SMOKE.md` — сверка по `$RB/tgweb-runtime-before.json`
- `PRE-FLIGHT-CHECKLIST.md` — бэкап-пункты трёх артефактов + dry-run/drift пункты (заодно починен разорванный code-fence)
- `REPORT-PRODUCTION-ROLLOUT-DESIGN-FINAL.md` — addendum; прежняя версия сохранена как `REPORT-PRODUCTION-ROLLOUT-DESIGN-FINAL2.md`
- `REPORT-PRODUCTION-ROLLOUT-RUNBOOK-FIXES.md` — данный отчёт
