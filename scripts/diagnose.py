# Collect the original smoke sequence after startup/version findings.
# Original strict run.py results remain authoritative; this does not turn findings into passes.
import hashlib,json,os,platform,shutil,socket,subprocess,sys,time,urllib.request
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def fingerprint(p):
 h=hashlib.sha256()
 with open(p,'rb') as f:
  for block in iter(lambda:f.read(1024*1024),b''):h.update(block)
 return h.hexdigest()
def download(url,dest,sha,size):
 for attempt in range(4):
  try:
   h=hashlib.sha256();count=0
   with urllib.request.urlopen(url,timeout=120) as response,open(dest,'wb') as out:
    while True:
     chunk=response.read(1024*1024)
     if not chunk:break
     count+=len(chunk)
     if count>size:raise ValueError('size limit')
     h.update(chunk);out.write(chunk)
   if h.hexdigest()!=sha or count!=size:raise ValueError('checksum mismatch')
   return
  except Exception:
   dest.unlink(missing_ok=True)
   if attempt==3:raise RuntimeError('Public artifact download failed') from None
   time.sleep(2**attempt)
def main():
 job=next(j for j in json.loads((ROOT/'manifest.json').read_text())['jobs'] if j['id']==sys.argv[1])
 resultdir=ROOT/'results'/job['id'];resultdir.mkdir(parents=True,exist_ok=True)
 results=[]
 for case in job['cases']:
  print('::group::'+case['id'],flush=True)
  work=Path(os.environ['RUNNER_TEMP'])/('oct-'+job['id']+'-'+case['id']);work.mkdir(parents=True,exist_ok=True)
  outdir=resultdir/case['id'];outdir.mkdir(parents=True,exist_ok=True)
  record={'job':job['id'],'case':case['id'],'archive':case['archive'],'build_id':job['build_id'],'run_id':os.environ['GITHUB_RUN_ID'],'revision':os.environ['GITHUB_SHA'],'runner':job['runner'],'status':'failed','release_approved':False,'diagnostic_only':True,'findings':[]}
  log=open(outdir/'installation-and-smoke.log','w',encoding='utf-8')
  def command(args,env=None,strict_stderr=False):
   print('+ '+' '.join(map(str,args)),flush=True);log.write('+ '+' '.join(map(str,args))+'\n');log.flush()
   p=subprocess.run(list(map(str,args)),stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,errors='replace',env=env,timeout=1800)
   for data in (p.stdout,p.stderr):
    if data:print(data,end='',flush=True);log.write(data);log.flush()
   if p.returncode:raise RuntimeError('Command failed with exit '+str(p.returncode)+': '+str(args[0]))
   if strict_stderr and p.stderr.strip():record['findings'].append({'kind':'startup/runtime stderr','command':str(args[0]),'stderr':p.stderr})
   return p.stdout
  try:
   archive=work/case['archive']['name']
   f=case['archive'];download(f['url'],archive,f['sha256'],f['bytes']);print('SHA256 verified:',f['name'],f['sha256'],flush=True)
   if job['repo']=='php-darwin':
    Path(str(archive)+'.sha256').write_text(f['sha256']+'  '+f['name']+'\n')
   env=os.environ.copy();env.pop('PHPRC',None);env.pop('PHP_INI_SCAN_DIR',None)
   if job['repo']=='php-builder-windows':
    install=work/'php';command(['pwsh','-NoProfile','-File',ROOT/'scripts/install-windows.ps1',archive,install])
    php=install/'php.exe';cgi=install/'php-cgi.exe';env['PATH']=str(install)+os.pathsep+env['PATH'];env['PHPRC']=str(install/'php.ini');env['PHP_INI_SCAN_DIR']=''
    import zipfile
    with zipfile.ZipFile(archive) as z:expected=hashlib.sha256(z.read('php.exe')).hexdigest()
    assert fingerprint(php)==expected,'Installed PHP differs from verified ZIP'
   else:
    installer=ROOT/case['installer']['path'];assert fingerprint(installer)==case['installer']['sha256']
    if job['repo']=='php-darwin':
     assert platform.machine()==case['arch'], 'Runner architecture mismatch'
     env.update(HOMEBREW_NO_AUTO_UPDATE='1',HOMEBREW_NO_INSTALL_FROM_API='1',HOMEBREW_DEVELOPER='1')
     command(['bash',installer,job['minor'],case['build'],case['ts'],archive],env)
     prefix=Path(case['brew_prefix'])/'opt'/case['formula'];php=prefix/'bin/php';cgi=prefix/'bin/php-cgi';fpm=prefix/'sbin/php-fpm';config=prefix/'bin/php-config';phpize=prefix/'bin/phpize'
    else:
     expected_arch='aarch64' if case['arch']=='arm64' else 'x86_64';assert platform.machine()==expected_arch
     assert 'VERSION_ID="'+job['runner'].split('-')[1]+'"' in Path('/etc/os-release').read_text()
     env['DEBIAN_FRONTEND']='noninteractive'
     if job['repo']=='php-builder':
      env['PHP_BUILDER_ARCHIVE_DIR']=str(work);command(['bash',installer,job['minor'],'github',case['build'],case['ts']],env)
     else:
      env['PHP_UBUNTU_ARCHIVE_DIR']=str(work);env['PHP_UBUNTU_SKIP_PACKAGE_REPAIR']='true';command(['bash',installer,job['minor'],case['build'],case['ts']],env)
     php=Path('/usr/bin/php'+job['minor']);cgi=Path('/usr/bin/php-cgi'+job['minor']);fpm=Path('/usr/sbin/php-fpm'+job['minor']);config=Path('/usr/bin/php-config'+job['minor']);phpize=Path('/usr/bin/phpize'+job['minor'])
     members=subprocess.check_output(['tar','-I','zstd','-tf',str(archive)],text=True).splitlines();member=next(x for x in members if x.lstrip('./')=='usr/bin/php'+job['minor'])
     p=subprocess.Popen(['tar','-I','zstd','-xOf',str(archive),member],stdout=subprocess.PIPE);h=hashlib.sha256()
     for chunk in iter(lambda:p.stdout.read(1024*1024),b''):h.update(chunk)
     assert p.wait()==0 and fingerprint(php)==h.hexdigest(),'Installed PHP differs from verified archive'
    env['PATH']=str(php.parent)+os.pathsep+env['PATH']
    command([config,'--version'],env);command([phpize,'--version'],env)
    command((['sudo'] if job['repo']!='php-darwin' else [])+[fpm,'-t'],env)
   command([php,'-v'],env,True);command([php,'--ini'],env,True);command([php,'-m'],env,True);command([cgi,'-v'],env,True)
   identity=json.loads(command([php,ROOT/'scripts/smoke.php'],env,True))
   if identity['version']!=job['version']:record['findings'].append({'kind':'version label mismatch','manifest':job['version'],'observed':identity['version']})
   assert identity['zts']==(case['ts']=='zts'),'Thread safety mismatch'
   assert identity['int_size']==(4 if case['arch']=='x86' else 8),'Word-size mismatch'
   if job['repo']=='php-darwin':assert identity['debug']==(case['build']=='debug'),'Debug build mismatch'
   command([php,'-d','opcache.enable_cli=0',ROOT/'scripts/smoke.php'],env,True)
   command([php,'-d','opcache.enable_cli=1',ROOT/'scripts/smoke.php'],env,True)
   cenv=env.copy();cenv.update(REDIRECT_STATUS='200',REQUEST_METHOD='GET',SCRIPT_FILENAME=str(ROOT/'scripts/http.php'),SCRIPT_NAME='/http.php',QUERY_STRING='',SERVER_PROTOCOL='HTTP/1.1',GATEWAY_INTERFACE='CGI/1.1')
   body=command([cgi],cenv,True);data=json.loads(body.replace('\r\n','\n').split('\n\n',1)[1]);assert data['version']==identity['version'] and data['smoke']=='ok'
   with socket.socket() as sock:sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
   with open(outdir/'http-server.log','w') as serverlog:
    server=subprocess.Popen([str(php),'-S','127.0.0.1:'+str(port),str(ROOT/'scripts/http.php')],env=env,stdout=serverlog,stderr=serverlog)
    try:
     for retry in range(30):
      try:
       with urllib.request.urlopen('http://127.0.0.1:'+str(port),timeout=5) as response:http=json.load(response)
       assert http['smoke']=='ok' and http['version']==identity['version'];break
      except OSError:
       if server.poll() is not None:raise RuntimeError('PHP web server exited')
       time.sleep(.3)
     else:raise RuntimeError('PHP web server did not respond')
    finally:server.terminate();server.wait(timeout=20)
   record.update(status='diagnostics_complete',runtime=identity,installed_php_sha256=fingerprint(php),checks=['archive SHA256 and size','installer','version/architecture/ZTS','clean startup','CLI','CGI request','HTTP request','common extensions','OpenSSL','JSON/hash','SQLite/PDO','ZIP/filesystem/session','OPcache on/off execution'])
  except Exception as e:
   record['error']=str(e);print('SMOKE FAILURE:',str(e),flush=True)
  finally:
   log.close();(outdir/'result.json').write_text(json.dumps(record,indent=2)+'\n');results.append(record)
   # Only this case's downloaded input and Windows installation are temporary.
   shutil.rmtree(work,ignore_errors=True);print('::endgroup::',flush=True)
 (resultdir/'summary.json').write_text(json.dumps(results,indent=2)+'\n')
 with open(os.environ['GITHUB_STEP_SUMMARY'],'a') as s:
  s.write('| Case | Result |\n|---|---|\n');s.writelines('| '+r['case']+' | '+r['status']+' |\n' for r in results)
 return 0 if all(r['status']=='diagnostics_complete' for r in results) else 1
if __name__=='__main__':
 try:sys.exit(main())
 except Exception as e:print('Smoke setup failed:',type(e).__name__,str(e));sys.exit(1)
