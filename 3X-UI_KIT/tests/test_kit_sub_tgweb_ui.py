#!/usr/bin/env python3
import importlib.util
import json
import os
import sqlite3
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
KIT_SUB = ROOT / "kit-sub.py"
THEME = ROOT / "sub-theme" / "index.html"


class FakeResponse:
    def __init__(self, payload):
        self.payload = payload

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        return False

    def read(self):
        return json.dumps(self.payload).encode()


def load_module(tmp):
    config = Path(tmp) / "config.json"
    config.write_text(json.dumps({
        "path": "sub",
        "upstream": "http://127.0.0.1:2097",
        "port": 9443,
        "host": "ru.connect.maicraft.tech",
    }), encoding="utf-8")
    old = os.environ.get("KIT_SUB_CONFIG")
    os.environ["KIT_SUB_CONFIG"] = str(config)
    try:
        spec = importlib.util.spec_from_file_location("kit_sub_under_test", KIT_SUB)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod
    finally:
        if old is None:
            os.environ.pop("KIT_SUB_CONFIG", None)
        else:
            os.environ["KIT_SUB_CONFIG"] = old


class TgWebUiTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.mod = load_module(self.tmp.name)
        self.db = Path(self.tmp.name) / "x-ui.db"
        con = sqlite3.connect(self.db)
        con.executescript("""
            CREATE TABLE clients (
              id INTEGER PRIMARY KEY,
              email TEXT,
              sub_id TEXT,
              enable INTEGER,
              comment TEXT
            );
            CREATE TABLE inbounds (
              id INTEGER PRIMARY KEY,
              protocol TEXT,
              enable INTEGER
            );
            CREATE TABLE client_inbounds (
              client_id INTEGER,
              inbound_id INTEGER
            );
            INSERT INTO clients VALUES (1, 'MV', 'sub-mv', 1, '');
            INSERT INTO inbounds VALUES (8, 'tgweb', 1);
            INSERT INTO client_inbounds VALUES (1, 8);
        """)
        con.commit()
        con.close()
        self.mod.CONF["xui_db"] = str(self.db)

    def tearDown(self):
        self.tmp.cleanup()

    def sql(self, query):
        con = sqlite3.connect(self.db)
        try:
            con.execute(query)
            con.commit()
        finally:
            con.close()

    def test_effective_attachment_requires_client_inbound_and_relation_enabled(self):
        self.assertTrue(self.mod._tgweb_attached("MV"))

        self.sql("UPDATE clients SET enable=0 WHERE email='MV'")
        self.assertFalse(self.mod._tgweb_attached("MV"))

        self.sql("UPDATE clients SET enable=1 WHERE email='MV'")
        self.sql("DELETE FROM client_inbounds")
        self.assertFalse(self.mod._tgweb_attached("MV"))

        self.sql("INSERT INTO client_inbounds VALUES (1,8)")
        self.sql("UPDATE inbounds SET enable=0 WHERE id=8")
        self.assertFalse(self.mod._tgweb_attached("MV"))

    def test_runtime_disabled_hides_link(self):
        token = Path(self.tmp.name) / "admin.token"
        token.write_text("dummy-token", encoding="utf-8")
        env = {
            "TGWEB_DOMAIN": "web.maicraft.tech",
            "TGWEB_ADMIN": "http://127.0.0.1:9601",
            "TGWEB_TOKEN_FILE": str(token),
        }
        payload = [{
            "domain": "web.maicraft.tech",
            "clients": [{"name": "MV", "secret": "aabbcc", "enabled": False}],
        }]
        with mock.patch.object(self.mod, "_read_tgweb_env", return_value=env), \
             mock.patch.object(self.mod, "_client_email", return_value="MV"), \
             mock.patch.object(self.mod, "_tgweb_attached", return_value=True), \
             mock.patch.object(self.mod.urllib.request, "urlopen", return_value=FakeResponse(payload)):
            self.assertEqual("", self.mod.tgweb_link_for_sub("sub-mv"))

    def test_runtime_enabled_builds_canonical_share_link(self):
        token = Path(self.tmp.name) / "admin.token"
        token.write_text("dummy-token", encoding="utf-8")
        env = {
            "TGWEB_DOMAIN": "web.maicraft.tech",
            "TGWEB_ADMIN": "http://127.0.0.1:9601",
            "TGWEB_TOKEN_FILE": str(token),
        }
        payload = [{
            "domain": "web.maicraft.tech",
            "clients": [{"name": "MV", "secret": "aabbcc", "enabled": True}],
        }]
        with mock.patch.object(self.mod, "_read_tgweb_env", return_value=env), \
             mock.patch.object(self.mod, "_client_email", return_value="MV"), \
             mock.patch.object(self.mod, "_tgweb_attached", return_value=True), \
             mock.patch.object(self.mod.urllib.request, "urlopen", return_value=FakeResponse(payload)):
            self.assertEqual(
                "https://t.me/webproxy?secret=aabbcc&server=web.maicraft.tech",
                self.mod.tgweb_link_for_sub("sub-mv"),
            )

    def test_injection_uses_existing_links_menu_not_standalone_card(self):
        body = b'<html><div class="links-wrap" id="links-box"></div><div class="notice">x</div></html>'
        link = "https://t.me/webproxy?secret=aabbcc&server=web.maicraft.tech"
        with mock.patch.object(self.mod, "tgweb_link_for_sub", return_value=link):
            out = self.mod.inject_tgweb_html(body, "sub-mv").decode()

        self.assertIn('data-kind="tgweb"', out)
        self.assertIn("Telegram WebProxy", out)
        self.assertIn("tg://webproxy?server=web.maicraft.tech&amp;secret=aabbcc", out)
        self.assertNotIn("<h2>Telegram WEB Proxy</h2>", out)
        self.assertEqual(1, out.count("tgweb-link-card"))

    def test_theme_routes_tgweb_through_existing_qr_logic(self):
        text = THEME.read_text(encoding="utf-8")
        self.assertIn("MTProto · WebProxy · Amnezia · TUIC", text)
        self.assertIn("kind==='tgweb'", text)
        self.assertIn("makeQr(card.querySelector('.link-qr'),raw)", text)
        self.assertIn("card.dataset.openLink", text)


if __name__ == "__main__":
    unittest.main()
