from pathlib import Path
import hashlib, json, os, subprocess, sys
E=os.environ
temp = Path(E['RUNNER_TEMP'])
stage = E['STAGE']
windows = E['RUNNER_OS'] == 'Windows'
mac = E['RUNNER_OS'] == 'macOS'
evidence = Path('evidence')
evidence.mkdir(exist_ok=True)
def digest(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()
def check(condition, message):
    if not condition: raise RuntimeError(message)
def read_seed():
    return json.loads((Path('seed')/'snapshot.json').read_text())
def extensions():
    return ['memcached'] if windows or mac else ['memcached','grpc','protobuf']
def dll(name):
    return 'php_'+name+'.dll' if windows else name+'.so'
def abi():
    return {'8.2':'20220829','8.3':'20230831','8.4':'20240924','8.5':'20250925'}[E['PHPV']]
def scoped():
    return Path(E['RUNNER_TOOL_CACHE'])/'deps'/(os.uname().machine+'-'+abi())
def request_rows():
    import csv
    rows=list(csv.reader((temp/(E['FAULT']+'.tsv')).read_text().splitlines(),delimiter='\t'))
    suite=next(s.split('=',1)[1].strip('"') for s in Path('/etc/os-release').read_text().splitlines() if s.startswith('VERSION_CODENAME='))
    arch=subprocess.check_output(['dpkg','--print-architecture'],text=True).strip()
    path=f'dists/{suite}/main/binary-{arch}/Packages.gz'
    check([r[0] for r in rows[:2]]==[root+'/'+path for root in ['https://packages.sury.org/php','https://ppa.setup-php.com/sury']], f'wrong index requests: {rows}')
    low=4.8 if E['FAULT']=='connect' else 14
    check(rows[0][1]=='28' and float(rows[0][3])>=low and rows[1][1:3]==['0','200'], str(rows))
    check(all(r[0].startswith('https://ppa.setup-php.com/sury/') and r[1:3]==['0','200'] for r in rows[2:]), str(rows))
    check(not any('xmlrpc' in r[0] or 'dbgsym' in r[0] for r in rows), str(rows))
    check(not (Path('/tmp/extcache/xml/xmlrpc')).exists(), 'xmlrpc registered as dependency of xml')
    debs=[r for r in rows if '/pool/' in r[0]]
    if stage=='warm':
        check(not any(any(name in row[0] for name in ['igbinary','msgpack']) for row in debs), 'warm dependency redownload')
    else:
        for dep in ['igbinary','msgpack']:
            check(any(dep in row[0] for row in debs), f'no real cold download for {dep}')
    print(f"{E['FAULT']} {rows[0][3]}s -> HTTP 200 in {rows[1][3]}s, {len(debs)} package downloads")
    (evidence/'requests.json').write_text(json.dumps(rows))
def deps():
    if windows:
        check(not (temp/'deps-dir').exists(),'Windows attempted Unix dependency preparation')
        return {}
    cache=Path((temp/'deps-dir').read_text())
    check(cache==scoped(),f'unexpected scoped path {cache}')
    files={p.relative_to(cache).as_posix():digest(p) for p in cache.rglob('*') if p.is_file() and not p.name.endswith('.tar')}
    for name in ['igbinary.so','msgpack.so']:
        check(name in files,f'missing {name} in {files.keys()}')
    if mac:
        manifest=cache/'memcached/list'
        libs=manifest.read_text().splitlines()
        check(libs and len(set(libs))==len(libs),'empty or duplicate Homebrew manifest')
        for lib in libs:
            archive=manifest.parent/(lib+'.tar.zst')
            subprocess.run(['zstd','-qt',str(archive)],check=True)
            with subprocess.Popen(['zstd','-dc',str(archive)],stdout=subprocess.PIPE) as unpack:
                members=subprocess.check_output(['tar','-tf','-'],stdin=unpack.stdout,text=True).splitlines()
                check(unpack.wait()==0,f'failed to unpack {archive}')
            check(bool(members) and all(m.split('/')[0]==lib for m in members),f'invalid archive {archive}')
        print('verified Homebrew archives:', ', '.join(libs))
    return files
def ext_hashes():
    extdir=Path(E['EXT_DIR'])
    return {name:digest(extdir/dll(name)) for name in extensions()}
command=sys.argv[1]
if command=='prepare':
    if not windows:
        check(not scoped().exists() or not any(scoped().iterdir()), 'dependency cache already populated before restore')
    if E['RUNNER_OS']=='Linux':
        api=Path('/usr/lib/php')/abi()
        for name in ['igbinary','msgpack']:
            src=api/dll(name)
            if src.exists() or src.is_symlink():
                subprocess.run(['sudo','mv',str(src),str(temp/('stock-'+src.name))],check=True)
elif command=='dependencies':
    if E['RUNNER_OS']=='Linux': request_rows()
    files=deps()
    (evidence/'dependencies.json').write_text(json.dumps(files,sort_keys=True))
    if stage=='warm':
        check(files==read_seed()['dependencies'], 'dependency cache differs from seed')
        # Prove restored modules came from the archive, even on pre-provisioned images.
        for name in extensions():
            p=Path(E['EXT_DIR'])/dll(name)
            if p.exists() or p.is_symlink():
                if windows: p.rename(temp/('stock-'+p.name))
                else: subprocess.run(['sudo','mv',str(p),str(temp/('stock-ext-'+p.name))],check=True)
elif command=='restored':
    seed=read_seed()
    check(E['CACHE_HIT']=='true' and E['CACHE_KEY']==seed['key'], 'no exact cache hit')
    check(ext_hashes()==seed['extensions'],'restored extension files differ before setup-php')
    print('Restored extension SHA-256:',ext_hashes())
elif command=='finish':
    info=dict(key=E['CACHE_KEY'],os=E['RUNNER_OS'],php=E['PHPV'],stage=stage,
              extensions=ext_hashes(),dependencies=json.loads((evidence/'dependencies.json').read_text()))
    (evidence/'snapshot.json').write_text(json.dumps(info,sort_keys=True,indent=2))
    print('Runtime extension SHA-256:', info['extensions'])
