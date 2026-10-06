#!/usr/bin/env python3
"""Idempotent migration from legacy [tgweb:off] state to virtual inbound rows.

Run only against an OFFLINE COPY / STAGING database first.
This script never calls PUT on TgWebProxy: it reads GET /clients only, so
existing secrets and usage counters cannot be modified.
"""
import argparse, json, os, re, sqlite3, urllib.request

MARKER = "[tgweb:off]"

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

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", default="/etc/x-ui/x-ui.db")
    ap.add_argument("--env", default="/etc/kit/tgweb.env")
    ap.add_argument("--apply", action="store_true", help="commit changes (default: dry-run)")
    args = ap.parse_args()
    env = read_env(args.env)
    names = tgweb_names(env["TGWEB_ADMIN"], env["TGWEB_TOKEN_FILE"], env["TGWEB_DOMAIN"])

    con = sqlite3.connect(args.db)
    con.row_factory = sqlite3.Row
    try:
        con.execute("""CREATE TABLE IF NOT EXISTS client_external_inbounds (
            client_id INTEGER NOT NULL,
            provider TEXT NOT NULL,
            created_at INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (client_id, provider)
        )""")
        rows = con.execute("SELECT id,email,COALESCE(comment,'') comment FROM clients ORDER BY id").fetchall()
        attached = detached = untouched = 0
        for row in rows:
            email, comment = row["email"], row["comment"]
            # AWG shadow identities are never external TgWeb identities.
            if re.search(r"-awg\d*$", email):
                untouched += 1
                continue
            if MARKER in comment:
                con.execute("DELETE FROM client_external_inbounds WHERE client_id=? AND provider='tgweb'", (row["id"],))
                con.execute("UPDATE clients SET comment=? WHERE id=?", (strip_marker(comment), row["id"]))
                detached += 1
            elif email in names:
                con.execute("""INSERT OR IGNORE INTO client_external_inbounds(client_id,provider,created_at)
                               VALUES (?,'tgweb',strftime('%s','now')*1000)""", (row["id"],))
                attached += 1
            else:
                # Safe default: do not mint/attach TgWeb for a VPN-only user.
                untouched += 1
        print(json.dumps({"attached": attached, "detached": detached, "untouched": untouched,
                          "tgwebRuntimeUsers": len(names), "dryRun": not args.apply}, ensure_ascii=False))
        if args.apply:
            con.commit()
        else:
            con.rollback()
    finally:
        con.close()

if __name__ == "__main__":
    main()
