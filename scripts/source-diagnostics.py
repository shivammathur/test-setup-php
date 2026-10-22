import argparse
import concurrent.futures
import hashlib
import json
import os
import pathlib
import re
import subprocess
import xml.etree.ElementTree as ET
from pe_imports import closure

p=argparse.ArgumentParser();p.add_argument('--run-id',required=True);p.add_argument('--source-sha',required=True);p.add_argument('--mode',choices=['full','soap'],default='full');a=p.parse_args()
workspace=pathlib.Path.cwd();source=workspace/'php-src';reports=workspace/'reports/source-diagnostics';reports.mkdir(parents=True,exist_ok=True)
assert subprocess.check_output(['git','rev-parse','HEAD'],cwd=source,text=True).strip()==a.source_sha
pattern=re.compile(r'^php-(?!debug-pack-|devel-pack-|test-pack-).+?-(nts-)?Win32-(v[sc]\d+)-(x64|x86)\.zip$')
rows=[];failed=False
for archive in sorted((workspace/'artifacts').glob('*.zip')):
    m=pattern.match(archive.name)
    if not m:continue
    variant=m[3]+'-'+('nts' if m[1] else 'ts');out=reports/variant;out.mkdir(exist_ok=True)
    runtime=pathlib.Path(os.environ['RUNNER_TEMP'])/a.run_id/archive.stem
    php=runtime/'php.exe';cgi=runtime/'php-cgi.exe'
    assert php.is_file() and cgi.is_file()
    if a.mode=='soap':
        env=os.environ.copy();env.update(PATH=str(runtime)+os.pathsep+env['PATH'],TEST_PHP_EXECUTABLE=str(php),TEST_PHP_CGI_EXECUTABLE=str(cgi),SKIP_IO_CAPTURE_TESTS='1',NO_INTERACTION='1',REPORT_EXIT_STATUS='1')
        deps=closure(runtime,'php.exe')
        assert not any('brotli' in x or 'curl' in x for names in deps.values() for x in names)
        soap_deps=closure(runtime/'ext','php_soap.dll')
        assert not any('brotli' in x or 'curl' in x for names in soap_deps.values() for x in names)
        modules=subprocess.run([str(php),'-n','-d','extension='+str(runtime/'ext/php_soap.dll'),'-m'],env=env,capture_output=True,text=True,check=True).stdout
        assert re.search(r'^soap$',modules,re.M) and not re.search(r'^(curl|brotli)$',modules,re.M)
        (out/'soap-modules.txt').write_text(modules);(out/'soap-imports.json').write_text(json.dumps({'php':deps,'soap':soap_deps},indent=2))
        cases=[]
        for iteration in range(20):
            xml=out/f'soap-{iteration}.xml';env['TEST_PHP_JUNIT']=str(xml)
            args=[str(php),'-n',str(source/'run-tests.php'),'-p',str(php),'-n','-d','extension_dir='+str(runtime/'ext'),'-q','--offline','--show-diff','--set-timeout','120','ext/soap/tests/content_type_header_injection.phpt']
            result=subprocess.run(args,cwd=source,env=env,capture_output=True,text=True,timeout=180)
            (out/f'soap-{iteration}.log').write_text(result.stdout+result.stderr)
            tests=list(ET.parse(xml).getroot().iter('testcase')) if xml.exists() else []
            errors=[{'name':t.attrib['name'],'details':c.text} for t in tests for c in t if c.tag in ['failure','error']]
            ok=result.returncode==0 and len(tests)==1 and not errors and not any(c.tag=='skipped' for t in tests for c in t)
            cases.append({'iteration':iteration,'exit':result.returncode,'ok':ok,'failures':errors});failed|=not ok
        row={'variant':variant,'sourceSha':a.source_sha,'phpSha256':hashlib.sha256(php.read_bytes()).hexdigest(),'soapCases':cases}
        rows.append(row);print(json.dumps(row),flush=True);continue
    deps=closure(runtime,'php-cgi.exe')
    assert not any('brotli' in x or 'curl' in x for names in deps.values() for x in names),deps
    (out/'cgi-imports.json').write_text(json.dumps(deps,indent=2))
    env=os.environ.copy();env.update(PATH=str(runtime)+os.pathsep+env['PATH'],TEST_PHP_EXECUTABLE=str(php),TEST_PHP_CGI_EXECUTABLE=str(cgi),TEST_PHPDBG_EXECUTABLE=str(runtime/'phpdbg.exe'),SKIP_IO_CAPTURE_TESTS='1',NO_INTERACTION='1',REPORT_EXIT_STATUS='1')
    modules=subprocess.run([str(cgi),'-n','-m'],env=env,capture_output=True,text=True,check=True).stdout
    assert not re.search(r'^(curl|brotli)$',modules,re.M)
    (out/'cgi-modules.txt').write_text(modules)
    cases=[]
    for iteration in range(11):
        xml=out/('suite.xml' if iteration==0 else f'repeat-{iteration}.xml')
        env['TEST_PHP_JUNIT']=str(xml)
        selection=['sapi/cgi/tests'] if iteration==0 else ['sapi/cgi/tests/004.phpt','sapi/cgi/tests/010.phpt','sapi/cgi/tests/011.phpt']
        args=[str(php),'-n',str(source/'run-tests.php'),'-p',str(php),'-n','-q','--offline','--no-progress','--show-diff','--set-timeout','120','-g','FAIL,BORK,WARN,LEAK']
        if iteration==0:args.append('-j6')
        args.extend(selection)
        run=subprocess.run(args,cwd=source,env=env,capture_output=True,text=True,timeout=600)
        (out/(xml.stem+'.log')).write_text(run.stdout+run.stderr)
        tests=list(ET.parse(xml).getroot().iter('testcase')) if xml.exists() else []
        failures=[t.attrib for t in tests if any(c.tag in ['failure','error'] for c in t)]
        ok=run.returncode==0 and bool(tests) and not failures
        cases.append({'iteration':iteration,'selection':selection,'tests':len(tests),'exit':run.returncode,'failures':failures,'ok':ok});failed|=not ok
    script=out/'header-remove.php';script.write_text('<?php header_remove(""); ?>')
    def direct(i):
        r=subprocess.run([str(cgi),'-n','-dreport_zend_debug=0','-dhtml_errors=0',str(script)],env=env,capture_output=True,text=True,timeout=30)
        ok=r.returncode==0 and 'X-Powered-By: PHP/' in r.stdout and 'Content-type: text/html; charset=UTF-8' in r.stdout and not r.stderr
        return {'iteration':i,'exit':r.returncode,'stdout':r.stdout,'stderr':r.stderr,'ok':ok}
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:direct_rows=list(pool.map(direct,range(100)))
    (out/'direct-processes.json').write_text(json.dumps(direct_rows,indent=2));failed|=not all(x['ok'] for x in direct_rows)
    ini=out/'php-test.ini';ini.write_text('memory_limit=-1\nextension_dir="'+str(runtime/'ext')+'"\n')
    def focused(label,test,custom_ini=False):
        xml=out/(label+'.xml');env['TEST_PHP_JUNIT']=str(xml)
        cmd=[str(php),'-n',str(source/'run-tests.php'),'-p',str(php),'-n','-d','extension_dir='+str(runtime/'ext'),'-q','--offline','--show-diff','--set-timeout','120']
        if custom_ini:cmd+=['-c',str(ini)]
        cmd.append(str(test))
        run=subprocess.run(cmd,cwd=source,env=env,capture_output=True,text=True,timeout=180)
        (out/(label+'.log')).write_text(run.stdout+run.stderr)
        tests=list(ET.parse(xml).getroot().iter('testcase')) if xml.exists() else []
        return {'label':label,'exit':run.returncode,'tests':len(tests),'passed':bool(tests) and all(not any(c.tag in ['failure','error','skipped'] for c in t) for t in tests),'failures':[t.attrib for t in tests if any(c.tag in ['failure','error'] for c in t)]}
    ini_test=source/'ext/standard/tests/ini_info/php_ini_loaded_file.phpt'
    ini_results=[focused('ini-with-inherited-config',ini_test,True),focused('ini-without-inherited-config',ini_test)]
    failed|=not ini_results[1]['passed']
    ffi_test=source/'ext/standard/tests/general_functions/sleep_alertable_win32.phpt'
    ffi_results=[]
    if ffi_test.exists():
        ffi_results.append(focused('apc-original-callback',ffi_test))
        held=out/'sleep_alertable_held_callback.phpt'
        text=ffi_test.read_text()
        assert text.count('$QueueUserAPC($callback,')==3
        text=text.replace('echo "usleep()\\n";', '$callbackStorage = $ffi->new("PAPCFUNC[1]");\n$callbackStorage[0] = $callback;\n\necho "usleep()\\n";')
        text=text.replace('$QueueUserAPC($callback,','$QueueUserAPC($callbackStorage[0],')
        held.write_text(text)
        ffi_results.append(focused('apc-held-callback',held))
        failed|=not ffi_results[1]['passed']
        ffi_imports=closure(runtime/'ext','php_ffi.dll')
        assert not any('brotli' in x or 'curl' in x for names in ffi_imports.values() for x in names)
        (out/'ffi-imports.json').write_text(json.dumps(ffi_imports,indent=2))
    row={'variant':variant,'sourceSha':a.source_sha,'phpSha256':hashlib.sha256(php.read_bytes()).hexdigest(),'cgiSha256':hashlib.sha256(cgi.read_bytes()).hexdigest(),'suiteAndRepeats':cases,'directProcessCount':len(direct_rows),'directProcessFailures':sum(not x['ok'] for x in direct_rows),'iniDiagnostics':ini_results,'ffiDiagnostics':ffi_results}
    rows.append(row);print(json.dumps(row),flush=True)
(reports/'summary.json').write_text(json.dumps(rows,indent=2))
assert len(rows)==4 and not failed,'Source diagnostic failures; inspect retained evidence'
