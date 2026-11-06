"""Capture startup failures with and without executing zlib, retaining exact artifact identity."""
import argparse,concurrent.futures,hashlib,json,os,pathlib,re,subprocess,time,zipfile
p=argparse.ArgumentParser();p.add_argument('--run',required=True);a=p.parse_args()
root=pathlib.Path.cwd();spec=json.loads((root/'source-checks.json').read_text())[a.run];rows=[]
pattern=re.compile(r'^php-(?!debug-pack-|devel-pack-|test-pack-).+?-(nts-)?Win32-(v[sc]\d+)-(x64|x86)\.zip$')
for archive in sorted((root/'artifacts').glob('*.zip')):
 m=pattern.match(archive.name)
 if not m:continue
 digest=hashlib.sha256(archive.read_bytes()).hexdigest();assert digest==spec['hashes'][archive.name]
 variant=m[3]+'-'+('nts' if m[1] else 'ts');runtime=pathlib.Path(os.environ['RUNNER_TEMP'])/'startup-diagnostics'/variant;runtime.mkdir(parents=True,exist_ok=True)
 with zipfile.ZipFile(archive) as z:z.extractall(runtime)
 debug=root/'artifacts'/archive.name.replace('php-','php-debug-pack-',1)
 assert debug.exists()
 with zipfile.ZipFile(debug) as z:z.extractall(runtime)
 fixtures={'plain':'<?php echo "plain|ok";','zlib':'<?php echo "zlib=".ZLIB_VERSION."|".gzuncompress(gzcompress("ok"));'}
 for name,code in fixtures.items():(runtime/(name+'.php')).write_text(code)
 env=os.environ.copy();env['PATH']=str(runtime)+os.pathsep+env['PATH']
 for key in ['PHPRC','PHP_INI_SCAN_DIR','TEST_PHP_ARGS','TEST_PHP_EXTRA_ARGS','REQUEST_METHOD','SCRIPT_FILENAME','REDIRECT_STATUS']:env.pop(key,None)
 def check(pair):
  executable,mode,iteration=pair;started=time.monotonic()
  try:
   r=subprocess.run([str(runtime/executable),'-n',str(runtime/(mode+'.php'))],cwd=runtime,env=env,capture_output=True,timeout=60)
   expected=b'plain|ok' if mode=='plain' else ('zlib='+spec.get('zlibVersion','1.4')+'|ok').encode()
   passed=r.returncode==0 and r.stdout.rstrip().endswith(expected) and not r.stderr
   row={'executable':executable,'mode':mode,'iteration':iteration,'exit':r.returncode,'stdoutSha256':hashlib.sha256(r.stdout).hexdigest(),'passed':passed,'seconds':time.monotonic()-started}
   if not passed:row.update(stdout=r.stdout.decode(errors='replace'),stderr=r.stderr.decode(errors='replace'))
   return row
  except subprocess.TimeoutExpired as e:return {'executable':executable,'mode':mode,'iteration':iteration,'timeout':True,'passed':False,'stdout':(e.stdout or b'').decode(errors='replace'),'stderr':(e.stderr or b'').decode(errors='replace')}
 with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:results=list(pool.map(check,[(exe,mode,i) for exe in ['php.exe','php-cgi.exe'] for mode in fixtures for i in range(250)]))
 row={'variant':variant,'archive':archive.name,'archiveSha256':digest,'sourceRun':a.run,'workers':6,'cases':results,'passed':all(x['passed'] for x in results)};rows.append(row)
 print(variant,len(results),'starts;',sum(not x['passed'] for x in results),'failures',flush=True)
report=root/'reports/process-startup-diagnostics.json';report.parent.mkdir(exist_ok=True);report.write_text(json.dumps(rows,indent=2)+'\n')
assert len(rows)==4
# This diagnostic run records all observed failures; its successful completion is not release acceptance.
