"""Regression checks for the update gate and signed-build reuse."""

import importlib.util
import subprocess
from pathlib import Path

import pytest

SPEC = importlib.util.spec_from_file_location("aksk_dev", Path(__file__).parents[1] / "scripts/dev.py")
dev = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(dev)


@pytest.fixture
def workspace(tmp_path, monkeypatch):
    monkeypatch.setattr(dev, "ROOT", tmp_path)
    monkeypatch.setattr(dev, "CACHE", tmp_path / ".build/dev")
    monkeypatch.setattr(dev, "APP", tmp_path / "runtime/AKSKHelper.app")
    (tmp_path / "native").mkdir()
    (tmp_path / "native/main.swift").write_text("original source")
    (tmp_path / "scripts").mkdir()
    (tmp_path / "scripts/build-native.sh").write_text("build")
    dev.APP.mkdir(parents=True)
    (dev.APP / "binary").write_text("signed binary")
    return tmp_path


def test_native_reuse_invalidates_for_source_artifact_and_team(workspace, monkeypatch):
    calls = []
    monkeypatch.setattr(dev, "run", lambda argv, **kwargs: calls.append(argv))
    monkeypatch.setattr(dev.subprocess, "run", lambda *a, **k: subprocess.CompletedProcess(a, 0))
    assert dev.ensure_native() is True
    assert any("scripts/smoke-keychain.py" in call for call in calls)
    calls.clear()
    assert dev.ensure_native() is False
    assert calls == []
    (workspace / "native/main.swift").write_text("changed source")
    assert dev.ensure_native() is True
    (dev.APP / "binary").write_text("changed binary")
    assert dev.ensure_native() is True
    monkeypatch.setenv("AKSK_DEVELOPMENT_TEAM", "another-team")
    assert dev.ensure_native() is True
    assert dev.ensure_native(force=True) is True


def test_failed_native_smoke_does_not_cache(workspace, monkeypatch):
    def fail_smoke(argv, **kwargs):
        if "scripts/smoke-keychain.py" in argv:
            raise subprocess.CalledProcessError(1, argv)
    monkeypatch.setattr(dev, "run", fail_smoke)
    with pytest.raises(subprocess.CalledProcessError):
        dev.ensure_native()
    assert not (dev.CACHE / "native.json").exists()


def test_update_test_failure_prevents_build_and_install(monkeypatch):
    calls = []
    monkeypatch.setattr(dev.shutil, "which", lambda _: "/fake/command")
    monkeypatch.setattr(dev, "frontend_dependencies", lambda: ["npm"])
    def run(argv, **kwargs):
        calls.append(argv)
        if "pytest" in argv:
            raise subprocess.CalledProcessError(1, argv)
    monkeypatch.setattr(dev, "run", run)
    with pytest.raises(subprocess.CalledProcessError):
        dev.update()
    assert not any("scripts/install-local.sh" in call or "build" in call for call in calls)


def test_check_only_never_signs_or_installs(monkeypatch):
    calls = []
    monkeypatch.setattr(dev.shutil, "which", lambda _: "/fake/command")
    monkeypatch.setattr(dev, "frontend_dependencies", lambda: ["npm"])
    monkeypatch.setattr(dev, "run", lambda argv, **kwargs: calls.append(argv))
    monkeypatch.setattr(dev, "ensure_native", lambda *a: pytest.fail("check must not sign"))
    dev.update(check_only=True)
    assert ["npm", "test"] in calls
    assert not any("scripts/install-local.sh" in call for call in calls)
