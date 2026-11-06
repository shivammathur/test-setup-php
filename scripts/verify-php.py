import argparse,hashlib,json,pathlib
p=argparse.ArgumentParser()
for option in ['directory','vs','arch','php','report']:p.add_argument('--'+option,required=True)
a=p.parse_args();root=pathlib.Path(a.directory)
manifest=json.loads(pathlib.Path('expected-hashes.json').read_text())
expected=json.loads(pathlib.Path('expected-components.json').read_text())[a.php][a.arch]
bom=json.loads((root/'extras/sbom/php.cdx.json').read_text())
components=bom['components'];deps={d['ref']:d.get('dependsOn',[]) for d in bom['dependencies']}
php_ref=bom['metadata']['component']['bom-ref']
verified=[];files={}
for item in expected:
    wanted=item['component'];purl=wanted['purl']
    matches=[c for c in components if c.get('bom-ref')==wanted['bom-ref'] and c.get('name')==wanted['name'] and c.get('purl')==purl]
    assert len(matches)==1,(wanted['name'],'missing or duplicate',matches)
    c=matches[0];assert c['version']==wanted['version'],(wanted['name'],'wrong package variant')
    assert c['bom-ref'] in deps[php_ref],(wanted['name'],'not a direct PHP dependency')
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
assert len(zlibs)==3,('Unexpected zlib identities',zlibs)
sdk=next(c for c in zlibs if c['purl']=='pkg:generic/zlib@1.4')
assert {p['name']:p['value'] for p in sdk.get('properties',[])}['php:source-commit']=='cf7eb981cf4fce56a88608c68fd3f255a2c452c9'
private=[c for c in zlibs if c['purl'].startswith('pkg:vcpkg/zlib@')]
assert len(private)==2 and {c['purl'].split('triplet=')[1].split('&')[0] for c in private}=={a.arch+'-windows',a.arch+'-windows-static-md'}
baseline=next(item['privateZlib'] for item in expected if item['component']['name']=='apache')
for wanted in baseline:
    matches=[c for c in private if c['purl']==wanted['purl']]
    assert len(matches)==1 and matches[0]['version']==wanted['version'],'Deferred Apache package changed'
    actual={p['name']:p['value'] for p in matches[0].get('properties',[])}
    original={p['name']:p['value'] for p in wanted.get('properties',[])}
    for key,value in original.items():
        assert actual.get(key)==value,('Deferred Apache zlib provenance changed',key)
apache=next(c for c in verified if c['name']=='apache')
assert all(c['bom-ref'] in deps[apache['bom-ref']] for c in private)
for name in ['libcurl','libzip','libpng','glib','libssh2']:
    cs=[c for c in verified if c['name']==name];assert len(cs)==1
    assert sdk['bom-ref'] in deps.get(cs[0]['bom-ref'],[]),(name,'Missing zlib dependency')
component_refs={c['bom-ref'] for c in components}
assert len(component_refs)==len(components),'Duplicate SBOM identity'
assert all(ref in component_refs or ref==php_ref for ref in deps),'Unknown dependency node'
assert all(ref in component_refs for refs in deps.values() for ref in refs),'Unresolved dependency edge'
reachable=set();pending=[php_ref]
while pending:
    ref=pending.pop()
    if ref in reachable:continue
    reachable.add(ref);pending.extend(deps.get(ref,[]))
# Deferred Apache ships an existing disconnected vcpkg inventory. Require it unchanged.
apache_artifact=next(item['artifact'] for item in expected if item['component']['name']=='apache')
original_disconnected=json.loads(pathlib.Path('expected-apache-disconnected.json').read_text())[apache_artifact]
actual_disconnected={c['bom-ref']:c for c in components if c['bom-ref'] not in reachable}
assert actual_disconnected==original_disconnected,'New or changed disconnected SBOM component'
assert all(c['bom-ref'] in deps for c in verified),'Missing package dependency graph'
pathlib.Path(a.report).write_text(json.dumps({'verified':True,'files':files,'components':verified,'zlib':zlibs},indent=2))
print('Exact candidate package identities, runtime DLL hashes, zlib 1.4, and unchanged Apache private zlib verified')
