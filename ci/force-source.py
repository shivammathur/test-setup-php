"""Remove the argon2 bottle after setup-php has refreshed Homebrew/core."""
import hashlib
import json
import os
from pathlib import Path
import re
import sys

evidence = Path(os.environ["GITHUB_WORKSPACE"]) / "evidence"
if (evidence / "forced-source.json").exists():
    raise RuntimeError("Unexpected second Homebrew dependency update")
formula = next(Path(sys.argv[1]).glob("Formula/**/argon2.rb"))
original = formula.read_text()
patched, count = re.subn(r"(?ms)^  bottle do\n.*?^  end\n", "", original)
assert count == 1, "argon2 must have exactly one bottle block"
assert patched.count("  def install\n") == 1
patched = patched.replace("  def install\n", '  def install\n    system "sleep", "190"\n', 1)
formula.write_text(patched)
(evidence / "argon2-original.rb").write_text(original)
(evidence / "argon2-source.rb").write_text(patched)
result = {"formula": str(formula), "quiet_seconds": 190, "original_sha256": hashlib.sha256(original.encode()).hexdigest()}
(evidence / "forced-source.json").write_text(json.dumps(result, indent=2))
print(json.dumps(result))
