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
zlibs=[c for c in components if c.get('name')=='zlib' and c.get('purl','').startswith('pkg:generic/zlib@')]
inherited_zlibs=[c for c in components if c.get('name')=='zlib' and c not in zlibs]
assert len(zlibs)==1 and zlibs[0]['version']=='1.3.2-1','Wrong zlib build identity'
zp={p['name']:p['value'] for p in zlibs[0].get('properties',[])}
assert zp['php:source-commit']=='838fe0e338adb28f5662e5ac332b0f0eb96ba93a'
# phpsdk_sbom.php normalizes resolved_with_pedigree to resolved for Dependency-Track.
assert any(v['id']=='CVE-2026-85091' and v.get('analysis',{}).get('state')=='resolved' and any(x['ref']==zlibs[0]['bom-ref'] for x in v.get('affects',[])) for v in bom.get('vulnerabilities',[])), 'Missing fixed zlib CVE claim'
vex=json.loads((root/'extras/sbom/php.openvex.json').read_text())
assert any(v['vulnerability']['name']=='CVE-2026-85091' and v['status']=='fixed' and any(p['@id']==zlibs[0]['bom-ref'] for p in v['products']) for v in vex['statements']), 'Missing fixed zlib OpenVEX statement'
apache_evidence=None
if f'apache-2.4.69-{a.vs}-{a.arch}' in manifest:
    apaches=[c for c in components if c.get('name')=='apache']
    assert len(apaches)==1 and apaches[0]['version']=='2.4.69', 'Wrong Apache SDK identity'
    private_zlibs=[c for c in inherited_zlibs if c.get('purl','').startswith('pkg:vcpkg/zlib@')]
    assert len(private_zlibs)==2 and all(c['version']=='1.3.2-winlibs.1' for c in private_zlibs), 'Unpatched Apache zlib identity'
    assert {c['purl'].split('triplet=')[1].split('&')[0] for c in private_zlibs}=={a.arch+'-windows',a.arch+'-windows-static-md'}
    for c in private_zlibs:
        cp={p['name']:p['value'] for p in c['properties']}
        assert cp['php:source-commit']=='838fe0e338adb28f5662e5ac332b0f0eb96ba93a'
        assert c['bom-ref'] in deps[apaches[0]['bom-ref']], 'Missing Apache -> private zlib dependency'
        assert any(v['id']=='CVE-2026-85091' and v.get('analysis',{}).get('state')=='resolved' and any(x['ref']==c['bom-ref'] for x in v.get('affects',[])) for v in bom['vulnerabilities']), 'Missing fixed Apache zlib CDX claim'
        assert any(v['vulnerability']['name']=='CVE-2026-85091' and v['status']=='fixed' and any(p['@id']==c['bom-ref'] for p in v['products']) for v in vex['statements']), 'Missing fixed Apache zlib OpenVEX statement'
    private_brotlis=[c for c in components if c.get('purl','').startswith('pkg:vcpkg/brotli@')]
    assert len(private_brotlis)==1 and private_brotlis[0]['version']=='1.2.1', 'Wrong Apache Brotli version'
    apache_evidence={'apache':apaches[0],'zlib':private_zlibs,'brotli':private_brotlis[0]}
glibs=[c for c in components if c.get('name')=='glib']
assert len(glibs)==1 and glibs[0]['version']=='2.90.1', 'Wrong GLib identity'
gp={p['name']:p['value'] for p in glibs[0].get('properties',[])}
assert gp['php:source-commit']=='3d33aa2203f1686cb7ff8ff63c707855c019b5b1', 'Wrong retagged GLib source'
for name in ['libcurl', 'libzip', 'libpng', 'glib']:
    matches=[c for c in components if c.get('name')==name]
    assert len(matches)==1, (name,'missing or duplicate')
    assert zlibs[0]['bom-ref'] in deps.get(matches[0]['bom-ref'],[]), (name,'missing zlib dependency')
for artifact, entries in manifest.items():
    if not artifact.endswith('-'+a.vs+'-'+a.arch): continue
    if not artifact.startswith(('glib-', 'libenchant2-', 'libpng-', 'libssh2-', 'libtiff-')): continue
    ssh_revision = '9' if a.php in ['8.2','8.3','8.4'] else '10' if a.php=='8.5' else '11'
    if artifact.startswith('libssh2-') and not artifact.startswith('libssh2-1.11.1-'+ssh_revision+'-'): continue
    for path,digest in entries.items():
        if path.startswith('bin/') and path.endswith('.dll') and (root/pathlib.Path(path).name).is_file():
            actual=hashlib.sha256((root/pathlib.Path(path).name).read_bytes()).hexdigest()
            assert actual==digest, ('Wrong runtime DLL',artifact,path)
            files[pathlib.Path(path).name]=actual
pathlib.Path(a.report).write_text(json.dumps({'files':files,'brotli':brotlis[0],'curl':curls[0],'libzip':zips[0],'zlib':zlibs[0],'inheritedZlibIdentities':inherited_zlibs,'glib':glibs[0],**({'apache':apache_evidence} if apache_evidence else {}),'verified':True},indent=2))
print('PHP runtime DLL hashes, source identities and curl/Brotli dependency verified')
