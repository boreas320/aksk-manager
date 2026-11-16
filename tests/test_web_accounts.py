import platform
import subprocess

import pytest
from conftest import ROOT

from aksk_manager.bridge import BridgeError


@pytest.mark.skipif(int(platform.mac_ver()[0].split(".")[0] or 0) < 26, reason="requires macOS credential exchange")
def test_exchange_item_mapping_and_rfc_vector(tmp_path):
    binary = tmp_path / "exchange-checks"
    subprocess.run(["swiftc", "-D", "TESTING", "-target", platform.machine() + "-apple-macos26",
                    "native/Sources/Vault.swift", "native/Exchange/Receiver.swift", "tests/ExchangeChecks.swift",
                    "-o", str(binary)], cwd=ROOT, check=True)
    subprocess.run([binary], check=True)


async def test_totp_seed_cannot_be_revealed_bound_or_referenced(native):
    seed = "JBSWY3DPEHPK3PXP"
    record = await native.call("save", {"kind": "password", "name": "demo", "values": {
        "url": "https://example.invalid", "username": "user", "totp": seed}})
    revealed = (await native.call("reveal", record))["values"]
    assert len(revealed["otp_code"]) == 6 and seed not in str(revealed)
    assert await native.call("ui_list", {"query": seed}) == []
    with pytest.raises(BridgeError):
        await native.call("run", {"argv": ["/usr/bin/true"], "cwd": "/tmp", "bindings": {
            "VALUE": {"secret_id": record["id"], "field": "totp"}}})
    with pytest.raises(BridgeError):
        await native.call("update", {"id": record["id"], "revision": record["revision"], "changes": {},
                          "remove_fields": [], "field_refs": {"password": {"secret_id": record["id"],
                          "revision": record["revision"], "field": "totp", "json_path": []}}})
