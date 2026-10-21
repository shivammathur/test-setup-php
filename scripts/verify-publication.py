import concurrent.futures as cf,hashlib,json,os,subprocess,sys,time,urllib.request
from pathlib import Path
item=next(x for x in json.loads(Path('publication-verification.json').read_text())['items'] if x['id']==sys.argv[1])
def api(path):return json.loads(subprocess.check_output(['gh','api',path]))
pages=api(f'repos/{item["repository"]}/releases/{item["release_id"]}/assets?per_page=100')
all_assets=pages;page=2
while len(pages)==100:
 pages=api(f'repos/{item["repository"]}/releases/{item["release_id"]}/assets?per_page=100&page={page}');all_assets+=pages;page+=1
assets={a['name']:a for a in all_assets};assert len(assets)==len(all_assets)
for old in item['untouched']:
 a=assets[old['name']];assert all(a[k]==old[k] for k in ('id','size','digest')),('Unrelated asset changed',old['name'])
def verify(f):
 a=assets[f['name']];assert a['state']=='uploaded' and a['size']==f['bytes'] and a['digest']=='sha256:'+f['sha256'],f['name']
 for attempt in range(4):
  try:
   h=hashlib.sha256();count=0;capture=[]
   with urllib.request.urlopen(a['browser_download_url'],timeout=180) as response:
    for b in iter(lambda:response.read(4*1024*1024),b''):
     count+=len(b);h.update(b)
     if f['name']=='install.sh':capture.append(b)
   assert count==f['bytes'] and h.hexdigest()==f['sha256'],f['name']
   if capture:
    data=b''.join(capture);assert ('https://github.com/'+item['repository']+'/').encode() in data;assert b'-security-test' not in data
    subprocess.run(['bash','-n'],input=data,check=True)
   return {'name':f['name'],'asset_id':a['id'],'bytes':count,'sha256':h.hexdigest(),'github_digest_verified':True,'download_hash_verified':True}
  except Exception:
   if attempt==3:raise
   time.sleep(2**attempt)
with cf.ThreadPoolExecutor(max_workers=8) as pool:verified=list(pool.map(verify,item['files']))
Path('verification-results').mkdir(exist_ok=True)
report={'id':item['id'],'repository':item['repository'],'minor':item['minor'],'release_id':item['release_id'],'run_id':os.environ['GITHUB_RUN_ID'],'revision':os.environ['GITHUB_SHA'],'verified':True,'files':verified,'unrelated_assets_preserved':item['untouched']}
Path('verification-results/'+item['id']+'.json').write_text(json.dumps(report,indent=2)+'\n')
print('Verified',item['id'],len(verified),'downloaded assets;',len(item['untouched']),'unrelated assets preserved')
