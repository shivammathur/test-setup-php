import base64
import csv
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import os
from pathlib import Path
import subprocess
from threading import Thread

from archive import published_binary, sha256

def output(*args):
    return subprocess.check_output(args, text=True).strip()

series = os.environ["PHP_SERIES"]
arch = os.environ["EXPECTED_ARCH"]
build = os.environ["EXPECTED_BUILD"]
ts = os.environ["phpts"]
with open("published.tsv", newline="") as f:
    artifact, = (row for row in csv.DictReader(f, delimiter="\t")
                 if (row["series"], row["architecture"], row["build"], row["ts"]) == (series, arch, build, ts))

info = json.loads(output("php", "-r", 'echo json_encode(array(PHP_VERSION, (bool) PHP_DEBUG, (bool) PHP_ZTS, realpath(PHP_BINARY)));'))
version, debug, zts, binary = info
assert (version, debug, zts) == (artifact["version"], build == "debug", ts == "zts"), info
assert output("lipo", "-archs", binary) == arch, binary
assert output("php-config", "--version") == version
prefix = Path(output("brew", "--prefix"))
keg = Path(binary).parent.parent
assert (prefix / "opt" / artifact["formula"] / "bin/php").resolve() == Path(binary)
recipe = (keg / ".brew" / (artifact["formula"] + ".rb")).read_text()
assert ('url "https://github.com/shivammathur/php-src-backports/archive/' + artifact["source"] + '.tar.gz"') in recipe
stem = f"php_{series}-{ts}-{build}+darwin_{arch}"
success = f"Installed PHP {version} ({build}, {ts}, {arch}) from {stem}.tar.zst"
log = (Path(os.environ["RUNNER_TEMP"]) / "php-darwin-install.log").read_text()
assert success in log.splitlines(), (success, log[-2000:])
archive_name = f"{stem}.{artifact['sha256']}.tar.zst"
expected_binary = published_binary(series, archive_name, artifact["sha256"], str(Path(binary).relative_to(prefix)))
with open(binary, "rb") as binary_file:
    assert sha256(binary_file) == expected_binary, "Installed CLI differs from the published archive"
for program in ("php-cgi", "php-fpm"):
    assert version in output(str(keg / ("bin" if program == "php-cgi" else "sbin") / program), "-v").splitlines()[0]

class ImageRedirect(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/redirect":
            self.send_response(302)
            self.send_header("Location", "/pixel.gif")
            self.end_headers()
        elif self.path == "/pixel.gif":
            data = base64.b64decode("R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==")
            self.send_response(200)
            self.send_header("Content-Type", "image/gif")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        else:
            self.send_error(404)

with HTTPServer(("127.0.0.1", 0), ImageRedirect) as server:
    thread = Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        data = json.loads(output("php", "-r", "echo json_encode(getimagesize($argv[1]));",
                                 "http://127.0.0.1:%d/redirect" % server.server_port))
        assert (data["0"], data["1"], data["mime"]) == (1, 1, "image/gif"), data
    finally:
        server.shutdown()
        thread.join()

print(f"Verified PHP {version} {arch} {build}/{ts}, backports {artifact['source']}, archive SHA-256 {artifact['sha256']}")
