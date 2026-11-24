"""Record Homebrew's active operation and watchdog diagnostics without changing its PATH or output."""
import os
from pathlib import Path
import re
import subprocess
import time

start = time.monotonic()
seen = set()
positions = {}
temporary = Path(os.environ["TMPDIR"])
def report(line):
    print(f"+{time.monotonic()-start:.1f}s {line}", flush=True)

while True:
    processes = subprocess.check_output(["ps", "-axo", "pid=,command="], text=True)
    for line in processes.splitlines():
        match = re.search(r"^\s*(\d+)\s+.*?(?:/brew\.rb|/bin/brew|/bin/git)\s+(install|upgrade|link|unlink|trust|tap|fetch|clone)(?:\s+([^\n]*))?$", line)
        if not match or match[1] in seen:
            continue
        seen.add(match[1])
        # Only print package names and options, never origins or credentials.
        args = [v for v in (match[3] or "").split() if re.fullmatch(r"(?:-{1,2}[a-z-]+|(?:shivammathur/php/)?[a-z][a-z0-9@.+-]*)", v)]
        report(" ".join([match[2], *args]))
    for stream in temporary.glob("setup-php-brew.*/*.log"):
        try:
            with stream.open(errors="replace") as f:
                f.seek(positions.get(stream, 0))
                for line in f:
                    line = re.sub(r"\x1b\[[0-9;]*m", "", line.strip())
                    if line.startswith(("Error:", "Warning:", "==>")) and "://" not in line:
                        report(line[:240])
                positions[stream] = f.tell()
        except FileNotFoundError:
            continue
    time.sleep(2)
