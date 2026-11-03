"""Agent editing uses references only; all credentials here are synthetic fixtures."""
import json

import pytest
from test_native import DB_VALUES, TOKEN, create

from aksk_manager.bridge import BridgeError
from aksk_manager.server import CredentialReference, MetadataChanges, mcp


def request(record, *, changes=None, refs=None, removed=None):
    return {"id": record["id"], "revision": record["revision"], "changes": changes or {},
            "field_refs": refs or {}, "remove_fields": removed or []}


def ref(record, field="token", path=None):
    return {"secret_id": record["id"], "revision": record["revision"],
            "field": field, "json_path": path or []}


async def test_metadata_edit_preserves_id_values_and_unmentioned_metadata(native):
    old = await create(native)
    new = await native.call("update", request(old, changes={"name": "改名", "environment": "dev"}))
    assert new["id"] == old["id"] and new["revision"] != old["revision"]
    for key in ["kind", "provider", "account", "tags", "notes", "expiresAt"]:
        assert new[key] == old[key]
    assert (await native.call("reveal", new))["values"] == {"token": TOKEN}
    assert TOKEN not in json.dumps(new)
    with pytest.raises(BridgeError) as error:
        await native.call("update", request(old, changes={"name": "stale"}))
    assert error.value.code == "CONFLICT"


async def test_convert_json_token_to_database_in_place_without_revealing(native):
    old = await create(native, values={"token": json.dumps({"connection": DB_VALUES})})
    new = await native.call("update", request(old, changes={"kind": "database"},
        refs={field: ref(old, path=["connection", field]) for field in DB_VALUES}))
    assert new["id"] == old["id"] and new["kind"] == "database"
    assert new["fields"] == sorted(DB_VALUES)
    assert (await native.call("reveal", new))["values"] == DB_VALUES
    assert len(await native.call("list")) == 1
    assert all(value not in json.dumps(new) for value in DB_VALUES.values())


async def test_cross_record_reference_and_optional_field_removal(native):
    source = await create(native)
    target = await create(native, kind="database", values=DB_VALUES)
    new = await native.call("update", request(target, refs={"password": ref(source)}, removed=["port"]))
    assert (await native.call("reveal", new))["values"] == {
        **{k: v for k, v in DB_VALUES.items() if k != "port"}, "password": TOKEN}
    assert (await native.call("metadata", {"id": source["id"]})) == source


@pytest.mark.parametrize("source_change", ["revise", "trash", "purge"])
async def test_source_changes_fail_without_partial_target_write(native, source_change):
    source = await create(native)
    target = await create(native, kind="database", values=DB_VALUES)
    if source_change == "revise":
        await native.call("save", {**source, "values": {"token": "new-synthetic-secret"}})
    else:
        deleted = await native.call("trash", source)
        if source_change == "purge":
            await native.call("purge", deleted)
    with pytest.raises(BridgeError):
        await native.call("update", request(target, changes={"name": "must not change"},
                                            refs={"password": ref(source)}))
    assert await native.call("metadata", {"id": target["id"]}) == target
    assert (await native.call("reveal", target))["values"] == DB_VALUES


@pytest.mark.parametrize("bad", ["missing", "number", "object", "raw", "required", "unknown", "overlap"])
async def test_invalid_reference_or_patch_is_atomic_and_errors_are_safe(native, bad):
    source = await create(native, values={"token": json.dumps({"text": TOKEN, "number": 123, "object": {}})})
    target = await create(native, kind="database", values=DB_VALUES)
    patch = request(target, changes={"name": "must not change"})
    if bad in ["missing", "number", "object"]:
        patch["field_refs"] = {"password": ref(source, path=[bad])}
    elif bad == "raw":
        patch["values"] = {"password": TOKEN}
    elif bad == "required":
        patch["remove_fields"] = ["host"]
    elif bad == "unknown":
        patch["changes"]["values"] = {"password": TOKEN}
    else:
        patch["field_refs"] = {"password": ref(source)}
        patch["remove_fields"] = ["password"]
    with pytest.raises(BridgeError) as error:
        await native.call("update", patch)
    assert error.value.code == "INVALID_INPUT" and TOKEN not in error.value.message
    assert await native.call("metadata", {"id": target["id"]}) == target


async def test_missing_or_trashed_target_cannot_create_or_restore(native):
    old = await create(native)
    deleted = await native.call("trash", old)
    with pytest.raises(BridgeError) as error:
        await native.call("update", request(deleted, changes={"name": "no restore"}))
    assert error.value.code == "TRASHED"
    await native.call("purge", deleted)
    with pytest.raises(BridgeError) as error:
        await native.call("update", request(deleted, changes={"name": "no create"}))
    assert error.value.code == "NOT_FOUND"
    assert await native.call("list", {"trash": True}) == []


async def test_agent_tool_is_public_but_references_and_results_never_contain_values(api, native):
    source = await create(native, values={"token": json.dumps(DB_VALUES)})
    tools = {t.name: t for t in await mcp.list_tools()}
    tool = tools["update_secret"]
    assert not (tool.meta or {}).get("ui", {}).get("visibility")
    assert not tool.annotations.readOnlyHint and not tool.annotations.openWorldHint
    assert "values" not in tool.inputSchema["properties"]
    result = await mcp.call_tool("update_secret", {
        "secret_id": source["id"], "expected_revision": source["revision"],
        "changes": {"kind": "database"},
        "field_refs": {field: ref(source, path=[field]) for field in DB_VALUES},
    })
    assert not result.isError
    assert all(value not in result.model_dump_json() for value in DB_VALUES.values())
    assert result.structuredContent["data"]["fields"] == sorted(DB_VALUES)
    with pytest.raises(ValueError):
        MetadataChanges.model_validate({"values": {"token": TOKEN}})
    with pytest.raises(ValueError):
        CredentialReference.model_validate({**ref(source), "value": TOKEN})
