"""Create an immutable, compact local source and register only our marketplace entry."""

import hashlib
import json
import shutil
from pathlib import Path

from package_files import plugin_files

root = Path(__file__).resolve().parents[1]
files = plugin_files(root)
digest = hashlib.sha256()
for path in files:
    digest.update(str(path.relative_to(root)).encode())
    digest.update(path.read_bytes())
revision = digest.hexdigest()[:12]
stage = root / "dist/local" / revision / "aksk-manager"
if not stage.exists():
    stage.mkdir(parents=True)
    for path in files:
        destination = stage / path.relative_to(root)
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, destination)
    for name in ["plugin.json", ".codex-plugin/plugin.json"]:
        path = stage / name
        manifest = json.loads(path.read_text())
        manifest["version"] = manifest["version"].split("+")[0] + "+local." + revision
        path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
marketplace = root / ".agents/plugins/marketplace.json"
marketplace.parent.mkdir(parents=True, exist_ok=True)
data = (
    json.loads(marketplace.read_text())
    if marketplace.exists()
    else {"name": "aksk-manager", "interface": {"displayName": "AKSK Manager"}, "plugins": []}
)
if data["name"] != "aksk-manager":
    raise ValueError("Refusing to overwrite a different marketplace")
entry = {
    "name": "aksk-manager",
    "source": {"source": "local", "path": "./" + str(stage.relative_to(root))},
    "policy": {"installation": "AVAILABLE", "authentication": "ON_INSTALL"},
    "category": "Developer Tools",
}
data["plugins"] = [p for p in data["plugins"] if p["name"] != "aksk-manager"] + [entry]
marketplace.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
print("Prepared local plugin:", stage)
