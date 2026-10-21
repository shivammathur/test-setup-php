import json
import os
from pathlib import Path

rows = json.loads(Path('expected.json').read_text())['releases']
assert len(rows) == 48 and len({r['formula'] for r in rows}) == 48
mac = [{'runner': 'macos-15', 'tag': 'arm64_sequoia'}, {'runner': 'macos-26', 'tag': 'arm64_tahoe'},
       {'runner': 'xcode-27', 'tag': 'arm64_golden_gate'}]
linux = [{'runner': 'ubuntu-24.04', 'tag': 'x86_64_linux'}, {'runner': 'ubuntu-24.04-arm', 'tag': 'arm64_linux'}]
with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
    for key, platforms in [('macos', mac), ('linux', linux)]:
        cases = [{'formula': r['formula'], 'series': r['series'], 'debug': r['debug'], 'phpts': r['phpts'], **p}
                 for r in rows for p in platforms]
        output.write(key + '=' + json.dumps({'include': cases}, separators=(',', ':')) + '\n')
