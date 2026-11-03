"""A running old version must not share a mutable Python install with an update."""
import os
import subprocess
from pathlib import Path


def test_launchers_isolate_versions_but_reuse_the_same_root(tmp_path):
    binary = tmp_path / "bin"
    binary.mkdir()
    uv = binary / "uv"
    uv.write_text('#!/bin/sh\nprintf "%s\\n" "$UV_PROJECT_ENVIRONMENT" "$AKSK_PLUGIN_ROOT"\n')
    uv.chmod(0o755)
    source = Path(__file__).resolve().parents[1] / "scripts/run-server.sh"
    env = {**os.environ, "PATH": f"{binary}:/usr/bin:/bin", "XDG_CACHE_HOME": str(tmp_path / "cache")}

    def launch(name):
        root = tmp_path / name
        scripts = root / "scripts"
        scripts.mkdir(parents=True, exist_ok=True)
        launcher = scripts / "run-server.sh"
        launcher.write_text(source.read_text())
        result = subprocess.run(["/bin/sh", str(launcher)], env=env, text=True,
                                capture_output=True, check=True)
        venv, actual_root = result.stdout.splitlines()
        assert actual_root == str(root)
        return venv

    first = launch("version one")
    second = launch("version two")
    assert first != second
    assert launch("version one") == first
    assert first.startswith(str(tmp_path / "cache" / "aksk-manager"))
