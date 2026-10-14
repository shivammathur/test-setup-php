import csv
import json
import sys
from pathlib import Path


def rows(path):
    with open(path, newline='') as stream:
        return {(r['font'], r['size'], r['char']): r for r in csv.DictReader(stream)}


before, after = rows(sys.argv[1]), rows(sys.argv[2])
assert before.keys() == after.keys() and len(after) >= 4032
changes = []
for key in before:
    diff = {field: [before[key][field], after[key][field]]
            for field in before[key] if before[key][field] != after[key][field]}
    if diff:
        changes.append({'font_size_char': key, 'differences': diff})
report = {'glyphs': len(after), 'changed_glyphs': len(changes),
          'changed_advances': sum(any(f.startswith('advance') for f in c['differences']) for c in changes),
          'changed_bitmaps': sum('bitmap_hash' in c['differences'] for c in changes), 'changes': changes}
Path(sys.argv[3]).write_text(json.dumps(report, indent=2))
print(json.dumps({k: v for k, v in report.items() if k != 'changes'}))
