import os
from pathlib import Path
import xml.etree.ElementTree as ET

namespace = {"p": "http://pear.php.net/dtd/rest.allreleases"}
root = ET.parse("evidence/allreleases.xml").getroot()
releases = root.findall("p:r", namespace)
latest = next(release for release in releases if release.findtext("p:v", namespaces=namespace) == os.environ["EXPECTED_VERSION"])
version = latest.findtext("p:v", namespaces=namespace)
state = latest.findtext("p:s", namespaces=namespace)
assert version == os.environ["EXPECTED_VERSION"], (version, os.environ["EXPECTED_VERSION"])
expected_state = os.environ.get("EXPECTED_RELEASE_STATE", os.environ["EXPECTED_STATE"])
assert state == expected_state, (state, expected_state)
stable = next((release.findtext("p:v", namespaces=namespace) for release in releases
               if release.findtext("p:s", namespaces=namespace) == "stable"), None)
print(f'{os.environ["EXTENSION"]}: selected={version}, state={state}, latest stable={stable}')
Path("evidence/expected-version.txt").write_text(version + "\n")
