"""Check the exact published Homebrew bottle and its unmodified runtime."""
import json
import os
from pathlib import Path
import subprocess
import sys

output = Path('results')
output.mkdir(exist_ok=True)
formula = os.environ['FORMULA']
tag = os.environ['EXPECTED_TAG']
expected = next(r for r in json.loads(Path('expected.json').read_text())['releases'] if r['formula'] == formula)
report = {'formula': formula, 'expected_package': expected['package'], 'expected_tag': tag,
          'commit': os.environ.get('GITHUB_SHA'), 'run_id': os.environ.get('GITHUB_RUN_ID'),
          'attempt': os.environ.get('GITHUB_RUN_ATTEMPT'), 'checks': {}}


def save():
    (output / 'installation.json').write_text(json.dumps(report, indent=2) + '\n')


def run(name, arguments, timeout=120):
    result = subprocess.run(arguments, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
    (output / (name + '.log')).write_text(result.stdout)
    (output / (name + '.stderr.log')).write_text(result.stderr)
    print(result.stdout, end='', flush=True)
    print(result.stderr, end='', file=sys.stderr, flush=True)
    report['checks'][name] = {'exit_code': result.returncode, 'command': arguments}
    save()
    if result.returncode:
        raise RuntimeError(name + ' failed')
    return result.stdout.strip()


try:
    qualified = 'shivammathur/php/' + formula
    prefix = Path(run('prefix', ['brew', '--prefix', qualified]))
    info = json.loads(run('brew-info', ['brew', 'info', '--json=v2', qualified]))['formulae'][0]
    assert info['name'] == formula and info['versions']['stable'] == expected['version']
    assert info['revision'] == expected['revision']
    assert info['bottle']['stable']['rebuild'] == expected['rebuild']
    assert info['bottle']['stable']['files'][tag]['sha256'] == expected['bottles'][tag]
    installed = [i for i in info['installed'] if i['version'] == expected['package']]
    assert len(installed) == 1 and installed[0]['poured_from_bottle'], installed
    receipt = json.loads((prefix / 'INSTALL_RECEIPT.json').read_text())
    assert receipt['source']['tap'] == 'shivammathur/php' and receipt['poured_from_bottle'] is True
    assert prefix.resolve().name == expected['package']
    actual_tag = run('bottle-tag', ['brew', 'ruby', '-e', 'require "utils/bottles"; puts Utils::Bottles.tag'])
    assert actual_tag == tag, (actual_tag, tag)
    report['receipt'] = receipt
    report['resolved_prefix'] = str(prefix.resolve())
    brew_prefix = Path(run('brew-prefix', ['brew', '--prefix']))
    suffix = '' if expected['variant'] == 'normal' else '-' + expected['variant']
    config = brew_prefix / 'etc/php' / (expected['series'] + suffix)
    required = ['php.ini', 'php-fpm.conf']
    if expected['series'] != '5.6':
        required.append('php-fpm.d/www.conf')
    for name in required:
        assert (config / name).is_file() and (config / name).stat().st_size > 0, str(config / name)
    report['configuration_files'] = [str(config / name) for name in required]
    php = str(prefix / 'bin/php')
    debug = int(expected['debug'] == 'true')
    zts = int(expected['phpts'] == 'ts')
    code = (
        'if (PHP_VERSION !== ' + json.dumps(expected['version']) + ' || (int)PHP_DEBUG !== ' + str(debug) +
        ' || (int)PHP_ZTS !== ' + str(zts) + ') { fwrite(STDERR, "wrong build"); exit(1); } '
        '$ldap = ldap_connect(); if (!is_resource($ldap) && !is_object($ldap)) { exit(2); } '
        'foreach (array("ldap", "openssl", "curl", "mbstring", "mysqli", "pdo_mysql", "xml", "zip") as $module) '
        '{ if (!extension_loaded($module)) { fwrite(STDERR, $module); exit(3); } } '
        'echo json_encode(array("version"=>PHP_VERSION,"debug"=>PHP_DEBUG,"zts"=>PHP_ZTS,"ldap"=>is_object($ldap)?get_class($ldap):get_resource_type($ldap))), PHP_EOL;'
    )
    run('runtime-clean', [php, '-n', '-r', code])
    run('runtime-default', [php, '-r', code])
    run('modules', [php, '-m'])
    loaded = run('loaded-ini', [php, '-r', 'echo php_ini_loaded_file();'])
    assert Path(loaded).resolve() == (config / 'php.ini').resolve(), loaded
    run('cgi', [str(prefix / 'bin/php-cgi'), '-n', '-v'])
    run('fpm', [str(prefix / 'sbin/php-fpm'), '-n', '-t'])
    run('linkage', ['brew', 'linkage', '--test', qualified])
    report['result'] = 'passed'
except Exception as error:
    report['result'] = 'failed'
    report['error'] = str(error)
    raise
finally:
    save()
