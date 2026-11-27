import csv
import hashlib
import os
import subprocess
import sys
from pathlib import Path

phase = sys.argv[1]
temp = Path(os.environ["RUNNER_TEMP"])
rows = list(csv.reader((temp / f"{phase}.tsv").read_text().splitlines(), delimiter="\t"))
sury = "https://packages.sury.org/php/"
mirror = "https://ppa.setup-php.com/sury/"
for url, rc, http, seconds in rows:
    print(f"{url} curl={rc} HTTP={http} elapsed={seconds}s", flush=True)
arch = subprocess.check_output(["dpkg", "--print-architecture"], text=True).strip()
if phase == "unavailable":
    path = f"dists/{os.environ['SUITE']}/main/binary-{arch}/Packages.gz"
    assert [r[0] for r in rows] == [sury + path, mirror + path]
    assert all(r[1:3] == ["28", "000"] and float(r[3]) >= 4.9 for r in rows)
    sys.exit(0)
if phase == "index":
    path = f"dists/{os.environ['SUITE']}/main/binary-{arch}/Packages.gz"
    expected = [sury + path, mirror + path]
    assert [r[0] for r in rows[:2]] == expected
    assert all(row[0].startswith(mirror) and row[1:3] == ["0", "200"] for row in rows[2:])
else:
    packages = Path("/tmp/Packages").read_text().split("\n\n")
    expected = []
    for name in ("php8.2-protobuf", "php8.2-grpc"):
        section = next(s for s in packages if s.startswith("Package: " + name + "\n"))
        fields = dict(line.split(": ", 1) for line in section.splitlines() if line and not line[0].isspace() and ": " in line)
        path = fields["Filename"]
        if not expected:
            expected.append(sury + path)
        expected.append(mirror + path)
        deb = temp / f"{name}.deb"
        assert hashlib.sha256(deb.read_bytes()).hexdigest() == fields["SHA256"]
        assert subprocess.check_output(["dpkg-deb", "-f", deb, "Package"], text=True).strip() == name
        assert subprocess.check_output(["dpkg-deb", "-f", deb, "Architecture"], text=True).strip() == arch
    assert [r[0] for r in rows] == expected
    assert rows[2][1:3] == ["0", "200"]
assert rows[0][1:3] == ["28", "000"]
assert float(rows[0][3]) >= 4.9
assert rows[1][1:3] == ["0", "200"]
