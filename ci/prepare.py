"""Instrument a disposable action; leave the candidate unchanged."""
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess

workspace = Path(os.environ["GITHUB_WORKSPACE"])
candidate = workspace / "candidate"
action = workspace / "action-under-test"
evidence = workspace / "evidence"
assert platform.machine() == "arm64"
evidence.mkdir()
Path(os.environ["HOMEBREW_LOGS"]).mkdir()
state = Path(os.environ["HOMEBREW_TEMP"]) / "timeout-state"
state.mkdir(parents=True)
shutil.copy2(workspace / "ci/stall.sh", state / "stall.sh")
action.mkdir()
for name in ("src", "dist"):
    shutil.copytree(candidate / name, action / name)
shutil.copy2(candidate / "action.yml", action / "action.yml")

# Use the local core formulas that setup-php refreshes before installation.
subprocess.run(["brew", "tap", "--force", "homebrew/core"], check=True)
cellar = Path(subprocess.check_output(["brew", "--cellar"], text=True).strip())
for name in ("php@8.4", "php"):
    installed = cellar / name
    if installed.exists() and any(p.name.startswith("8.4.") for p in installed.iterdir()):
        subprocess.run(["brew", "uninstall", "--ignore-dependencies", "--force", name], check=True)

darwin = action / "src/scripts/darwin.sh"
original_darwin = darwin.read_text()
text = original_darwin.replace("setup_cached_versions() {", "setup_cached_versions_original() {", 1)
wrapper = r'''
setup_cached_versions() {
  echo cache-forced-failure >>"$GITHUB_WORKSPACE/evidence/events.log"
  return 37
}
'''
assert text.count("\n# Variables\n") == 1
darwin.write_text(text.replace("\n# Variables\n", wrapper + "\n# Variables\n"))

brew = action / "src/scripts/tools/brew.sh"
original_brew = brew.read_text()
text = original_brew
for name in ("safe_brew", "is_brew_building_from_source", "terminate_process_tree"):
    assert text.count(name + "() {") == 1
    text = text.replace(name + "() {", name + "_original() {", 1)
text += r'''
safe_brew() {
  local result=0
  printf 'brew-start:%s:%s\n' "$(date +%s)" "$*" >>"$GITHUB_WORKSPACE/evidence/events.log"
  if [[ "$*" = "install --only-dependencies "* ]]; then
    python3 "$GITHUB_WORKSPACE/ci/force-source.py" "$core_repo" "$tap_dir/$php_tap/Formula/php@8.4.rb" || return $?
  fi
  safe_brew_original "$@" 2> >(tee -a "$GITHUB_WORKSPACE/evidence/brew-stderr.log" >&2) || result=$?
  printf 'brew-end:%s:%s:%s\n' "$(date +%s)" "$result" "$*" >>"$GITHUB_WORKSPACE/evidence/events.log"
  return "$result"
}
is_brew_building_from_source() {
  if is_brew_building_from_source_original "$@"; then
    echo "source:$(date +%s)" >>"$GITHUB_WORKSPACE/evidence/events.log"
    return 0
  fi
  return 1
}
terminate_process_tree() {
  local pids pid state
  pids=$(get_process_tree "$1")
  printf 'cleanup-start:%s:%s\n' "$(date +%s)" "$(echo "$pids" | tr '\n' ' ')" >>"$GITHUB_WORKSPACE/evidence/events.log"
  terminate_process_tree_original "$@"
  for pid in $pids; do
    state=$(ps -p "$pid" -o stat= 2>/dev/null || true)
    if [[ -n "$state" && "$state" != *Z* ]]; then
      echo "cleanup-survivor:$pid:$state" >>"$GITHUB_WORKSPACE/evidence/events.log"
    fi
  done
  echo "cleanup-complete:$(date +%s)" >>"$GITHUB_WORKSPACE/evidence/events.log"
}
'''
brew.write_text(text)
for script in (darwin, brew):
    subprocess.run(["/bin/bash", "-n", str(script)], check=True)

assert not any(k.startswith("SETUP_PHP_BREW_") for k in os.environ), "Keep production watchdog defaults"
manifest = {
    "candidate": subprocess.check_output(["git", "-C", str(candidate), "rev-parse", "HEAD"], text=True).strip(),
    "architecture": platform.machine(), "bottle_timeout": 180, "source_timeout": 1800, "attempt_limit": 3,
    "original_brew_sha256": hashlib.sha256(original_brew.encode()).hexdigest(),
    "original_darwin_sha256": hashlib.sha256(original_darwin.encode()).hexdigest(),
    "test_only_developer_mode": True,
}
(evidence / "instrumentation.json").write_text(json.dumps(manifest, indent=2))
print(json.dumps(manifest, indent=2))
