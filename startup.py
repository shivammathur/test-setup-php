import json
import os
from pathlib import Path
import subprocess
import time

php = '/opt/local/bin/php55'
ext = subprocess.check_output(['/opt/local/bin/php-config55', '--extension-dir'], text=True).strip()
cases = [('default', []), ('no-ini', ['-n'])]
for extension in ('curl', 'openssl', 'intl', 'gd', 'imap', 'memcached', 'mongodb', 'xsl', 'amqp', 'opcache'):
    directive = 'zend_extension' if extension == 'opcache' else 'extension'
    cases.append((extension, ['-n', '-d', '%s=%s/%s.so' % (directive, ext, extension)]))
results = []
for name, options in cases:
    for trial in range(3):
        start = time.perf_counter()
        completed = subprocess.run([php] + options + ['-r', 'echo PHP_VERSION;'], capture_output=True, text=True)
        result = dict(case=name, trial=trial + 1, seconds=round(time.perf_counter() - start, 3),
                      exit_code=completed.returncode, stderr=completed.stderr)
        assert completed.returncode == 0 and completed.stdout == '5.5.38', result
        results.append(result)
        print(json.dumps(result), flush=True)
(Path(os.environ['RUNNER_TEMP']) / 'startup.json').write_text(json.dumps(results, indent=2))
subprocess.run([php, '-v'], env=dict(os.environ, DYLD_PRINT_STATISTICS='1'), check=True)
