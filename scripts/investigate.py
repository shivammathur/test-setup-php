import argparse
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
import zipfile

p=argparse.ArgumentParser()
p.add_argument('--php',required=True);p.add_argument('--run-id',required=True);p.add_argument('--source-sha',required=True)
p.add_argument('--focus',action='store_true')
p.add_argument('--ffi-style',action='store_true')
a=p.parse_args()
assert sys.flags.utf8_mode, 'Run with PYTHONUTF8=1 for portable source and debugger evidence'
workspace=Path.cwd();source=workspace/'php-src';reports=workspace/'reports';reports.mkdir(exist_ok=True)
assert subprocess.check_output(['git','rev-parse','HEAD'],cwd=source,text=True).strip()==a.source_sha
expected=json.loads((workspace/'expected.json').read_text())[a.php]
pattern=re.compile(r'^php-(?!debug-pack-|devel-pack-|test-pack-).+?-(nts-)?Win32-(v[sc]\d+)-(x64|x86)\.zip$')
rows=[]

def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def save(path,value):path.write_text(json.dumps(value,indent=2)+'\n')
def execute(command,env,cwd,timeout=90):
    start=time.monotonic()
    try:
        r=subprocess.run([str(c) for c in command],env=env,cwd=cwd,capture_output=True,timeout=timeout)
        def decode(b):
            try:return b.decode('utf-8')
            except UnicodeDecodeError:return b.decode('cp1252',errors='replace')
        return {'command':[str(c) for c in command],'exit':r.returncode,'exitHex':hex(r.returncode & 0xffffffff),'stdout':decode(r.stdout),'stderr':decode(r.stderr),'seconds':time.monotonic()-start}
    except subprocess.TimeoutExpired as e:
        return {'command':[str(c) for c in command],'timeout':True,'stdout':(e.stdout or b'').decode(errors='replace') if isinstance(e.stdout,bytes) else e.stdout,'stderr':(e.stderr or b'').decode(errors='replace') if isinstance(e.stderr,bytes) else e.stderr,'seconds':time.monotonic()-start}

for archive in sorted((workspace/'artifacts').glob('*.zip')):
    m=pattern.match(archive.name)
    if not m:continue
    assert sha(archive)==expected[archive.name],archive.name
    arch=m[3];ts='nts' if m[1] else 'ts';variant=arch+'-'+ts
    out=reports/variant;out.mkdir(exist_ok=True)
    runtime=Path(os.environ['RUNNER_TEMP'])/'source-failure-investigation'/variant;runtime.mkdir(parents=True,exist_ok=True)
    with zipfile.ZipFile(archive) as z:z.extractall(runtime)
    symbols=runtime/'symbols';symbols.mkdir(exist_ok=True)
    packs=[f for f in (workspace/'artifacts').glob('php-debug-pack-*.zip') if ('-nts-Win32-' in f.name)==(ts=='nts') and f.name.endswith('-'+arch+'.zip')]
    assert len(packs)==1,packs
    assert sha(packs[0])==expected[packs[0].name]
    with zipfile.ZipFile(packs[0]) as z:z.extractall(symbols)
    php=runtime/'php.exe'
    env=os.environ.copy()
    for key in ['TEST_PHP_ARGS','TEST_PHP_EXTRA_ARGS','TEST_PHP_JUNIT','PHPRC','PHP_INI_SCAN_DIR']:env.pop(key,None)
    empty=out/'empty.ini';empty.write_text('[PHP]\ndate.timezone=UTC\n')
    env.update(PATH=str(runtime)+os.pathsep+env['PATH'],PHPRC=str(empty),PHP_INI_SCAN_DIR=str(out/'no-ini-scan'),TEST_PHP_EXECUTABLE=str(php),NO_INTERACTION='1',REPORT_EXIT_STATUS='1',SKIP_IO_CAPTURE_TESTS='1')
    row={'php':a.php,'variant':variant,'sourceSha':a.source_sha,'sourceRun':a.run_id,'archive':archive.name,'archiveSha256':sha(archive),'debugPackSha256':sha(packs[0]),'phpSha256':sha(php),'ffiSha256':sha(runtime/'ext/php_ffi.dll'),'cases':[]}
    modules=execute([php,'-n','-m'],env,source);save(out/'modules.json',modules)
    assert modules['exit']==0 and not modules['stderr']
    opcache=[] if re.search(r'^Zend OPcache$',modules['stdout'],re.M) else ['-d','zend_extension='+(runtime/'ext/php_opcache.dll').as_posix()]
    cache_on=[*opcache,'-d','opcache.enable=1','-d','opcache.enable_cli=1'];cache_off=['-d','opcache.enable_cli=0']
    ini=out/'php-test.ini';ini.write_text('memory_limit=-1\nextension_dir="'+str(runtime/'ext')+'"\n')
    def phpt(label,test,extra):
        xml=out/(label+'.xml');testenv=env.copy();testenv['TEST_PHP_JUNIT']=str(xml)
        r=execute([php,'-n',source/'run-tests.php','-p',php,'-n','-d','extension_dir='+str(runtime/'ext'),'-q','--offline','--show-diff',*extra,test],testenv,source)
        save(out/(label+'.json'),r)
        cases=list(ET.parse(xml).getroot().iter('testcase')) if xml.exists() else []
        assert len(cases)==1,(label,r)
        errors=[{'test':t.attrib.get('name'),'type':c.tag,'detail':c.text} for t in cases for c in t if c.tag in ['failure','error','skipped']]
        result={'label':label,'exit':r.get('exit'),'testCount':len(cases),'issues':errors}
        row['cases'].append(result)
        print(a.php,variant,label,result['exit'],len(errors),flush=True)
        return result
    if a.focus:
        from deep_probe import run
        run(a,workspace,source,reports,out,runtime,symbols,php,arch,variant,env,execute,save,cache_on,cache_off)
        rows.append(row);save(reports/'summary.json',rows)
        continue
    original=source/'ext/standard/tests/ini_info/php_ini_loaded_file.phpt'
    fixed=original.with_name('php_ini_loaded_file-isolated.phpt')
    text=original.read_text();assert 'passthru("$php $args -n -r $code");' in text
    fixed.write_text(text.replace('passthru("$php $args -n -r $code");','passthru("$php -n -r $code");'))
    for mode,cache in [('nocache',cache_off),('opcache',cache_on)]:
        probe=execute([php,'-n',*cache,'-r','echo json_encode(["loaded"=>extension_loaded("Zend OPcache"),"enabled"=>function_exists("opcache_get_status") && opcache_get_status(false)!==false]);'],env,source)
        save(out/(mode+'-probe.json'),probe)
        assert probe['exit']==0 and not probe['stderr'] and json.loads(probe['stdout'])['enabled']==(mode=='opcache')
        phpt('ini-original-'+mode,original,['-c',str(ini),*cache])
        phpt('ini-isolated-'+mode,fixed,['-c',str(ini),*cache])
    ffi_test=source/'ext/standard/tests/general_functions/sleep_alertable_win32.phpt'
    for mode,cache in [('nocache',cache_off),('opcache',cache_on)]:phpt('ffi-original-'+mode,ffi_test,cache)
    body=ffi_test.read_text().split('--FILE--\n',1)[1].split('\n--EXPECT',1)[0]
    original_script=out/'ffi-original.php';original_script.write_text(body)
    no_sleep=out/'ffi-no-inner-sleep.php';no_sleep.write_text(body.replace('usleep(300000);','/* No nested alertable wait in callback. */'))
    ffi_options=['-d','extension_dir='+str(runtime/'ext'),'-d','extension=php_ffi.dll','-d','ffi.enable=1']
    no_sleep_result=execute([php,'-n',*ffi_options,no_sleep],env,source);save(out/'ffi-no-inner-sleep.json',no_sleep_result)
    cc='__stdcall' if arch=='x86' else ''
    native=out/'ffi-native-control.php'
    native.write_text('''<?php
$ffi=FFI::cdef("typedef void (CALLCONV *CB)(uintptr_t); unsigned int invoke_stdcall(CB cb); unsigned int native_apc_control(void);", LIBPATH);
echo "native APC: ";var_dump($ffi->native_apc_control());
$storage=$ffi->new('CB[1]');$called=0;
$storage[0]=static function(int $data) use (&$called):void { echo "callback: $data\\n";$called=$data; };
echo "calling native stdcall invoker\\n";
var_dump($ffi->invoke_stdcall($storage[0]));var_dump($called);
'''.replace('CALLCONV',cc).replace('LIBPATH',json.dumps((workspace/('callback-'+arch+'.dll')).as_posix())))
    native_result=execute([php,'-n',*ffi_options,native],env,source);save(out/'ffi-native-control.json',native_result)
    if arch=='x86':
        native_ffi=[]
        for mode in ['stdcall-void','cdecl-void','stdcall-int']:
            native_ffi.append({'mode':mode,**execute([workspace/'libffi-control.exe',mode],env,source)})
        save(out/'native-libffi.json',native_ffi)
    def debugger(label,script,options,children=False,timeout=180):
        cdb=Path(os.environ['CDB_ROOT'])/arch/'cdb.exe'
        stack='@esp' if arch=='x86' else '@rsp';ip='@eip' if arch=='x86' else '@rip'
        dump=(out/(label+'.dmp')).as_posix()
        commands='sxi ibp; sxd -c2 ".echo CAPTURED_SECOND_CHANCE_AV; .lastevent; .ecxr; r; ln '+ip+'; u '+ip+'-20 '+ip+'+40; kv 60; dps '+stack+' L80; lmv m php*; .dump /m '+dump+'; q" av; g'
        symbol_dirs=[symbols]+[p for p in symbols.rglob('*') if p.is_dir()]
        symbol_path=';'.join(str(p) for p in symbol_dirs)+';srv*'+str(out/'symbol-cache')+'*https://msdl.microsoft.com/download/symbols'
        r=execute([cdb,'-G',*(['-o'] if children else []),'-y',symbol_path,'-c',commands,php,'-n',*options,script],env,source,timeout)
        save(out/(label+'-debugger.json'),r)
        (out/(label+'-debugger.txt')).write_text((r.get('stdout') or '')+(r.get('stderr') or ''))
    if arch=='x86':
        debugger('ffi-original',original_script,ffi_options)
        if native_result.get('exit')!=0:debugger('ffi-native-control',native,ffi_options)
    if a.php=='8.4' and arch=='x86':
        for mode,cache in [('nocache',cache_off),('opcache',cache_on)]:
            r=execute([php,'-n',*cache,'-d','extension_dir='+str(runtime/'ext'),'-d','extension=php_com_dotnet.dll',workspace/'scripts/com-probe.php'],env,source,240)
            save(out/('com-activation-pairs-'+mode+'.json'),r)
    if a.php=='master':
        server=workspace/'scripts/server-probe.php'
        server_result=execute([php,'-n',*cache_off,server,'300'],env,source,240)
        save(out/'server-startup.json',server_result)
        # Capture a second-chance child-process crash while retaining original exit evidence.
        debug_server=out/'server-debugger.php'
        debug_server.write_text(server.read_text().replace('(int)$argv[1]','300'))
        debugger('server-startup',debug_server,cache_off,children=True,timeout=240)
        # Keep test filenames and fixtures local to each child to avoid introducing concurrent PHPT file races.
        cms=[]
        for test in ['openssl_cms_sign_verify_detached','openssl_cms_sign_verify_nodetached_pem']:
            original_file=source/'ext/openssl/tests'/(test+'.phpt')
            php_body=original_file.read_text().split('--FILE--\n',1)[1].split('\n--EXPECT',1)[0]
            # Errors are evidence, never suppressed or retried. Record OpenSSL's error queue too.
            handler='''
set_error_handler(static function($severity,$message,$file,$line) {
    $errors=[];while($error=openssl_error_string()) $errors[]=$error;
    fwrite(STDERR,json_encode(['severity'=>$severity,'message'=>$message,'file'=>$file,'line'=>$line,'opensslErrors'=>$errors])."\\n");
    return false;
});
'''
            # Trace the reserved name and every file operation to detect overlapping ownership.
            php_body=php_body.replace('$vout= $outfile . ".vout";', '$vout= $outfile . ".vout";\nfwrite(STDERR, json_encode(["event"=>"allocated","pid"=>getmypid(),"time"=>microtime(true),"path"=>$outfile])."\\n");')
            for slot in range(6):
                script=original_file.with_name(test+'-diagnostic-'+str(slot)+'.php')
                script.write_text(php_body.replace('<?php','<?php'+handler,1));cms.append((test,script))
        def cms_run(task):
            test,script,iteration=task;enabled=iteration%2==1
            r=execute([php,'-n','-d','extension_dir='+str(runtime/'ext'),'-d','extension=php_openssl.dll',*(cache_on if enabled else cache_off),script],env,source,45)
            # Detached S/MIME errors at the end are expected; all earlier operations must remain true.
            main=(r.get('stdout') or '').split('S/MIME Detached (an error):')[0]
            unexpected='Warning:' in main or 'Fatal error:' in main or 'bool(false)' in main or r.get('exit')!=0
            return {'test':test,'iteration':iteration,'opcache':enabled,'unexpected':unexpected,**r}
        # One task per filename at a time; each worker owns its filename for all repetitions.
        def cms_slot(pair):return [cms_run((*pair,i)) for i in range(30)]
        with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
            cms_results=[r for batch in pool.map(cms_slot,cms) for r in batch]
        save(out/'cms-stress.json',cms_results)
        # An A/B control reserves a unique per-process directory for the entire test lifetime.
        private_cms=[]
        for test,script in cms:
            private=script.with_name(script.stem+'-private.php')
            original_text=script.read_text()
            private_text=original_text.replace('$outfile = tempnam(sys_get_temp_dir(), "ssl");', '$privateDir = sys_get_temp_dir()."/cms-".getmypid()."-".bin2hex(random_bytes(8));\nif (!mkdir($privateDir)) { throw new Exception("mkdir failed"); }\nregister_shutdown_function(static function() use ($privateDir) { foreach (glob($privateDir."/*") as $file) { @unlink($file); } @rmdir($privateDir); });\n$outfile = tempnam($privateDir, "ssl");')
            assert private_text!=original_text
            private.write_text(private_text);private_cms.append((test,private))
        with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
            private_results=[r for batch in pool.map(cms_slot,private_cms) for r in batch]
        save(out/'cms-private-directory.json',private_results)
    rows.append(row);save(reports/'summary.json',rows)
    print('FINISHED',a.php,variant,flush=True)
assert len(rows)==4
print('Diagnostic capture complete. Expected baseline failures are retained in reports; workflow success does not mean the original tests passed.')
