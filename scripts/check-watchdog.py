import json
import os
import signal
import subprocess
import sys
import tempfile
import time
import traceback
from pathlib import Path

source = Path(sys.argv[1]).resolve()
output = Path(sys.argv[2]).resolve()
output.mkdir(parents=True, exist_ok=True)
brew = (source / 'src/scripts/tools/brew.sh').read_text()
darwin = (source / 'src/scripts/darwin.sh').read_text().split('\n# Variables\n')[0]
fixture = Path(__file__).with_name('build-fixture.py').resolve()
records = []


def alive(pid):
    state = subprocess.run(['ps', '-p', str(pid), '-o', 'stat='], capture_output=True, text=True)
    return state.returncode == 0 and not state.stdout.strip().startswith('Z')


def check(name, script, expected=0, env=None, verify=None):
    started = time.monotonic()
    record = {'name': name, 'expected_status': expected}
    with tempfile.TemporaryDirectory(prefix='brew-regression-') as directory:
        root = Path(directory)
        build = root / 'Homebrew/build.rb'
        build.parent.mkdir()
        build.symlink_to(fixture)
        environment = {
            **os.environ,
            'TEST_ROOT': str(root), 'TEST_PYTHON': sys.executable,
            'TEST_FIXTURE': str(fixture), 'TEST_BUILD_SCRIPT': str(build),
            'TEST_BUILD_STDIO': 'ignore', 'TEST_BUILD_DURATION': '',
            'TEST_AFTER_BUILD_DELAY': '0',
            'SETUP_PHP_BREW_WATCHDOG': 'true',
            'SETUP_PHP_BREW_INACTIVITY_TIMEOUT': '2',
            'SETUP_PHP_BREW_SOURCE_INACTIVITY_TIMEOUT': '2',
            'SETUP_PHP_BREW_WATCHDOG_POLL': '0.1',
            'SETUP_PHP_BREW_RETRY_ATTEMPTS': '3',
            **(env or {}),
        }
        process = subprocess.Popen(['/bin/bash', '-c', brew + '\n' + script],
                                   env=environment, text=True, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, start_new_session=True)
        try:
            stdout, stderr = process.communicate(timeout=45)
            record.update(status=process.returncode, stdout=stdout, stderr=stderr)
            assert process.returncode == expected, record
            if verify:
                verify(root, stdout, stderr)
            pids = [int(pid) for pid in (root / 'pids').read_text().splitlines()] if (root / 'pids').exists() else []
            record['process_count'] = len(pids)
            record['surviving_processes'] = [pid for pid in pids if alive(pid)]
            assert not record['surviving_processes'], record
            assert not (root / 'overlap').exists(), 'A retry overlapped the previous build'
            record['passed'] = True
        except Exception as error:
            record['passed'] = False
            record['error'] = str(error)
            record['traceback'] = traceback.format_exc()
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
            if (root / 'pids').exists():
                for pid in reversed((root / 'pids').read_text().splitlines()):
                    try:
                        os.kill(int(pid), signal.SIGKILL)
                    except ProcessLookupError:
                        pass
            if process.stdout and not process.stdout.closed:
                stdout, stderr = process.communicate()
                record.setdefault('stdout', stdout)
                record.setdefault('stderr', stderr)
    record['duration_seconds'] = round(time.monotonic() - started, 2)
    records.append(record)
    (output / (name + '.json')).write_text(json.dumps(record, indent=2) + '\n')
    print(('PASS' if record['passed'] else 'FAIL') + ' ' + name, flush=True)
    if not record['passed']:
        print(record.get('error'), flush=True)


def require(condition, message):
    assert condition, message


def expect_attempts(count):
    def verify(root, stdout, stderr):
        require((root / 'attempts').read_text().splitlines() == ['attempt'] * count, 'Wrong attempt count')
        require(stderr.count('retrying brew command') == count - 1, stderr)
        require('attempt 4' not in stderr, stderr)
    return verify


retry = '''
brew() { "$TEST_PYTHON" "$TEST_FIXTURE"; }
sleep() { case "$1" in 5|10) return 0;; *) command sleep "$@";; esac; }
'''
for stream in ['ignore', 'inherit']:
    check('tree-' + stream, 'run_with_inactivity_watchdog "$TEST_PYTHON" "$TEST_FIXTURE"', 124,
          {'TEST_BUILD_STDIO': stream},
          lambda root, out, err: require(len((root / 'pids').read_text().splitlines()) == 3 and 'retrying' not in err, err))
check('retry-limit', retry + '\nsafe_brew install php@8.4', 124, verify=expect_attempts(3))
check('recover-after-timeout', retry + '''
brew() {
  if [ -f "$TEST_ROOT/attempts" ]; then echo recovered; else "$TEST_PYTHON" "$TEST_FIXTURE"; fi
}
safe_brew install php@8.4
''', verify=lambda root, out, err: require('recovered' in out and err.count('retrying brew command') == 1, out + err))
check('ordinary-failure-recovery', retry + '''
brew() { if [ -f "$TEST_ROOT/failed" ]; then printf recovered; else touch "$TEST_ROOT/failed"; return 37; fi; }
safe_brew install php@8.4
''', verify=lambda root, out, err: require(out == 'recovered' and 'attempt 2/3, exit 37' in err, out + err))
check('watchdog-opt-out', 'brew() { printf disabled; return 37; }; safe_brew install php@8.4', 37,
      {'SETUP_PHP_BREW_WATCHDOG': 'false'},
      lambda root, out, err: require(out == 'disabled' and err == '', out + err))
for status in [0, 37]:
    check('output-status-' + str(status),
          "run_with_inactivity_watchdog bash -c 'printf out; printf err >&2; exit " + str(status) + "'", status,
          verify=lambda root, out, err: require(out == 'out' and err == 'err', out + err))
for stream in ['stdout', 'stderr']:
    check('partial-' + stream,
          '''run_with_inactivity_watchdog "$TEST_PYTHON" -c 'import sys,time
for _ in range(30):
 sys.''' + stream + '''.write("."); sys.''' + stream + '''.flush(); time.sleep(0.1)
' ''', verify=lambda root, out, err, stream=stream: require((out if stream == 'stdout' else err) == '.' * 30, out + err))
for timeout in ['', '6']:
    check('quiet-source-' + (timeout or 'default'),
          'run_with_inactivity_watchdog "$TEST_PYTHON" "$TEST_FIXTURE"',
          env={'TEST_BUILD_DURATION': '3.5', 'SETUP_PHP_BREW_SOURCE_INACTIVITY_TIMEOUT': timeout},
          verify=lambda root, out, err: require((root / 'built').exists() and 'terminating' not in err, out + err))
check('source-timeout', 'run_with_inactivity_watchdog "$TEST_PYTHON" "$TEST_FIXTURE"', 124,
      {'SETUP_PHP_BREW_SOURCE_INACTIVITY_TIMEOUT': '3'},
      lambda root, out, err: require('no output for 3s' in err, err))
check('bottle-timeout', 'run_with_inactivity_watchdog "$TEST_PYTHON" -c "import time; time.sleep(10)"', 124,
      {'SETUP_PHP_BREW_SOURCE_INACTIVITY_TIMEOUT': '6'},
      lambda root, out, err: require('no output for 2s' in err, err))
check('restore-bottle-timeout', 'run_with_inactivity_watchdog "$TEST_PYTHON" "$TEST_FIXTURE"', 124,
      {'SETUP_PHP_BREW_SOURCE_INACTIVITY_TIMEOUT': '6', 'TEST_BUILD_DURATION': '3.5', 'TEST_AFTER_BUILD_DELAY': '8'},
      lambda root, out, err: require((root / 'built').exists() and 'no output for 2s' in err, err))

install_init = darwin + '''
version=8.4 debug=release ts=nts runner=self-hosted
update_dependencies() { :; }
add_brew_tap() { :; }
'''
check('php-install-retry-limit', install_init + retry + '''
brew() {
  printf '%s\\n' "$*" >> "$TEST_ROOT/commands"
  case "$*" in
    *--only-dependencies*) return 0;;
    install*) "$TEST_PYTHON" "$TEST_FIXTURE";;
    *) return 0;;
  esac
}
add_php install false
''', 124, verify=lambda root, out, err: require(
    (root / 'commands').read_text().splitlines() == ['install --only-dependencies shivammathur/php/php@8.4'] +
    ['install --skip-link -f --overwrite shivammathur/php/php@8.4'] * 3,
    (root / 'commands').read_text()))

for action, dependency, install, upgrade, status, calls in [
    ('install', 124, 0, 0, 124, 1), ('install', 37, 0, 0, 37, 1),
    ('install', 0, 124, 0, 124, 2), ('install', 0, 37, 124, 124, 3),
    ('install', 0, 37, 37, 37, 3), ('upgrade', 124, 0, 0, 124, 1),
    ('upgrade', 0, 0, 124, 124, 2), ('upgrade', 0, 0, 37, 37, 2),
]:
    script = install_init + '''
safe_brew() {
  printf 'brew %s\\n' "$*"
  case "$*" in
    *--only-dependencies*) return "$TEST_DEPENDENCY_STATUS";;
    install*) return "$TEST_INSTALL_STATUS";;
    upgrade*) return "$TEST_UPGRADE_STATUS";;
  esac
}
brew() { echo "unexpected $*"; }
add_php "$TEST_ACTION" "$TEST_EXISTING_VERSION"
'''
    check(f'propagate-{action}-{dependency}-{install}-{upgrade}', script, status, {
        'TEST_ACTION': action, 'TEST_EXISTING_VERSION': '8.4.10' if action == 'upgrade' else 'false',
        'TEST_DEPENDENCY_STATUS': str(dependency), 'TEST_INSTALL_STATUS': str(install),
        'TEST_UPGRADE_STATUS': str(upgrade),
    }, lambda root, out, err, calls=calls: require(len(out.splitlines()) == calls and 'unexpected' not in out, out))

check('ordinary-install-upgrade-fallback', install_init + '''
safe_brew() { echo "brew $*"; case "$*" in install*--skip-link*) return 1;; esac; return 0; }
brew() { echo "brew $*"; }
add_php install false
''', verify=lambda root, out, err: require('brew upgrade -f --overwrite shivammathur/php/php@8.4' in out and
                                         'brew link --force --overwrite php@8.4' in out, out))
summary = {'source_commit': subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip(),
           'passed': sum(row['passed'] for row in records), 'total': len(records), 'checks': records}
(output / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
print(f"{summary['passed']}/{summary['total']} passed", flush=True)
sys.exit(0 if summary['passed'] == summary['total'] else 1)
