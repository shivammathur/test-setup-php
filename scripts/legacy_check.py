"""Install via setup-php, then verify published bytes and runtime behavior."""
import hashlib,json,os,platform,re,shutil,subprocess,sys,tarfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1];RESULTS=ROOT/'results';RESULTS.mkdir(exist_ok=True)
MINOR=os.environ['PHP_SERIES'];SHORT=MINOR.replace('.','');MAC=platform.system()=='Darwin';ARCH=platform.machine();ARM=ARCH in ('arm64','aarch64');SUFFIX='-arm64' if ARM else ''
PROJECT='php5-darwin' if MAC else 'php5-ubuntu';REPO='shivammathur/'+PROJECT
CONFIG=json.loads((ROOT/'scripts/packages.json').read_text())[PROJECT];FILES={f['name']:f for f in CONFIG[MINOR]}
VERSION={'5.3':'5.3.29','5.4':'5.4.45','5.5':'5.5.38'}[MINOR]
def sha(path):
 h=hashlib.sha256()
 with Path(path).open('rb') as f:
  for c in iter(lambda:f.read(1024*1024),b''):h.update(c)
 return h.hexdigest()
def save(name,data):(RESULTS/(name+'.json')).write_text(json.dumps(data,indent=2)+'\n')
def api(path):return json.loads(subprocess.check_output(['gh','api',path]))
def run(label,args,env=None,php_stderr=True):
 p=subprocess.run([str(x) for x in args],capture_output=True,env=env,timeout=180)
 (RESULTS/(label+'.stdout')).write_bytes(p.stdout);(RESULTS/(label+'.stderr')).write_bytes(p.stderr)
 assert p.returncode==0,(label,'exit',p.returncode,p.stderr.decode(errors='replace')[-1500:])
 assert not re.search(rb'PHP (?:Warning|Notice|Deprecated|Fatal error|Parse error|Startup)',p.stdout+p.stderr),(label,'PHP diagnostic')
 if php_stderr:assert not p.stderr.strip(),(label,'Unexpected stderr',p.stderr.decode(errors='replace')[-1500:])
 print(label,p.stdout.decode(errors='replace')[:1200],flush=True);return p.stdout

def published():
 r=api('repos/'+REPO+'/releases/latest');assert r['tag_name']=='builds' and not r['draft'] and not r['prerelease']
 assets={a['name']:a for a in api(f'repos/{REPO}/releases/{r["id"]}/assets?per_page=100')}
 for f in list(FILES.values())+CONFIG['metadata']:
  a=assets[f['name']];assert a['state']=='uploaded' and a['size']==f['bytes'] and a['digest']=='sha256:'+f['sha256'],f['name']
 save('public-assets',{'repository':REPO,'release_id':r['id'],'files':[{k:assets[f['name']][k] for k in ('id','name','size','digest','browser_download_url')} for f in FILES.values()]})
 return assets

def download(name):
 f=FILES[name];assets=published();out=Path(os.environ['RUNNER_TEMP'])/'verified-public-archives'/name;out.parent.mkdir(exist_ok=True)
 if not out.exists():
  with out.open('wb') as fp:subprocess.run(['curl','--fail','--location','--retry','3','--silent','--show-error',assets[name]['browser_download_url']],stdout=fp,check=True)
 assert out.stat().st_size==f['bytes'] and sha(out)==f['sha256'],name
 return out

def installed_bytes(phase):
 if MAC:
  name=f'php{SHORT}-imagick{SUFFIX}-cache.tar.zst' if phase=='imagick' else f'php{SHORT}{SUFFIX}-cache.tar.zst'
  archive=download(name)
 else:
  name=f'php-{MINOR}{SUFFIX}.tar.zst';installer=Path('/tmp')/name
  assert installer.stat().st_size==FILES[name]['bytes'] and sha(installer)==FILES[name]['sha256'],'setup-php installer archive differs'
  name=f'php-{MINOR}-build{SUFFIX}.tar.zst';archive=Path('/tmp')/('php-'+MINOR)/name
  assert archive.stat().st_size==FILES[name]['bytes'] and sha(archive)==FILES[name]['sha256']
 records=[];p=subprocess.Popen(['zstd','-dcq',str(archive)],stdout=subprocess.PIPE)
 with tarfile.open(fileobj=p.stdout,mode='r|') as tar:
  for m in tar:
   if not m.isfile():continue
   rel=m.name.removeprefix('./').lstrip('/')
   if MAC:
    selected=(rel in [f'opt/local/bin/php{SHORT}',f'opt/local/bin/php-cgi{SHORT}',f'opt/local/sbin/php-fpm{SHORT}'] or (rel.startswith(f'opt/local/lib/php{SHORT}/extensions/') and rel.endswith('.so')))
    if phase=='imagick':selected=selected and Path(rel).name=='imagick.so'
    target=Path('/')/rel
   else:
    selected=rel in [f'{MINOR}/bin/php',f'{MINOR}/bin/php-cgi',f'{MINOR}/sbin/php-fpm'] or (rel.startswith(f'{MINOR}/lib/php/extensions/') and rel.endswith('.so'))
    target=Path('/usr/local/php')/rel
   if not selected:continue
   assert '..' not in Path(rel).parts
   h=hashlib.sha256()
   with tar.extractfile(m) as fp:
    for c in iter(lambda:fp.read(1024*1024),b''):h.update(c)
   assert target.is_file() and sha(target)==h.hexdigest(),('Installed payload mismatch',str(target))
   records.append({'path':str(target),'bytes':m.size,'sha256':h.hexdigest()})
 assert p.wait()==0
 assert len(records)==1 if phase=='imagick' else len(records)>20
 return {'archive':name,'sha256':FILES[name]['sha256'],'installed_files':records}

def capture(phase):
 php=Path('/opt/local/bin/php'+SHORT) if MAC else Path('/usr/local/php')/MINOR/'bin/php'
 selected=Path(shutil.which('php'))
 # Ubuntu's production installer copies the executable to /usr/bin/phpX.Y.
 # Verify byte identity; inode identity would incorrectly reject that copy.
 save(phase+'-selected-php',{'selected':str(selected),'resolved':str(selected.resolve()),'package_path':str(php),'selected_sha256':sha(selected),'package_sha256':sha(php)})
 assert sha(selected)==sha(php),'Selected PHP bytes differ from the approved runtime'
 file_output=run(phase+'-architecture',['file','-L',php]).decode()
 assert ('arm64' in file_output or 'aarch64' in file_output) if ARM else ('x86_64' in file_output or 'x86-64' in file_output)
 installer=next(f for f in CONFIG['metadata'] if f['name']=='install.sh');assert sha('/tmp/install.sh')==installer['sha256'],'setup-php used a different installer'
 for label,args in [('version',['-v']),('modules',['-m']),('ini',['--ini'])]:run(phase+'-'+label,['php',*args])
 inv=json.loads(run(phase+'-inventory',['php',ROOT/'scripts/inventory.php']))
 assert inv['php_version']==VERSION and inv['sapi']=='cli' and inv['int_size']==8
 proof=installed_bytes(phase)
 if MAC:
  expected=json.loads((ROOT/'scripts/darwin-modules.json').read_text())[MINOR]['arm64' if ARM else 'x86_64'][phase]
  for k in ('normal_extensions','zend_extensions'):assert set(inv[k])==set(expected[k]),(phase,k,sorted(set(inv[k])^set(expected[k])))
 if phase=='base':
  smoke=json.loads(run('functional',['php',ROOT/'scripts/smoke.php']));assert smoke['status']=='passed' and smoke['version']==VERSION
  cgi=Path('/opt/local/bin/php-cgi'+SHORT) if MAC else php.parent/'php-cgi';fpm=Path('/opt/local/sbin/php-fpm'+SHORT) if MAC else php.parent.parent/'sbin/php-fpm'
  run('cgi-version',[cgi,'-v']);run('fpm-version',[fpm,'-v']);run('fpm-config',['sudo',fpm,'-t'],php_stderr=False)
  env=os.environ.copy();env.update(REDIRECT_STATUS='1',SCRIPT_FILENAME=str(ROOT/'scripts/http.php'),REQUEST_METHOD='GET')
  response=run('cgi-request',[cgi],env);body=response.replace(b'\r\n',b'\n').split(b'\n\n',1)[1];data=json.loads(body);assert data=={'version':VERSION,'sapi':'cgi-fcgi','status':'passed'}
  # Imagick is already bundled and loaded by the Ubuntu installer.
  if not MAC:
   imagick=json.loads(run('imagick-functional',['php',ROOT/'scripts/imagick.php']));assert all(x['roundtrip'] and x['resize'] and x['file_roundtrip'] for x in imagick['checks'].values())
 else:
  imagick=json.loads(run('imagick-functional',['php',ROOT/'scripts/imagick.php']));assert all(x['roundtrip'] and x['resize'] and x['file_roundtrip'] for x in imagick['checks'].values())
 save(phase,{'status':'passed','version':VERSION,'architecture':ARCH,'inventory':inv,'payload':proof,'startup_warnings':0})

mode=sys.argv[1]
if mode=='before':
 assert api('repos/shivammathur/setup-php/commits/v2')['sha']=='eb7c497e18156a6bbabfef1d3a82760b9eda3962','setup-php v2 changed'
 published()
elif mode in ('base','imagick'):capture(mode)
elif mode=='finish':
 phases=['base','imagick'] if MAC else ['base'];assert all(json.loads((RESULTS/(p+'.json')).read_text())['status']=='passed' for p in phases)
 save('report',{'status':'passed','minor':MINOR,'version':VERSION,'runner':os.environ['RUNNER_LABEL'],'architecture':ARCH,'run_id':os.environ['GITHUB_RUN_ID'],'revision':os.environ['GITHUB_SHA'],'setup_php_revision':'eb7c497e18156a6bbabfef1d3a82760b9eda3962','phases':phases,'imagick_passed':True,'cgi_passed':True,'fpm_config_passed':True,'startup_warnings':0,'evidence':{p.name:{'bytes':p.stat().st_size,'sha256':sha(p)} for p in RESULTS.iterdir() if p.is_file()}})
 print('All setup-php installation and smoke checks passed')
else:raise ValueError(mode)
