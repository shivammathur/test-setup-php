import os
import pathlib
import subprocess

root = pathlib.Path(__file__).resolve().parent.parent
source = root / 'php-src'
evidence = root / 'evidence'
evidence.mkdir(exist_ok=True)
variant = os.environ['VARIANT']
patch = root / 'patches' / (variant + '.patch')
if patch.exists():
    subprocess.run(['git', 'apply', '--check', '--reverse', str(patch)], cwd=source, check=True)
    subprocess.run(['git', 'apply', '--reverse', str(patch)], cwd=source, check=True)
elif variant not in ('before', 'after', 'after-merge'):
    raise RuntimeError('Missing patch for ' + variant)
(evidence / 'source-ref.txt').write_text(subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=source, text=True))
(evidence / 'source.patch').write_bytes(subprocess.check_output(['git', 'diff', '--binary'], cwd=source))
print('Prepared', variant)
