"""One allowlist shared by local installation and archive generation."""

import subprocess
from pathlib import Path


def plugin_files(root: Path) -> list[Path]:
    names = [
        "plugin.json",
        "mcp.json",
        ".mcp.json",
        "pyproject.toml",
        "uv.lock",
        "README.md",
        ".gitignore",
        "THIRD_PARTY_NOTICES.md",
    ]
    folders = [".codex-plugin", "src", "scripts", "assets", "skills", "native", "docs", "frontend", "tests"]
    if (root / "runtime/AKSKHelper.app/Contents/embedded.provisionprofile").is_file():
        subprocess.run(
            ["/usr/bin/codesign", "--verify", "--strict", str(root / "runtime/AKSKHelper.app")], check=True
        )
        folders.append("runtime")
    excluded = {"__pycache__", "node_modules", "test-results", "playwright-report", "xcuserdata"}
    paths = [root / name for name in names]
    for folder in folders:
        paths.extend(
            p
            for p in (root / folder).rglob("*")
            if p.is_file()
            and not any(part in excluded for part in p.relative_to(root).parts)
            and p.suffix not in {".pyc", ".png"}
            and p.name != ".DS_Store"
        )
    for path in paths:
        if path.is_symlink():
            raise ValueError(f"Refusing to package a symbolic link: {path.relative_to(root)}")
    return sorted(set(paths))
