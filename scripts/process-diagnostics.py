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

p=argparse.ArgumentParser()
p.add_argument('--run-id',required=True)
p.add_argument('--source-sha',required=True)
p.add_argument('--kind',choices=['proc','cgi','cli','soap','openssl'],required=True)
a=p.parse_args()
workspace=pathlib.Path.cwd()
source=workspace/'php-src'
reports=workspace/'reports/process-diagnostics'
reports.mkdir(parents=True,exist_ok=True)
assert subprocess.check_output(['git','rev-parse','HEAD'],cwd=source,text=True).strip()==a.source_sha
pattern=re.compile(r'^php-(?!debug-pack-|devel-pack-|test-pack-).+?-(nts-)?Win32-(v[sc]\d+)-(x64|x86)\.zip$')
rows=[]
for archive in sorted((workspace/'artifacts').glob('*.zip')):
    m=pattern.match(archive.name)
    if not m:continue
    variant=m[3]+'-'+('nts' if m[1] else 'ts')
    out=reports/variant;out.mkdir(exist_ok=True)
    runtime=pathlib.Path(os.environ['RUNNER_TEMP'])/a.run_id/archive.stem
    php=runtime/'php.exe';cgi=runtime/'php-cgi.exe'
    assert php.is_file() and cgi.is_file()
    empty=out/'empty.ini';empty.write_text('[PHP]\ndate.timezone=UTC\n')
    env=os.environ.copy()
    for key in ['TEST_PHP_ARGS','TEST_PHP_EXTRA_ARGS','REDIRECT_STATUS','QUERY_STRING','PATH_TRANSLATED','SCRIPT_FILENAME','SERVER_SOFTWARE','SERVER_NAME','GATEWAY_INTERFACE','REQUEST_METHOD']:
        env.pop(key,None)
    env.update(PATH=str(runtime)+os.pathsep+env['PATH'],PHPRC=str(empty),PHP_INI_SCAN_DIR=str(out/'no-extra-ini'),
        TEST_PHP_EXECUTABLE=str(php),TEST_PHP_CGI_EXECUTABLE=str(cgi),SKIP_IO_CAPTURE_TESTS='1',NO_INTERACTION='1',REPORT_EXIT_STATUS='1')
    imports={exe:closure(runtime,exe) for exe in ['php.exe','php-cgi.exe']}
    if a.kind in ['soap','openssl']:imports['php_'+a.kind+'.dll']=closure(runtime/'ext','php_'+a.kind+'.dll')
    assert not any('php_zip' in dll or 'libzip' in dll for graph in imports.values() for deps in graph.values() for dll in deps)
    (out/'imports.json').write_text(json.dumps(imports,indent=2))
    modules=subprocess.run([str(php),'-m'],env=env,capture_output=True,text=True,check=True)
    assert not re.search(r'^(zip|curl|gd|brotli)$',modules.stdout,re.M)
    (out/'child-modules.txt').write_text(modules.stdout+modules.stderr)
    if a.kind in ['soap','openssl']:
        modules=subprocess.run([str(php),'-n','-d','extension_dir='+str(runtime/'ext'),'-d','extension=php_'+a.kind+'.dll','-m'],env=env,capture_output=True,text=True,check=True)
        assert re.search(r'^'+a.kind+'$',modules.stdout,re.M) and not re.search(r'^(zip|curl|gd|brotli)$',modules.stdout,re.M)
        (out/(a.kind+'-modules.txt')).write_text(modules.stdout+modules.stderr)
    cases=[]
    selection={'proc':['ext/standard/tests/general_functions/proc_open_sockets3.phpt'],
        'cgi':['sapi/cgi/tests/002.phpt'],
        'cli':['sapi/cli/tests/bug67429_1.phpt','sapi/cli/tests/php_cli_server_019.phpt','sapi/cli/tests/bug71005.phpt'],
        'soap':['ext/soap/tests/gh23686/header-from-stringable.phpt','ext/soap/tests/gh23686/schema-authorization-digest.phpt'],
        'openssl':['ext/openssl/tests/openssl_cms_sign_verify_nodetached_pem.phpt','ext/openssl/tests/openssl_cms_sign_verify_detached.phpt']}[a.kind]
    test=','.join(selection)
    count=100 if a.kind=='proc' and variant=='x64-nts' else 20
    if a.kind=='openssl':
        count=40
        # Newer PHP includes OPcache in the runtime; only load a DLL when absent.
        opcache_args=[] if re.search(r'^Zend OPcache$',modules.stdout,re.M) else ['-d','zend_extension='+(runtime/'ext/php_opcache.dll').as_posix()]
        opcache_args+=['-d','opcache.enable=1','-d','opcache.enable_cli=1']
        cache_modules=subprocess.run([str(php),'-n','-d','extension_dir='+str(runtime/'ext'),'-d','extension=php_openssl.dll',*opcache_args,'-m'],env=env,capture_output=True,text=True,check=True)
        assert not cache_modules.stderr and 'Zend OPcache' in cache_modules.stdout and not re.search(r'^(zip|curl|gd|brotli)$',cache_modules.stdout,re.M)
        (out/'openssl-opcache-modules.txt').write_text(cache_modules.stdout+cache_modules.stderr)
        modes=[]
        for enabled,options in [(False,['-d','opcache.enable_cli=0']),(True,opcache_args)]:
            probe=subprocess.run([str(php),'-n',*options,'-r','echo json_encode(["loaded"=>extension_loaded("Zend OPcache"),"enabled"=>opcache_get_status(false)!==false]);'],env=env,capture_output=True,text=True,check=True)
            result=json.loads(probe.stdout)
            assert not probe.stderr and result['loaded'] and result['enabled']==enabled
            modes.append({'requestedEnabled':enabled,'actual':result,'stderr':probe.stderr})
        (out/'opcache-modes.json').write_text(json.dumps(modes,indent=2))
    for iteration in range(count):
        xml=out/f'case-{iteration}.xml';env['TEST_PHP_JUNIT']=str(xml)
        cache_enabled=a.kind=='openssl' and iteration>=20
        cache_options=opcache_args if cache_enabled else ['-d','opcache.enable_cli=0'] if a.kind=='openssl' else []
        command=[str(php),'-n',str(source/'run-tests.php'),'-p',str(php),'-n','-d','extension_dir='+str(runtime/'ext'),*cache_options,'-q','--offline','--show-diff','--set-timeout','30',*selection]
        result=subprocess.run(command,cwd=source,env=env,capture_output=True,text=True,timeout=90)
        (out/f'case-{iteration}.log').write_text(result.stdout+result.stderr)
        tests=list(ET.parse(xml).getroot().iter('testcase')) if xml.exists() else []
        errors=[{'test':t.attrib.get('name'),'type':c.tag,'text':c.text} for t in tests for c in t if c.tag in ['failure','error','skipped']]
        ok=result.returncode==0 and len(tests)==len(selection) and not errors
        cases.append({'iteration':iteration,'exit':result.returncode,'testCount':len(tests),'ok':ok,'errors':errors,'opcache':cache_enabled})
    direct=[]
    if a.kind=='cgi':
        script=out/'ini-probe.php';script.write_text('<?php var_dump(ini_get("max_execution_time")); ?>')
        def launch(i):
            result=subprocess.run([str(cgi),'-n','-d','max_execution_time=111',str(script)],env=env,capture_output=True,text=True,timeout=30)
            return {'iteration':i,'exit':result.returncode,'stdout':result.stdout,'stderr':result.stderr,
                'ok':result.returncode==0 and 'string(3) "111"' in result.stdout and not result.stderr}
        with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:direct=list(pool.map(launch,range(100)))
        (out/'direct-cgi.json').write_text(json.dumps(direct,indent=2))
    row={'variant':variant,'sourceSha':a.source_sha,'phpSha256':hashlib.sha256(php.read_bytes()).hexdigest(),
        'cgiSha256':hashlib.sha256(cgi.read_bytes()).hexdigest(),'libzipLoaded':False,'test':test,'cases':cases,
        'directCgiCount':len(direct),'directCgiFailures':sum(not x['ok'] for x in direct),'failedCases':sum(not x['ok'] for x in cases)}
    rows.append(row)
    if a.kind in ['soap','openssl']:row[a.kind+'Sha256']=hashlib.sha256((runtime/('ext/php_'+a.kind+'.dll')).read_bytes()).hexdigest()
    (reports/'summary.json').write_text(json.dumps(rows,indent=2))
    print(json.dumps({k:row[k] for k in ['variant','test','failedCases','directCgiCount','directCgiFailures','libzipLoaded']}),flush=True)
assert len(rows)==4
if any(r['failedCases'] or r['directCgiFailures'] for r in rows):
    raise SystemExit('The original process failures reproduced without libzip; diagnostic evidence retained')
