import json
import struct
import sys
from pathlib import Path

root = Path(sys.argv[1])
artifacts = sorted(p for p in root.glob('pr37-*') if p.is_dir())
assert len(artifacts) == 4, f'Expected four native jobs, got {len(artifacts)}'
reference = {}
results = []
for artifact in artifacts:
    def read(name):
        return json.loads((artifact / name).read_text(encoding='utf-8-sig'))
    vs = read('vs-results.json')
    sbom = read('sbom-results.json')
    existing = read('existing-results.json')
    ps_major = int(vs['powershell'].split('.')[0])
    assert ps_major == (5 if artifact.name.endswith('-powershell') else 7)
    assert len(vs['fixtures']) == 14
    assert len(vs['native']) == 2
    assert len(vs['baselineFailures']) == (2 if ps_major == 5 else 0)
    assert len(sbom['baselineFailures']) == (3 if ps_major == 5 else 0)
    assert all(r['passed'] == 23 and r['failed'] == 2 for r in existing)
    for version in ['8.2', '8.7', 'master']:
        head = read(f'head-{version}.json')
        base = read(f'base-{version}.json')
        assert head == base, (artifact.name, version, 'base differs')
        assert head == reference.setdefault(version, head), (artifact.name, version, 'shell/runner differs')
        assert len(head['components']) == 23
    for arch, machine in [('x86', 0x14c), ('x64', 0x8664)]:
        exe = artifact / f'helpers-{arch}/ext/standard/tests/helpers/bad_cmd.exe'
        data = exe.read_bytes()
        offset = struct.unpack_from('<I', data, 0x3c)[0]
        assert data[:2] == b'MZ' and data[offset:offset+4] == b'PE\0\0'
        assert struct.unpack_from('<H', data, offset+4)[0] == machine
    results.append({'job': artifact.name, 'powershell': vs['powershell'], 'assertions': vs['checks'], 'toolsets': vs['native'], 'sbom': 'identical across base, head, shells, runners', 'helpers': ['x86', 'x64'], 'baselineRegressionsReproduced': len(vs['baselineFailures']) + len(sbom['baselineFailures'])})
report = {'result': 'pass', 'jobs': results}
(root / 'comparison.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2))
