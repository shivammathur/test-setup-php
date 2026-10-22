import hashlib, json, pathlib, re, subprocess, zipfile
root = pathlib.Path.cwd()
report = root / 'reports'
report.mkdir(exist_ok=True)
rows = []
for archive in sorted((root / 'artifacts').glob('*.zip')):
    match = re.fullmatch(r'php-(?!debug-pack-|devel-pack-|test-pack-).+?-(nts-)?Win32-v[sc]\d+-(x64|x86)\.zip', archive.name)
    if not match:
        continue
    variant = match[2] + '-' + ('nts' if match[1] else 'ts')
    target = root / 'runtime' / variant
    with zipfile.ZipFile(archive) as z:
        assert z.testzip() is None
        z.extractall(target)
    output = report / (variant + '.json')
    args = [str(target/'php.exe'), '-n', '-d', 'memory_limit=128M', '-d', 'extension_dir='+str(target/'ext'), '-d', 'extension=zip', str(root/'tests/zip-password-diagnostics.php'), str(output)]
    process = subprocess.run(args, capture_output=True, text=True, timeout=240)
    rows.append({'variant': variant, 'archive': archive.name,
                 'archiveSha256': hashlib.sha256(archive.read_bytes()).hexdigest(),
                 'phpSha256': hashlib.sha256((target/'php.exe').read_bytes()).hexdigest(),
                 'zipSha256': hashlib.sha256((target/'ext/php_zip.dll').read_bytes()).hexdigest(),
                 'exit': process.returncode, 'stdout': process.stdout, 'stderr': process.stderr})
    (report/'provenance.json').write_text(json.dumps(rows, indent=2))
    print(variant, process.returncode, process.stdout, process.stderr, flush=True)
assert len(rows) == 4 and all(r['exit'] == 0 for r in rows)
