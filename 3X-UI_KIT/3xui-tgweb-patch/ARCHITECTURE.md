# 3x-ui ↔ TgWebProxy integration architecture

Upstream baseline: `MHSanaei/3x-ui@d57dcf824b6211201252da137b79029747f142f3`.

## Decision

TgWeb is an **external/virtual client attachment**, not an Xray inbound.

Do **not** create a row in `inbounds`, do not use a fake protocol, and do not encode TgWeb as a negative integer in `inboundIds`.

Persist desired state in a new join table:

```text
client_external_inbounds
  client_id   INTEGER NOT NULL
  provider    TEXT    NOT NULL
  created_at  BIGINT
  PRIMARY KEY (client_id, provider)
```

Initial provider set contains one stable key: `tgweb`.

The normal API/UI keeps real Xray inbound IDs in `inboundIds: number[]` and adds:

```json
{
  "externalInboundKeys": ["tgweb"]
}
```

This preserves old API clients and creates a type-level barrier between Xray IDs and external providers.

## Why this is the safest option

The upstream Xray path reads `inbounds` and `client_inbounds`. The new table is never joined by Xray config generation. Therefore no TgWeb value can become:

- an Xray listener;
- an Xray protocol;
- an Xray tag;
- an `inbound.settings.clients[]` entry;
- a reason to restart/reload Xray.

Only the existing real `inboundIds` are passed to `ClientService.Attach/Detach/Create` and `InboundService`.

## Database changes

### New model

Add `model.ClientExternalInbound` in `internal/database/model/model.go`:

- `ClientId int` — composite primary key, indexed;
- `Provider string` — composite primary key;
- `CreatedAt int64`.

Table name: `client_external_inbounds`.

No TgWeb secret is stored in 3x-ui DB. The secret stays owned by TgWebProxy and its private state file.

### Migration

Add the model to the normal AutoMigrate model list and to `migrationModels` in `internal/database/migrate_data.go` so SQLite↔PostgreSQL migration includes it.

Migration/bootstrap of desired state must be idempotent:

1. Existing row => keep it.
2. Client comment contains `[tgweb:off]` => do not attach `tgweb`; remove only this marker after migration succeeds, preserving the rest of the comment.
3. No marker and a TgWeb client with the same canonical client name exists => attach `tgweb`.
4. No marker and no TgWeb client exists => leave detached. This is the safe default: migration must not silently create WebProxy credentials for every VPN user.

Existing TgWeb secrets and counters are never rewritten by the migration.

## Backend API

Existing routes stay:

- `POST /panel/api/clients/{email}/attach`
- `POST /panel/api/clients/{email}/detach`

Request body is extended compatibly:

```json
{
  "inboundIds": [7, 9],
  "externalInboundKeys": ["tgweb"]
}
```

Old requests containing only `inboundIds` keep current behavior.

Client hydrate/list payloads gain:

```json
{
  "externalInboundKeys": ["tgweb"],
  "externalInboundStates": {
    "tgweb": {
      "desiredAttached": true,
      "runtime": "active|disabled|pending|error|unknown"
    }
  }
}
```

Runtime state is display-only; the attachment table is the source of truth.

Bulk attach/detach: phase 1 leaves external providers unsupported in bulk actions. The UI must not offer TgWeb in those bulk modals. This avoids widening the initial patch surface.

## TgWeb integration service

Add an isolated package/service (proposed path `internal/web/service/tgweb`) with:

- provider key constant `tgweb`;
- private admin API client;
- reconciliation entry point;
- migration probe;
- runtime-state cache/status.

Configuration is read server-side only (environment/file wiring in the custom patch), including:

- public host used to build the share link;
- admin URL fixed to loopback/private socket;
- admin token file.

The token is never serialized to API responses or frontend data and is never logged.

Desired state lives in 3x-ui. A failed TgWeb call must not roll back an otherwise valid Xray client edit. Reconciliation retries later.

## Effective enable policy

For an attached TgWeb provider:

```text
effective_enabled =
    client.enable
    AND not_expired
    AND quota_not_exhausted
```

Detached clients are disabled/absent regardless of `client.enable`.

Quota sent to TgWeb is the remaining shared allowance after already-accounted VPN/AWG usage. TgWeb usage is then included once in aggregate usage. AWG shadow identities such as `NAME-awg` / `NAME-awg2` never receive their own external attachment.

## Delete semantics

Client deletion first records/removes desired TgWeb attachment and schedules a reconcile that disables/removes the TgWeb credential, then performs existing VPN deletion. TgWeb unavailability must not leave VPN deletion blocked; the reconciler handles the outstanding external cleanup.

## Subscription behavior

The admin/client share-link endpoint may return a TgWeb link only when `tgweb` is desired-attached.

Do not inject `tg://webproxy` into generic VPN subscription formats (Mihomo/FlClash/Hiddify/Happ). It should be exposed separately on the personal subscription page/UI.

## Frontend

The edit form renders one extra option in the same visual selector:

```text
☑ Telegram WebProxy   [External]
```

Tooltip: `External Telegram WebProxy. Does not create an Xray inbound.`

Internally it binds to `externalInboundKeys`, not to `inboundIds`.

The clients table/chip cell can render `Telegram WebProxy` next to real inbound chips while retaining separate data internally.

## Exact upstream files to change

Backend/schema:

- `internal/database/model/model.go`
- `internal/database/db.go` (AutoMigrate registration / settled checks if needed)
- `internal/database/migrate_data.go`
- `internal/web/service/client.go`
- `internal/web/service/client_lookup.go`
- `internal/web/service/client_crud.go`
- `internal/web/service/client_portable.go` (export/import semantics)
- `internal/web/controller/client.go`
- new isolated TgWeb service files under `internal/web/service/tgweb/`

Frontend:

- `frontend/src/schemas/client.ts`
- `frontend/src/hooks/useClients.ts`
- `frontend/src/pages/clients/ClientFormModal.tsx`
- `frontend/src/pages/clients/ClientsPage.tsx`
- `frontend/src/pages/clients/ClientInfoModal.tsx`
- locale strings for the new label/tooltip/statuses

Tests:

- database migration/model tests;
- client attach/detach CRUD tests;
- controller/API compatibility tests;
- Xray config regression assertion;
- TgWeb reconciler unit tests using an httptest admin endpoint;
- frontend schema/form tests.

## Explicitly not changed

- Xray config generator;
- `model.Inbound`;
- Xray inbound validation;
- nginx stream config;
- MTProto/MTG;
- UFW;
- production services.

## Rollback

Before production deployment, back up the 3x-ui DB.

Rollback of the panel patch is safe because the only new persistent object is `client_external_inbounds`; an older binary ignores that table. The table may be retained for a later retry or dropped after exporting desired attachments. TgWebProxy remains independently operational.

No production deployment or merge to upstream/main is part of this patchset.
