import argparse,hashlib,json,pathlib
p=argparse.ArgumentParser();p.add_argument('--directory',required=True);p.add_argument('--vs',required=True);p.add_argument('--arch',required=True);p.add_argument('--php',required=True);p.add_argument('--report',required=True);a=p.parse_args()
root=pathlib.Path(a.directory)
manifest=json.loads(pathlib.Path('expected-hashes.json').read_text())
brotli=manifest[f'brotli-1.2.1-{a.vs}-{a.arch}']
files={}
for name in ['brotlicommon.dll','brotlidec.dll']:
    actual=hashlib.sha256((root/name).read_bytes()).hexdigest()
    assert actual==brotli['bin/'+name],('Wrong Brotli DLL',name)
    files[name]=actual
if a.php in ['8.6','master']:
    jxl=manifest[f'libjxl-0.12.0-{a.vs}-{a.arch}']
    for name in ['jxl.dll','jxl_cms.dll','jxl_threads.dll','brotlienc.dll']:
        if not (root/name).is_file():continue
        actual=hashlib.sha256((root/name).read_bytes()).hexdigest()
        expected=(brotli if name.startswith('brotli') else jxl)['bin/'+name]
        assert actual==expected,('Wrong JXL runtime DLL',name)
        files[name]=actual
bom=json.loads((root/'extras/sbom/php.cdx.json').read_text())
components=bom['components'];brotlis=[c for c in components if c.get('purl')=='pkg:generic/brotli@1.2.1']
assert len(brotlis)==1,'Expected one Winlibs Brotli 1.2.1 identity'
props={x['name']:x['value'] for x in brotlis[0].get('properties',[])}
assert props['php:source-commit']=='db24a98aed38a16de78cc05ca15cdd8dc2a0d92d'
curl_version='8.23.0-'+('1' if a.php in ['8.2','8.3','8.4'] else '2')
curls=[c for c in components if c.get('name')=='libcurl' and c.get('version')==curl_version]
assert len(curls)==1,'Wrong curl package variant'
curl_props={x['name']:x['value'] for x in curls[0].get('properties',[])}
assert curl_props['php:source-commit']=='43598272579250d20c3587d018bda5a2d5222f92'
if a.php in ['8.6','master']:
    jxls=[c for c in components if c.get('name')=='libjxl' and c.get('version')=='0.12.0']
    assert len(jxls)==1,'Missing selected libjxl identity'
    jp={x['name']:x['value'] for x in jxls[0].get('properties',[])}
    assert jp['php:source-commit']=='a7a9c787341cf703dede03c2009fa460cae5e5df'
deps={d['ref']:d.get('dependsOn',[]) for d in bom.get('dependencies',[])}
assert brotlis[0]['bom-ref'] in deps.get(curls[0]['bom-ref'],[]),'Missing curl -> Brotli dependency'
zips=[c for c in components if c.get('name')=='libzip' and c.get('version')=='1.12.1']
assert len(zips)==1,'Expected exactly one libzip 1.12.1 identity'
zp={p['name']:p['value'] for p in zips[0].get('properties',[])}
assert zp['php:source-commit']=='5cccb1bd6a8dc1349e2bddceab771acc4ae635dd','Wrong libzip source commit'
assert zips[0]['purl']=='pkg:generic/libzip@1.12.1'
pathlib.Path(a.report).write_text(json.dumps({'files':files,'brotli':brotlis[0],'curl':curls[0],'libzip':zips[0],'verified':True},indent=2))
print('PHP runtime DLL hashes, source identities and curl/Brotli dependency verified')
