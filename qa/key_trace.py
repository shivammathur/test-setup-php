import sys
from pathlib import Path

PRIMARY = "https://packages.sury.org/php/apt.gpg"
MIRROR = "https://ppa.setup-php.com/keys/sury/php.gpg"
FINGERPRINT = "15058500A0235D97F5D10063B188E2B695BD4743"
SKS = [
    f"https://{host}/pks/lookup?op=get&options=mr&exact=on&search=0x{FINGERPRINT}"
    for host in ("keyserver.ubuntu.com", "pgp.mit.edu", "keys.openpgp.org")
]


def verify_trace(route, path):
    rows = [line.split("\t") for line in path.read_text().splitlines()]
    assert all(len(row) == 3 for row in rows), rows
    if route == "primary":
        expected = [PRIMARY]
    elif route == "fallback":
        expected = [PRIMARY, MIRROR]
    else:
        assert route == "sks" and 3 <= len(rows) <= 2 + len(SKS), rows
        expected = [PRIMARY, MIRROR, *SKS[:len(rows) - 2]]
    assert [row[0] for row in rows] == expected, (expected, rows)
    # Require an observed failure for each attempt preceding the single success.
    for url, rc, http in rows[:-1]:
        assert len(http) == 3 and http.isdigit(), (url, rc, http)
        assert int(rc) != 0 or http != "200", (url, rc, http)
    assert rows[-1][1:] == ["0", "200"], rows[-1]


if __name__ == "__main__":
    verify_trace(sys.argv[1], Path(sys.argv[2]))
