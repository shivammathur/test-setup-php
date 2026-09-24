import hashlib, json, os, pathlib, subprocess, tempfile, time
version = os.environ['PHP_VERSION']
expected = json.loads(pathlib.Path('assets.json').read_text())[version]
repo = pathlib.Path('php-darwin').resolve()
with tempfile.TemporaryDirectory(prefix='php-darwin-install-profile-') as folder:
    root = pathlib.Path(folder)
    name = f'php_{version}-nts-release+darwin_x86_64.tar.zst'
    archive = root / name
    subprocess.run(['curl', '-fsSL', '--retry', '0', '--connect-timeout', '10', '--max-time', '60',
                    f'https://artifacts.php-darwin.setup-php.com/php-{version}/{expected["download"]}', '-o', str(archive)], check=True)
    assert hashlib.sha256(archive.read_bytes()).hexdigest() == expected['sha256']
    pathlib.Path(str(archive) + '.sha256').write_text(expected['sha256'] + '  ' + name + '\n')
    with (root / name.replace('.tar.zst', '.json')).open('w') as output:
        subprocess.run(['tar', '-xOf', str(archive), 'var/php-darwin/' + name.replace('.tar.zst', '.json')], stdout=output, check=True)
    env = {**os.environ, 'ARCH': 'x86_64', 'BUILD': 'release', 'TS': 'nts', 'ARCHIVE_DIR': str(root)}
    subprocess.run(['bash', 'scripts/test-install.sh', 'prepare'], cwd=repo, env=env, check=True)
    env['BASH_ENV'] = str(repo / 'scripts/trace-install-phases.sh')
    started = time.monotonic()
    with open('install.log', 'w') as log:
        process = subprocess.Popen(['bash', 'scripts/test-install.sh', 'install'], cwd=repo, env=env,
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        for line in process.stdout:
            print(line, end='', flush=True)
            log.write(line)
        code = process.wait()
    result = {'php': version, 'runner': os.environ.get('RUNNER_NAME'), 'installer_test_status': code,
              'test_seconds_including_preflight_and_preservation_check': time.monotonic() - started}
    result['runtime_status'] = subprocess.run(['bash', 'scripts/test-install.sh', 'runtime'], cwd=repo, env=env).returncode
    pathlib.Path('install-results.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result))
    raise SystemExit(code or result['runtime_status'])
