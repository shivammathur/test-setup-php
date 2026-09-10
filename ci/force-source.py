"""Remove six bottle definitions only after setup-php has refreshed both taps."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

DEPENDENCIES = ("argon2", "libsodium", "libzip", "oniguruma", "pcre2")
workspace = Path(os.environ["GITHUB_WORKSPACE"])
evidence = workspace / "evidence"
state = Path(os.environ["HOMEBREW_TEMP"]) / "timeout-state"
assert not (evidence / "forced-source.json").exists(), "Unexpected repeated dependency install"
core = Path(sys.argv[1])
php_formula = Path(sys.argv[2])
php_original = php_formula.read_text()
for name in DEPENDENCIES:
    assert f'  depends_on "{name}"' in php_original, f"{name} must be a PHP dependency"

formulas = {name: next(core.glob(f"Formula/**/{name}.rb")) for name in DEPENDENCIES}
formulas["php@8.4"] = php_formula
manifest = []
for name, path in formulas.items():
    original = path.read_text()
    patched, count = re.subn(r"(?ms)^  bottle do\n.*?^  end\n", "", original)
    assert count == 1 and patched.count("  def install\n") == 1, path
    assert patched.endswith("\nend\n"), path
    ruby = '''
  alias_method :install_without_timeout_fixture, :install
  def install
    fixture_state = Pathname.new(STATE)
    fixture_state.mkpath
    fixture_events = fixture_state/"builds.jsonl"
    starts = fixture_events.exist? ? fixture_events.readlines.map { |line| JSON.parse(line) } : []
    attempt = starts.count { |event| event["formula"] == FORMULA && event["event"] == "start" } + 1
    record = lambda do |event, extra = {}|
      value = { "formula" => FORMULA, "event" => event, "attempt" => attempt,
                "pid" => Process.pid, "time" => Time.now.to_f }.merge(extra)
      File.open(fixture_events, "a") { |file| file.puts(JSON.generate(value)) }
    end
    record.call("start")
    install_without_timeout_fixture
    record.call("compiled")
PHP_FAULT
    record.call("return")
  end
'''.replace("STATE", json.dumps(str(state))).replace("FORMULA", json.dumps(name))
    fault = '''
    cp bin/"php", fixture_state/"php-attempt-#{attempt}.bin"
    record.call("php-artifact", { "version" => Utils.safe_popen_read(bin/"php", "-n", "-v") })
    if attempt == 1
      record.call("stall")
      system "/bin/bash", (fixture_state/"stall.sh").to_s, fixture_state.to_s
      raise "The source watchdog failed to terminate the injected stall"
    end
'''
    ruby = ruby.replace("PHP_FAULT", fault if name == "php@8.4" else "")
    patched = patched[:-5] + ruby + "\nend\n"
    (evidence / "formulas").mkdir(exist_ok=True)
    (evidence / "formulas" / (name + "-original.rb")).write_text(original)
    (evidence / "formulas" / (name + "-source.rb")).write_text(patched)
    path.write_text(patched)
    subprocess.run(["/usr/bin/ruby", "-c", str(path)], check=True)
    manifest.append({"formula": name, "path": str(path), "original_sha256": hashlib.sha256(original.encode()).hexdigest()})

# Refreshes and tap setup are finished before removing PCRE2, which host tools
# may use. Homebrew uses /usr/bin/git throughout this disposable runner test.
cellar = Path(subprocess.check_output(["brew", "--cellar"], text=True).strip())
installed = [name for name in DEPENDENCIES if (cellar / name).exists()]
if installed:
    subprocess.run(["brew", "uninstall", "--ignore-dependencies", "--force", *installed], check=True)
(evidence / "forced-source.json").write_text(json.dumps(manifest, indent=2))
print("Source builds required for: " + ", ".join(formulas), flush=True)
