"""Build one portable plugin archive; never include test storage or signing credentials."""

import json
import zipfile
from pathlib import Path

from package_files import plugin_files

root = Path(__file__).resolve().parents[1]
version = json.loads((root / "plugin.json").read_text())["version"]
native = root / "runtime/AKSKHelper.app"
ready = (native / "Contents/embedded.provisionprofile").is_file()
out = root / "dist" / f"aksk-manager-{version}{'' if ready else '-source'}.zip"
out.parent.mkdir(exist_ok=True)
paths = plugin_files(root)
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for path in sorted(set(paths)):
        z.write(path, str(Path("aksk-manager") / path.relative_to(root)))
with zipfile.ZipFile(out) as z:
    assert z.testzip() is None
    assert "aksk-manager/src/aksk_manager/ui/index.html" in z.namelist()
    for manifest in ["plugin.json", "mcp.json", ".codex-plugin/plugin.json"]:
        json.loads(z.read(f"aksk-manager/{manifest}"))
print(out)
print("包含签名组件" if ready else "源码包：不包含已签名组件，真实钥匙串操作尚不可用")
