import subprocess
from pathlib import Path

import pytest
import pytest_asyncio

from aksk_manager.bridge import NativeBridge

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture(scope="session")
def native_binary():
    path = ROOT / ".build/aksk-helper-test"
    path.parent.mkdir(exist_ok=True)
    subprocess.run(
        ["swiftc", "-D", "TESTING", str(ROOT / "native/Sources/main.swift"), "-o", str(path)],
        check=True,
        capture_output=True,
    )
    return path


@pytest_asyncio.fixture
async def native(native_binary):
    bridge = NativeBridge(native_binary, verify=False)
    yield bridge
    await bridge.close()


@pytest_asyncio.fixture
async def api(native, monkeypatch):
    from aksk_manager import server

    monkeypatch.setattr(server, "bridge", native)
    return server
