"""Local development commands. Preview never starts a native helper or MCP service."""

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CACHE = ROOT / ".build/dev"
APP = ROOT / "runtime/AKSKHelper.app"


def run(argv, *, cwd=ROOT, capture=False, env=None):
    print("→ " + " ".join(map(str, argv)), flush=True)
    return subprocess.run(
        list(map(str, argv)), cwd=cwd, check=True, text=True, capture_output=capture, env=env
    )


def fingerprint(paths, root=None, extra=""):
    root = root or ROOT
    digest = hashlib.sha256(extra.encode())
    for path in sorted(paths):
        if path.is_file():
            digest.update(str(path.relative_to(root)).encode())
            digest.update(path.read_bytes())
    return digest.hexdigest()


def read_stamp(path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return None


def write_stamp(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value) + "\n")


def frontend_dependencies():
    for name in ["node", "npm", "npx"]:
        if not shutil.which(name):
            raise RuntimeError("请先安装 Node 22.12+（包含 npm 和 npx）。")
    version = run(["node", "--version"], capture=True).stdout.strip().lstrip("v")
    if tuple(map(int, version.split(".")[:2])) < (22, 12):
        raise RuntimeError("前端开发需要 Node 22.12+。")
    # Use the same npm major as the documented, locked install workflow.
    npm = ["npx", "--yes", "npm@10"]
    stamp = CACHE / "frontend.json"
    digest = fingerprint([ROOT / "frontend/package.json", ROOT / "frontend/package-lock.json"], extra=version)
    if read_stamp(stamp) != digest or not (ROOT / "frontend/node_modules/.bin/vite").exists():
        run([*npm, "ci"], cwd=ROOT / "frontend")
        write_stamp(stamp, digest)
    return npm


def native_inputs():
    paths = [p for p in (ROOT / "native").rglob("*")
             if p.is_file() and "xcuserdata" not in p.parts and p.name != ".DS_Store"]
    paths.append(ROOT / "scripts/build-native.sh")
    return fingerprint(paths, extra=os.environ.get("AKSK_DEVELOPMENT_TEAM", "XHD2S8GC8Q"))


def ensure_native(force=False):
    stamp = CACHE / "native.json"
    inputs = native_inputs()
    previous = read_stamp(stamp)
    artifact = fingerprint(APP.rglob("*")) if APP.exists() else ""
    reusable = previous == {"inputs": inputs, "artifact": artifact}
    if reusable and not force:
        checked = subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(APP)],
                                 capture_output=True, check=False)
        reusable = checked.returncode == 0
    if reusable and not force:
        print("签名组件内容与源码未变化，复用已有构建。", flush=True)
        return False
    run(["sh", "scripts/build-native.sh"])
    # Only cache after the signed helper has passed an actual Keychain lifecycle test.
    run(["uv", "run", "python", "scripts/smoke-keychain.py", "--kind", "database"])
    write_stamp(stamp, {"inputs": inputs, "artifact": fingerprint(APP.rglob("*"))})
    return True


def update(*, force_native=False, check_only=False):
    for name in ["uv", "codex"] if not check_only else ["uv"]:
        if not shutil.which(name):
            raise RuntimeError(f"缺少命令 {name}，请先安装。")
    npm = frontend_dependencies()
    run(["uv", "sync", "--frozen"])
    run(["uv", "run", "ruff", "check", "src", "tests", "scripts"])
    run(["uv", "run", "pytest", "-q"])
    run([*npm, "run", "build"], cwd=ROOT / "frontend")
    env = os.environ.copy()
    if "PLAYWRIGHT_CHANNEL" not in env and Path("/Applications/Google Chrome.app").exists():
        env["PLAYWRIGHT_CHANNEL"] = "chrome"
    if not env.get("PLAYWRIGHT_CHANNEL"):
        run([*npm, "exec", "--", "playwright", "install", "chromium"], cwd=ROOT / "frontend")
    run([*npm, "test"], cwd=ROOT / "frontend", env=env)
    run(["uv", "run", "python", "scripts/export-contract.py"])
    if check_only:
        print("检查通过；未构建签名组件、未安装插件。", flush=True)
        return
    ensure_native(force_native)
    # Diagnose runtime/signing failures before changing the installed plugin.
    run(["uv", "run", "python", "scripts/smoke-plugin.py", "--root", str(ROOT)])
    run(["sh", "scripts/install-local.sh"])
    listed = json.loads(run(["codex", "plugin", "list", "--marketplace", "aksk-manager", "--json"],
                            capture=True).stdout)
    plugin = next(p for p in listed["installed"] if p["pluginId"] == "aksk-manager@aksk-manager")
    codex_home = Path(os.environ.get("CODEX_HOME", Path.home() / ".codex"))
    installed = codex_home / "plugins/cache/aksk-manager/aksk-manager" / plugin["version"]
    run(["uv", "run", "python", "scripts/smoke-plugin.py", "--root", str(installed)])
    run(["uv", "run", "python", "scripts/package.py"])
    version = json.loads((ROOT / "plugin.json").read_text())["version"]
    archive = ROOT / "dist" / f"aksk-manager-{version}.zip"
    checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
    archive.with_suffix(".zip.sha256").write_text(f"{checksum}  {archive.name}\n")
    print(f"\n更新完成：{plugin['version']}\n安装包：{archive}\n"
          "已有 Codex 聊天可能继续使用旧进程，请在新聊天打开 AKSK Manager 验收。", flush=True)


def main():
    parser = argparse.ArgumentParser(description="AKSK Manager 实时预览和一键更新")
    sub = parser.add_subparsers(dest="command", required=True)
    preview = sub.add_parser("preview", help="仅启动本地演示预览，不访问钥匙串")
    preview.add_argument("--port", type=int, default=5173)
    deploy = sub.add_parser("update", help="测试、构建、安装并验证插件")
    deploy.add_argument("--native", action="store_true", help="强制重建签名组件")
    deploy.add_argument("--check", action="store_true", help="仅检查与前端构建，不安装")
    args = parser.parse_args()
    try:
        if args.command == "preview":
            npm = frontend_dependencies()
            print(f"\n实时预览：http://127.0.0.1:{args.port}/preview.html\n"
                  "仅内存演示数据；保存代码自动刷新。按 Ctrl+C 停止。\n", flush=True)
            os.chdir(ROOT / "frontend")
            os.execvp(npm[0], [*npm, "run", "dev", "--", "--port", str(args.port), "--strictPort"])
        else:
            update(force_native=args.native, check_only=args.check)
    except (RuntimeError, OSError, subprocess.CalledProcessError, StopIteration, ValueError) as exc:
        print(f"\n操作失败，已停止后续步骤：{exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
