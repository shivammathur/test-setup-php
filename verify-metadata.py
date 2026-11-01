import os
from pathlib import Path
import xml.etree.ElementTree as ET

namespace = {"p": "http://pear.php.net/dtd/rest.allreleases"}
root = ET.parse("evidence/allreleases.xml").getroot()
releases = root.findall("p:r", namespace)
latest = releases[0]
version = latest.findtext("p:v", namespaces=namespace)
state = latest.findtext("p:s", namespaces=namespace)
assert version == os.environ["EXPECTED_VERSION"], (version, os.environ["EXPECTED_VERSION"])
assert state == os.environ["EXPECTED_STATE"], (state, os.environ["EXPECTED_STATE"])
stable = next((release.findtext("p:v", namespaces=namespace) for release in releases
               if release.findtext("p:s", namespaces=namespace) == "stable"), None)
print(f'{os.environ["EXTENSION"]}: latest={version}, state={state}, latest stable={stable}')
Path("evidence/expected-version.txt").write_text(version + "\n")
