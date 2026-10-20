import json,os,sys
from pathlib import Path
jobs=json.loads(Path('manifest.json').read_text())['jobs']
def canary(j):
 return (j['minor']=='5.6' and j['repo']!='php-builder-windows') or (j['repo']=='php-builder-windows' and j['minor'] in ('7.2','8.5'))
mode=sys.argv[1]
selected=[j for j in jobs if mode=='all' or (mode=='canary' and canary(j)) or (mode=='remaining' and not canary(j))]
if mode.startswith('['):
 ids=json.loads(mode);assert len(ids)==len(set(ids));assert set(ids)<=set(j['id'] for j in jobs)
 selected=[j for j in jobs if j['id'] in ids]
assert selected and len(selected)<=256
matrix={'include':[{'id':j['id'],'runner':j['runner']} for j in selected]}
with open(os.environ['GITHUB_OUTPUT'],'a') as f:f.write('matrix='+json.dumps(matrix,separators=(',',':'))+'\n')
print('Selected',len(selected),'jobs;',sum(len(j['cases']) for j in selected),'installations')
