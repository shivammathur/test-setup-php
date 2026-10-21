"""Collect FPM shutdown diagnostics without modifying published PHP files."""
import hashlib,json,os,shutil,subprocess,sys,time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1];OUT=ROOT/'results';OUT.mkdir(exist_ok=True)
MINOR=os.environ['PHP_SERIES'];PREFIX=Path('/usr/local/php')/MINOR;FPM=PREFIX/'sbin/php-fpm';INI=PREFIX/'etc/php.ini';SCANS=PREFIX/'etc/conf.d';RECORDS=[]
def sha(path):
 h=hashlib.sha256()
 with Path(path).open('rb') as f:
  for c in iter(lambda:f.read(1048576),b''):h.update(c)
 return h.hexdigest()
def call(name,args,env=None,timeout=90):
 try:
  p=subprocess.run([str(a) for a in args],capture_output=True,env=env,timeout=timeout);code=p.returncode;stdout=p.stdout;stderr=p.stderr
 except subprocess.TimeoutExpired as e:code=124;stdout=e.stdout or b'';stderr=e.stderr or b''
 (OUT/(name+'.stdout')).write_bytes(stdout);(OUT/(name+'.stderr')).write_bytes(stderr)
 record={'name':name,'argv':[str(a) for a in args],'exit':code,'stdout_sha256':hashlib.sha256(stdout).hexdigest(),'stderr_sha256':hashlib.sha256(stderr).hexdigest()};RECORDS.append(record)
 print(name,'exit',code,flush=True);return code,stdout,stderr
# Ensure this diagnostic uses the published interpreter selected by setup-php.
assert sha(shutil.which('php'))==sha(PREFIX/'bin/php')
original={str(p):sha(p) for p in [FPM,INI,*sorted(SCANS.glob('*.ini'))]}
call('php-inventory',['php',ROOT/'scripts/inventory.php'])
call('fpm-default-1',['sudo',FPM,'-t'])
call('fpm-default-2',['sudo',FPM,'-t'])
call('fpm-no-ini',['sudo',FPM,'-n','-t'])
# Copied scan directories change only individual diagnostic process inputs.
for label,exclude in [('no-xdebug',('xdebug',)),('no-opcache',('opcache',)),('no-zend-debuggers',('xdebug','opcache'))]:
 directory=Path(os.environ['RUNNER_TEMP'])/label;directory.mkdir(exist_ok=True)
 selected=[]
 for p in sorted(SCANS.glob('*.ini')):
  text=p.read_text()
  if any(token in text.lower() for token in exclude):continue
  shutil.copyfile(p,directory/p.name);selected.append(p.name)
 (OUT/(label+'-ini-files.json')).write_text(json.dumps(selected,indent=2))
 call('fpm-'+label,['sudo','env','PHP_INI_SCAN_DIR='+str(directory),FPM,'-c',INI,'-t'])
call('fpm-system-service',['sudo','service','php'+MINOR+'-fpm','status'])
call('cgi-version',[PREFIX/'bin/php-cgi','-v'])
env=os.environ.copy();env.update(REDIRECT_STATUS='1',SCRIPT_FILENAME=str(ROOT/'scripts/http.php'),REQUEST_METHOD='GET')
code,stdout,stderr=call('cgi-request',[PREFIX/'bin/php-cgi'],env)
cgi=None
try:cgi=json.loads(stdout.replace(b'\r\n',b'\n').split(b'\n\n',1)[1])
except (ValueError,IndexError):pass
code,stdout,stderr=call('imagick-functional',['php',ROOT/'scripts/imagick.php']);imagick=None
try:imagick=json.loads(stdout)
except ValueError:pass
# Exercise an actual FPM request with the repository's installed SAPI switcher.
call('prepare-webroot',['sudo','cp',ROOT/'scripts/http.php','/var/www/html/index.php'])
call('remove-default-index',['sudo','rm','-f','/var/www/html/index.html'])
call('select-fpm-nginx',['sudo','switch_sapi','fpm:nginx'],timeout=180)
code,stdout,stderr=call('fpm-http',['curl','--fail','--silent','--show-error','--retry','3','--max-time','20','http://localhost/index.php'])
http=None
try:http=json.loads(stdout)
except ValueError:pass
call('fpm-service-after-request',['sudo','service','php'+MINOR+'-fpm','status'])
# Keep the default INI and package bytes unchanged throughout the probes.
assert {p:sha(p) for p in original}==original,'Original FPM binary or INIs changed'
if shutil.which('gdb'):
 call('fpm-gdb',['sudo','gdb','--batch','-ex','set pagination off','-ex','run','-ex','thread apply all bt','-ex','info sharedlibrary','--args',FPM,'-t'],timeout=120)
else:(OUT/'gdb-unavailable.txt').write_text('gdb is not installed; no stack trace collected\n')
call('fpm-ldd',['ldd',FPM])
result={'minor':MINOR,'runner':os.environ['RUNNER_LABEL'],'run_id':os.environ['GITHUB_RUN_ID'],'revision':os.environ['GITHUB_SHA'],'diagnostic_collection_complete':True,'php_tests_passed':False,'records':RECORDS,'original_files':original,'original_files_unchanged':True,'cgi':cgi,'imagick':imagick,'fpm_http':http,'published_packages_changed':False,'evidence':{p.name:{'sha256':sha(p),'bytes':p.stat().st_size} for p in OUT.iterdir() if p.is_file()}}
(OUT/'diagnostic.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps({'collected':True,'cgi':cgi,'fpm_http':http,'not_a_php_pass_claim':True}))
