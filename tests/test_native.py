import asyncio
import json
import sys

import pytest

from aksk_manager.bridge import BridgeError

TOKEN = "synthetic-token-MUST-NOT-APPEAR-12345"
AK = "synthetic-access-12345"
SK = "synthetic-secret-67890"


async def create(native, **changes):
    record = {
        "kind": "token",
        "name": "测试凭据",
        "provider": "Example",
        "account": "test",
        "environment": "test",
        "tags": ["demo"],
        "notes": "synthetic fixture",
        "values": {"token": TOKEN},
    }
    record.update(changes)
    return await native.call("save", record)


async def run(native, record, program, *, bindings=None, timeout=10):
    return await native.call(
        "run",
        {
            "argv": [sys.executable, "-c", program],
            "cwd": "/tmp",
            "bindings": bindings or {"TOKEN": {"secret_id": record["id"], "field": "token"}},
            "timeout_seconds": timeout,
        },
    )


async def finished(native, job):
    for _ in range(200):
        result = await native.call("get_run", {"id": job["id"]})
        if result["state"] != "running":
            return result
        await asyncio.sleep(0.025)
    pytest.fail("run never completed")


async def test_crud_revision_trash_restore_purge(native):
    r = await create(native)
    assert TOKEN not in json.dumps(r)
    assert (await native.call("list", {"query": "DEMO"}))[0]["id"] == r["id"]
    assert (await native.call("reveal", {"id": r["id"], "revision": r["revision"]}))["values"][
        "token"
    ] == TOKEN
    new = await native.call("save", {**r, "name": "重命名"})
    with pytest.raises(BridgeError, match="发生变化"):
        await native.call("save", {**r, "name": "stale"})
    assert (await native.call("reveal", {"id": new["id"], "revision": new["revision"]}))["values"][
        "token"
    ] == TOKEN
    with pytest.raises(BridgeError) as e:
        await native.call("purge", new)
    assert e.value.code == "NOT_TRASHED"
    trashed = await native.call("trash", new)
    assert await native.call("list") == []
    assert len(await native.call("list", {"trash": True})) == 1
    with pytest.raises(BridgeError) as e:
        await run(native, trashed, "print('should not run')")
    assert e.value.code == "TRASHED"
    restored = await native.call("restore", trashed)
    assert restored["deletedAt"] is None
    again = await native.call("trash", restored)
    await native.call("purge", again)
    assert await native.call("list", {"trash": True}) == []


async def test_aksk_and_kind_change(native):
    r = await create(native, kind="aksk", values={"access_key": AK, "secret_key": SK, "session_token": ""})
    assert r["fields"] == ["access_key", "secret_key"]
    with pytest.raises(BridgeError):
        await native.call("save", {**r, "kind": "token"})
    new = await native.call("save", {**r, "kind": "token", "values": {"token": TOKEN}})
    assert new["fields"] == ["token"]


DB_VALUES = {
    "engine": "PostgreSQL",
    "host": "synthetic-db.internal",
    "port": "55432",
    "database": "synthetic_ledger",
    "username": "synthetic_reader",
    "password": "synthetic-db-password-31973",
    "ssl_mode": "verify-full",
}


async def test_search_all_metadata_and_private_connection_fields(native):
    r = await create(native, kind="database", values=DB_VALUES, notes="Café 值班交接")
    for query in ["值班交接", "CAFE", "数据库连接", "TLS 模式", "主机", "ssl_mode",
                  "  EXAMPLE\t数据库\n交接  ", "ＥＸＡＭＰＬＥ", r["id"], r["updatedAt"]]:
        assert [i["id"] for i in await native.call("list", {"query": query})] == [r["id"]]
    for field, value in DB_VALUES.items():
        assert await native.call("list", {"query": value}) == []
        result = await native.call("ui_list", {"query": value})
        assert [i["id"] for i in result] == ([] if field == "password" else [r["id"]])
        assert all(v not in json.dumps(result) for v in DB_VALUES.values())
    assert await native.call("ui_list", {"query": "postgresql nobody-matches"}) == []
    assert len(await native.call("ui_list", {"query": "POSTGRESQL synthetic_reader 55432"})) == 1
    trashed = await native.call("trash", r)
    assert await native.call("ui_list", {"query": "synthetic-db.internal"}) == []
    assert len(await native.call("ui_list", {"query": "synthetic-db.internal", "trash": True})) == 1
    await native.call("restore", trashed)
    assert len(await native.call("ui_list", {"query": "synthetic-db.internal"})) == 1


async def test_search_never_matches_credential_values(native):
    await create(native)
    await create(native, kind="aksk", values={"access_key": AK, "secret_key": SK,
                                             "session_token": "session-sensitive-99881"})
    for value in [TOKEN, AK, SK, "session-sensitive-99881", "sensitive-9988", "MUST-NOT-APPEAR"]:
        for method in ["list", "ui_list"]:
            assert await native.call(method, {"query": value}) == []


async def test_database_preservation_injection_and_lifecycle(native):
    r = await create(native, kind="database", values=DB_VALUES)
    assert r["fields"] == sorted(DB_VALUES)
    assert all(v not in json.dumps(r) for v in DB_VALUES.values())
    r = await native.call("save", {**r, "name": "数据库改名"})
    assert (await native.call("reveal", r))["values"] == DB_VALUES
    bindings = {"DB_" + k.upper(): {"secret_id": r["id"], "field": k} for k in DB_VALUES}
    job = await run(
        native,
        r,
        "import os; print('|'.join(os.environ[k] for k in sorted(os.environ) if k.startswith('DB_')))",
        bindings=bindings,
    )
    result = await finished(native, job)
    assert result["exit_code"] == 0
    assert result["stdout"].count("[REDACTED]") == len(DB_VALUES)
    assert all(v not in json.dumps(result) for v in DB_VALUES.values())
    trashed = await native.call("trash", r)
    restored = await native.call("restore", trashed)
    assert (await native.call("reveal", restored))["values"] == DB_VALUES
    await native.call("purge", await native.call("trash", restored))
    assert await native.call("list", {"trash": True}) == []


@pytest.mark.parametrize(
    "changes",
    [
        {"host": " "},
        {"engine": ""},
        {"port": "0"},
        {"port": "65536"},
        {"port": "-1"},
        {"port": "5432.0"},
        {"port": "abc"},
        {"token": TOKEN},
    ],
)
async def test_database_rejects_invalid_configuration(native, changes):
    with pytest.raises(BridgeError) as e:
        await create(native, kind="database", values={**DB_VALUES, **changes})
    assert e.value.code == "INVALID_INPUT"
    assert DB_VALUES["password"] not in e.value.message


async def test_database_optional_fields_and_kind_change(native):
    r = await create(
        native, kind="database", values={"engine": "Redis", "host": "localhost", "port": "", "password": ""}
    )
    assert r["fields"] == ["engine", "host"]
    with pytest.raises(BridgeError):
        await native.call("save", {**r, "kind": "token"})
    changed = await native.call("save", {**r, "kind": "token", "values": {"token": TOKEN}})
    assert changed["fields"] == ["token"]


@pytest.mark.parametrize(
    "changes",
    [
        {"name": " "},
        {"kind": "password"},
        {"values": {"token": ""}},
        {"values": {"token": "a\0b"}},
        {"values": {"token": "a", "password": "b"}},
        {"kind": "aksk", "values": {"access_key": "a"}},
        {"tags": ["x"] * 31},
        {"values": {"token": 123}},
        {"tags": "incorrect-type"},
        {"account": 123},
    ],
)
async def test_validation_does_not_echo_secret(native, changes):
    with pytest.raises(BridgeError) as e:
        await create(native, **changes)
    assert e.value.code == "INVALID_INPUT"
    assert TOKEN not in e.value.message


async def test_inject_multiple_keys_and_redact_both_streams(native):
    r = await create(native)
    cloud = await create(native, kind="aksk", values={"access_key": AK, "secret_key": SK})
    bindings = {
        "TOKEN": {"secret_id": r["id"], "field": "token"},
        "AK": {"secret_id": cloud["id"], "field": "access_key"},
        "SK": {"secret_id": cloud["id"], "field": "secret_key"},
    }
    job = await run(
        native,
        r,
        "import os,sys; print(os.environ['TOKEN'],os.environ['AK']); print(os.environ['SK'],file=sys.stderr)",
        bindings=bindings,
    )
    result = await finished(native, job)
    assert result["state"] == "completed"
    assert result["stdout"].count("[REDACTED]") == 2
    assert "[REDACTED]" in result["stderr"]
    assert not any(s in json.dumps(result) for s in [TOKEN, AK, SK])


async def test_no_partial_output_leak(native):
    r = await create(native)
    job = await run(
        native,
        r,
        "import os,time; v=os.environ['TOKEN'].encode(); os.write(1,v[:10]); time.sleep(.3); os.write(1,v[10:])",
    )
    await asyncio.sleep(0.1)
    partial = await native.call("get_run", {"id": job["id"]})
    assert partial["state"] == "running" and partial["stdout"] == ""
    result = await finished(native, job)
    assert result["stdout"] == "[REDACTED]"


async def test_output_limit_boundary_and_drain(native):
    r = await create(native)
    result = await finished(
        native,
        await run(
            native,
            r,
            "import os; v=os.environ['TOKEN'].encode(); os.write(1,b'x'*(524288-8)+v+b'y'*600000); os.write(2,v)",
        ),
    )
    assert result["truncated"]
    assert len(result["stdout"].encode()) + len(result["stderr"].encode()) <= 1048576
    assert TOKEN not in result["stdout"] and TOKEN[:8] not in result["stdout"]
    # A secret straddling the truncation boundary may be dropped entirely.
    assert "[REDACTED]" in result["stderr"]


async def test_failure_timeout_cancel(native):
    r = await create(native)
    failure = await finished(native, await run(native, r, "raise SystemExit(7)"))
    assert failure["state"] == "failed" and failure["exit_code"] == 7
    timeout = await finished(native, await run(native, r, "import time; time.sleep(10)", timeout=0.15))
    assert timeout["state"] == "timed_out"
    job = await run(native, r, "import subprocess,time; subprocess.Popen(['sleep','15']); time.sleep(15)")
    await asyncio.sleep(0.05)
    await native.call("cancel_run", {"id": job["id"]})
    assert (await finished(native, job))["state"] == "cancelled"


async def test_inherited_environment_is_minimal(native, monkeypatch):
    monkeypatch.setenv("UNRELATED_SECRET", "never-inherit-this")
    r = await create(native)
    result = await finished(
        native, await run(native, r, "import os; print('UNRELATED_SECRET' in os.environ)")
    )
    assert result["stdout"].strip() == "False"


async def test_bad_references_cwd_and_missing_binary(native):
    r = await create(native)
    with pytest.raises(BridgeError) as e:
        await run(native, r, "pass", bindings={"TOKEN": {"secret_id": r["id"], "field": "missing"}})
    assert e.value.code == "FIELD_NOT_FOUND"
    for payload in [
        {"argv": ["/definitely/not/a/command"], "cwd": "/tmp"},
        {"argv": ["/bin/echo"], "cwd": "relative"},
    ]:
        with pytest.raises(BridgeError):
            await native.call("run", {**payload, "bindings": {"T": {"secret_id": r["id"], "field": "token"}}})


async def test_invalid_record_id_does_not_echo(native):
    with pytest.raises(BridgeError) as e:
        await native.call("metadata", {"id": TOKEN})
    assert TOKEN not in str(e.value)


async def test_short_secret_and_invalid_utf8_stay_bounded(native):
    r = await create(native, values={"token": "a"})
    output = await finished(
        native, await run(native, r, "import os; os.write(1,b'a'*600000); os.write(2,b'\\xff'*600000)")
    )
    assert output["state"] == "completed" and output["truncated"]
    assert len(output["stdout"].encode()) + len(output["stderr"].encode()) <= 1048576
    assert output["stdout"].startswith("[REDACTED]")
