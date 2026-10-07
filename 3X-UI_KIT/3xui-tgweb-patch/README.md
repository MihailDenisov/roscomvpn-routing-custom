# TgWeb integration patchset for 3x-ui

Target baseline:

```text
MHSanaei/3x-ui@6be3c438e1420f24dd10060f8a1dd620b2d0e73b
```

This directory contains a **development/test patchset only**. It must not be
deployed to production MAIN without explicit approval.

## Architecture

TgWeb is a normal 3x-ui inbound attachment with:

```text
protocol = tgweb
port     = 0
listen   = ""
```

It uses ordinary `client_inbounds`, but is hard-excluded from Xray.

Public traffic remains:

```text
Internet :443
  -> nginx stream ssl_preread
  -> SNI web.maicraft.tech
  -> local nginx TLS vhost
  -> HTTP/WebSocket
  -> 127.0.0.1:4600
  -> tgwebproxy-multi (behind_proxy=true)
```

Admin reconciliation remains loopback-only:

```text
3x-ui -> http://127.0.0.1:9601/clients
```

See `ARCHITECTURE.md` and `nginx-sni-reference.conf`.

## Patch order

Apply to a clean checkout of the pinned upstream commit:

```bash
git checkout 6be3c438e1420f24dd10060f8a1dd620b2d0e73b

git apply --check 0001-tgweb-protocol-isolation.patch
git apply 0001-tgweb-protocol-isolation.patch

git apply --check 0002-tgweb-runtime-reconciler.patch
git apply 0002-tgweb-runtime-reconciler.patch

git apply --check 0003-tgweb-frontend.patch
git apply 0003-tgweb-frontend.patch
```

Do not continue if any `--check` fails. Rebase the patchset against the new
upstream explicitly instead of forcing hunks.

## Runtime configuration

Patch 0002 defaults to:

```text
admin URL  = http://127.0.0.1:9601
token file = /etc/tgwebproxy/admin.token
```

Optional server-side overrides:

```bash
XUI_TGWEB_ADMIN=http://127.0.0.1:9601
XUI_TGWEB_TOKEN_FILE=/etc/tgwebproxy/admin.token
```

The implementation rejects a non-loopback admin URL and never serializes the
admin token into frontend/API data.

The TgWeb inbound itself stores only public metadata, e.g.:

```json
{
  "publicHost": "web.maicraft.tech",
  "publicPort": 443,
  "clients": []
}
```

Runtime client secrets remain owned by tgwebproxy-multi.

## Tests

Backend safety and runtime tests:

```bash
go test ./internal/tgweb/...
go test ./internal/web/service/... -run 'TgWeb|Tgweb'
```

Then run the wider backend suite:

```bash
go test ./internal/web/service/...
go test ./internal/web/job/...
```

Frontend:

```bash
cd frontend
npm ci
npm test -- --run src/test/tgweb-inbound-form.test.ts
npm run build
```

Finally build the panel using the upstream project's normal build procedure.

## Mandatory acceptance checks

1. Create a TgWeb inbound with public host `web.maicraft.tech`.
2. Confirm its DB row has `protocol=tgweb`, `port=0`.
3. Attach an existing client through the standard client inbound selector.
4. Confirm a normal `client_inbounds` row is created.
5. Confirm no TgWeb UUID/password/runtime secret is minted in the 3x-ui client record.
6. Generate Xray config and confirm none of these appear:
   - `tgweb`
   - `web.maicraft.tech`
   - TgWeb runtime secret
   - TgWeb inbound tag
7. Attach/detach TgWeb only and confirm Xray restart is not requested.
8. Stop or firewall the local TgWeb admin API, edit a normal VPN client, and
   confirm the 3x-ui edit succeeds. Restore TgWeb API and confirm reconciliation
   catches up.
9. Detach and reattach an existing TgWeb client and confirm its runtime secret is
   unchanged.
10. Verify expiry and shared quota disable TgWeb.
11. Verify `NAME-awg` / `NAME-awg2` traffic contributes to `NAME` quota but
    does not produce a separate TgWeb runtime client.

## Traffic accounting note

Patch 0002 intentionally does **not** write TgWeb runtime byte counters into
3x-ui's `client_traffics` table.

The shared-quota calculation is currently:

```text
VPN/Xray/AWG usage from 3x-ui DB
+ current TgWeb runtime bytes
```

This preserves correct enforcement without double counting. A later patch may
surface TgWeb traffic inside the 3x-ui UI, but it must introduce explicit
anti-double-count accounting first.

## Migration gate

Do not switch the production reconciler to DB attachment policy until all of
these are true:

- patched panel binary is built and tested;
- one `tgweb` inbound exists;
- existing TgWeb users are mapped:
  - existing runtime client + no `[tgweb:off]` -> attach;
  - `[tgweb:off]` -> detached;
  - no existing runtime client -> detached;
- existing runtime secrets/counters are unchanged;
- only after successful mapping remove the legacy marker while preserving the
  rest of each comment.

During development, current KIT scripts retain a legacy-marker fallback when
no TgWeb inbound exists.

## SNI deployment gate

`tgwebproxy-multi` currently runs with `behind_proxy=true`, therefore
`127.0.0.1:4600` is plaintext HTTP/WebSocket.

Never configure stream `ssl_preread` to send raw TLS directly to `:4600`.
Use the local TLS-vhost hop documented in `nginx-sni-reference.conf`.

Before any production change:

```bash
nginx -t
ss -lntp
```

Confirm the local TLS vhost, TgWeb backend and admin port are loopback-only,
then run the TgWeb deployment probe against the public hostname.

## Rollback

Before an eventual production rollout, back up the 3x-ui database.

To roll back to an unpatched panel:

1. disable the TgWeb inbound;
2. migrate desired attachment state back to legacy KIT policy if needed;
3. remove/detach the TgWeb inbound and its `client_inbounds` rows;
4. restore the previous panel binary;
5. keep tgwebproxy-multi running independently if desired.

An older 3x-ui binary does not understand `protocol=tgweb`; do not leave a
TgWeb inbound row active when rolling back.
