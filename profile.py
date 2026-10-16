#!/usr/bin/env python3
import json
from pathlib import Path
import shutil
import subprocess
import sys
import time

root, archive = Path(sys.argv[1]), sys.argv[2]
results = []
for variant in ('original', 'candidate'):
    for method in ('staged', 'streamed'):
        for trial in range(1, 4):
            target = root / ('extract-%s-%s-%s' % (variant, method, trial))
            target.mkdir()
            source = root / variant / archive
            start = time.perf_counter()
            if method == 'staged':
                tar = target / 'archive.tar'
                subprocess.run(['zstd', '-dq', str(source), '-o', str(tar)], check=True)
                subprocess.run(['tar', 'xf', str(tar), '-C', str(target)], check=True)
            else:
                decompress = subprocess.Popen(['zstd', '-dcq', str(source)], stdout=subprocess.PIPE)
                extract = subprocess.run(['tar', 'xf', '-', '-C', str(target)], stdin=decompress.stdout)
                decompress.stdout.close()
                assert decompress.wait() == 0
                extract.check_returncode()
            result = dict(variant=variant, method=method, trial=trial,
                          seconds=round(time.perf_counter() - start, 3))
            results.append(result)
            print(json.dumps(result), flush=True)
            shutil.rmtree(target)
(root / 'report' / 'extraction.json').write_text(json.dumps(results, indent=2))
