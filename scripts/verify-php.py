import argparse,hashlib,json,pathlib
p=argparse.ArgumentParser()
for option in ['directory','vs','arch','php','report']:p.add_argument('--'+option,required=True)
a=p.parse_args();root=pathlib.Path(a.directory)
manifest=json.loads(pathlib.Path('expected-hashes.json').read_text())
expected=json.loads(pathlib.Path('expected-components.json').read_text())[a.php][a.arch]
bom=json.loads((root/'extras/sbom/php.cdx.json').read_text())
components=bom['components'];deps={d['ref']:d.get('dependsOn',[]) for d in bom['dependencies']}
verified=[];files={}
for item in expected:
    wanted=item['component'];purl=wanted['purl']
    matches=[c for c in components if c.get('name')==wanted['name'] and c.get('purl')==purl]
    assert len(matches)==1,(wanted['name'],'missing or duplicate',matches)
    c=matches[0];assert c['version']==wanted['version'],(wanted['name'],'wrong package variant')
    props={p['name']:p['value'] for p in c.get('properties',[])}
    want={p['name']:p['value'] for p in wanted.get('properties',[])}
    for key in ['php:source-commit','php:arch','php:vs']:
        if key in want:assert props.get(key)==want[key],(wanted['name'],key,props,want)
    for rel,digest in manifest[item['artifact']].items():
        if not rel.startswith('bin/') or not rel.endswith('.dll'):continue
        binary=root/pathlib.Path(rel).name
        if binary.exists():
            actual=hashlib.sha256(binary.read_bytes()).hexdigest()
            assert actual==digest,('Wrong runtime DLL',item['artifact'],rel)
            files[binary.name]=actual
    verified.append(c)
zlibs=[c for c in components if c['name']=='zlib']
assert len(zlibs)==3 and {c['version'] for c in zlibs}=={'1.4'},('Stale/duplicate zlib identities',zlibs)
for z in zlibs:
    props={p['name']:p['value'] for p in z.get('properties',[])}
    assert props['php:source-commit']=='cf7eb981cf4fce56a88608c68fd3f255a2c452c9'
sdk=next(c for c in zlibs if c['purl']=='pkg:generic/zlib@1.4')
private=[c for c in zlibs if c['purl'].startswith('pkg:vcpkg/zlib@1.4?')]
assert len(private)==2 and {c['purl'].split('triplet=')[1].split('&')[0] for c in private}=={a.arch+'-windows',a.arch+'-windows-static-md'}
apache=next(c for c in verified if c['name']=='apache')
assert all(c['bom-ref'] in deps[apache['bom-ref']] for c in private)
for name in ['libcurl','libzip','libpng','glib','libssh2']:
    cs=[c for c in verified if c['name']==name];assert len(cs)==1
    assert sdk['bom-ref'] in deps.get(cs[0]['bom-ref'],[]),(name,'Missing zlib dependency')
assert all(c['bom-ref'] in deps for c in components),'Incomplete SBOM graph'
pathlib.Path(a.report).write_text(json.dumps({'verified':True,'files':files,'components':verified,'zlib':zlibs},indent=2))
print('Exact candidate package identities, runtime DLL hashes, and all three zlib 1.4 identities verified')
