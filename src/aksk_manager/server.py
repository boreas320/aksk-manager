"""Codex MCP tools and app-only secret management. No HTTP server or secret logging."""

import json
import logging
from contextlib import asynccontextmanager
from pathlib import Path

from mcp.server.fastmcp import FastMCP
from mcp.server.lowlevel.helper_types import ReadResourceContents
from mcp.types import CallToolResult, Icon, TextContent, ToolAnnotations

from .bridge import BridgeError, NativeBridge

# SDK debug traces can include tool arguments, so disable them explicitly.
for namespace in ("mcp", "httpx", "httpcore"):
    logger = logging.getLogger(namespace)
    logger.handlers = [logging.NullHandler()]
    logger.propagate = False

bridge = NativeBridge()


@asynccontextmanager
async def lifespan(_server):
    try:
        yield {}
    finally:
        await bridge.close()


mcp = FastMCP(
    "AKSK Manager",
    lifespan=lifespan,
    instructions="Find credential metadata and use secret references in local commands. "
    "Never ask for secrets in chat or try to print, encode, export, or transmit them. "
    "Ask the user to enter credentials in the AKSK Manager app. "
    "Command execution has side effects and must respect the user's task and host policies.",
)
URI = "ui://aksk-manager/vault"
READ = ToolAnnotations(readOnlyHint=True, destructiveHint=False, openWorldHint=False)
WRITE = ToolAnnotations(readOnlyHint=False, destructiveHint=False, openWorldHint=False)
EXEC = ToolAnnotations(readOnlyHint=False, destructiveHint=True, openWorldHint=True)
APP_ONLY = {"ui": {"visibility": ["app"]}}
ICON = Icon(
    src="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 64 64'%3E%3Crect x='8' y='27' width='48' height='30' rx='8' fill='%232e7164'/%3E%3Cpath d='M20 27V19a12 12 0 0 1 24 0v8' fill='none' stroke='%232e7164' stroke-width='5'/%3E%3C/svg%3E",
    mimeType="image/svg+xml",
)


def result(data=None, error=None, *, private=False):
    payload = {"ok": error is None}
    payload["data" if error is None else "error"] = data if error is None else error
    if private:
        # _meta is app-only: secret values never occur in content or structuredContent.
        return CallToolResult(
            content=[TextContent(type="text", text="界面操作完成。" if not error else "界面操作失败。")],
            isError=error is not None,
            _meta={"private": payload},
        )
    return CallToolResult(
        content=[TextContent(type="text", text=json.dumps(payload, ensure_ascii=False))],
        structuredContent=payload,
        isError=error is not None,
    )


async def invoke(method, payload=None, *, private=False):
    try:
        return result(await bridge.call(method, payload), private=private)
    except BridgeError as exc:
        return result(error={"code": exc.code, "message": exc.message}, private=private)
    except Exception:  # noqa: BLE001 -- exception details may contain credential input.
        return result(
            error={"code": "INTERNAL_ERROR", "message": "操作失败，已省略可能含有密钥的详情。"},
            private=private,
        )


@mcp.tool(
    name="aksk.open",
    title="AKSK Manager",
    annotations=READ,
    icons=[ICON],
    meta={"ui": {"resourceUri": URI}, "openai/ui": {"entrypoints": [{"type": "thread"}]}},
)
async def open_manager() -> CallToolResult:
    """Open the AKSK Manager credential management app."""
    # Always allow the UI to open and explain missing signing/installation prerequisites.
    return result({"version": "0.1.0", "storage": "Apple Keychain", "sync": "iCloud Keychain"})


@mcp.resource(URI, mime_type="text/html;profile=mcp-app", title="AKSK Manager")
def app_html():
    return (Path(__file__).parent / "ui/index.html").read_text()


@mcp._mcp_server.read_resource()
async def read_resource(uri):
    if str(uri) != URI:
        raise ValueError("Unknown resource")
    return [
        ReadResourceContents(
            content=app_html(),
            mime_type="text/html;profile=mcp-app",
            meta={
                "ui": {
                    "csp": {"connectDomains": [], "resourceDomains": []},
                    "permissions": {"clipboardWrite": {}},
                },
                "openai/ui": {
                    "preferredDisplayMode": "fullscreen",
                    "availableDisplayModes": ["fullscreen", "inline"],
                },
            },
        )
    ]


@mcp.tool(annotations=READ)
async def list_secrets(query: str = "") -> CallToolResult:
    """Search all active metadata including notes, kind, field names, IDs and dates.

    Whitespace-separated terms match across fields, ignoring case, accents and width.
    Credential and database connection values are not searched or returned.
    """
    return await invoke("list", {"query": query})


@mcp.tool(annotations=READ)
async def get_secret_metadata(secret_id: str) -> CallToolResult:
    """Get a credential's metadata, revision and available field names without revealing secrets."""
    return await invoke("metadata", {"id": secret_id})


@mcp.tool(annotations=EXEC)
async def run_with_secrets(
    argv: list[str], cwd: str, bindings: dict[str, dict[str, str]], timeout_seconds: float = 600
) -> CallToolResult:
    """Run a user-authorized command with credentials injected locally into its environment.

    bindings maps an environment variable name to {secret_id, field}. Fields are access_key,
    secret_key, session_token, token, or database fields engine, host, port, database,
    username, password, ssl_mode. Bind only fields listed in metadata. Use an absolute cwd. argv is not shell-expanded;
    explicitly invoke a shell only when needed. Returns a run id; poll get_run for output.
    Never run commands intended to reveal or export credentials. This is not a security sandbox.
    """
    return await invoke(
        "run", {"argv": argv, "cwd": cwd, "bindings": bindings, "timeout_seconds": timeout_seconds}
    )


@mcp.tool(annotations=READ)
async def get_run(run_id: str) -> CallToolResult:
    """Get the run's state and completed redacted output. Jobs belong to this MCP session."""
    return await invoke("get_run", {"id": run_id})


@mcp.tool(annotations=EXEC)
async def cancel_run(run_id: str) -> CallToolResult:
    """Cancel a running command and its process group."""
    return await invoke("cancel_run", {"id": run_id})


@mcp.tool(annotations=READ, meta=APP_ONLY)
async def ui_status() -> CallToolResult:
    """App only: inspect helper and Keychain access, without claiming remote sync."""
    return await invoke("status", private=True)


@mcp.tool(annotations=READ, meta=APP_ONLY)
async def ui_list(trash: bool = False, query: str = "") -> CallToolResult:
    """App only: search metadata and non-password database connection fields locally.

    Returns metadata only. Never searches passwords, keys or token values.
    """
    return await invoke("ui_list", {"trash": trash, "query": query}, private=True)


@mcp.tool(annotations=WRITE, meta=APP_ONLY)
async def ui_save(record: dict) -> CallToolResult:
    """App only: save a credential. Omitted values preserve existing secrets of the same kind."""
    return await invoke("save", record, private=True)


@mcp.tool(annotations=READ, meta=APP_ONLY)
async def ui_reveal(secret_id: str, revision: str) -> CallToolResult:
    """App only: reveal a credential to its management interface via private metadata."""
    return await invoke("reveal", {"id": secret_id, "revision": revision}, private=True)


@mcp.tool(annotations=WRITE, meta=APP_ONLY)
async def ui_trash(secret_id: str, revision: str) -> CallToolResult:
    """App only: move a credential into trash."""
    return await invoke("trash", {"id": secret_id, "revision": revision}, private=True)


@mcp.tool(annotations=WRITE, meta=APP_ONLY)
async def ui_restore(secret_id: str, revision: str) -> CallToolResult:
    """App only: restore a trashed credential."""
    return await invoke("restore", {"id": secret_id, "revision": revision}, private=True)


@mcp.tool(
    annotations=ToolAnnotations(readOnlyHint=False, destructiveHint=True, openWorldHint=False), meta=APP_ONLY
)
async def ui_purge(secret_id: str, revision: str) -> CallToolResult:
    """App only: permanently delete a trashed item, including its synced copies."""
    return await invoke("purge", {"id": secret_id, "revision": revision}, private=True)


def main():
    mcp.run(transport="stdio")


if __name__ == "__main__":
    main()
