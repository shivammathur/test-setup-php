from itertools import product
from pathlib import Path
import os
from key_trace import verify_trace

releases = ["22.04", "24.04", "26.04"]
states = ["none", "launchpad", "launchpad-mirror", "sury", "sury-mirror"]
origins = {"primary": "https://packages.sury.org/php", "fallback": "https://ppa.setup-php.com/sury",
           "sks": "https://ppa.setup-php.com/sury"}
root = Path("evidence")
cases = {(release, state, route): root / f"evidence-{release}-{state}-{route}"
         for release, state, route in product(releases, states, origins)}
assert set(root.iterdir()) == set(cases.values())
summary = ["| Ubuntu | Verified cases | Extracted runtime |", "|---|---:|---|"]
for release in releases:
    reference = None
    for state, route in product(states, origins):
        directory = cases[release, state, route]
        assert (directory / "action-sha.txt").read_text().strip() == "fc54582bc7efab69133e1c97e04b6846884d385b"
        verify_trace(route, directory / "initial-requests.tsv")
        initial = (directory / "initial-requests.tsv").read_bytes()
        assert initial == (directory / "repeat-requests.tsv").read_bytes() == (directory / "requests.tsv").read_bytes()
        if route == "primary" and state in ("sury", "sury-mirror"):
            assert "/usr/share/keyrings/debsuryorg-archive-keyring.gpg" in (directory / "installed-key.txt").read_text()
            assert (directory / "starting-repositories.txt").read_bytes() == (directory / "warm-start-repositories.txt").read_bytes()
        assert (directory / "origin.txt").read_text().strip() == origins[route]
        assert (directory / "action-php.txt").read_bytes() == (directory / "repeat-php.txt").read_bytes()
        assert (directory / "initial-config.sha256").read_bytes() == (directory / "repeat-config.sha256").read_bytes()
        manifest = (directory / "packages.tsv").read_bytes()
        assert len(manifest.splitlines()) == 4
        if reference is None:
            reference = manifest
        assert manifest == reference, (release, state, route)
    runtime = (directory / "downloaded-runtime.txt").read_text().strip()
    summary.append(f"| {release} | 15/15 | {runtime} |")
summary.append("\nAll 45 key traces passed. SKS was reached only after both key URLs failed. "
               "The 6 preinstalled-key checks reused the existing keyring. "
               "All three routes supplied identical package SHA-256 hashes on each release.")
report = "\n".join(summary) + "\n"
print(report)
with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as out:
    out.write(report)
