import json,os,re
from pathlib import Path

def run(a,workspace,source,reports,out,runtime,symbols,php,arch,variant,env,execute,save,cache_on,cache_off):
    if a.ffi_style:
        import xml.etree.ElementTree as ET
        original=source/'ext/standard/tests/general_functions/sleep_alertable_win32.phpt'
        content=original.read_text()
        modified=content.replace('($callconv *PAPCFUNC)', '$callconv (*PAPCFUNC)').replace('($callconv *GetCurrentThread_t)', '$callconv (*GetCurrentThread_t)').replace('($callconv *QueueUserAPC_t)', '$callconv (*QueueUserAPC_t)').replace('($callconv *SleepEx_t)', '$callconv (*SleepEx_t)')
        assert modified!=content and modified.count('$callconv (*')==4
        test=original.with_name('sleep_alertable_win32-abi-isolated.phpt');test.write_text(modified)
        results=[]
        for mode,cache in [('nocache',cache_off),('opcache',cache_on)]:
            xml=out/('ffi-abi-isolated-'+mode+'.xml');e=env.copy();e['TEST_PHP_JUNIT']=str(xml)
            options=['-n','-d','extension_dir='+str(runtime/'ext'),'-q','--offline','--show-diff',*cache,test]
            result=execute([php,'-n',source/'run-tests.php','-p',php,*options],e,source)
            save(out/('ffi-abi-isolated-'+mode+'.json'),result)
            cases=list(ET.parse(xml).getroot().iter('testcase')) if xml.exists() else []
            assert len(cases)==1,(variant,mode,result)
            results.append({'mode':mode,'exit':result.get('exit'),'issues':[c.tag for t in cases for c in t if c.tag in ('failure','error','skipped')]})
        save(out/'ffi-abi-isolated-summary.json',results)
        print(a.php,variant,'ffi-style',results,flush=True)
        return
    cdb=Path(os.environ['CDB_ROOT'])/arch/'cdb.exe'
    dirs=[workspace,symbols]+[p for p in symbols.rglob('*') if p.is_dir()]
    symbol_path=';'.join(map(str,dirs))+';srv*'+str(out/'symbol-cache')+'*https://msdl.microsoft.com/download/symbols'
    stack='@esp' if arch=='x86' else '@rsp'
    def debug(label,script,options,extra='',children=False,timeout=360):
        dump=(out/(label+'.dmp')).as_posix()
        commands='sxi ibp; sxd -c2 ".echo CAPTURED_SECOND_CHANCE_AV; .lastevent; r; kv 50; dps '+stack+' L30; lmv m php*; .dump /m '+dump+'; q" av; '+extra+' g'
        r=execute([cdb,'-G',*(['-o'] if children else []),'-y',symbol_path,'-c',commands,php,'-n',*options,script],env,source,timeout)
        save(out/(label+'.json'),r)
        (out/(label+'.txt')).write_text(r.get('stdout','')+r.get('stderr',''))
        print(a.php,variant,label,r.get('exit'),r.get('timeout'),flush=True)
    if arch=='x86':
        opts=['-d','extension_dir='+str(runtime/'ext'),'-d','extension=php_ffi.dll','-d','ffi.enable=1']
        for cc in ['stdcall','cdecl']:
            p=out/('ffi-'+cc+'.php')
            p.write_text('''<?php
$f=FFI::cdef("typedef void (__CALLCONV *CB)(uintptr_t); unsigned int invoke_CALLCONV(CB cb);", LIBPATH);
$c=$f->new('CB[1]');$c[0]=static function(int $x):void {echo "callback $x\\n";};
var_dump($f->invoke_CALLCONV($c[0]));echo "RETURNED\\n";
'''.replace('CALLCONV',cc).replace('LIBPATH',json.dumps((workspace/'callback-x86.dll').as_posix())))
            r=execute([php,'-n',*opts,p],env,source);save(out/('ffi-'+cc+'-plain.json'),r)
            # Use a command file to avoid nested command quoting at breakpoint creation.
            entry=out/'inner-entry.cdb';entry.write_text('.echo INNER_ENTRY\nr\ndd @ecx La\ndd poi(@ecx+1c) L6\nbp /1 poi(@esp) ".echo INNER_RETURN; r; dd @esp L10; gc"\ngc\n')
            cb=out/'callback-entry.cdb';cb.write_text('.echo PHP_CALLBACK_ENTRY\nr\ndd @esp L8\nbp /1 poi(@esp) ".echo PHP_CALLBACK_RETURN; r; dd @esp L8; gc"\ngc\n')
            traces='bu php_ffi!ffi_closure_STDCALL ".echo STDCALL_ENTRY; r; dd @esp L10; gc"; bu php_ffi!ffi_closure_inner "$$><'+entry.as_posix()+'"; bu php_ffi!zend_ffi_callback_trampoline "$$><'+cb.as_posix()+'";'
            debug('ffi-'+cc+'-trace',p,opts,traces)
    if a.php=='master':
        # Child processes execute the exact CMS body, with a private directory and no error handler.
        test=source/'ext/openssl/tests/openssl_cms_sign_verify_detached.phpt'
        body=test.read_text().split('--FILE--\n',1)[1].split('\n--EXPECT',1)[0]
        body=body.replace('$outfile = tempnam(sys_get_temp_dir(), "ssl");', '$dir=sys_get_temp_dir()."/cms-".getmypid()."-".bin2hex(random_bytes(8));mkdir($dir);register_shutdown_function(static function() use($dir){foreach(glob($dir."/*") as $p)@unlink($p);@rmdir($dir);});$outfile=tempnam($dir,"ssl");')
        child=test.with_name('cms-startup-probe.php');child.write_text(body)
        parent=out/'parallel-startup.php'
        template=(workspace/'scripts/parallel-startup.php').read_text()
        command=[str(php),'-n','-d','extension_dir='+str(runtime/'ext'),'-d','extension=php_openssl.dll',*cache_on,str(child)]
        parent.write_text(template.replace('COMMAND_JSON',json.dumps(json.dumps(command))).replace('RESULT_JSON',json.dumps((out/'parallel-startup-results.json').as_posix())))
        debug('opcache-startup',parent,cache_off,children=True,timeout=360)
