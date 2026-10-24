"""Repeat selected original PHPT failures using the exact reviewed PHP ZIPs."""
import argparse, hashlib, json, os, pathlib, re, subprocess, time, zipfile
import xml.etree.ElementTree as ET
p=argparse.ArgumentParser();p.add_argument('--php',required=True);p.add_argument('--run',required=True);p.add_argument('--source-sha',required=True);a=p.parse_args()
root=pathlib.Path.cwd();source=root/'php-src';reports=root/'reports';reports.mkdir(exist_ok=True)
assert subprocess.check_output(['git','rev-parse','HEAD'],cwd=source,text=True).strip()==a.source_sha
spec=json.loads((root/'source-checks.json').read_text())[a.run]
assert spec['sourceSha']==a.source_sha
pattern=re.compile(r'^php-(?!debug-pack-|devel-pack-|test-pack-).+?-(nts-)?Win32-(v[sc]\d+)-(x64|x86)\.zip$')
rows=[]
for archive in sorted((root/'artifacts').glob('*.zip')):
 m=pattern.match(archive.name)
 if not m:continue
 digest=hashlib.sha256(archive.read_bytes()).hexdigest();assert digest==spec['hashes'][archive.name]
 variant=m[3]+'-'+('nts' if m[1] else 'ts');cases=[x for x in spec['cases'] if x['variant']==variant]
 if not cases:continue
 runtime=pathlib.Path(os.environ['RUNNER_TEMP'])/'source-checks'/variant;runtime.mkdir(parents=True,exist_ok=True)
 with zipfile.ZipFile(archive) as z:z.extractall(runtime)
 php=runtime/'php.exe';out=reports/variant;out.mkdir(exist_ok=True)
 env=os.environ.copy()
 for key in ['TEST_PHP_ARGS','TEST_PHP_EXTRA_ARGS','TEST_PHP_JUNIT','PHPRC','PHP_INI_SCAN_DIR']:env.pop(key,None)
 env.update(PATH=str(runtime)+os.pathsep+env['PATH'],PHPRC='',PHP_INI_SCAN_DIR=str(out/'no-ini'),TEST_PHP_EXECUTABLE=str(php),TEST_PHP_CGI_EXECUTABLE=str(runtime/'php-cgi.exe'),NO_INTERACTION='1',REPORT_EXIT_STATUS='1',SKIP_IO_CAPTURE_TESTS='1')
 modules=subprocess.check_output([str(php),'-n','-m'],env=env,text=True)
 opcache=[] if re.search(r'^Zend OPcache$',modules,re.M) else ['-d','zend_extension='+(runtime/'ext/php_opcache.dll').as_posix()]
 ini=out/'php-test.ini';ini.write_text('memory_limit=-1\nextension_dir="'+str(runtime/'ext')+'"\n')
 for index,case in enumerate(cases):
  rel=pathlib.PurePosixPath(case['test']);assert not rel.is_absolute() and '..' not in rel.parts
  test=source/rel;assert test.is_file()
  original=hashlib.sha256(test.read_bytes()).hexdigest()
  cache=[*opcache,'-d','opcache.enable=1','-d','opcache.enable_cli=1'] if case['mode']=='opcache' else ['-d','opcache.enable_cli=0']
  for repeat in range(3):
   label=f'{index:02}-{case["mode"]}-{repeat}';xml=out/(label+'.xml');testenv=env.copy();testenv['TEST_PHP_JUNIT']=str(xml)
   cmd=[str(php),'-n',str(source/'run-tests.php'),'-p',str(php),'-n','-c',str(ini),'-d','extension_dir='+str(runtime/'ext'),'-q','--offline','--show-diff',*cache,str(test)]
   start=time.monotonic()
   try:
    r=subprocess.run(cmd,cwd=source,env=testenv,capture_output=True,timeout=120)
    result={'exit':r.returncode,'stdout':r.stdout.decode('utf-8',errors='replace'),'stderr':r.stderr.decode('utf-8',errors='replace')}
   except subprocess.TimeoutExpired as e:result={'timeout':True,'stdout':(e.stdout or b'').decode(errors='replace'),'stderr':(e.stderr or b'').decode(errors='replace')}
   tests=list(ET.parse(xml).getroot().iter('testcase')) if xml.exists() else []
   issues=[{'type':c.tag,'text':c.text} for t in tests for c in t if c.tag in ['failure','error','skipped']]
   row={'php':a.php,'sourceRun':a.run,'sourceSha':a.source_sha,'archiveSha256':digest,'variant':variant,'test':case['test'],'originalTestSha256':original,'mode':case['mode'],'repeat':repeat,'cases':len(tests),'issues':issues,'seconds':time.monotonic()-start,**result}
   assert hashlib.sha256(test.read_bytes()).hexdigest()==original
   (out/(label+'.json')).write_text(json.dumps(row,indent=2));rows.append(row)
   print(variant,case['test'],case['mode'],repeat,result.get('exit'),issues,flush=True)
(reports/'source-checks.json').write_text(json.dumps(rows,indent=2))
assert len(rows)==len(spec['cases'])*3
if any(r.get('exit')!=0 or r['cases']!=1 or r['issues'] for r in rows):raise SystemExit('Some original PHPT failures reproduced; see retained evidence')
print('All selected original PHPTs pass in serial repetition with exact PHP artifacts')
