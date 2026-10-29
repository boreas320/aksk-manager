import json
from pathlib import Path

import pytest
from test_native import DB_VALUES, TOKEN, create, finished

from aksk_manager.bridge import BridgeError, NativeBridge
from aksk_manager.server import mcp


async def test_tools_separate_app_management_from_agent_execution():
    tools = {t.name: t for t in await mcp.list_tools()}
    for name, tool in tools.items():
        if name.startswith("ui_"):
            assert tool.meta["ui"]["visibility"] == ["app"]
    assert tools["aksk.open"].meta["openai/ui"]["entrypoints"] == [{"type": "thread"}]
    assert tools["run_with_secrets"].annotations.destructiveHint is True
    assert not any("reveal" in name and not name.startswith("ui_") for name in tools)


async def test_private_reveal_never_in_model_visible_fields(api, native):
    r = await create(native)
    revealed = await api.ui_reveal(r["id"], r["revision"])
    encoded = revealed.model_dump(by_alias=True, exclude_none=True)
    assert encoded["_meta"]["private"]["data"]["values"]["token"] == TOKEN
    del encoded["_meta"]
    assert TOKEN not in json.dumps(encoded)
    metadata = await api.list_secrets()
    assert TOKEN not in metadata.model_dump_json()


async def test_database_configuration_is_private_to_app(api, native):
    r = await create(native, kind="database", values=DB_VALUES)
    for response in [await api.list_secrets(), await api.get_secret_metadata(r["id"])]:
        assert all(v not in response.model_dump_json() for v in DB_VALUES.values())
    revealed = await api.ui_reveal(r["id"], r["revision"])
    assert revealed.meta["private"]["data"]["values"] == DB_VALUES
    public = revealed.model_dump(by_alias=True, exclude_none=True)
    del public["_meta"]
    assert all(v not in json.dumps(public) for v in DB_VALUES.values())


async def test_protocol_tool_call_preserves_private_meta(api, native):
    r = await create(native)
    response = await mcp.call_tool("ui_reveal", {"secret_id": r["id"], "revision": r["revision"]})
    assert response.meta["private"]["data"]["values"]["token"] == TOKEN
    assert TOKEN not in json.dumps([c.model_dump() for c in response.content])


async def test_run_tool_returns_safe_completed_result(api, native):
    r = await create(native)
    result = await api.run_with_secrets(
        ["/usr/bin/printenv", "TOKEN"], "/tmp", {"TOKEN": {"secret_id": r["id"], "field": "token"}}
    )
    job = result.structuredContent["data"]
    await finished(native, job)
    output = await api.get_run(job["id"])
    assert TOKEN not in output.model_dump_json()
    assert "[REDACTED]" in output.structuredContent["data"]["stdout"]


async def test_errors_do_not_echo_unexpected_exception(api, monkeypatch):
    async def bad(*args, **kwargs):
        raise ValueError(TOKEN)

    monkeypatch.setattr(api.bridge, "call", bad)
    result = await api.ui_status()
    assert result.isError and TOKEN not in result.model_dump_json()


async def test_missing_helper_is_actionable():
    bridge = NativeBridge(Path("/definitely/not/installed"))
    with pytest.raises(BridgeError) as e:
        await bridge.call("status")
    assert e.value.code == "HELPER_MISSING"


async def test_app_opens_without_native_helper(api, monkeypatch):
    monkeypatch.setattr(api, "bridge", NativeBridge(Path("/not/installed")))
    assert not (await api.open_manager()).isError
    status = await api.ui_status()
    assert status.meta["private"]["error"]["code"] == "HELPER_MISSING"
