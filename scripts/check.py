"""Verify setup-php's public Windows installation and retain compact evidence."""
import hashlib,json,os,re,shutil,subprocess,sys,urllib.request,zipfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1];OUT=ROOT/'results';OUT.mkdir(exist_ok=True)
MINOR=os.environ['PHP_SERIES'];TS=os.environ['PHPTS'];PREFIX=Path('C:/tools/php')
PLAN=json.loads((ROOT/'scripts/packages.json').read_text())[MINOR];ASSET=PLAN['variants'][TS]
REPO='shivammathur/php-builder-windows';RECORDS=[]
def sha(p):
 h=hashlib.sha256()
 with Path(p).open('rb') as f:
  for b in iter(lambda:f.read(1048576),b''):h.update(b)
 return h.hexdigest()
def save(name,value):(OUT/(name+'.json')).write_text(json.dumps(value,indent=2)+'\n',encoding='utf-8')
def api(path):return json.loads(subprocess.check_output(['gh','api',path],text=True,encoding='utf-8'))
def fetch(url,path):
 path.parent.mkdir(parents=True,exist_ok=True)
 with urllib.request.urlopen(url,timeout=120) as r,path.open('wb') as f:shutil.copyfileobj(r,f)
 return path

def run(name,args,env=None):
 p=subprocess.run([str(a) for a in args],capture_output=True,env=env,timeout=120)
 (OUT/(name+'.stdout')).write_bytes(p.stdout);(OUT/(name+'.stderr')).write_bytes(p.stderr)
 save(name+'-command',{'args':[str(a) for a in args],'exit':p.returncode})
 assert p.returncode==0,(name,p.returncode,p.stderr.decode(errors='replace')[-1500:])
 assert not p.stderr.strip(),(name,'Unexpected stderr',p.stderr.decode(errors='replace')[-1500:])
 assert not re.search(rb'(?:PHP )?(?:Warning|Deprecated|Fatal error|Parse error|Notice):',p.stdout),(name,'PHP diagnostic')
 return p.stdout

def before():
 assert api('repos/shivammathur/setup-php/commits/v2')['sha']=='eb7c497e18156a6bbabfef1d3a82760b9eda3962'
 r=api(f'repos/{REPO}/releases/tags/{PLAN["tag"]}');assert not r['draft'] and not r['prerelease']
 assets={a['name']:a for a in r['assets']}
 for f in [ASSET,PLAN['manifest']]:
  a=assets[f['name']];assert a['state']=='uploaded' and a['size']==f['bytes'] and a['digest']=='sha256:'+f['sha256'],f['name']
 save('public-assets',{'repository':REPO,'tag':PLAN['tag'],'assets':[{k:assets[f['name']][k] for k in ['id','name','size','digest','browser_download_url']} for f in [ASSET,PLAN['manifest']]]})
 # A clean hosted VM install exercises the mirror route even when PHP is preinstalled.
 if PREFIX.exists():
  dest=Path(os.environ['RUNNER_TEMP'])/'preinstalled-php-before-release-smoke';assert not dest.exists()
  old={'path':str(PREFIX),'php_exe_sha256':sha(PREFIX/'php.exe') if (PREFIX/'php.exe').exists() else None}
  shutil.move(str(PREFIX),str(dest));old['preserved_at']=str(dest);save('preinstalled-php',old)
 assert not PREFIX.exists()
 print('Public release metadata verified; clean setup-php installation prepared.')

def verify_payload():
 meta=json.loads((OUT/'public-assets.json').read_text());url=next(a['browser_download_url'] for a in meta['assets'] if a['name']==ASSET['name'])
 dest=Path(os.environ['RUNNER_TEMP'])/'verified-public-assets';dest.mkdir(exist_ok=True)
 archive=PREFIX/ASSET['name']
 if not archive.exists():archive=fetch(url,dest/ASSET['name'])
 assert archive.stat().st_size==ASSET['bytes'] and sha(archive)==ASSET['sha256']
 manifest_meta=next(a for a in meta['assets'] if a['name']=='manifest.json');manifest=fetch(manifest_meta['browser_download_url'],dest/'manifest.json')
 assert sha(manifest)==PLAN['manifest']['sha256']
 assert json.loads(manifest.read_text())['stable']['php'][TS][PLAN['arch']]==ASSET['name']
 records=[];overrides=[]
 with zipfile.ZipFile(archive) as z:
  for info in z.infolist():
   n=info.filename.replace('\\','/');assert '..' not in Path(n).parts and not n.startswith('/')
   if info.is_dir() or Path(n).suffix.lower() not in ('.exe','.dll'):continue
   p=PREFIX/n;assert p.is_file(),('Missing installed binary',n)
   published=hashlib.sha256(z.read(info)).hexdigest();installed=sha(p)
   if installed!=published and MINOR in ('5.3','5.4') and n.lower() in ('libeay32.dll','ssleay32.dll'):
    # The unchanged setup-php action explicitly replaces these two legacy DLLs.
    replacement_url=f'https://github.com/{REPO}/releases/download/openssl-1.0.2u/{n}'
    replacement=fetch(replacement_url,dest/('setup-php-'+n));assert sha(replacement)==installed
    overrides.append({'name':n,'published_sha256':published,'installed_sha256':installed,'source':replacement_url,'verification':'downloaded replacement matched; legacy GitHub asset has no digest'})
   else:assert installed==published,('Installed binary differs',n,published,installed)
   records.append({'path':n,'published_sha256':published,'installed_sha256':installed})
 assert len(records)>10 and any(r['path'].lower()=='php.exe' for r in records)
 save('payload',{'asset':ASSET,'verified_binary_files':records,'setup_php_legacy_openssl_overrides':overrides})

def capture(phase):
 php=Path(shutil.which('php'));assert php.resolve()==(PREFIX/'php.exe').resolve(),('Wrong PHP on PATH',str(php))
 for name,args in [('version',['-v']),('modules',['-m']),('ini',['--ini'])]:run(phase+'-'+name,[php,*args])
 inv=json.loads(run(phase+'-inventory',[php,ROOT/'scripts/inventory.php']));assert inv['php_version']==PLAN['version'] and inv['sapi']=='cli'
 assert inv['zts']==(TS=='ts') and inv['int_size']==(4 if PLAN['arch']=='x86' else 8) and not inv['debug']
 if phase=='default':
  verify_payload()
  built=json.loads(run('builtin-inventory',[php,'-n',ROOT/'scripts/inventory.php']))
  expected={s.lower() for s in built['normal_extensions']}
  expected.update(['curl','mbstring','openssl'])
  if (PREFIX/'ext/php_opcache.dll').exists():expected.add('zend opcache')
  assert {s.lower() for s in inv['normal_extensions']}==expected,('Unexpected default modules',sorted(expected.symmetric_difference(s.lower() for s in inv['normal_extensions'])))
 else:
  functional=json.loads(run('functional',[php,ROOT/'scripts/smoke.php']));assert functional['status']=='passed' and functional['version']==PLAN['version']
  cgi=PREFIX/'php-cgi.exe';run('cgi-version',[cgi,'-v']);env=os.environ.copy();env.update(REDIRECT_STATUS='1',SCRIPT_FILENAME=str(ROOT/'scripts/http.php'),REQUEST_METHOD='GET',SERVER_PROTOCOL='HTTP/1.1',GATEWAY_INTERFACE='CGI/1.1',CONTENT_LENGTH='0')
  raw=run('cgi-request',[cgi],env);body=raw.replace(b'\r\n',b'\n').split(b'\n\n',1)[1];assert json.loads(body)=={'version':PLAN['version'],'sapi':'cgi-fcgi','status':'passed'}
  # setup-php enabled only bundled modules for the functional checks.
  verify_payload()
 save(phase,{'status':'passed','inventory':inv,'php_executable':str(php),'php_executable_sha256':sha(php)})
 print(phase,'passed',MINOR,TS,PLAN['arch'])

def finish():
 for phase in ['default','extended']:assert json.loads((OUT/(phase+'.json')).read_text())['status']=='passed'
 save('report',{'status':'passed','minor':MINOR,'version':PLAN['version'],'thread_safety':TS,'architecture':PLAN['arch'],'runner':'windows-2022','run_id':os.environ['GITHUB_RUN_ID'],'revision':os.environ['GITHUB_SHA'],'setup_php_revision':'eb7c497e18156a6bbabfef1d3a82760b9eda3962','default_startup_warnings':0,'functional_passed':True,'cgi_passed':True,'published_asset_sha256':ASSET['sha256'],'evidence':{p.name:{'sha256':sha(p),'bytes':p.stat().st_size} for p in OUT.iterdir() if p.is_file()}})
 print('All Windows setup-php installation and smoke checks passed.')

mode=sys.argv[1]
if mode=='before':before()
elif mode in ['default','extended']:capture(mode)
elif mode=='finish':finish()
else:raise ValueError(mode)
