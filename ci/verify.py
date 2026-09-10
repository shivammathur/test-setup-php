import json
import os
from pathlib import Path
import platform
import shutil
import subprocess

workspace = Path(os.environ["GITHUB_WORKSPACE"])
evidence = workspace / "evidence"
scenario = os.environ["TEST_SCENARIO"]
events_file = Path(os.environ["TEST_EVENTS"])
events = events_file.read_text().splitlines() if events_file.exists() else []
result = {"scenario": scenario, "architecture": platform.machine(), "events": events, "outcome": os.environ["ACTION_OUTCOME"]}
assert "cache-start" in events, "PHP installation did not enter the cache path"
if scenario == "intel-exit":
    assert result["outcome"] == "failure", result
    assert events == ["cache-start", "cache-forced-failure"], events
else:
    assert result["outcome"] == "success", result
    if scenario == "cache":
        assert "cache-result:0" in events, events
        assert not any(e.startswith("brew") for e in events), events
    else:
        assert "cache-forced-failure" in events, events
        assert any(e.startswith("brew:install --only-dependencies") for e in events), events
        assert any(e.startswith("brew:install --skip-link") for e in events), events

    php_test = r'''
    $required = ['mbstring', 'xml', 'openssl', 'pdo_sqlite'];
    foreach ($required as $extension) {
      if (!extension_loaded($extension)) throw new Exception("Missing extension: $extension");
    }
    if (PHP_MAJOR_VERSION !== 8 || PHP_MINOR_VERSION !== 4) throw new Exception('Wrong PHP version');
    if (ini_get('memory_limit') !== '256M') throw new Exception('Wrong memory_limit');
    if (ini_get('date.timezone') !== 'UTC') throw new Exception('Wrong timezone');
    $db = new PDO('sqlite::memory:');
    if ($db->query('SELECT 42')->fetchColumn() != 42) throw new Exception('SQLite failed');
    $hash = password_hash('watchdog-validation', PASSWORD_ARGON2ID);
    if (!password_verify('watchdog-validation', $hash)) throw new Exception('Argon2 failed');
    echo json_encode(['version' => PHP_VERSION, 'binary' => PHP_BINARY, 'extensions' => $required, 'argon2' => true, 'sqlite' => true, 'ini' => php_ini_loaded_file()]);
    '''
    php = json.loads(subprocess.check_output(["php", "-r", php_test], text=True))
    result["php"] = php
    result["php_version_output"] = subprocess.check_output(["php", "-v"], text=True)
    result["composer"] = subprocess.check_output(["composer", "--version"], text=True)
    result["binary_format"] = subprocess.check_output(["file", php["binary"]], text=True).strip()
    result["linked_libraries"] = subprocess.check_output(["otool", "-L", php["binary"]], text=True)
    assert ("arm64" if platform.machine() == "arm64" else "x86_64") in result["binary_format"]
    assert os.environ["PHP_OUTPUT"].startswith("8.4."), "Incorrect action output"
    if scenario != "cache":
        cellar = Path(subprocess.check_output(["brew", "--cellar"], text=True).strip())
        for name in ("php@8.4", "argon2"):
            receipts = list((cellar / name).glob("*/INSTALL_RECEIPT.json"))
            assert receipts, name
            receipt = max(receipts, key=lambda p: p.stat().st_mtime)
            value = json.loads(receipt.read_text())
            shutil.copy2(receipt, evidence / (name + "-receipt.json"))
            result[name + "_poured_from_bottle"] = value["poured_from_bottle"]
        assert result["php@8.4_poured_from_bottle"] is True, "PHP itself should use a bottle"
    source_events = [int(e.split(":", 1)[1]) for e in events if e.startswith("source:")]
    if scenario == "brew-source":
        assert result["argon2_poured_from_bottle"] is False, "Dependency did not fall back to source"
        assert source_events and max(source_events) - min(source_events) >= 180, source_events
        result["observed_source_seconds"] = max(source_events) - min(source_events)
    else:
        assert not source_events, "Unexpected source build on cache/bottle lane"

(evidence / "result.json").write_text(json.dumps(result, indent=2))
print(json.dumps(result, indent=2))
with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as summary:
    summary.write(f"### {os.environ['RUNNER_LABEL']} / {scenario}\n\nPassed. Architecture: `{platform.machine()}`. Candidate: `{os.environ['CANDIDATE_SHA']}`.\n")
