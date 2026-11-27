import csv
import os
import subprocess
import sys
from pathlib import Path

mode = sys.argv[1]
rows = list(csv.reader((Path(os.environ["RUNNER_TEMP"]) / f"{mode}.tsv").read_text().splitlines(), delimiter="\t"))
arch = subprocess.check_output(["dpkg", "--print-architecture"], text=True).strip()
path = f"dists/{os.environ['SUITE']}/main/binary-{arch}/Packages.gz"
primary = "https://packages.sury.org/php/"
mirror = "https://ppa.setup-php.com/sury/"
for url, code, http, seconds in rows:
    print(f"{url} curl={code} http={http} seconds={seconds}", flush=True)

if mode == "live":
    assert rows[0][:3] == [primary + path, "0", "200"]
elif mode == "unavailable":
    assert [r[0] for r in rows] == [primary + path, mirror + path]
    assert all(r[1:3] == ["28", "000"] and float(r[3]) >= 4.9 for r in rows)
    assert not Path("/tmp/Packages").exists() and not Path("/tmp/Packages.gz").exists()
else:
    assert rows[0][:3] == [primary + path, "28", "000"] and float(rows[0][3]) >= 4.9
    assert rows[1][:3] == [mirror + path, "0", "200"]
    assert all(r[0].startswith(mirror) and r[1:3] == ["0", "200"] for r in rows[2:])
    assert Path("/tmp/Packages").stat().st_size > 0
