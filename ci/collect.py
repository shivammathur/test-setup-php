"""Preserve evidence, including compiled outputs from a timed-out attempt."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

workspace = Path(os.environ["GITHUB_WORKSPACE"])
evidence = workspace / "evidence"
evidence.mkdir(exist_ok=True)
state = Path(os.environ["HOMEBREW_TEMP"]) / "timeout-state"
if state.exists():
    shutil.copytree(state, evidence / "build-state", dirs_exist_ok=True)
cellar = Path(subprocess.check_output(["brew", "--cellar"], text=True).strip())
artifacts = []
for name in ("argon2", "libsodium", "libzip", "oniguruma", "pcre2", "php@8.4"):
    rack = cellar / name
    if not rack.exists():
        continue
    destination = evidence / "installed" / name
    destination.mkdir(parents=True, exist_ok=True)
    for receipt in rack.glob("*/INSTALL_RECEIPT.json"):
        shutil.copy2(receipt, destination / (receipt.parent.name + "-receipt.json"))
    files = list(rack.glob("*/lib/*.dylib"))
    if name == "php@8.4":
        files += list(rack.glob("*/bin/php*")) + list(rack.glob("*/sbin/php-fpm"))
    for path in files:
        if path.is_symlink() or not path.is_file():
            continue
        fmt = subprocess.check_output(["file", str(path)], text=True).strip()
        if "Mach-O" not in fmt:
            continue
        target = destination / path.name
        shutil.copy2(path, target)
        artifacts.append({"formula": name, "path": str(path), "file": fmt,
                          "sha256": hashlib.sha256(path.read_bytes()).hexdigest()})
(evidence / "artifacts.json").write_text(json.dumps(artifacts, indent=2))
print(json.dumps(artifacts, indent=2))
