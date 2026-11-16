"""Register the verified native helper for this repository's Chrome extension."""

import base64
import hashlib
import json
import shlex
import subprocess
from pathlib import Path


def main():
    root = Path(__file__).resolve().parents[1]
    bundle = root / "runtime/AKSKHelper.app"
    subprocess.run(["codesign", "--verify", "--strict", str(bundle)], check=True)
    binary = bundle / "Contents/MacOS/AKSKHelper"
    if not (bundle / "Contents/embedded.provisionprofile").is_file():
        raise SystemExit("请先构建签名的本机组件。")
    manifest = json.loads((root / "browser/manifest.json").read_text())
    digest = hashlib.sha256(base64.b64decode(manifest["key"])).hexdigest()[:32]
    extension = "".join(chr(ord("a") + int(char, 16)) for char in digest)
    support = Path.home() / "Library/Application Support"
    launcher = support / "AKSK Manager/chrome-host"
    launcher.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    launcher.write_text("#!/bin/sh\nexec " + shlex.quote(str(binary)) + " --browser\n")
    launcher.chmod(0o700)
    target = support / "Google/Chrome/NativeMessagingHosts/com.boreas.aksk_manager.json"
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps({
        "name": "com.boreas.aksk_manager", "description": "AKSK Manager 本机填充",
        "path": str(launcher), "type": "stdio", "allowed_origins": [f"chrome-extension://{extension}/"],
    }, indent=2))
    print(f"在 Chrome 扩展管理中选择「加载已解压的扩展程序」，目录：{root / 'browser'}")


if __name__ == "__main__":
    main()
