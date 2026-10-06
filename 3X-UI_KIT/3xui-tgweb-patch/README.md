# 3x-ui TgWeb virtual inbound patch

This directory contains a fail-closed patchset for:

```text
MHSanaei/3x-ui
d57dcf824b6211201252da137b79029747f142f3
```

It implements TgWeb as a panel-level external attachment with provider key
`tgweb`. It does not create an `inbounds` record and does not modify Xray
config generation.

## Reproducible staging build

```bash
git clone https://github.com/MHSanaei/3x-ui.git 3x-ui
cd 3x-ui
git checkout d57dcf824b6211201252da137b79029747f142f3
cd ..
bash ./3X-UI_KIT/3xui-tgweb-patch/apply.sh ./3x-ui

cd 3x-ui
go test ./internal/web/service/... ./internal/database/...
! grep -Rni --exclude='*_test.go' -E 'tgweb|Telegram WebProxy|externalInboundKeys' internal/xray

cd frontend
npm ci
npm run typecheck --if-present
npm test -- --run
npm run build
cd ..
go build ./...
git diff --binary > ../3x-ui-tgweb.patch
```

The GitHub Actions workflow `.github/workflows/3x-ui-tgweb-patch.yml`
executes the same procedure and uploads the final diff as an artifact.

## Migration

Run `migrate_legacy.py` against a DB copy first. It is dry-run by default.

```bash
python3 migrate_legacy.py --db /path/to/staging/x-ui.db
```

Migration rules:

- `[tgweb:off]` -> detached; only that marker is removed from the comment;
- matching existing TgWeb client -> attached;
- no matching TgWeb client -> detached (safe default);
- AWG shadow identities are ignored;
- the script performs GET-only access to TgWeb, so it does not rotate secrets
  or reset counters.

Only after reviewing the dry-run:

```bash
python3 migrate_legacy.py --db /path/to/staging/x-ui.db --apply
```

## Runtime behavior

The 3x-ui DB is desired state. TgWebProxy is reconciled runtime state.

- attach persists `provider=tgweb`;
- detach removes desired attachment but preserves an existing runtime secret and
  disables it;
- user disable/expiry/quota exhaustion disables TgWeb;
- deleted primary clients cause orphan TgWeb credentials to be disabled, never
  rotated;
- TgWeb outage does not roll back ordinary Xray/VPN edits.

Bulk virtual attach/detach is intentionally not exposed in phase 1.

## Rollback

Before any production installation:

1. back up the 3x-ui database and TgWeb state;
2. retain the original 3x-ui binary;
3. keep the current KIT scripts/package as a tagged rollback point.

An unpatched 3x-ui binary ignores the new `client_external_inbounds` table.
Rollback therefore consists of restoring the previous binary/frontend and KIT
scripts. The new table may remain in place for a later retry; dropping it is
optional only after exporting desired attachment state.

Do not delete or rewrite TgWeb runtime clients during rollback. Their secrets
and usage counters are intentionally owned by TgWebProxy.

## Production guardrail

This patchset does not deploy to `connect.maicraft.tech`, alter nginx, restart
x-ui/Xray, change MTG/MTProto, modify UFW, or touch live users. Production
installation requires separate explicit approval.
