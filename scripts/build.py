#!/usr/bin/env python3
import base64
import json
from pathlib import Path
from urllib.request import Request, urlopen

UPSTREAM = "https://raw.githubusercontent.com/hydraponique/roscomvpn-routing/main/HAPP/DEFAULT.JSON"
ROOT = Path(__file__).resolve().parents[1]
CUSTOM = ROOT / "custom-direct.json"
CUSTOM_PROXY = ROOT / "custom-proxy.json"
OUT_DIR = ROOT / "HAPP"
OUT_JSON = OUT_DIR / "DEFAULT-CUSTOM.JSON"
OUT_DEEPLINK = OUT_DIR / "DEFAULT-CUSTOM.DEEPLINK"

def load_url(url: str) -> dict:
    req = Request(url, headers={"User-Agent": "roscomvpn-routing-custom"})
    with urlopen(req, timeout=30) as response:
        return json.load(response)

def unique(items):
    return list(dict.fromkeys(items))

def main():
    base = load_url(UPSTREAM)
    custom = json.loads(CUSTOM.read_text(encoding="utf-8"))

    for key in ("DirectSites", "DirectIp"):
        base[key] = unique([*base.get(key, []), *custom.get(key, [])])

    if CUSTOM_PROXY.exists():
        custom_proxy = json.loads(CUSTOM_PROXY.read_text(encoding="utf-8"))
        base["ProxySites"] = unique([*base.get("ProxySites", []), *custom_proxy.get("ProxySites", [])])

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    payload = json.dumps(base, ensure_ascii=False, indent=2) + "\n"
    OUT_JSON.write_text(payload, encoding="utf-8")

    encoded = base64.b64encode(payload.strip().encode("utf-8")).decode("ascii")
    OUT_DEEPLINK.write_text(f"happ://routing/onadd/{encoded}\n", encoding="utf-8")

if __name__ == "__main__":
    main()
