import argparse,json,pathlib,subprocess,tempfile
p=argparse.ArgumentParser();p.add_argument('--brotli',required=True);p.add_argument('--corpus',required=True);p.add_argument('--report',required=True);a=p.parse_args()
root=pathlib.Path(a.corpus);results=[]
for f in sorted(root.glob('*.compressed*')):
    raw=root/f.name.split('.compressed')[0]
    if not raw.is_file():raise RuntimeError('Missing expected corpus output')
    r=subprocess.run([a.brotli,'-d','-c',str(f)],capture_output=True,timeout=60)
    results.append({'case':f.name,'ok':r.returncode==0 and r.stdout==raw.read_bytes(),'exit':r.returncode})
with tempfile.TemporaryDirectory() as temp:
    for f in sorted(root.iterdir()):
        if '.compressed' in f.name or not f.is_file():continue
        for quality in [0,4,11]:
            r=subprocess.run([a.brotli,'-q',str(quality),'-c',str(f)],capture_output=True,timeout=90)
            compressed=pathlib.Path(temp)/'payload.br';compressed.write_bytes(r.stdout)
            decoded=subprocess.run([a.brotli,'-d','-c',str(compressed)],capture_output=True,timeout=60)
            results.append({'case':f'{f.name}:q{quality}','ok':r.returncode==0 and decoded.returncode==0 and decoded.stdout==f.read_bytes()})
pathlib.Path(a.report).write_text(json.dumps(results,indent=2))
print(len(results),'corpus/roundtrip cases',sum(not r['ok'] for r in results),'failures')
if not results or not all(r['ok'] for r in results):raise SystemExit(1)
