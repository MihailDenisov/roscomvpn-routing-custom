# 3x-ui ↔ TgWebProxy integration architecture

Upstream baseline: `MHSanaei/3x-ui@6be3c438e1420f24dd10060f8a1dd620b2d0e73b`.

## Decision

TgWeb follows the existing **MTProto-style non-Xray inbound** pattern.

It is a real 3x-ui `Inbound` row and uses the normal `client_inbounds` attachment table, but its runtime is external and it never becomes an Xray listener/config object.

Stable protocol key:

```text
tgweb
```

Network publishing stays outside 3x-ui:

```text
Internet :443
    |
nginx stream / ssl_preread
    |
SNI web.maicraft.tech
    |
127.0.0.1:4600
    |
tgwebproxy-multi
```

The private management API remains:

```text
127.0.0.1:9601
```

3x-ui manages desired clients through that loopback API; nginx/SNI routing is static and does not change per user.

## Why this is preferred

Current upstream already treats MTProto, AmneziaWG and TUIC as protocols that are represented as normal inbounds in the panel while being served outside Xray.

TgWeb can therefore reuse the familiar client assignment model:

```text
clients
inbounds
client_inbounds
```

Example:

```text
MV
 ├─ Reality inbound
 ├─ XHTTP inbound
 ├─ MTProto inbound
 └─ Telegram WebProxy inbound (protocol=tgweb)
```

No negative IDs, no virtual IDs and no second attachment table are needed.

## Port/listener model

TgWeb does **not** own public port 443. nginx owns the public listener and routes by SNI.

The TgWeb inbound is portless from 3x-ui's runtime perspective:

```text
Protocol = tgweb
Port     = 0
Listen   = ""
```

Upstream currently validates inbound ports as `gte=0,lte=65535`, so `0` is representable without a fake port.

The public endpoint used for share links is configured separately:

```text
publicHost = web.maicraft.tech
publicPort = 443
```

The backend and management endpoints remain server-side implementation details:

```text
backend = 127.0.0.1:4600
admin   = 127.0.0.1:9601
```

No backend/admin address or admin token is exposed to the browser.

## Xray isolation

This is the critical invariant.

Upstream already excludes non-Xray protocols from Xray config generation. TgWeb must be added to every equivalent exclusion/capability gate.

Conceptually:

```go
if inbound.Protocol == model.MTProto ||
   inbound.Protocol == model.AmneziaWG ||
   inbound.Protocol == model.TUIC ||
   inbound.Protocol == model.TgWeb {
    continue
}
```

Mandatory regression test:

1. create a `tgweb` inbound;
2. attach a client;
3. generate Xray config;
4. assert that no `tgweb`, `web.maicraft.tech`, TgWeb secret, listener, tag or fake protocol appears in the Xray JSON.

Attaching/detaching TgWeb alone must not request an Xray restart.

## Database

No new attachment table.

Add only the new protocol constant/validation value:

```go
TgWeb Protocol = "tgweb"
```

The existing tables remain authoritative:

```text
inbounds
clients
client_inbounds
```

The TgWeb secret is not stored in 3x-ui's generic Xray client fields unless a later implementation proves that safe and upstream-friendly. Phase 1 keeps the runtime secret owned by tgwebproxy-multi and reconciles it through the private management API.

## TgWeb inbound settings

The inbound settings should contain only non-secret operational metadata required by the panel, for example:

```json
{
  "publicHost": "web.maicraft.tech",
  "publicPort": 443
}
```

Local admin URL/token are read from server-side configuration, not persisted in browser-visible inbound JSON.

If desired, a later revision may support multiple TgWeb runtimes/providers, but phase 1 targets one local `tgwebproxy-multi` instance.

## Runtime integration

Add an isolated package, proposed:

```text
internal/tgweb/
  client.go
  manager.go
  model.go
```

and a periodic web job:

```text
internal/web/job/tgweb_job.go
```

Unlike MTProto, TgWeb Manager does not spawn a listener process. It reconciles the already-running `tgwebproxy-multi` through the loopback management API.

Desired state comes from:

- enabled local `tgweb` inbound;
- clients attached through `client_inbounds`;
- client enable flag;
- expiry;
- shared quota state.

Runtime state is eventually reconciled. TgWeb/API failure must not make normal VPN edits fail.

## Effective enable policy

For a client attached to the enabled TgWeb inbound:

```text
effective_enabled =
    client.enable
    AND tgweb_inbound.enable
    AND not_expired
    AND quota_not_exhausted
```

If the client is detached, it is disabled/removed from TgWeb desired state.

Re-attachment reuses the existing TgWeb secret when the runtime still has it; a new secret is created only when no credential exists.

## Shared quota and AWG shadows

Shared quota remains calculated across the canonical client identity.

AWG shadow names such as:

```text
MV-awg
MV-awg2
```

contribute traffic to `MV` but do not receive their own TgWeb credentials.

TgWeb usage is counted exactly once in the aggregate.

## SNI routing

The production-facing flow uses two nginx layers in the same nginx process/configuration role:

```text
Telegram WebProxy client
    |
TLS ClientHello, SNI=web.maicraft.tech
    |
MAIN :443
    |
nginx stream + ssl_preread
    |
local TLS terminator for web.maicraft.tech
    |
HTTP / WebSocket reverse proxy
    |
127.0.0.1:4600
    |
tgwebproxy-multi (behind_proxy=true)
```

Important: with `behind_proxy=true`, `tgwebproxy-multi` on `127.0.0.1:4600` serves plaintext HTTP/WebSocket. The stream SNI router must therefore **not** forward raw TLS directly to port 4600.

A typical shape is:

```text
:443 stream SNI router
  web.maicraft.tech -> 127.0.0.1:<local TLS vhost port>
                              |
                              | nginx ssl server
                              v
                        http://127.0.0.1:4600
```

The TLS vhost must preserve the original `Host`, forward WebSocket Upgrade/Connection headers, preserve the query string for the upstream request, and avoid logging the capability-bearing query string.

An alternative future mode is raw TLS passthrough directly to TgWeb, but only if TgWeb is run with `behind_proxy=false` and owns its certificate/TLS listener on a private local port. That is not the selected phase-1 deployment.

The 3x-ui patch does not modify production nginx. A reference nginx fragment may be shipped with the patchset, but applying it to MAIN remains a separate, explicitly approved deployment step.

## Client CRUD / attachment behavior

Because TgWeb uses normal `client_inbounds`:

- create/edit can select Telegram WebProxy alongside other inbounds;
- attach/detach APIs remain structurally unchanged;
- list/paged/hydrate use ordinary `inboundIds`;
- bulk attach/detach can work through the existing inbound mechanism once protocol-specific validation is safe.

Protocol-specific client defaults must not invent Xray credentials for TgWeb.

Attaching/detaching TgWeb invokes/reconciles only the TgWeb runtime path and must not add TgWeb to Xray.

## Frontend

Add `tgweb` as a supported inbound protocol and display:

```text
Telegram WebProxy
```

Recommended badge/description:

```text
External
Published via SNI routing. Does not create an Xray listener.
```

TgWeb should have a minimal form. Phase 1 fields:

- public host: `web.maicraft.tech`;
- public port: `443`.

It should not expose:

- Xray stream settings;
- sniffing;
- TLS/Reality controls;
- local backend/admin address;
- admin token.

## Share link / subscription

TgWeb share link:

```text
https://t.me/webproxy?secret=<secret>&server=web.maicraft.tech
```

Expose it only for a client attached to the TgWeb inbound and only through a dedicated/share-link context.

Do not inject the TgWeb share link (`https://t.me/webproxy`) into generic VPN subscription payloads for Happ/FlClash/Hiddify/Mihomo.

## Migration from current KIT state

Migration remains idempotent and preserves existing TgWeb secrets/counters.

For each canonical client:

1. if already attached to a `tgweb` inbound, keep it;
2. if comment contains `[tgweb:off]`, leave detached;
3. otherwise, if a TgWeb runtime client with the same canonical name exists, attach to the TgWeb inbound;
4. otherwise leave detached.

After a successful migration, remove only the legacy `[tgweb:off]` marker while preserving the rest of the comment.

Do not silently create TgWeb credentials for every VPN client.

The migration must run before the reconciler switches from legacy comment policy to DB attachment policy.

## Exact upstream areas to change

Backend/model:

- `internal/database/model/model.go` — add `TgWeb` protocol and validator value.
- `internal/web/service/inbound_protocol.go` — protocol capability/node policy.
- `internal/web/service/xray.go` — hard exclusion from Xray config generation.
- `internal/web/runtime/local.go` — local runtime dispatch for TgWeb without Xray restart.
- `internal/web/service/client_crud.go` — protocol-specific client defaults/validation.
- `internal/web/service/client_inbound_apply.go` — attach/detach runtime application.
- new `internal/tgweb/` package.
- new `internal/web/job/tgweb_job.go`.
- web startup/job registration alongside existing non-Xray runtimes.

Frontend:

- protocol schemas/registry;
- inbound form registry;
- protocol capability gates so TgWeb has no stream/TLS/Reality/sniffing controls;
- protocol labels/icons/locales;
- minimal TgWeb settings form.

Tests:

- TgWeb protocol/model validation;
- attach/detach through normal `client_inbounds`;
- no Xray restart for TgWeb-only attachment changes;
- Xray config contains no TgWeb data;
- TgWeb API unavailable does not break normal client changes;
- enable/disable, expiry and quota behavior;
- deletion;
- existing-secret preservation;
- AWG shadow aggregation;
- frontend protocol/form capability tests.

## Explicitly not changed in this patchset

- production nginx;
- production `connect.maicraft.tech`;
- UFW;
- MTG/MTProto behavior;
- existing Xray protocols;
- upstream/main.

## Rollback

Before any eventual production deployment, back up the 3x-ui DB.

The database addition is a normal `inbounds` row with `protocol=tgweb` plus ordinary `client_inbounds` rows. Rollback procedure must first disable/remove that inbound (or migrate assignments back to legacy KIT policy) before starting an older 3x-ui binary that does not recognize `tgweb`.

TgWebProxy remains independently operational.

No production deployment or upstream merge is part of this patchset.
