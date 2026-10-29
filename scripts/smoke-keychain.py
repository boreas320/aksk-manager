"""Explicit live test. Creates and removes ONE uniquely identified synthetic item only."""

import argparse
import asyncio
import uuid

from aksk_manager.bridge import BridgeError, NativeBridge


async def main(kind="token"):
    bridge = NativeBridge()
    independent = NativeBridge()
    record = None
    cleanup_failed = False
    try:
        await bridge.call("status")
        value = "SYNTHETIC-" + uuid.uuid4().hex
        values = (
            {"token": value}
            if kind == "token"
            else {
                "engine": "PostgreSQL",
                "host": "synthetic-db.invalid",
                "port": "55432",
                "database": "synthetic_database",
                "username": "synthetic_user",
                "password": value,
                "ssl_mode": "verify-full",
            }
        )
        record = await bridge.call(
            "save",
            {
                "kind": kind,
                "name": "AKSK smoke " + uuid.uuid4().hex,
                "values": values,
                "tags": ["synthetic-test"],
            },
        )
        revealed = await bridge.call("reveal", {"id": record["id"], "revision": record["revision"]})
        assert revealed["values"] == values
        if kind == "database":
            query = record["name"] + " " + values["host"] + " " + values["username"]
            matches = await independent.call("ui_list", {"query": query})
            assert [item["id"] for item in matches] == [record["id"]]
            assert await independent.call("list", {"query": query}) == []
        secret_query = record["name"] + " " + value
        matches = await independent.call("ui_list", {"query": secret_query})
        assert [item["id"] for item in matches] == [record["id"]]
        assert value not in str(matches)
        assert await independent.call("list", {"query": secret_query}) == []
        print("PASS: 界面支持密钥值搜索；结果不含明文，模型接口仍仅搜索元数据。")
        updated = await bridge.call("save", {**record, "name": record["name"] + " updated"})
        readback = await independent.call("metadata", {"id": updated["id"]})
        assert readback["revision"] == updated["revision"]
        try:
            await bridge.call("save", record)
            raise AssertionError("stale update unexpectedly succeeded")
        except BridgeError as exc:
            assert exc.code == "CONFLICT"
        trashed = await bridge.call("trash", updated)
        restored = await bridge.call("restore", trashed)
        revealed = await independent.call("reveal", {"id": restored["id"], "revision": restored["revision"]})
        assert revealed["values"] == values
        # Never print the secret. Use it only in the native runner's environment.
        job = await bridge.call(
            "run",
            {
                "argv": [
                    "/bin/sh",
                    "-c",
                    "printf '%s\\n' " + " ".join('"$AKSK_SMOKE_' + field.upper() + '"' for field in values),
                ],
                "cwd": "/tmp",
                "bindings": {
                    "AKSK_SMOKE_" + field.upper(): {"secret_id": record["id"], "field": field}
                    for field in values
                },
            },
        )
        for _ in range(100):
            result = await bridge.call("get_run", {"id": job["id"]})
            if result["state"] != "running":
                assert result["state"] == "completed" and result["stdout"].splitlines() == [
                    "[REDACTED]"
                ] * len(values)
                break
            await asyncio.sleep(0.05)
        else:
            raise RuntimeError("Smoke command timed out")
        print(
            f"PASS ({kind}): 本机可同步钥匙串新增、更新、冲突检查、回收站、恢复、独立进程读回、引用执行及脱敏。"
        )
    finally:
        if record:
            try:
                current = await bridge.call("metadata", {"id": record["id"]})
                trashed = await bridge.call("trash", current)
                await bridge.call("purge", trashed)
                try:
                    await independent.call("metadata", {"id": record["id"]})
                    raise AssertionError("deleted item is still readable")
                except BridgeError as exc:
                    assert exc.code == "NOT_FOUND"
                print("PASS: 合成测试条目已清理，并经独立进程确认不存在。双机同步仍需独立验收。")
            except Exception:  # noqa: BLE001 -- never emit a cleanup traceback containing credential data.
                cleanup_failed = True
                print("测试条目清理未完成，请在界面中查找 AKSK smoke 条目；ID:", record["id"])
        await bridge.close()
        await independent.close()
        if cleanup_failed:
            raise SystemExit(1)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--kind", choices=["token", "database"], default="token")
    asyncio.run(main(parser.parse_args().kind))
