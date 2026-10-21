"""Exercise public setup-php installs; package bytes stay on Actions runners."""
import hashlib,json,os,platform,re,shutil,subprocess,sys,tarfile
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
MINOR=os.environ['PHP_SERIES']
if MINOR in ('5.3','5.4','5.5'):
    os.execv(sys.executable,[sys.executable,str(ROOT/'scripts/legacy_check.py'),*sys.argv[1:]])
RESULTS=ROOT/'results';RESULTS.mkdir(exist_ok=True)
ARCH=platform.machine();assert ARCH in ('arm64','x86_64')
REPO='shivammathur/php-darwin'
CONFIG=json.loads((ROOT/'scripts/darwin-packages.json').read_text())[MINOR]
FILES={f['name']:f for f in CONFIG['files']}
VERSION=CONFIG['version']
SETUP='eb7c497e18156a6bbabfef1d3a82760b9eda3962'

def sha(path):
    h=hashlib.sha256()
    with Path(path).open('rb') as f:
        for c in iter(lambda:f.read(1024*1024),b''):h.update(c)
    return h.hexdigest()
def save(name,data):(RESULTS/(name+'.json')).write_text(json.dumps(data,indent=2)+'\n')
def api(path):return json.loads(subprocess.check_output(['gh','api',path]))
def run(label,args,env=None,strict_stderr=True):
    p=subprocess.run([str(x) for x in args],capture_output=True,env=env,timeout=180)
    (RESULTS/(label+'.stdout')).write_bytes(p.stdout);(RESULTS/(label+'.stderr')).write_bytes(p.stderr)
    assert p.returncode==0,(label,p.returncode,p.stderr.decode(errors='replace')[-1500:])
    assert not re.search(rb'PHP (?:Warning|Notice|Deprecated|Fatal error|Parse error|Startup)',p.stdout+p.stderr),(label,'PHP diagnostic')
    if strict_stderr:assert not p.stderr.strip(),(label,p.stderr.decode(errors='replace')[-1500:])
    print(label,p.stdout.decode(errors='replace')[:1500],flush=True)
    return p.stdout
def published():
    r=api('repos/'+REPO+'/releases/tags/'+CONFIG['tag']);assert not r['draft'] and not r['prerelease']
    assets={}
    for page in range(1,20):
        rows=api(f'repos/{REPO}/releases/{r["id"]}/assets?per_page=100&page={page}')
        assets.update({a['name']:a for a in rows})
        if len(rows)<100:break
    for f in FILES.values():
        a=assets[f['name']];assert a['state']=='uploaded' and a['size']==f['bytes'] and a['digest']=='sha256:'+f['sha256'],f['name']
    save('public-assets',{'repository':REPO,'release_id':r['id'],'files':[{k:assets[n][k] for k in ('id','name','size','digest','browser_download_url')} for n in FILES]})
    return assets
def installed_bytes(php):
    name=next(n for n in FILES if n.startswith(f'php_{MINOR}-nts-release+darwin_{ARCH}.') and n.endswith('.tar.zst'))
    f=FILES[name];assets=published();archive=Path(os.environ['RUNNER_TEMP'])/name
    if not archive.exists():
        with archive.open('wb') as fp:subprocess.run(['curl','--fail','--location','--retry','3','--silent','--show-error',assets[name]['browser_download_url']],stdout=fp,check=True)
    assert archive.stat().st_size==f['bytes'] and sha(archive)==f['sha256']
    prefix=Path(subprocess.check_output(['brew','--prefix'],text=True).strip())
    records=[];p=subprocess.Popen(['zstd','-dcq',str(archive)],stdout=subprocess.PIPE)
    with tarfile.open(fileobj=p.stdout,mode='r|') as tar:
        for m in tar:
            if not m.isfile():continue
            rel=m.name.removeprefix('./');assert not rel.startswith('/') and '..' not in Path(rel).parts
            if not (rel.startswith(f'Cellar/php@{MINOR}/') and (rel.endswith('/bin/php') or rel.endswith('/bin/php-cgi') or rel.endswith('/sbin/php-fpm') or rel.endswith('.so'))):continue
            target=prefix/rel;h=hashlib.sha256()
            with tar.extractfile(m) as fp:
                for c in iter(lambda:fp.read(1024*1024),b''):h.update(c)
            assert target.is_file() and sha(target)==h.hexdigest(),('Installed payload mismatch',str(target))
            records.append({'path':str(target),'bytes':m.size,'sha256':h.hexdigest()})
    assert p.wait()==0 and len(records)>=3
    assert any(Path(r['path']).resolve()==php.resolve() for r in records),'Selected PHP is not the published runtime'
    assert any(r['path'].endswith('/bin/php-cgi') for r in records) and any(r['path'].endswith('/sbin/php-fpm') for r in records)
    return {'archive':name,'sha256':f['sha256'],'installed_files':records}
def capture(phase):
    php=Path(shutil.which('php'));assert php.is_file()
    arch=run(phase+'-architecture',['file','-L',php]).decode();assert ARCH in arch
    assert sha('/tmp/install.sh')==FILES['install.sh']['sha256'],'setup-php used a different installer'
    for label,args in [('version',['-v']),('modules',['-m']),('ini',['--ini'])]:run(phase+'-'+label,[php,*args])
    inv=json.loads(run(phase+'-inventory',[php,ROOT/'scripts/inventory.php']))
    assert inv['php_version']==VERSION and inv['sapi']=='cli' and inv['int_size']==8
    if phase=='base':
        proof=installed_bytes(php)
        for cache in ('0','1'):
            smoke=json.loads(run('functional-opcache-'+cache,[php,'-d','opcache.enable_cli='+cache,ROOT/'scripts/smoke.php']))
            assert smoke['status']=='passed' and smoke['version']==VERSION and not smoke['zts'] and not smoke['debug']
        prefix=php.resolve().parent.parent;cgi=prefix/'bin/php-cgi';fpm=prefix/'sbin/php-fpm'
        run('cgi-version',[cgi,'-v']);run('fpm-version',[fpm,'-v']);run('fpm-config',[fpm,'-t'],strict_stderr=False)
        env=os.environ.copy();env.update(REDIRECT_STATUS='1',SCRIPT_FILENAME=str(ROOT/'scripts/http.php'),REQUEST_METHOD='GET')
        response=run('cgi-request',[cgi],env);body=response.replace(b'\r\n',b'\n').split(b'\n\n',1)[1]
        assert json.loads(body)=={'version':VERSION,'sapi':'cgi-fcgi','status':'passed'}
    else:
        base=json.loads((RESULTS/'base.json').read_text())
        for k in ('normal_extensions','zend_extensions'):
            expected=set(base['inventory'][k])|({'imagick'} if k=='normal_extensions' else set())
            assert set(inv[k])==expected,(k,sorted(set(inv[k])^expected))
        assert sha(php)==base['selected_php_sha256'],'Imagick setup replaced PHP'
        imagick=json.loads(run('imagick-functional',[php,ROOT/'scripts/imagick.php']))
        assert all(x['roundtrip'] and x['resize'] and x['file_roundtrip'] for x in imagick['checks'].values())
        proof={'unchanged_php_sha256':sha(php)}
    save(phase,{'status':'passed','version':VERSION,'architecture':ARCH,'inventory':inv,'payload':proof,'selected_php_sha256':sha(php),'startup_warnings':0})

mode=sys.argv[1]
if mode=='before':
    assert api('repos/shivammathur/setup-php/commits/v2')['sha']==SETUP,'setup-php v2 changed'
    published()
elif mode in ('base','imagick'):capture(mode)
elif mode=='finish':
    assert all(json.loads((RESULTS/(p+'.json')).read_text())['status']=='passed' for p in ('base','imagick'))
    save('report',{'status':'passed','minor':MINOR,'version':VERSION,'runner':os.environ['RUNNER_LABEL'],'architecture':ARCH,'run_id':os.environ['GITHUB_RUN_ID'],'revision':os.environ['GITHUB_SHA'],'setup_php_revision':SETUP,'phases':['base','imagick'],'imagick_passed':True,'cgi_passed':True,'fpm_config_passed':True,'startup_warnings':0,'evidence':{p.name:{'bytes':p.stat().st_size,'sha256':sha(p)} for p in RESULTS.iterdir() if p.is_file()}})
    print('All setup-php installation and smoke checks passed')
else:raise ValueError(mode)
