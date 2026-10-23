import hashlib,json,pathlib,subprocess,sys,urllib.request,zipfile
root=pathlib.Path.cwd();vs='vs17' if sys.argv[1] in ['8.4','8.5'] else 'vs18'
folder=root/'libffi-sdk';folder.mkdir(exist_ok=True)
report=root/'reports';report.mkdir(exist_ok=True)
archive=folder/'libffi.zip'
if len(sys.argv)==2:
    url=f'https://downloads.php.net/~windows/php-sdk/deps/{vs}/x86/libffi-3.8.0-1-{vs}-x86.zip'
    with urllib.request.urlopen(url) as r:archive.write_bytes(r.read())
    with zipfile.ZipFile(archive) as z:
        assert z.testzip() is None
        assert all(not pathlib.PurePosixPath(p).is_absolute() and '..' not in pathlib.PurePosixPath(p).parts for p in z.namelist())
        z.extractall(folder)
    boms=list(folder.rglob('*.cdx.json'));assert len(boms)==1
    bom=json.loads(boms[0].read_text());component=bom['metadata']['component']
    assert component['version']=='3.8.0-1'
    (report/'libffi-sdk.json').write_text(json.dumps({'url':url,'sha256':hashlib.sha256(archive.read_bytes()).hexdigest(),'bom':bom},indent=2)+'\n')
else:
    headers=list(folder.rglob('ffi.h'));libs=list(folder.rglob('libffi.lib'));assert len(headers)==1 and len(libs)==1
    subprocess.run(['cl','/nologo','/Zi','/Od','/MD','/I'+str(headers[0].parent),'native/libffi-control.c',str(libs[0]),'/link','/out:libffi-control.exe'],check=True)
