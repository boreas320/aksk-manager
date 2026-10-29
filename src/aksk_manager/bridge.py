"""Private, unlogged pipe to the native component. Never place secrets in argv or files."""

import asyncio
import json
import os
import plistlib
from pathlib import Path


class BridgeError(Exception):
    def __init__(self, code: str, message: str):
        self.code, self.message = code, message
        super().__init__(message)


def helper_path() -> Path:
    root = Path(os.environ.get("AKSK_PLUGIN_ROOT", Path(__file__).resolve().parents[2]))
    bundled = root / "runtime/AKSKHelper.app/Contents/MacOS/AKSKHelper"
    if bundled.exists():
        return bundled
    return Path.home() / "Library/Application Support/AKSK Manager/AKSKHelper.app/Contents/MacOS/AKSKHelper"


class NativeBridge:
    def __init__(self, path: Path | None = None, *, verify: bool = True):
        self.path = path or helper_path()
        self.verify = verify
        self.process = None
        self.lock = asyncio.Lock()
        self.sequence = 0

    async def start(self):
        if not self.path.is_file():
            raise BridgeError("HELPER_MISSING", "尚未安装签名的本地组件，请先完成安装说明中的签名构建。")
        if self.verify:
            bundle = self.path.parents[2]
            try:
                info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
                if info.get("CFBundleIdentifier") != "com.boreas.aksk-manager.helper":
                    raise ValueError()
                if not (bundle / "Contents/embedded.provisionprofile").is_file():
                    raise ValueError()
            except (OSError, ValueError, plistlib.InvalidFileException):
                raise BridgeError(
                    "SIGNING_REQUIRED", "本地组件缺少匹配的 Mac 配置描述文件，请重新签名构建。"
                ) from None
            check = await asyncio.create_subprocess_exec(
                "/usr/bin/codesign",
                "--verify",
                "--strict",
                str(bundle),
                stdout=asyncio.subprocess.DEVNULL,
                stderr=asyncio.subprocess.DEVNULL,
            )
            if await check.wait() != 0:
                raise BridgeError("SIGNATURE_INVALID", "本地组件签名无效，请重新安装。")
        env = {
            k: v
            for k, v in os.environ.items()
            if k in {"PATH", "HOME", "TMPDIR", "USER", "LOGNAME", "LANG", "LC_ALL", "SHELL"}
        }
        self.process = await asyncio.create_subprocess_exec(
            str(self.path),
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL,
            env=env,
            limit=8 * 1024 * 1024,
        )

    async def call(self, method: str, payload: dict | None = None):
        async with self.lock:
            if self.process is None:
                await self.start()
            if self.process.returncode is not None:
                raise BridgeError(
                    "HELPER_STOPPED", "本地组件已停止，请检查签名与配置描述文件后重新打开插件。"
                )
            self.sequence += 1
            request = (
                json.dumps(
                    {"id": self.sequence, "method": method, "payload": payload or {}}, ensure_ascii=False
                ).encode()
                + b"\n"
            )
            if len(request) > 1024 * 1024:
                raise BridgeError("INVALID_INPUT", "请求过大。")
            try:
                self.process.stdin.write(request)
                await self.process.stdin.drain()
                raw = await asyncio.wait_for(self.process.stdout.readline(), timeout=60)
                response = json.loads(raw)
                if response.get("id") != self.sequence:
                    raise ValueError()
            except (TimeoutError, OSError, ValueError):
                await self.close()
                raise BridgeError(
                    "HELPER_UNAVAILABLE", "本地组件未返回有效结果，操作结果未知；请刷新检查，不要重复提交。"
                ) from None
            if not response.get("ok"):
                error = response.get("error", {})
                raise BridgeError(error.get("code", "INTERNAL_ERROR"), error.get("message", "本地操作失败。"))
            return response["data"]

    async def close(self):
        if self.process and self.process.returncode is None:
            self.process.stdin.close()
            try:
                await asyncio.wait_for(self.process.wait(), timeout=3)
            except TimeoutError:
                self.process.terminate()
                await self.process.wait()
