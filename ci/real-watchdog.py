"""Exercise real Homebrew source workers in disposable prefixes on ARM."""
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import signal
import subprocess
import tarfile
import tempfile
import time

assert platform.machine() == "arm64"
workspace = Path(os.environ["GITHUB_WORKSPACE"])
helper = workspace / "candidate/src/scripts/tools/brew.sh"
homebrew = Path(subprocess.check_output(["brew", "--repository"], text=True).strip())
evidence = workspace / "evidence"


def check(mode):
    root = Path(tempfile.mkdtemp(prefix="spbrew-", dir="/private/tmp"))
    prefix = root / "brew"
    (prefix / "bin").mkdir(parents=True)
    (prefix / "Library").mkdir()
    (prefix / "Library/Homebrew").symlink_to(homebrew / "Library/Homebrew", target_is_directory=True)
    shutil.copy2(homebrew / "bin/brew", prefix / "bin/brew")
    subprocess.run(["git", "init", "--quiet", str(prefix)], check=True)
    source = root / "source"
    source.mkdir()
    body = "sleep(15); return 0;" if mode == "success" else "for (;;) pause();"
    (source / "source.c").write_text('''#include <signal.h>
#include <stdio.h>
#include <unistd.h>
int main(int argc, char **argv) {
  signal(SIGTERM, SIG_IGN);
  FILE *pid = fopen(argv[1], "w");
  if (!pid) return 1;
  fprintf(pid, "%d\\n", getpid());
  fclose(pid);
  BODY
}
'''.replace("BODY", body))
    archive = root / "source-1.0.tar.gz"
    with tarfile.open(archive, "w:gz") as tar:
        tar.add(source, arcname="source-1.0")
    tap = prefix / "Library/Taps/setup-php/homebrew-watchdog"
    (tap / "Formula").mkdir(parents=True)
    subprocess.run(["git", "init", "--quiet", str(tap)], check=True)
    formula = '''class SetupPhpWatchdog < Formula
  desc "Source-build watchdog validation fixture"
  homepage "https://github.com/shivammathur/setup-php"
  url "ARCHIVE_URL"
  version "1.0"
  sha256 "ARCHIVE_SHA"
  license "MIT"
  def install
    system ENV.cc, "source.c", "-o", "source"
    cp "source", logs/"source"
    system "./source", "#{logs}/worker.pid"
    bin.install "source"
  end
end
'''.replace("ARCHIVE_URL", archive.as_uri()).replace("ARCHIVE_SHA", hashlib.sha256(archive.read_bytes()).hexdigest())
    (tap / "Formula/setup-php-watchdog.rb").write_text(formula)
    (root / "tmp").mkdir()
    (root / "config").mkdir()
    env = {**os.environ,
           "PATH": str(prefix / "bin") + ":" + os.environ["PATH"],
           "HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ANALYTICS": "1",
           "HOMEBREW_NO_INSTALL_FROM_API": "1", "HOMEBREW_NO_INSTALL_CLEANUP": "1",
           "HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK": "1", "HOMEBREW_NO_BOOTSNAP": "1",
           "HOMEBREW_NO_ENV_HINTS": "1", "HOMEBREW_CACHE": str(root / "cache"),
           "HOMEBREW_LOGS": str(root / "logs"), "HOMEBREW_TEMP": str(root / "tmp"),
           "XDG_CONFIG_HOME": str(root / "config"), "TEST_BREW_HELPER": str(helper),
           "SETUP_PHP_BREW_INACTIVITY_TIMEOUT": "10", "SETUP_PHP_BREW_WATCHDOG_POLL": "1",
           "SETUP_PHP_BREW_SOURCE_INACTIVITY_TIMEOUT": "30",
           "SETUP_PHP_BREW_RETRY_ATTEMPTS": "1" if mode == "success" else "2",
           "SETUP_PHP_BREW_WATCHDOG": "true"}
    for flag, expected in [("--prefix", prefix), ("--cellar", prefix / "Cellar")]:
        actual = subprocess.check_output(["brew", flag], env=env, text=True).strip()
        assert actual == str(expected), actual
    log_path = evidence / ("real-source-" + mode + ".log")
    script = '. "$TEST_BREW_HELPER"\nsafe_brew install --ignore-dependencies setup-php/watchdog/setup-php-watchdog\n'
    worker_pids = set()
    start = time.monotonic()
    with log_path.open("w") as log:
        process = subprocess.Popen(["/bin/bash", "-c", script], env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        while process.poll() is None and time.monotonic() - start < 180:
            pid_file = root / "logs/setup-php-watchdog/worker.pid"
            if pid_file.exists() and pid_file.read_text().strip():
                worker_pids.add(int(pid_file.read_text().strip()))
            time.sleep(0.25)
    if process.poll() is None:
        for pid in worker_pids:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        os.killpg(process.pid, signal.SIGKILL)
        raise RuntimeError("Homebrew fixture exceeded its outer deadline")
    alive = []
    for pid in worker_pids:
        state = subprocess.run(["ps", "-p", str(pid), "-o", "stat="], capture_output=True, text=True)
        if state.returncode == 0 and not state.stdout.strip().startswith("Z"):
            alive.append(pid)
    artifact = root / "logs/setup-php-watchdog/source"
    result = {"mode": mode, "exit_status": process.returncode, "seconds": round(time.monotonic() - start, 1),
              "worker_pids": sorted(worker_pids), "surviving_workers": alive,
              "installed": (prefix / "bin/source").exists(),
              "artifact": subprocess.run(["file", str(artifact)], capture_output=True, text=True).stdout.strip()}
    log = log_path.read_text()
    (evidence / ("real-source-" + mode + ".json")).write_text(json.dumps(result, indent=2))
    if artifact.exists():
        shutil.copy2(artifact, evidence / ("real-source-" + mode + ".bin"))
    print(json.dumps(result), flush=True)
    assert not alive and "Mach-O 64-bit executable arm64" in result["artifact"], result
    if mode == "success":
        assert process.returncode == 0 and result["installed"] and len(worker_pids) == 1, result
        assert "terminating" not in log, log
    else:
        assert process.returncode == 124 and not result["installed"] and len(worker_pids) == 2, result
        assert log.count("no output for 30s; terminating") == 2, log
        assert log.count("retrying brew command") == 1, log
    shutil.rmtree(root)
    return result


with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
    results = list(pool.map(check, ["success", "timeout"]))
(evidence / "real-source-results.json").write_text(json.dumps(results, indent=2))
