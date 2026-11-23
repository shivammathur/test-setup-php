import errno
import fcntl
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time


def instrument(source):
    """Add a scheduling point and an errno observer; leave the lock and cleanup intact."""
    path = source / "ext/opcache/zend_file_cache.c"
    text = path.read_text()
    anchor = "\tif (zend_file_cache_flock(fd, LOCK_EX) != 0) {\n"
    assert text.count(anchor) == 1
    hook = (
        '\tif (getenv("TEST_PAUSE_CACHE_WRITER")) { raise(SIGSTOP); }\n'
        + anchor
        + '\t\tint saved_errno = errno;\n'
        + '\t\tfprintf(stderr, "OPcache test LOCK_EX errno=%d\\n", saved_errno);\n'
        + '\t\terrno = saved_errno;\n'
    )
    path.write_text(text.replace('#include <fcntl.h>', '#include <fcntl.h>\n#include <signal.h>').replace(anchor, hook))


def wait_for_stop(child):
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        pid, status = os.waitpid(child.pid, os.WUNTRACED | os.WNOHANG)
        if pid:
            if os.WIFSTOPPED(status) and os.WSTOPSIG(status) == signal.SIGSTOP:
                return
            raise RuntimeError("PHP exited before opening the cache: " + repr(child.communicate()))
        time.sleep(0.015)
    raise TimeoutError("PHP did not stop after creating the cache file")


def get_entry(cache):
    entries = list(cache.rglob("*.bin"))
    assert len(entries) == 1, entries
    return entries[0]


def run_case(revision, build, evidence):
    with tempfile.TemporaryDirectory(dir=str(build)) as tmp:
        work = Path(tmp)
        cache = work / "cache"
        cache.mkdir()
        src = work / "app.php"
        src.write_text('<?php echo "app ran\\n";')
        php = [str(build / "sapi/cli/php"), "-n", "-d", "opcache.enable_cli=1",
               "-d", "opcache.file_cache_only=1", "-d", "opcache.file_cache=" + str(cache),
               "-d", "opcache.file_update_protection=0", "-d", "opcache.log_verbosity_level=2",
               "-r", 'if (!pcntl_signal(SIGUSR1, static function () {}, false)) exit(1); require $argv[1];',
               str(src)]
        rows = []

        def record(label, out, err):
            assert out == b"app ran\n", (out, err)
            entry = get_entry(cache)
            data = entry.read_bytes()
            shutil.copyfile(entry, evidence / (label + ".bin"))
            rows.append(dict(phase=label, bytes=len(data), header=data[:8].hex(),
                             stdout=out.decode().strip(), stderr=err.decode().strip()))
            (evidence / "observations.json").write_text(json.dumps(rows, indent=2) + "\n")
            print(json.dumps(rows[-1]), flush=True)
            return data

        normal = subprocess.run(php, capture_output=True, check=True, timeout=15)
        assert record("normal", normal.stdout, normal.stderr).startswith(b"OPCACHE\0")
        get_entry(cache).unlink()

        child = subprocess.Popen(php, env=dict(os.environ, TEST_PAUSE_CACHE_WRITER="1"),
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            wait_for_stop(child)
            entry = get_entry(cache)
            assert entry.stat().st_size == 0
            with entry.open("rb") as reader:
                fcntl.lockf(reader, fcntl.LOCK_SH | fcntl.LOCK_NB)
                os.kill(child.pid, signal.SIGCONT)
                # Keep the read lock until PHP exits. If PHP is still waiting, a
                # non-restarting signal lets the kernel interrupt F_SETLKW.
                for attempt in range(20):
                    try:
                        child.wait(timeout=0.25)
                        break
                    except subprocess.TimeoutExpired:
                        os.kill(child.pid, signal.SIGUSR1)
                out, err = child.communicate(timeout=10)
        finally:
            if child.poll() is None:
                child.kill()
                child.wait()
        assert child.returncode == 0, (child.returncode, out, err)
        interrupted = record("contended", out, err)
        if revision == "pr":
            assert ("OPcache test LOCK_EX errno=%d" % errno.EINTR).encode() in err, err
            assert interrupted == b""
        else:
            assert err == b"" and interrupted.startswith(b"OPCACHE\0"), err

        retry = subprocess.run(php, capture_output=True, check=True, timeout=15)
        assert record("retry", retry.stdout, retry.stderr).startswith(b"OPCACHE\0")
        warned = b"opcache cannot read from file" in retry.stderr and b"(info)" in retry.stderr
        assert warned == (revision == "pr"), retry.stderr


if __name__ == "__main__":
    if sys.argv[1] == "instrument":
        instrument(Path(sys.argv[2]))
    else:
        run_case(sys.argv[1], Path(sys.argv[2]), Path(sys.argv[3]))
