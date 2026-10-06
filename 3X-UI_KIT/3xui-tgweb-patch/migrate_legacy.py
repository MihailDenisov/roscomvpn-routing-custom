#!/usr/bin/env python3
"""Idempotent migration from legacy [tgweb:off] marker policy to the virtual
tgweb inbound + client_inbounds attachment model.

Run only against an OFFLINE COPY / STAGING database first.
This script never calls PUT on tgwebproxy-multi: it reads GET /clients only,
so existing secrets and usage counters cannot be modified.

Idempotency model
-----------------
A marker row in the existing 3x-ui settings table
(`tgweb_client_inbounds_migration_v1 = complete`) is the single source of
truth for "migration has run".

Before the marker is complete, the legacy rules apply per canonical client
(matched by email/name):

  1. already attached to a tgweb inbound            -> keep attached
  2. comment contains [tgweb:off]                   -> detached, marker stripped
  3. no marker and runtime credential exists        -> attached
  4. no marker and no runtime credential            -> detached

AWG shadow identities (email ending in -awg, -awg2, ...) are never treated
as standalone TgWeb identities and are left untouched. The [tgweb:off]
marker is stripped (adjacent whitespace only; the rest of the comment is
preserved) and is not used again.

After the marker is complete, client_inbounds is the ONLY authoritative
attachment state: runtime credentials are never consulted again and a rerun
is a no-op. This closes the previous re-attach defect where a stripped
marker plus a retained (disabled) runtime credential re-attached opted-out
clients on the second run.

Optional --names-json bypasses the runtime query (staging / offline tests):
  ./migrate_legacy.py --db x.db --names-json '["mv","alice"]' --apply
"""
import argparse, json, os, re, sqlite3, urllib.request

MARKER = "[tgweb:off]"
SHADOW = re.compile(r"-awg\d*$")
SETTINGS_KEY = "tgweb_client_inbounds_migration_v1"
SETTINGS_VALUE = "complete"


def read_env(path):
    out = {}
    with open(path, encoding="utf-8") as f:
        for raw in f:
            s = raw.strip()
            if not s or s.startswith("#") or "=" not in s:
                continue
            k, v = s.split("=", 1)
            out[k.strip()] = v.strip().strip("'\"")
    return out


def tgweb_names(admin, token_file, domain):
    token = open(token_file, encoding="utf-8").read().strip()
    req = urllib.request.Request(admin.rstrip("/") + "/clients",
        headers={"Authorization": "Bearer " + token})
    with urllib.request.urlopen(req, timeout=5) as r:
        obj = json.loads(r.read().decode())
    for host in obj if isinstance(obj, list) else []:
        if host.get("domain") == domain:
            return {str(c.get("name")) for c in host.get("clients", []) if c.get("name")}
    return set()


def strip_marker(comment):
    # Remove only the marker and adjacent whitespace; preserve all other text.
    return re.sub(r"\s*\[tgweb:off\]\s*", " ", comment or "").strip()


def migration_state(con):
    row = con.execute("SELECT value FROM settings WHERE key = ?", (SETTINGS_KEY,)).fetchone()
    return row[0] if row else None


def complete_migration(con):
    if migration_state(con) is None:
        con.execute("INSERT INTO settings (key, value) VALUES (?, ?)",
                    (SETTINGS_KEY, SETTINGS_VALUE))
    else:
        con.execute("UPDATE settings SET value = ? WHERE key = ?",
                    (SETTINGS_VALUE, SETTINGS_KEY))


def ensure_tgweb_inbound(con, domain, public_port):
    row = con.execute(
        "SELECT id FROM inbounds WHERE protocol='tgweb' AND node_id IS NULL "
        "ORDER BY id LIMIT 1").fetchone()
    if row:
        return row[0], False
    settings = json.dumps({"publicHost": domain, "publicPort": public_port, "clients": []})
    tag = "tgweb-web"
    if con.execute("SELECT 1 FROM inbounds WHERE tag=?", (tag,)).fetchone():
        tag = "tgweb-web-%d" % (con.execute("SELECT COALESCE(MAX(id),0)+1 FROM inbounds").fetchone()[0])
    cur = con.execute(
        "INSERT INTO inbounds (user_id, remark, protocol, listen, port, enable, "
        "settings, stream_settings, tag, sniffing, share_addr_strategy) "
        "VALUES (1, ?, 'tgweb', '', 0, 1, ?, '', ?, '', 'listen')",
        ("Telegram WebProxy", settings, tag))
    return cur.lastrowid, True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", default="/etc/x-ui/x-ui.db")
    ap.add_argument("--env", default="/etc/kit/tgweb.env")
    ap.add_argument("--names-json", default=None,
                    help="JSON array of runtime client names; skips the runtime query")
    ap.add_argument("--apply", action="store_true", help="commit changes (default: dry-run)")
    ap.add_argument("--force-legacy", action="store_true",
                    help="run legacy rules even if the migration marker is complete")
    args = ap.parse_args()

    con = sqlite3.connect(args.db)
    con.row_factory = sqlite3.Row
    try:
        state = migration_state(con)
        if state == SETTINGS_VALUE and not args.force_legacy:
            # client_inbounds is authoritative; runtime credentials are never
            # consulted after migration. Reruns are no-ops by design.
            print(json.dumps({"alreadyMigrated": True, "dryRun": not args.apply},
                             ensure_ascii=False))
            return

        if args.names_json is not None:
            names = set(json.loads(args.names_json))
            domain = os.environ.get("TGWEB_DOMAIN", "web.maicraft.tech")
            public_port = 443
        else:
            env = read_env(args.env)
            domain = env["TGWEB_DOMAIN"]
            public_port = int(env.get("TGWEB_PUBLIC_PORT", "443"))
            names = tgweb_names(env["TGWEB_ADMIN"], env["TGWEB_TOKEN_FILE"], domain)

        inbound_id, created_inbound = ensure_tgweb_inbound(con, domain, public_port)

        attached = detached = untouched = kept = 0
        stripped = 0
        rows = con.execute(
            "SELECT id,email,COALESCE(comment,'') comment FROM clients ORDER BY id").fetchall()
        for row in rows:
            email, comment = row["email"], row["comment"]
            if SHADOW.search(email):
                untouched += 1
                continue
            is_attached = con.execute(
                "SELECT 1 FROM client_inbounds WHERE client_id=? AND inbound_id=?",
                (row["id"], inbound_id)).fetchone() is not None
            new_comment, marker_removed = comment, False
            if is_attached:
                kept += 1
                if MARKER in comment:
                    new_comment, marker_removed = strip_marker(comment), True
            elif MARKER in comment:
                con.execute(
                    "DELETE FROM client_inbounds WHERE client_id=? AND inbound_id=?",
                    (row["id"], inbound_id))
                new_comment, marker_removed = strip_marker(comment), True
                detached += 1
            elif email in names:
                con.execute(
                    "INSERT OR IGNORE INTO client_inbounds (client_id, inbound_id) "
                    "VALUES (?, ?)", (row["id"], inbound_id))
                attached += 1
            else:
                untouched += 1
            if marker_removed:
                stripped += 1
                con.execute("UPDATE clients SET comment=? WHERE id=?",
                            (new_comment, row["id"]))

        if args.apply:
            complete_migration(con)

        print(json.dumps({
            "tgwebInboundId": inbound_id,
            "tgwebInboundCreated": created_inbound,
            "keptAttached": kept,
            "attached": attached,
            "detached": detached,
            "untouched": untouched,
            "markersStripped": stripped,
            "tgwebRuntimeUsers": len(names),
            "migrationCompleted": bool(args.apply),
            "dryRun": not args.apply,
        }, ensure_ascii=False))
        if args.apply:
            con.commit()
        else:
            con.rollback()
    finally:
        con.close()


if __name__ == "__main__":
    main()
