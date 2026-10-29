import asyncio
import json
from pathlib import Path

from aksk_manager.server import mcp


async def main():
    tools = await mcp.list_tools()
    target = Path(__file__).resolve().parents[1] / "docs/mcp-contract.json"
    target.write_text(
        json.dumps(
            {
                "version": "0.1.0",
                "transport": "stdio",
                "tools": [t.model_dump(mode="json", by_alias=True, exclude_none=True) for t in tools],
            },
            indent=2,
            ensure_ascii=False,
        )
        + "\n"
    )
    print(target)


asyncio.run(main())
