import json
import os
from pathlib import Path

reports = Path('diagnostics')
dependencies = json.loads((reports / 'dependencies/state.json').read_text())
restored = json.loads((reports / 'restored/state.json').read_text())
final = json.loads((reports / 'final/state.json').read_text())
startup = (reports / 'final/php-startup.txt').read_text()
legacy = os.environ['CACHE_VERSION'] == '1.14.1'
warm = int(os.environ['GITHUB_RUN_ATTEMPT']) > 1
assert (os.environ['CACHE_HIT'] == 'true') == warm, 'Unexpected extension cache hit/miss'
assert restored['extension_exists'] == warm, 'Unexpected cached extension state'
assert dependencies['library_exists'] == (not legacy), 'Unexpected Firebird dependency state'
assert final['library_exists'], 'Library still missing after Setup PHP'
assert 'pdo_firebird=loaded' in startup, 'Extension did not load after Setup PHP'
expected_directives = 3 if legacy and warm else 1
assert len(final['directives']) == expected_directives, final['directives']
assert ('already loaded' in startup) == (legacy and warm), startup
assert 'Unable to load' not in startup, startup
if legacy:
    archive = reports / 'dependencies/firebird-client@3.contents.txt'
    assert archive.exists() and not archive.read_text().strip(), 'Expected empty cached Firebird archive'
summary = {
    'cache_version': os.environ['CACHE_VERSION'],
    'cache_state': 'warm' if warm else 'cold',
    'dependency_usable_before_setup': dependencies['library_exists'],
    'final_ini_directives': len(final['directives']),
    'duplicate_startup_warning': 'already loaded' in startup,
}
print(json.dumps(summary, indent=2))
(reports / 'result.json').write_text(json.dumps(summary, indent=2))
with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as stream:
    stream.write('```json\n' + json.dumps(summary, indent=2) + '\n```\n')
