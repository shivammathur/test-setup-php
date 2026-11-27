import gzip
import hashlib
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

ROOTS = {
    "sury": "https://packages.sury.org/php",
    "mirror": "https://ppa.setup-php.com/sury",
}
INDEX = "dists/resolute/main/binary-amd64/Packages.gz"
lane = int(sys.argv[1])
out = Path("measurements")
out.mkdir(exist_ok=True)
records = []
snapshots = {}
issues = []


def fetch(site, path, dest, kind, sample=None):
    fmt = "%{http_code}\t%{time_appconnect}\t%{time_starttransfer}\t%{time_total}\t%{size_download}\t%{url_effective}"
    args = [
        "curl", "-H", "User-Agent: Debian APT-HTTP/GHA(ce)", "--connect-timeout", "5",
        "--max-time", "30", "-fsSL", "-o", str(dest), "-w", fmt,
        ROOTS[site] + "/" + path,
    ]
    proc = subprocess.run(args, capture_output=True, text=True)
    status, tls, first, total, size, final_url = proc.stdout.split("\t")
    row = dict(site=site, kind=kind, sample=sample, lane=lane, rc=proc.returncode,
               http=int(status), tls=float(tls), first_byte=float(first), total=float(total),
               size=int(size), effective_url=final_url)
    records.append(row)
    if proc.returncode or row["http"] != 200:
        print(f"{site} {kind} {sample}: {row} {proc.stderr.strip()}", flush=True)
        return None
    return row


def sha256(data):
    return hashlib.sha256(data).hexdigest()


for sample in range(1, 9):
    order = list(ROOTS)
    if (sample + lane) % 2:
        order.reverse()
    for site in order:
        dest = Path(f"{site}.gz")
        row = fetch(site, INDEX, dest, "index", sample)
        if row:
            data = dest.read_bytes()
            try:
                packages = gzip.decompress(data).decode()
            except (OSError, EOFError, UnicodeError) as error:
                issues.append(f"{site}: invalid Packages.gz: {error}")
                continue
            row["sha256"] = sha256(data)
            snapshots[site] = (row["sha256"], packages)
    if sample < 8:
        time.sleep(5)

for site, (digest, packages) in snapshots.items():
    dest = Path(f"{site}.inrelease")
    release = fetch(site, "dists/resolute/InRelease", dest, "release")
    if release:
        content = dest.read_text()
        hashes = content.split("\nSHA256:\n", 1)[1].split("\n\n", 1)[0]
        entry = re.search(r"^\s*([0-9a-f]{64})\s+\d+\s+main/binary-amd64/Packages\.gz$", hashes, re.M)
        release["date"] = re.search(r"^Date: (.+)$", content, re.M).group(1)
        if not entry or entry[1] != digest:
            issues.append(site + " index digest disagrees with InRelease")

    for package in ("php8.2-grpc", "php8.2-protobuf"):
        entries = (p for p in packages.split("\n\n") if p.startswith("Package: " + package + "\n"))
        entry = next(entries, None)
        if not entry:
            issues.append(f"{site} missing {package}")
            continue
        fields = dict(line.split(": ", 1) for line in entry.splitlines() if line and not line[0].isspace() and ": " in line)
        dest = Path(f"{site}-{package}.deb")
        row = fetch(site, fields["Filename"], dest, package)
        if row:
            row["sha256"] = sha256(dest.read_bytes())
            row["version"] = fields["Version"]
            deb_name = subprocess.check_output(["dpkg-deb", "-f", dest, "Package"], text=True).strip()
            if row["sha256"] != fields["SHA256"] or row["size"] != int(fields["Size"]) or deb_name != package:
                issues.append(f"{site} invalid {package} payload")

for site in ROOTS:
    for kind in ("index", "release", "php8.2-grpc", "php8.2-protobuf"):
        attempts = [r for r in records if r["site"] == site and r["kind"] == kind]
        successes = sum(r["rc"] == 0 and r["http"] == 200 for r in attempts)
        print(f"{site} {kind}: {successes}/{len(attempts)}")
        if successes != (8 if kind == "index" else 1):
            issues.append(f"{site} {kind} unavailable in at least one attempt")
(out / f"lane-{lane}.json").write_text(json.dumps(dict(records=records, issues=issues), indent=2))
if issues:
    sys.exit("\n".join(issues))
