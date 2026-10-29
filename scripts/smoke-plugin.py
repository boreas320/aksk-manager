"""Verify an installed plugin's actual stdio protocol without touching secrets."""

import argparse
import asyncio
import json
from pathlib import Path

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client


async def main(root: Path):
    config = json.loads((root / "mcp.json").read_text())["mcpServers"]["aksk-manager"]
    command = config["command"]
    assert not command.startswith("/"), "Codex plugin commands must use a bare executable or contained ./ path"
    args = [arg.replace("${PLUGIN_ROOT}", str(root)) for arg in config.get("args", [])]
    params = StdioServerParameters(command=command, args=args)
    async with stdio_client(params) as (reader, writer), ClientSession(reader, writer) as session:
        await session.initialize()
        tools = {t.name: t for t in (await session.list_tools()).tools}
        assert tools["aksk.open"].meta["openai/ui"]["entrypoints"] == [{"type": "thread"}]
        assert tools["ui_reveal"].meta["ui"]["visibility"] == ["app"]
        assert (await session.call_tool("aksk.open", {})).isError is False
        resource = await session.read_resource("ui://aksk-manager/vault")
        assert "AKSK Manager" in resource.contents[0].text
        assert resource.contents[0].mimeType == "text/html;profile=mcp-app"
        print(f"PASS: 实际安装包 stdio 启动、{len(tools)} 个工具发现、会话入口与内嵌界面资源。")
        status = await session.call_tool("ui_status", {})
        private = status.meta["private"]
        if private["ok"]:
            print("PASS: 本机钥匙串可读取；未执行真实写入或双机同步测试。")
        else:
            raise SystemExit("BLOCKED: " + private["error"]["code"] + ": " + private["error"]["message"])


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    asyncio.run(main(parser.parse_args().root.resolve()))
