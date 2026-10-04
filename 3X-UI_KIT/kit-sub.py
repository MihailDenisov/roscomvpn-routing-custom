#!/usr/bin/env python3
"""Подписка с учётом приложения — посредник перед подпиской 3X-UI.

https://github.com/itsnotkubrick/3X-UI_KIT

Слушает публичный адрес подписки (HTTPS) и ходит в подписку 3X-UI на 127.0.0.1:
  * Clash / Mihomo (Clash Verge, FlClash, Mihomo Party…) — конфиг 3X-UI плюс AmneziaWG
    из подписки «<id>-awg»: Mihomo умеет AmneziaWG, а остальные приложения нет;
  * остальные приложения и браузер — ответ 3X-UI как есть (ссылки или страница);
  * заголовок Subscription-Userinfo: expire=0 («бессрочно») убирается — иначе
    приложения показывают срок «01.01.1970».

Настройки — /etc/kit-sub/config.json. Сертификат перечитывается сам после продления.
"""

import base64
import http.server
import json
import os
import re
import socket
import ssl
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

import yaml

CONFIG = os.environ.get("KIT_SUB_CONFIG", "/etc/kit-sub/config.json")
CLASH_UA = re.compile(r"clash|mihomo|flclash|stash|nyanpasu|meta", re.I)
HAPP_UA = re.compile(r"happ", re.I)
# AmneziaWG добавляем только приложениям на ядре Mihomo. Karing, Hiddify и другие на sing-box
# тоже могут просить формат Clash (Karing так и делает), но AmneziaWG не умеют.
NO_AWG_UA = re.compile(r"karing|hiddify|nekobox|sing-?box|husi|stash|shadowrocket|v2box|streisand|happ|loon|surge|quantumult", re.I)
SUB_ID = re.compile(r"^[A-Za-z0-9_.@-]{1,64}$")
PASS_HEADERS = ("content-type", "content-disposition", "profile-title", "profile-update-interval",
                "profile-web-page-url", "subscription-userinfo", "support-url", "cache-control",
                "routing-enable", "routing")

with open(CONFIG, encoding="utf-8") as f:
    CONF = json.load(f)
PATH = "/" + CONF["path"].strip("/") + "/"


def log(msg):
    print(msg, flush=True)


def upstream(sub_id, ua, host, accept):
    """GET к подписке 3X-UI. Возвращает (код, заголовки, тело) или (None, {}, b"")."""
    req = urllib.request.Request(CONF["upstream"].rstrip("/") + PATH + sub_id, headers={
        "User-Agent": ua, "Host": host, "Accept": accept or "*/*"})
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return r.status, {k.lower(): v for k, v in r.getheaders()}, r.read()
    except urllib.error.HTTPError as e:
        return e.code, {k.lower(): v for k, v in e.headers.items()}, e.read()
    except (urllib.error.URLError, OSError, socket.timeout) as e:
        log(f"upstream недоступен: {e}")
        return None, {}, b""


def fix_userinfo(value):
    # «expire=0» значит «бессрочно», но приложения рисуют 01.01.1970 — убираем.
    parts = [p.strip() for p in value.split(";") if p.strip() and p.strip() != "expire=0"]
    return "; ".join(parts)


def strip_links(body):
    """Список ссылок (base64 или текст) без vpn:// и tg:// — их не умеет ни одно VPN-приложение
    со ссылками: vpn:// — конфиг для AmneziaVPN, tg:// — прокси для Telegram."""
    text = body.decode("utf-8", "replace").strip()
    encoded = "://" not in text
    if encoded:
        try:
            text = base64.b64decode(text + "=" * (-len(text) % 4)).decode("utf-8", "replace")
        except ValueError:
            return body
    lines = [l for l in text.splitlines() if l.strip() and not l.startswith(("vpn://", "tg://"))]
    out = "\n".join(lines)
    return base64.b64encode(out.encode()).decode().encode() if encoded else out.encode()


def _decode_raw_lines(body):
    """Decode 3x-ui raw subscription (plain or base64) and return non-empty lines."""
    text = body.decode("utf-8", "replace").strip()
    if not text:
        return []
    if "://" not in text:
        try:
            text = base64.b64decode(text + "=" * (-len(text) % 4)).decode("utf-8", "replace")
        except (ValueError, UnicodeError):
            return []
    return [line.strip() for line in text.splitlines() if line.strip()]


def _telegram_public_link(line):
    """Normalize one tg:// link to the public relay endpoint on TCP/443."""
    if not line.startswith("tg://proxy?"):
        return ""
    relay = _relay_host()
    if not relay:
        return ""
    try:
        parsed = urllib.parse.urlsplit(line)
        params = urllib.parse.parse_qsl(parsed.query, keep_blank_values=True)
        out = []
        seen_server = seen_port = False
        for key, value in params:
            if key == "server":
                value = relay
                seen_server = True
            elif key == "port":
                value = "443"
                seen_port = True
            out.append((key, value))
        if not seen_server:
            out.append(("server", relay))
        if not seen_port:
            out.append(("port", "443"))
        return "tg://proxy?" + urllib.parse.urlencode(out)
    except (ValueError, UnicodeError):
        return ""


def telegram_link_for_sub(sub_id, host):
    """Read the current per-user MTProto link from 3x-ui; do not persist its secret."""
    code, _, body = upstream(sub_id, "v2rayN/7.0", host, "text/plain")
    if code != 200:
        return ""
    for line in _decode_raw_lines(body):
        link = _telegram_public_link(line)
        if link:
            return link
    # Legacy KIT could keep MTProto under <subId>-tg.
    code, _, body = upstream(sub_id + "-tg", "v2rayN/7.0", host, "text/plain")
    if code == 200:
        for line in _decode_raw_lines(body):
            link = _telegram_public_link(line)
            if link:
                return link
    return ""


def telegram_http_url(sub_id):
    host = _relay_host()
    if not host:
        return ""
    return f"https://{host}{PATH}{urllib.parse.quote(sub_id, safe='')}/tg"


def add_happ_telegram_info(body, sub_id):
    """Prepend a harmless SOCKS info node whose remark contains the HTTPS Telegram launcher."""
    url = telegram_http_url(sub_id)
    if not url:
        return body
    text = body.decode("utf-8", "replace").strip()
    encoded = "://" not in text
    if encoded:
        try:
            text = base64.b64decode(text + "=" * (-len(text) % 4)).decode("utf-8", "replace")
        except (ValueError, UnicodeError):
            return body
    remark = urllib.parse.quote(f"📨 Telegram MTProto: {url}", safe="")
    info = f"socks://127.0.0.1:1080#{remark}"
    lines = [line for line in text.splitlines() if line.strip()]
    if info not in lines:
        lines.insert(0, info)
    out = "\n".join(lines)
    return base64.b64encode(out.encode()) if encoded else out.encode()


def add_clash_telegram_info(clash_yaml, sub_id):
    """Add a display-only Mihomo group. It is not referenced by routing and cannot proxy traffic."""
    url = telegram_http_url(sub_id)
    if not url:
        return clash_yaml
    cfg = yaml.safe_load(clash_yaml)
    if not isinstance(cfg, dict):
        return clash_yaml
    name = f"📨 Telegram: {url}"
    groups = cfg.setdefault("proxy-groups", [])
    if not any(isinstance(g, dict) and g.get("name") == name for g in groups):
        groups.insert(0, {"name": name, "type": "select", "proxies": ["DIRECT"]})
    return yaml.safe_dump(cfg, allow_unicode=True, sort_keys=False).encode()


RELAY_SCHEMES = {"vless", "trojan", "ss", "hysteria", "hysteria2", "tuic", "wireguard"}

def _relay_host():
    """Public endpoint advertised by kit-sub; never used as TLS SNI."""
    return str(CONF.get("host", "")).strip().split(":", 1)[0]


def _rewrite_uri_endpoint(line, relay):
    """Replace only URI authority host. Query parameters (sni/host/pbk/path/...) stay intact."""
    if not relay or "://" not in line:
        return line
    scheme = line.split("://", 1)[0].lower()
    if scheme == "vmess":
        try:
            raw = line.split("://", 1)[1].strip()
            obj = json.loads(base64.b64decode(raw + "=" * (-len(raw) % 4)))
            if isinstance(obj, dict) and obj.get("add"):
                obj["add"] = relay
                enc = base64.b64encode(json.dumps(obj, ensure_ascii=False, separators=(",", ":")).encode()).decode()
                return "vmess://" + enc
        except (ValueError, UnicodeError, json.JSONDecodeError):
            return line
        return line
    if scheme not in RELAY_SCHEMES:
        return line
    try:
        p = urllib.parse.urlsplit(line)
        if not p.hostname:
            return line
        user = ""
        if p.username is not None:
            user = urllib.parse.quote(urllib.parse.unquote(p.username), safe="")
            if p.password is not None:
                user += ":" + urllib.parse.quote(urllib.parse.unquote(p.password), safe="")
            user += "@"
        port = f":{p.port}" if p.port else ""
        netloc = f"{user}{relay}{port}"
        return urllib.parse.urlunsplit((p.scheme, netloc, p.path, p.query, p.fragment))
    except (ValueError, UnicodeError):
        return line


def rewrite_raw_endpoints(body):
    """Force raw share-link destination to relay without changing SNI/TLS/Reality parameters."""
    relay = _relay_host()
    if not relay:
        return body
    text = body.decode("utf-8", "replace").strip()
    encoded = "://" not in text
    if encoded:
        try:
            text = base64.b64decode(text + "=" * (-len(text) % 4)).decode("utf-8", "replace")
        except (ValueError, UnicodeError):
            return body
    out = "\n".join(_rewrite_uri_endpoint(line, relay) for line in text.splitlines())
    return base64.b64encode(out.encode()) if encoded else out.encode()


def rewrite_clash_endpoints(clash_yaml):
    """Force only Clash/Mihomo proxy server fields to relay. SNI/servername remain untouched."""
    relay = _relay_host()
    if not relay:
        return clash_yaml
    cfg = yaml.safe_load(clash_yaml)
    if not isinstance(cfg, dict):
        return clash_yaml
    types = {"vless", "vmess", "trojan", "ss", "hysteria", "hysteria2", "tuic", "wireguard"}
    for p in cfg.get("proxies") or []:
        if not isinstance(p, dict) or p.get("type") not in types:
            continue
        server = str(p.get("server", ""))
        if server not in ("", "127.0.0.1", "::1", "localhost"):
            p["server"] = relay
    return yaml.safe_dump(cfg, allow_unicode=True, sort_keys=False).encode()


def strip_awg(clash_yaml):
    """Clash-конфиг без AmneziaWG — для приложений, которые его не умеют."""
    cfg = yaml.safe_load(clash_yaml)
    if not isinstance(cfg, dict):
        return clash_yaml
    awg = {p.get("name") for p in cfg.get("proxies") or [] if isinstance(p, dict) and "amnezia-wg-option" in p}
    if not awg:
        return clash_yaml
    cfg["proxies"] = [p for p in cfg["proxies"] if p.get("name") not in awg]
    for g in cfg.get("proxy-groups") or []:
        if isinstance(g.get("proxies"), list):
            g["proxies"] = [x for x in g["proxies"] if x not in awg]
    return yaml.safe_dump(cfg, allow_unicode=True, sort_keys=False).encode()


def merge_awg(main_yaml, awg_yaml):
    """Добавляет прокси AmneziaWG в Clash-конфиг и во все группы, где перечислены прокси."""
    main = yaml.safe_load(main_yaml)
    awg = yaml.safe_load(awg_yaml)
    if not isinstance(main, dict) or not isinstance(awg, dict):
        return main_yaml
    extra = [p for p in (awg.get("proxies") or []) if isinstance(p, dict) and p.get("name")]
    if not extra:
        return main_yaml
    names = {p.get("name") for p in main.get("proxies") or []}
    for p in extra:
        # 3X-UI дописывает к имени запись-«двойника» («AmneziaWG-3.1-sasha-awg») — убираем хвост.
        p["name"] = re.sub(r"-[^-\s]+-awg\d*$", "", p["name"]) or p["name"]
        base, n = p["name"], 2
        while p["name"] in names:
            p["name"] = f"{base} {n}"
            n += 1
        names.add(p["name"])
    main.setdefault("proxies", []).extend(extra)
    added = [p["name"] for p in extra]
    for g in main.get("proxy-groups") or []:
        lst = g.get("proxies")
        if isinstance(lst, list) and any(x in names for x in lst):
            pos = lst.index("DIRECT") if "DIRECT" in lst else len(lst)
            g["proxies"] = lst[:pos] + added + lst[pos:]
    return yaml.safe_dump(main, allow_unicode=True, sort_keys=False).encode()


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "nginx"
    sys_version = ""
    timeout = 20  # зависшие соединения не держим

    def setup(self):
        # TLS-рукопожатие — в потоке запроса, а не в общем цикле приёма соединений.
        # Без сертификата (за nginx, на 127.0.0.1) работаем по обычному HTTP.
        self.request.settimeout(self.timeout)
        if self.server.ssl_ctx is not None:
            self.request = self.server.ssl_ctx.wrap_socket(self.request, server_side=True)
        super().setup()

    def handle(self):
        try:
            super().handle()
        except (ssl.SSLError, ConnectionError, socket.timeout, OSError):
            pass

    def log_message(self, fmt, *args):  # без IP клиентов в логах
        pass

    def send_plain(self, code, text=""):
        body = text.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if not path.startswith(PATH):
            return self.send_plain(404, "404 page not found")
        tail = path[len(PATH):]
        telegram_request = tail.endswith("/tg")
        sub_id = tail[:-3] if telegram_request else tail
        if not SUB_ID.match(sub_id):
            return self.send_plain(404, "404 page not found")
        ua = self.headers.get("User-Agent", "")
        host = self.headers.get("Host", CONF.get("host", ""))
        accept = self.headers.get("Accept", "")

        if telegram_request:
            link = telegram_link_for_sub(sub_id, host)
            if not link:
                return self.send_plain(404, "Telegram proxy is not available")
            self.send_response(302)
            self.send_header("Location", link)
            self.send_header("Cache-Control", "no-store, no-cache, must-revalidate, private")
            self.send_header("Referrer-Policy", "no-referrer")
            self.send_header("X-Robots-Tag", "noindex, nofollow, noarchive")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        code, headers, body = upstream(sub_id, ua, host, accept)
        if code is None:
            return self.send_plain(502, "subscription backend is unavailable")

        clash = bool(CLASH_UA.search(ua)) and "yaml" in headers.get("content-type", "")
        awg = clash and not NO_AWG_UA.search(ua)
        # В журнал — только приложение и что ему отдали, без IP.
        log(f"{ua[:80]!r} → {'clash+awg' if awg else 'clash' if clash else headers.get('content-type', '?').split(';')[0]}")
        try:
            if code == 200 and clash and not awg:
                body = add_clash_telegram_info(rewrite_clash_endpoints(strip_awg(body)), sub_id)
            elif code == 200 and awg and not sub_id.endswith(("-awg", "-tg")):
                # Установки до kit 1.1 держали AmneziaWG в подписке «<id>-awg» — подмешиваем её.
                acode, _, abody = upstream(sub_id + "-awg", ua, host, accept)
                if acode == 200 and abody:
                    body = merge_awg(body, abody)
                body = add_clash_telegram_info(rewrite_clash_endpoints(body), sub_id)
            elif code == 200 and clash:
                body = add_clash_telegram_info(rewrite_clash_endpoints(body), sub_id)
            elif code == 200 and "text/plain" in headers.get("content-type", ""):
                body = rewrite_raw_endpoints(strip_links(body))
                if HAPP_UA.search(ua):
                    body = add_happ_telegram_info(body, sub_id)
        except (yaml.YAMLError, UnicodeError) as e:
            log(f"не удалось обработать подписку: {e}")

        self.send_response(code)
        for k in PASS_HEADERS:
            if k in headers:
                v = fix_userinfo(headers[k]) if k == "subscription-userinfo" else headers[k]
                if v:
                    self.send_header(k.title(), v)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True
    ssl_ctx = None

    def handle_error(self, request, client_address):  # обрывы TLS от сканеров — не ошибка
        pass
    address_family = socket.AF_INET6 if ":" in CONF.get("listen", "") else socket.AF_INET


def main():
    cert, key = CONF.get("cert"), CONF.get("key")
    if not cert:
        srv = Server((CONF.get("listen", "127.0.0.1"), int(CONF["port"])), Handler)
        log(f"kit-sub слушает http://{CONF.get('listen', '127.0.0.1')}:{CONF['port']}{PATH} (TLS снимает nginx)")
        srv.serve_forever()
        return
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.load_cert_chain(cert, key)
    stamp = [os.path.getmtime(cert)]

    def reload_cert():
        # Let's Encrypt на IP живёт 6 дней — после продления берём новый сертификат без перезапуска.
        while True:
            time.sleep(600)
            try:
                m = os.path.getmtime(cert)
                if m != stamp[0]:
                    ctx.load_cert_chain(cert, key)
                    stamp[0] = m
                    log("сертификат обновлён")
            except (OSError, ssl.SSLError) as e:
                log(f"не удалось перечитать сертификат: {e}")

    threading.Thread(target=reload_cert, daemon=True).start()
    srv = Server((CONF.get("listen", "0.0.0.0"), int(CONF["port"])), Handler)
    srv.ssl_ctx = ctx
    log(f"kit-sub слушает {CONF.get('listen', '0.0.0.0')}:{CONF['port']}{PATH}")
    srv.serve_forever()


if __name__ == "__main__":
    main()
