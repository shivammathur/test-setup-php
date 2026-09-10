"""Observe the candidate and inject failures only in a disposable action copy."""
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
evidence.mkdir(exist_ok=True)
scenario = os.environ["TEST_SCENARIO"]
machine = platform.machine()
assert scenario not in ("brew-bottle", "brew-source") or machine == "arm64"
assert scenario != "intel-exit" or machine == "x86_64"
action.mkdir()
for name in ("src", "dist"):
    shutil.copytree(candidate / name, action / name)
shutil.copy2(candidate / "action.yml", action / "action.yml")

env = {**os.environ, "HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_INSTALL_CLEANUP": "1"}
cellar = Path(subprocess.check_output(["brew", "--cellar"], text=True, env=env).strip())
for formula in ("php@8.4", "php"):
    installed = cellar / formula
    if installed.exists() and any(p.name.startswith("8.4.") for p in installed.iterdir()):
        subprocess.run(["brew", "uninstall", "--ignore-dependencies", "--force", formula], env=env, check=True)

if scenario == "brew-source":
    env["HOMEBREW_NO_INSTALL_FROM_API"] = "1"
    subprocess.run(["brew", "tap", "--force", "homebrew/core"], env=env, check=True)
    if (cellar / "argon2").exists():
        subprocess.run(["brew", "uninstall", "--ignore-dependencies", "--force", "argon2"], env=env, check=True)

darwin = action / "src/scripts/darwin.sh"
original = darwin.read_text()
text = original.replace("setup_cached_versions() {", "setup_cached_versions_original() {", 1)
text = text.replace("update_dependencies() {", "update_dependencies_original() {", 1)
wrappers = r'''
setup_cached_versions() {
  local result
  echo cache-start >>"$TEST_EVENTS"
  if [ "$TEST_SCENARIO" != cache ]; then
    echo cache-forced-failure >>"$TEST_EVENTS"
    return 37
  fi
  setup_cached_versions_original "$@"
  result=$?
  echo "cache-result:$result" >>"$TEST_EVENTS"
  return "$result"
}
update_dependencies() {
  echo brew-update >>"$TEST_EVENTS"
  [ "$TEST_SCENARIO" != intel-exit ] || return 99
  update_dependencies_original "$@" || return $?
  if [ "$TEST_SCENARIO" = brew-source ]; then
    python3 "$GITHUB_WORKSPACE/ci/force-source.py" "$core_repo" || return $?
  fi
}
'''
assert text.count("\n# Variables\n") == 1
text = text.replace("\n# Variables\n", wrappers + "\n# Variables\n")
darwin.write_text(text)
brew = action / "src/scripts/tools/brew.sh"
brew_text = brew.read_text().replace("safe_brew() {", "safe_brew_original() {", 1)
brew_text = brew_text.replace("is_brew_building_from_source() {", "is_brew_building_from_source_original() {", 1)
brew_text += r'''
safe_brew() {
  printf 'brew:%s\n' "$*" >>"$TEST_EVENTS"
  [ "$TEST_SCENARIO" != intel-exit ] || return 99
  safe_brew_original "$@"
}
is_brew_building_from_source() {
  if is_brew_building_from_source_original "$@"; then
    echo "source:$(date +%s)" >>"$TEST_EVENTS"
    return 0
  fi
  return 1
}
'''
brew.write_text(brew_text)
for script in (darwin, brew):
    subprocess.run(["/bin/bash", "-n", str(script)], check=True)
manifest = {
    "scenario": scenario, "architecture": machine,
    "candidate": subprocess.check_output(["git", "-C", str(candidate), "rev-parse", "HEAD"], text=True).strip(),
    "original_darwin_sha256": hashlib.sha256(original.encode()).hexdigest(),
    "bottle_timeout": os.environ.get("SETUP_PHP_BREW_INACTIVITY_TIMEOUT", "180"),
    "source_timeout": os.environ.get("SETUP_PHP_BREW_SOURCE_INACTIVITY_TIMEOUT", "1800"),
    "source_fixture_developer_mode": scenario == "brew-source",
    "fault": "none" if scenario == "cache" else "setup_cached_versions returns 37",
}
(evidence / "instrumentation.json").write_text(json.dumps(manifest, indent=2))
print(json.dumps(manifest, indent=2))
