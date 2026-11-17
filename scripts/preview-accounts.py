"""Refresh the two acceptance accounts' display metadata for the local preview."""

import asyncio
import json
import os
import sys
import tempfile
from pathlib import Path

from aksk_manager.bridge import NativeBridge


async def main():
    target = Path(__file__).resolve().parents[1] / "frontend/preview/local-accounts.json"
    bridge = NativeBridge()
    rows = []
    try:
        if sys.argv[1:] == ["--otp"]:
            # Resolve only the designated test account, never a caller-supplied ID.
            rows = json.loads(target.read_text())
            ref, = (r for r in rows if r["name"] == "AKSK 内置双填 7a37" and "otp_code" in r["fields"])
            window = await bridge.call("otp", {"id": ref["id"], "revision": ref["revision"]})
            print(json.dumps({"code": window["code"], "expires": window["expires"]}))
            return
        for name, query in (("webauthn.io", "aksk-import-test-7ea4c1"),
                            ("AKSK 内置双填 7a37", "AKSK 内置双填 7a37")):
            matches = await bridge.call("ui_list", {"query": query, "trash": False})
            for item in matches:
                if item["kind"] == "password" and item["name"].casefold() == name.casefold():
                    rows.append({"id": item["id"], "revision": item["revision"], "website": item["website"],
                                 "websiteURLs": item.get("websiteURLs", []), "passkeyInfo": item["passkeyInfo"], "name": item["name"], "account": query if query != name else "",
                                 "updatedAt": item["updatedAt"], "passkeyCount": item["passkeyCount"],
                                 "fields": sorted(set(item["fields"]) & {"url", "username", "password", "otp_code"})})
    finally:
        await bridge.close()
    with tempfile.NamedTemporaryFile(mode="w", dir=target.parent, delete=False) as tmp:
        json.dump(rows, tmp, ensure_ascii=False)
    os.replace(tmp.name, target)
    print(f"已刷新 {len(rows)} 条测试账号摘要。")


if __name__ == "__main__":
    asyncio.run(main())
