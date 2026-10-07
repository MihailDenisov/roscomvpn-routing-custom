# REPORT — PRODUCTION ROLLOUT DESIGN, FINAL CORRECTIONS

Дата: 2026-10-07. Задача: documentation/preflight refinement только — **роллаут НЕ выполнялся**.
Кандидат: integration commit `63068b8438a89ffddeeeba8603c323e07b26b8fd` = upstream `6be3c438e1420f24dd10060f8a1dd620b2d0e73b` + 0001 + 0002(iter5) + 0003 + 0004.
Три финальные правки: (1) порядок отката, (2) реальный ABI/glibc preflight, (3) убрана обязательная live-правка KIT из cutover.

---

## ROLLBACK ORDER FIX

| Проверка | Результат |
|---|---|
| old x-ui starts before reconciler | **PASS** — ROLLBACK.md: шаг 6 (start x-ui) → шаг 7 (verify) → шаг 8 (`enable --now kit-tgweb-reconcile.timer`) только после верификации; явное правило «reconciler НИКОГДА не стартовать до работающего x-ui» |
| panel/API verification before reconciler | **PASS** — шаг 7: `systemctl is-active x-ui`, `curl http://127.0.0.1:2097/` (панель слушает 127.0.0.1:2097, подтверждено read-only), listener check, sidecar'ы Xray/mtg/tuic, повторная DB-сверка; стоп-критерий «панель не отвечает → reconciler НЕ включать» |
| successful reconciler tick verification | **PASS** — шаг 9: явная верификация первого тика (`ExecMainStatus == 0`, grep journal на 401/auth-fail/error, fingerprint/counter сверка против `$RB/tgweb-runtime-before.json` из rollback-бандла с флагом `RECONCILER_TICK_VERIFY`); не ограничивается «timer active» |

Дополнительно: ожидаемые DB-counts в откате берутся из манифеста preflight (не хардкодятся в скриптах — GOAL §2); `PRAGMA integrity_check = ok` — стоп-критерий перед стартом x-ui.

## BINARY COMPATIBILITY

Проверено на production 2026-10-07, read-only команды (`file`, `ldd`, `readelf`, `sha256sum`); бинарник **не запускался**.

```text
candidate sha256:  f625eac057b32b6868bfa43fdb8cdb000efc1617136838fc18edf75690aa87dd
                   (== validated artifact; совпал локально и на /usr/local/x-ui/x-ui.tgweb.new)
architecture:      x86-64 → совпадает с production host (x86_64) → PASS
static/dynamic:    DYNAMIC (interpreter /lib64/ld-linux-x86-64.so.2)
                   [reference: текущий x-ui STATICALLY linked — для сравнения]
production glibc:  2.39 (ldd (Ubuntu GLIBC 2.39-0ubuntu8.9) 2.39; Ubuntu 24.04.5)
max required glibc: 2.34 (readelf --version-info, max символ GLIBC_2.34)
missing libraries: none — ldd: libc.so.6 + ld-linux + linux-vdso, все resolve, "not found" нет
compatibility:     PASS (2.34 <= 2.39; динамические зависимости только стандартные)
```

Отметки: бинарник собран в WSL1 (glibc 2.43 у сборочного окружения), но требует только GLIBC ≤ 2.34. Кандидат `with debug_info, not stripped` — 102 MB против 73 MB у текущего; на совместимость не влияет, при желании можно strip'нуть перед окном (hash при этом изменится — перефиксировать). Переподтверждение ABI-пункта входит в PRE-FLIGHT на день окна.

## KIT POLICY

| Проверка | Результат |
|---|---|
| live KIT edit removed | **PASS** — PRODUCTION-ROLLOUT.md Phase I переписан: sed/script-правки `/usr/local/bin/kit` убраны; ROLLBACK.md секция guard-заглушки удалена (восстанавливать нечего) |
| legacy automatic reconciler still stopped in cutover | **PASS** — Phase F без изменений: `systemctl stop kit-tgweb-reconcile.timer kit-tgweb-reconcile.service` + `disable` перед миграцией; остаются stopped+disabled в Phase I |
| legacy KIT mutation command frozen operationally | **PASS** — Phase E «Шаг 0 окна»: владелец подтверждает freeze; Phase I и PRE-FLIGHT содержат явный запрет `DO NOT USE LEGACY KIT TgWeb MUTATION COMMANDS` на окно + observation-период; freeze снимается только после стабилизации |
| post-rollout cleanup separated | **PASS** — Phase I: отдельная follow-up задача после стабилизации — (A) миграция `kit user web` на client_inbounds path или (B) retirement команды; в initial deployment не смешивается |

Бэкапы KIT (`/usr/local/bin/kit`, `/usr/local/sbin/kit-tgweb-reconcile`, `/etc/kit/tgweb.env`) остаются обязательной частью бандла Phase B — файлы не изменяются и не удаляются (GOAL §10); добавлены в команды Phase B.

## UPDATED RISK SECTION

Убран риск «live KIT guard modification» (human-error при sed-правке в окне) — устранён самой правкой дизайна.

```text
RISK: legacy KIT mutation command remains present
  (/usr/local/bin/kit → `kit user web NAME on|off` → tgweb_sync_user → PUT /clients)
  Митигация:
  - administrative freeze на maintenance window + observation period
    (подтверждение владельцем, шаг 0 окна; явный запрет в Phase I / PRE-FLIGHT)
  - automatic legacy reconciler disabled (Phase F) — фоновых мутаций нет
  - отдельная post-rollout cleanup-задача: миграция на client_inbounds path
    или retirement команды
```

Сохранены без изменений (перенесены из базового отчёта, mitigations прежние): живой WAL при бэкапе (backup API, запрет cp); периодичность TgWebJob — проверить настройку панели в окне read-only до Phase F; staging≠production drift — свежая перепроверка counts/fingerprints в PRE-FLIGHT; новый риск несовпадения ABI при **любой пересборке** — любая новая сборка обязана повторить ABI/hash preflight (в чек-листе).

## DoD §22 — сверка

1. rollback starts old x-ui before legacy reconciler — **PASS** (ROLLBACK.md шаги 6→8)
2. panel/API health verified before reconciler restart — **PASS** (шаг 7 + стоп-критерий)
3. reconciler first successful tick explicitly checked — **PASS** (шаг 9, `RECONCILER_TICK_VERIFY`)
4. new binary hash matches validated artifact — **PASS** (`f625eac0…87dd` локально и на production)
5. binary ABI/glibc compatibility proven on production — **PASS** (file/ldd/readelf на production: dynamic, max GLIBC 2.34 ≤ 2.39)
6. no missing runtime libraries — **PASS** (ldd: все resolve)
7. live KIT editing removed from initial cutover — **PASS** (Phase I, Phase E шаг 0)
8. automatic legacy reconciler still disabled during cutover — **PASS** (Phase F)
9. legacy KIT TgWeb mutation use administratively frozen — **PASS** (Phase I/E + PRE-FLIGHT)
10. no production mutation during this task — **PASS** — выполнены только read-only команды (file/ldd/readelf/sha256sum/systemctl status/grep/ss/curl GET) и **stage нового файла** `/usr/local/x-ui/x-ui.tgweb.new` (добавление файла, прямо предусмотренное GOAL §4/§7; live-бинарник, сервисы, таймер, БД, конфиги, KIT, nginx не тронуты — `x-ui/tgwebproxy/kit-tgweb-reconcile.timer` подтверждены active после)

**DoD 10/10. Секреты не раскрыты — только sha256 fingerprints.**

## Обновлённые артефакты

- `PRODUCTION-ROLLOUT.md` — Phase B (KIT-бэкапы), Phase D (результаты ABI-preflight), Phase E (шаг 0 freeze), Phase I (без live-правки KIT, отдельный cleanup)
- `ROLLBACK.md` — новый 10-шаговый порядок (x-ui до reconciler), верификация первого тика, KIT-политика
- `PRE-FLIGHT-CHECKLIST.md` — секция Binary ABI/glibc compatibility + организационные пункты (reconciler идентифицирован, freeze KIT-команд)
- `REPORT-PRODUCTION-ROLLOUT-DESIGN-FINAL.md` — данный отчёт
- Staged артефакт на production: `/usr/local/x-ui/x-ui.tgweb.new` (1001:1001 755, sha256 `f625eac0…`)

## Статус

**STOP.** Роллаут не выполнялся и не начинается без явного approve владельца. Порядок после approve: PRE-FLIGHT (read-only часть + переподтверждение ABI) → Phase B (бэкапы) → Phase C (dry-run) → окно Phase F–H → smoke → Phase J; любой стоп-критерий → ROLLBACK.md.

---

## Addendum 2026-10-07 — runbook consistency fixes (FIX-1/2/3)

Внесены три исправления consistency в runbook (только документация, production не тронут):
**FIX-1** sanitized runtime reference (`tgweb-runtime-before.json`) теперь пишется и читается строго из rollback-бандла `$RB` (единый explicit output path; standalone `/root/tgweb-runtime-before.json` исключён);
**FIX-2** raw emergency-only snapshot `tgweb-runtime-state.json` добавлен в Phase B (команды задокументированы, не выполнялись); семантика emergency-only сохранена;
**FIX-3** хардкод имён пользователей убран из Phase C и Phase F — `$RB/runtime-names.json` генерируется из fresh GET /clients (только домен `web.maicraft.tech`), один и тот же файл для dry-run и apply, drift-check перед apply.

Детали и PASS/FAIL — в `REPORT-PRODUCTION-ROLLOUT-RUNBOOK-FIXES.md`. Предыдущая версия отчёта сохранена как `REPORT-PRODUCTION-ROLLOUT-DESIGN-FINAL2.md`.
