"""Require successful real source builds and a real 1800-second timeout."""
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess

workspace = Path(os.environ["GITHUB_WORKSPACE"])
evidence = workspace / "evidence"
state = Path(os.environ["HOMEBREW_TEMP"]) / "timeout-state"
assert os.environ["ACTION_OUTCOME"] == "success", "PHP installation did not recover; inspect the build logs"
events = (evidence / "events.log").read_text().splitlines()
builds = [json.loads(line) for line in (state / "builds.jsonl").read_text().splitlines()]
stderr = (evidence / "brew-stderr.log").read_text()
assert events.count("cache-forced-failure") == 1
assert any("install --only-dependencies" in event for event in events)
assert any("install --skip-link" in event for event in events)
assert not any("upgrade -f" in event for event in events), "Unexpected upgrade fallback"
assert stderr.count("no output for 1800s; terminating") == 1, stderr
assert stderr.count("retrying brew command") == 1, stderr
assert "attempt 2/3, exit 124" in stderr, stderr
assert "no output for 180s" not in stderr, stderr
assert not any(event.startswith("cleanup-survivor:") for event in events), events
cleanups = [event for event in events if event.startswith("cleanup-start:")]
completed = [event for event in events if event.startswith("cleanup-complete:")]
assert len(cleanups) == len(completed) == 1, events
cleanup_time = int(completed[0].split(":")[1])
stall_started = int((state / "stall-started").read_text())
stall_duration = int(cleanups[0].split(":")[1]) - stall_started
assert 1799 <= stall_duration <= 1860, stall_duration
recorded_pids = {int(pid) for pid in cleanups[0].split(":")[2].split()}
recorded_pids.add(int((state / "stall.pid").read_text()))
for pid in recorded_pids:
    status = subprocess.run(["ps", "-p", str(pid), "-o", "stat="], capture_output=True, text=True)
    assert status.returncode != 0 or status.stdout.strip().startswith("Z"), (pid, status.stdout)

dependencies = ("argon2", "libsodium", "libzip", "oniguruma", "pcre2")
for name in dependencies:
    assert [e["event"] for e in builds if e["formula"] == name] == ["start", "compiled", "return"], builds
php_builds = [e for e in builds if e["formula"] == "php@8.4"]
assert [e["event"] for e in php_builds if e["attempt"] == 1] == ["start", "compiled", "php-artifact", "stall"], php_builds
assert [e["event"] for e in php_builds if e["attempt"] == 2] == ["start", "compiled", "php-artifact", "return"], php_builds
assert {e["attempt"] for e in php_builds} == {1, 2}
assert next(e["time"] for e in php_builds if e["event"] == "start" and e["attempt"] == 2) >= cleanup_time
assert next(e["pid"] for e in php_builds if e["attempt"] == 1) in recorded_pids
assert all(e["time"] < php_builds[0]["time"] for e in builds if e["formula"] in dependencies)

cellar = Path(subprocess.check_output(["brew", "--cellar"], text=True).strip())
receipts = {}
for name in (*dependencies, "php@8.4"):
    receipt = max((cellar / name).glob("*/INSTALL_RECEIPT.json"), key=lambda p: p.stat().st_mtime)
    value = json.loads(receipt.read_text())
    assert value["poured_from_bottle"] is False, (name, value)
    assert value["built_as_bottle"] is False, (name, value)
    assert value["arch"] == "arm64", (name, value)
    receipts[name] = value
    shutil.copy2(receipt, evidence / (name + "-receipt.json"))

php_test = r'''
$required = ['mbstring','xml','openssl','pdo_sqlite','sodium','zip'];
foreach ($required as $extension) if (!extension_loaded($extension)) throw new Exception($extension);
if (PHP_MAJOR_VERSION !== 8 || PHP_MINOR_VERSION !== 4) throw new Exception('Wrong PHP');
if (ini_get('memory_limit') !== '256M' || ini_get('date.timezone') !== 'UTC') throw new Exception('Wrong ini');
$hash = password_hash('source-test', PASSWORD_ARGON2ID);
if (!password_verify('source-test', $hash)) throw new Exception('Argon2');
$key = sodium_crypto_secretbox_keygen(); $nonce = random_bytes(SODIUM_CRYPTO_SECRETBOX_NONCEBYTES);
$cipher = sodium_crypto_secretbox('source-test', $nonce, $key);
if (sodium_crypto_secretbox_open($cipher, $nonce, $key) !== 'source-test') throw new Exception('Sodium');
if (!mb_ereg('^source-[a-z]+$', 'source-test')) throw new Exception('Oniguruma');
if (preg_match('/^source-[a-z]+$/', 'source-test') !== 1) throw new Exception('PCRE2');
$file = tempnam(sys_get_temp_dir(), 'source-zip'); $zip = new ZipArchive();
if ($zip->open($file, ZipArchive::OVERWRITE) !== true) throw new Exception('Zip open');
$zip->addFromString('test.txt', 'source-test'); $zip->close();
if ($zip->open($file) !== true || $zip->getFromName('test.txt') !== 'source-test') throw new Exception('Zip read');
$zip->close(); unlink($file);
$db = new PDO('sqlite::memory:');
if ($db->query('SELECT 42')->fetchColumn() != 42) throw new Exception('SQLite');
echo json_encode(['version'=>PHP_VERSION,'binary'=>PHP_BINARY,'extensions'=>$required,'dependency_checks'=>true]);
'''
php = json.loads(subprocess.check_output(["php", "-r", php_test], text=True))
assert os.environ["PHP_OUTPUT"] == php["version"], os.environ["PHP_OUTPUT"]
linked = subprocess.check_output(["otool", "-L", php["binary"]], text=True)
for lib in ("libargon2", "libsodium", "libzip", "libonig", "libpcre2"):
    assert lib in linked, (lib, linked)
binary = subprocess.check_output(["file", php["binary"]], text=True).strip()
assert "Mach-O 64-bit executable arm64" in binary
for attempt in (1, 2):
    artifact = state / f"php-attempt-{attempt}.bin"
    assert "Mach-O 64-bit executable arm64" in subprocess.check_output(["file", str(artifact)], text=True)
composer = subprocess.check_output(["composer", "--version"], text=True)
php_prefix = Path(php["binary"]).parent.parent
sapis = {}
for command in ([str(php_prefix / "bin/php-cgi"), "-v"],
                [str(php_prefix / "bin/phpdbg"), "-V"],
                [str(php_prefix / "sbin/php-fpm"), "-t"]):
    sapis[Path(command[0]).name] = subprocess.check_output(command, text=True, stderr=subprocess.STDOUT)
result = {"candidate": os.environ["CANDIDATE_SHA"], "runner": os.environ["RUNNER_LABEL"],
          "architecture": platform.machine(), "php": php, "binary": binary, "linked_libraries": linked,
          "composer": composer, "sapis": sapis, "source_formulas": list(receipts), "php_source_attempts": 2,
          "timeout_exit_status": 124, "timeout_seconds": 1800, "stall_seconds": stall_duration,
          "cleaned_pids": sorted(recorded_pids), "surviving_pids": [], "outcome": "success"}
(evidence / "result.json").write_text(json.dumps(result, indent=2))
print(json.dumps(result, indent=2))
with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as summary:
    summary.write(f"All six formulas installed from source. PHP's first compiled build hit the 1800-second watchdog after {stall_duration} seconds. Cleanup completed before the successful second source build.\n")
