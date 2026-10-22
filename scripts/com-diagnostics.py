import argparse, hashlib, json, os, pathlib, re, subprocess, xml.etree.ElementTree as ET
from pe_imports import closure

p=argparse.ArgumentParser();p.add_argument('--run-id',required=True);p.add_argument('--source-sha',required=True);a=p.parse_args()
root=pathlib.Path.cwd();source=root/'php-src';report=root/'reports/com-diagnostics';report.mkdir(parents=True,exist_ok=True)
assert subprocess.check_output(['git','rev-parse','HEAD'],cwd=source,text=True).strip()==a.source_sha
archives=[z for z in (root/'artifacts').glob('php-*-Win32-vs17-x86.zip') if not any(s in z.name for s in ['-nts-','-debug-pack-','-devel-pack-','-test-pack-'])]
assert len(archives)==1
archive=archives[0];runtime=pathlib.Path(os.environ['RUNNER_TEMP'])/a.run_id/archive.stem
php=runtime/'php.exe';com=runtime/'ext/php_com_dotnet.dll';opcache=runtime/'ext/php_opcache.dll'
env=os.environ.copy();env.update(PATH=str(runtime)+os.pathsep+env['PATH'],TEST_PHP_EXECUTABLE=str(php),NO_INTERACTION='1',REPORT_EXIT_STATUS='1',SKIP_IO_CAPTURE_TESTS='1')
imports={'php':closure(runtime,'php.exe'),'com':closure(runtime/'ext',com.name),'opcache':closure(runtime/'ext',opcache.name)}
assert not any(any(token in name for token in ['zip','brotli','curl']) for group in imports.values() for names in group.values() for name in names)
(report/'imports.json').write_text(json.dumps(imports,indent=2))
rows=[]
for cache in [False,True]:
    options=['-n','-d','extension_dir='+str(runtime/'ext'),'-d','extension=com_dotnet']
    if cache:options+=['-d','zend_extension='+str(opcache),'-d','opcache.enable_cli=1']
    modules=subprocess.check_output([str(php),*options,'-m'],env=env,text=True)
    assert re.search(r'^com_dotnet$',modules,re.M) and not re.search(r'^(zip|curl|brotli)$',modules,re.M)
    (report/('modules-opcache.txt' if cache else 'modules-nocache.txt')).write_text(modules)
    for i in range(20):
        label=('opcache' if cache else 'nocache')+'-'+str(i)
        xml=report/(label+'.xml');env['TEST_PHP_JUNIT']=str(xml)
        args=[str(php),'-n',str(source/'run-tests.php'),'-p',str(php),*options,'-q','--offline','--show-diff','--set-timeout','120','ext/com_dotnet/tests/bug64130.phpt']
        result=subprocess.run(args,cwd=source,env=env,capture_output=True,text=True,timeout=180)
        (report/(label+'.log')).write_text(result.stdout+result.stderr)
        tests=list(ET.parse(xml).getroot().iter('testcase')) if xml.exists() else []
        issues=[{'type':c.tag,'text':c.text} for t in tests for c in t if c.tag in ['failure','error','skipped']]
        rows.append({'cache':cache,'iteration':i,'exit':result.returncode,'tests':len(tests),'issues':issues,'passed':result.returncode==0 and len(tests)==1 and not issues})
result={'sourceSha':a.source_sha,'run':a.run_id,'variant':'x86-ts','archiveSha256':hashlib.sha256(archive.read_bytes()).hexdigest(),'phpSha256':hashlib.sha256(php.read_bytes()).hexdigest(),'comSha256':hashlib.sha256(com.read_bytes()).hexdigest(),'opcacheSha256':hashlib.sha256(opcache.read_bytes()).hexdigest(),'cases':rows}
(report/'summary.json').write_text(json.dumps(result,indent=2))
print(json.dumps({'cases':len(rows),'passed':sum(r['passed'] for r in rows)}),flush=True)
assert len(rows)==40 and all(r['passed'] for r in rows),'Inspect preserved COM diagnostic reports'
