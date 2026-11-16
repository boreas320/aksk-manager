"""Exercise Chrome native messaging frames against the signed helper with a disposable account."""

import argparse
import asyncio
import json
import secrets
import struct
import subprocess
import uuid
from pathlib import Path

from aksk_manager.bridge import NativeBridge


async def main(extension=False):
    bridge = NativeBridge()
    origin = f"https://{uuid.uuid4().hex}.example.invalid"
    password = secrets.token_urlsafe(24)

    def browser(action, **kwargs):
        body = json.dumps({"origin": origin, "action": action, **kwargs}).encode()
        frame = struct.pack("<I", len(body)) + body
        response = subprocess.run([bridge.path, "--browser"], input=frame, capture_output=True, check=True).stdout
        assert struct.unpack("<I", response[:4])[0] == len(response) - 4
        return json.loads(response[4:])

    record = None
    other = None
    try:
        record = await bridge.call("save", {"kind": "password", "name": "AKSK browser smoke",
                                   "values": {"url": origin, "username": "demo", "password": password,
                                              "totp": "JBSWY3DPEHPK3PXP"}})
        reference = {"id": record["id"], "revision": record["revision"]}
        accounts = browser("accounts")
        assert accounts["ok"] and len(accounts["data"]) == 1
        assert browser("fill", **reference, field="password")["data"] == password
        assert len(browser("fill", **reference, field="otp_code")["data"]) == 6
        assert not browser("fill", **reference, field="totp")["ok"]
        assert not browser("fill", **reference, field="password", origin=origin + ".wrong")["ok"]
        if extension:
            root = Path(__file__).resolve().parents[1]
            other = await bridge.call("save", {"kind": "password", "name": "AKSK alternate smoke",
                                      "values": {"url": origin, "username": "other", "password": secrets.token_urlsafe(24)}})
            await asyncio.to_thread(subprocess.run, ["node", "smoke-extension.mjs"], cwd=root / "frontend",
                           input=json.dumps({"origin": origin, "password": password}), text=True, check=True, timeout=90)
            other = await bridge.call("trash", other)
        record = await bridge.call("trash", record)
        assert browser("accounts")["data"] == []
        assert not browser("fill", **reference, field="password")["ok"]
        print("PASS: signed Keychain helper and browser protocol")
    finally:
        try:
            for entry in (other, record):
                if entry:
                    if entry["deletedAt"] is None:
                        entry = await bridge.call("trash", entry)
                    await bridge.call("purge", entry)
        finally:
            await bridge.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--extension", action="store_true", help="also exercise the installed popup in Chrome for Testing")
    asyncio.run(main(parser.parse_args().extension))
