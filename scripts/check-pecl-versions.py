import concurrent.futures
import json
from pathlib import Path
import subprocess
import sys
import xml.etree.ElementTree as ET

script = str(Path(sys.argv[1]).resolve())
report = Path(sys.argv[2])
extensions = [
    "timezonedb", "redis", "xdebug", "pcov", "apcu", "igbinary", "msgpack",
    "mongodb", "yaml", "imagick", "swoole", "phalcon", "pecl_http", "event",
]
cases = [(extension, "") for extension in extensions] + [("phalcon", "4"), ("phalcon", "5")]
resolver = '''
. "$1"
get() {
  shift 3
  curl --fail --silent --show-error --location --retry 3 --max-time 60 "$1"
}
get_pecl_version "$2" stable "$3"
'''


def fetch(url):
    return subprocess.check_output([
        "curl", "--fail", "--silent", "--show-error", "--location",
        "--retry", "3", "--max-time", "60", url,
    ], text=True).strip()


def check(case):
    extension, major = case
    label = extension + (f" (major {major})" if major else "")
    try:
        actual = subprocess.check_output(
            ["bash", "-c", resolver, "resolver", script, extension, major], text=True
        ).strip()
        rest = f"https://pecl.php.net/rest/r/{extension}/"
        if major:
            root = ET.fromstring(fetch(rest + "allreleases.xml"))
            ns = {"p": "http://pear.php.net/dtd/rest.allreleases"}
            expected = next(
                release.findtext("p:v", namespaces=ns)
                for release in root.findall("p:r", ns)
                if release.findtext("p:s", namespaces=ns) == "stable"
                and release.findtext("p:v", namespaces=ns).split(".")[0] == major
            )
        else:
            expected = fetch(rest + "stable.txt")
        return {"case": label, "expected": expected, "actual": actual, "pass": actual == expected}
    except Exception as error:
        return {"case": label, "error": str(error), "pass": False}


with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
    results = list(pool.map(check, cases))
report.parent.mkdir(parents=True, exist_ok=True)
report.write_text(json.dumps(results, indent=2) + "\n")
for result in results:
    print(f"{'PASS' if result['pass'] else 'FAIL'} {result['case']}: "
          f"resolved={result.get('actual')} expected={result.get('expected')}"
          + (f" error={result['error']}" if "error" in result else ""))
sys.exit(0 if all(result["pass"] for result in results) else 1)
