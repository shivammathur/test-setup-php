"""Remove preinstalled PHP only on these disposable GitHub-hosted test runners."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

assert os.environ.get('GITHUB_ACTIONS') == 'true'
root = Path('results')
root.mkdir(exist_ok=True)
installed = subprocess.check_output(['brew', 'list', '--formula', '-1'], text=True).splitlines()
php = [name for name in installed if re.fullmatch(r'php(?:@\d+\.\d+)?(?:-debug)?(?:-zts)?', name)]
(root / 'preinstalled-php.json').write_text(json.dumps(php, indent=2) + '\n')
if php:
    subprocess.run(['brew', 'uninstall', '--force', '--ignore-dependencies', *php], check=True)
row = next(r for r in json.loads(Path('expected.json').read_text())['releases'] if r['formula'] == os.environ['FORMULA'])
suffix = '' if row['variant'] == 'normal' else '-' + row['variant']
prefix = Path(subprocess.check_output(['brew', '--prefix'], text=True).strip())
config = prefix / 'etc/php' / (row['series'] + suffix)
if config.exists():
    shutil.move(str(config), str(root / 'preinstalled-configuration'))
assert not config.exists()
