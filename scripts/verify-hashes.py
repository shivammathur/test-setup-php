import argparse,hashlib,json,pathlib
p=argparse.ArgumentParser();p.add_argument('--manifest',required=True);p.add_argument('--artifact',required=True);p.add_argument('--directory',required=True);p.add_argument('--report',required=True);a=p.parse_args()
expected=json.loads(pathlib.Path(a.manifest).read_text())[a.artifact]
root=pathlib.Path(a.directory);actual={str(p.relative_to(root)).replace('\\','/'):hashlib.sha256(p.read_bytes()).hexdigest() for p in root.rglob('*') if p.is_file()}
errors=[n for n,h in expected.items() if actual.get(n)!=h]+[n for n in actual if n not in expected]
pathlib.Path(a.report).write_text(json.dumps({'artifact':a.artifact,'files':actual,'errors':errors},indent=2))
if errors:raise SystemExit('Artifact content mismatch: '+str(errors))
print(a.artifact,len(actual),'file hashes match')
