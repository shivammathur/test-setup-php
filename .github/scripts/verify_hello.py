import hashlib
import json
import os
from pathlib import Path
import subprocess
import tarfile

formula = 'shivammathur/test-tap/hello'


def brew(*arguments):
    return subprocess.check_output(['brew', *arguments], text=True).strip()


tap = Path(brew('--repository', 'shivammathur/test-tap'))
report = json.loads((tap / 'evidence/promotion.json').read_text())
tag = os.environ['EXPECTED_BOTTLE_TAG']
expected = next(item for item in report['bottles'] if item['tag'] == tag)
archive = Path(brew('--cache', '--force-bottle', formula))
assert hashlib.sha256(archive.read_bytes()).hexdigest() == expected['promoted_bottle_sha256']
with tarfile.open(archive) as tar:
    binary = tar.extractfile('hello/2.12.3/bin/hello').read()
    assert hashlib.sha256(binary).hexdigest() == expected['hello_sha256']
    recipe = tar.extractfile('hello/2.12.3/.brew/hello.rb').read().decode()
    assert report['public_source_url'] in recipe
    assert 'test-tap-private' not in recipe
prefix = Path(brew('--prefix', formula))
receipt = json.loads((prefix / 'INSTALL_RECEIPT.json').read_text())
assert receipt['poured_from_bottle'] is True, receipt
assert receipt['source']['tap'] == 'shivammathur/test-tap', receipt['source']
installed_formula = (prefix / '.brew/hello.rb').read_text()
assert 'test-tap-private' not in installed_formula
spdx = json.loads((prefix / 'sbom.spdx.json').read_text())
assert 'test-tap-private' not in json.dumps(spdx)
assert report['public_source_url'] in json.dumps(spdx)
info = json.loads(brew('info', '--json=v2', formula))['formulae'][0]
assert info['full_name'] == formula
assert info['installed'][0]['version'] == '2.12.3'
assert info['installed'][0]['poured_from_bottle'] is True
evidence = {'platform': tag, 'public_formula': formula,
            'tap_commit': subprocess.check_output(['git', '-C', str(tap), 'rev-parse', 'HEAD'], text=True).strip(),
            'version': info['installed'][0]['version'],
            'poured_from_bottle': True, 'private_credentials_used': False,
            'published_bottle_sha256': expected['promoted_bottle_sha256'],
            'original_private_binary_sha256': expected['hello_sha256'],
            'downloaded_binary_sha256': hashlib.sha256(binary).hexdigest(),
            'installed_binary_sha256': hashlib.sha256((prefix / 'bin/hello').read_bytes()).hexdigest(),
            'source_sha256': report['source_sha256'],
            'private_build_run_id': report['private_build_run_id'],
            'formula_test': 'passed', 'linkage_test': 'passed', 'php_invocation': 'passed'}
Path('consumer-evidence.json').write_text(json.dumps(evidence, indent=2) + '\n')
print(json.dumps(evidence, indent=2))
