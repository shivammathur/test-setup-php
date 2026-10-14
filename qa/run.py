import os,json,pathlib,zipfile,subprocess,re,hashlib
root=pathlib.Path('C:/pr11669-jit');root.mkdir(exist_ok=True)
results=pathlib.Path('results');results.mkdir(exist_ok=True)
arch=os.environ['ARCH'];run=os.environ['BUILD_RUN'];branch=os.environ['BRANCH']
archives=[p for p in pathlib.Path('artifacts').glob('*.zip') if re.match(r'^php-\d.+-Win32-v[sc]\d+-'+arch+r'\.zip$',p.name) and '-nts-' not in p.name]
assert len(archives)==1,archives
runtime=root/'php'
with zipfile.ZipFile(archives[0]) as z:z.extractall(runtime)
cache=root/'file-cache';cache.mkdir(exist_ok=True)
scan=root/'empty-scan';scan.mkdir(exist_ok=True)
ini=runtime/'php.ini';ini.write_text('extension_dir="'+str(runtime/'ext')+'"\n'+'opcache.enable_cli=0\n')
env=os.environ.copy();env.update(PHPRC=str(ini),PHP_INI_SCAN_DIR=str(scan))
args=['-d','opcache.enable=1','-d','opcache.enable_cli=1','-d','opcache.jit_buffer_size=64M','-d','opcache.jit=tracing','-d','opcache.protect_memory=1','-d','opcache.file_update_protection=0','-d','opcache.revalidate_freq=0','-d','opcache.file_cache='+str(cache),'-d','opcache.jit_hot_func=1','-d','opcache.jit_hot_loop=1','-d','opcache.jit_hot_return=1','-d','opcache.jit_hot_side_exit=1','-d','output_buffering=0']
variants=['baseline','no-parent-jit','no-parent-opcache','unique-child-cache','no-file-cache','no-child-file-cache','function-jit','no-child-jit','inline']
summary=[]
for variant in variants:
 child=list(args)
 if variant=='no-file-cache':child+=['-d','opcache.file_cache=']
 if variant=='function-jit':child+=['-d','opcache.jit=function']
 parent=child+['-d','opcache.cache_id=diagnose-'+variant]
 if variant=='no-parent-jit':parent+=['-d','opcache.jit_buffer_size=0','-d','opcache.jit=disable']
 if variant=='no-parent-opcache':parent+=['-d','opcache.enable_cli=0']
 conf=root/(variant+'.json');conf.write_text(json.dumps(child))
 with (results/(variant+'.log')).open('wb') as f:
  p=subprocess.run([str(runtime/'php.exe'),*parent,str(pathlib.Path('qa/probe.php').resolve()),variant,str(conf)],env=env,stdout=f,stderr=subprocess.STDOUT,timeout=120)
 log=(results/(variant+'.log')).read_text(errors='replace')
 children=[json.loads(x) for x in re.findall(r'^RESULT (.*)$',log,re.M)]
 crashes=[{**c,'exit_hex':f'{c["exit"] & 0xffffffff:08X}'} for c in children if c['exit']!=0]
 record={'variant':variant,'exit':p.returncode,'children':len(children),'crashes':crashes}
 summary.append(record)
 (results/'summary.json').write_text(json.dumps({'branch':branch,'arch':arch,'build_run':run,'archive':archives[0].name,'sha256':hashlib.sha256(archives[0].read_bytes()).hexdigest(),'cases':summary},indent=2))
 print(json.dumps({'variant':variant,'exit':p.returncode,'children':len(children),'crashes':len(crashes)}),flush=True)
 assert p.returncode==0 and len(children)==32,record
