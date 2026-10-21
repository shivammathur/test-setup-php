"""One disposable runner per host VM. Never forward parent workflow credentials."""
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.request

VERSION = '2.338.0'
ARCHES = {
    'x64': ('ubuntu-24.04', 'af4b794c1bc41d73d40535e3fe092a39f9679cd8d965954c2aca25a05ca41d32'),
    'arm64': ('ubuntu-24.04-arm', '628b4a7258487b80c1d3c221095a7ded349f5ae0175fd3dfab708d07428f041b'),
}
MAC_ARCHES = {
    'x64': 'dea7a58796ce215fc424a8b27c0fdd9b813fa5fc03d109a4a1d38131d6bfa1a3',
    'arm64': 'df4cebda25c86a886ed204e49fee63f5c2e7cec5f447b5c98440a826bbdf9df2',
}
UBUNTU_VERSIONS = {
    'linux': '24.04',
    'ubuntu-22.04': '22.04',
    'ubuntu-24.04': '24.04',
    'ubuntu-26.04': '26.04',
    # Fail closed if GitHub migrates this alias to another OS version.
    'ubuntu-latest': '24.04',
}
MAC_ARM_PROFILES = {
    'macos-26': ('macos-26', []),
    'macos-15-arm64': ('macos-15', []),
    'macos-26-arm': ('macos-26', ['macos-26-arm64']),
}
PLATFORMS = (*UBUNTU_VERSIONS, 'macos-14', 'macos-15', *MAC_ARM_PROFILES)


def host_spec(host_platform, arch):
    if arch not in ARCHES or host_platform not in PLATFORMS:
        raise ValueError('Unsupported host platform or architecture')
    if host_platform in UBUNTU_VERSIONS:
        if host_platform == 'ubuntu-latest' and arch != 'x64':
            raise ValueError('ubuntu-latest supports x64 only; select a numbered ARM64 image')
        label = 'ubuntu-24.04' if host_platform == 'linux' else host_platform
        label += '-arm' if arch == 'arm64' else ''
        return {'label': label, 'image': label, 'checksum': ARCHES[arch][1], 'package': 'linux', 'system': 'Linux'}
    if host_platform in MAC_ARM_PROFILES:
        if arch != 'arm64':
            raise ValueError('This macOS runner label requires ARM64')
        image, additional_labels = MAC_ARM_PROFILES[host_platform]
        return {'label': host_platform, 'image': image, 'additional_labels': additional_labels,
                'checksum': MAC_ARCHES[arch], 'package': 'osx', 'system': 'macOS'}
    # macos-14 is ARM64 only. Never advertise an OS/architecture alias that
    # would change the target build's deployment baseline.
    if host_platform == 'macos-14' and arch != 'arm64':
        raise ValueError('macOS 14 hosts support ARM64 only')
    label = host_platform + ('-intel' if arch == 'x64' else '')
    return {'label': label, 'image': label, 'checksum': MAC_ARCHES[arch], 'package': 'osx', 'system': 'macOS'}


def runner_labels(host_platform, arch, label_suffix=''):
    spec = host_spec(host_platform, arch)
    if label_suffix and (label_suffix != 'sf' or host_platform != 'ubuntu-24.04'):
        raise ValueError('The sf label suffix requires native Ubuntu 24.04')
    label = ('ubuntu-24' + ('-arm' if arch == 'arm64' else '') + '-sf'
             if label_suffix else spec['label'])
    return ['self-hosted', spec['system'], 'X64' if arch == 'x64' else 'ARM64',
            label, *spec.get('additional_labels', [])]


def validate_host(host_platform, arch, system, machine, version):
    host_spec(host_platform, arch)
    expected_system = 'Linux' if host_platform in UBUNTU_VERSIONS else 'Darwin'
    expected_machine = 'x86_64' if arch == 'x64' else ('aarch64' if system == 'Linux' else 'arm64')
    expected_version = UBUNTU_VERSIONS[host_platform] if expected_system == 'Linux' else host_platform.split('-')[1]
    actual_version = version if system == 'Linux' else version.split('.')[0]
    if (system, machine, actual_version) != (expected_system, expected_machine, expected_version):
        raise ValueError('Host does not match the advertised runner label')


def matrix(pool, x64, arm64, host_platform='linux'):
    if not re.fullmatch(r'runner-pool-[a-z0-9-]{1,60}', pool):
        raise ValueError('Invalid pool environment')
    counts = [int(x64), int(arm64)]
    if any(n < 0 or n > 30 for n in counts) or not 1 <= sum(counts) <= 30:
        raise ValueError('Select 1 to 30 runners in total')
    return {'include': [
        {'arch': arch, 'os': host_spec(host_platform, arch)['image'],
         'platform': host_platform,
         'slot': str(slot), 'secret': f'RUNNER_JIT_{arch.upper()}_{slot}'}
        for arch, count in zip(ARCHES, counts) for slot in range(1, count + 1)
    ]}


def child_environment(parent):
    # In particular, omit GITHUB_*, ACTIONS_*, RUNNER_*, GH_TOKEN and our
    # registration secrets. The nested runner creates its own job context.
    allowed = ('HOME', 'USER', 'LOGNAME', 'PATH', 'LANG', 'LC_ALL', 'SHELL', 'TERM')
    return {key: parent[key] for key in allowed if key in parent}


def start_runner(directory, jit, env, log):
    # Keep the supervisor's directory and diagnostics private, while matching
    # normal hosted-runner permissions for checkouts and generated packages.
    return subprocess.Popen(['./run.sh', '--jitconfig', jit], cwd=directory, env=env,
                            stdout=log, stderr=log, start_new_session=True, umask=0o022)


def download_runner(directory, arch, host_platform='linux'):
    spec = host_spec(host_platform, arch)
    archive = directory / 'runner.tar.gz'
    url = f'https://github.com/actions/runner/releases/download/v{VERSION}/actions-runner-{spec["package"]}-{arch}-{VERSION}.tar.gz'
    with urllib.request.urlopen(url, timeout=120) as response, archive.open('wb') as output:
        shutil.copyfileobj(response, output)
    with archive.open('rb') as downloaded:
        checksum = hashlib.file_digest(downloaded, 'sha256').hexdigest()
    if checksum != spec['checksum']:
        raise RuntimeError('Runner archive verification failed')
    with tarfile.open(archive) as package:
        package.extractall(directory, filter='data')
    archive.unlink()


def stop(process):
    if process is None or process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGINT)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=30)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=10)


def serve():
    os.umask(0o077)
    jit = os.environ.pop('RUNNER_JIT_CONFIG')
    arch = os.environ.pop('POOL_ARCH')
    slot = os.environ.pop('POOL_SLOT')
    host_platform = os.environ.pop('POOL_PLATFORM', 'linux')
    if not re.fullmatch(r'[A-Za-z0-9+/=]+', jit):
        raise ValueError('Missing or invalid single-runner configuration')
    if arch not in ARCHES or not re.fullmatch(r'[1-9][0-9]?', slot):
        raise ValueError('Invalid runner slot')
    system = platform.system()
    version = platform.freedesktop_os_release()['VERSION_ID'] if system == 'Linux' else platform.mac_ver()[0]
    validate_host(host_platform, arch, system, platform.machine(), version)
    env = child_environment(os.environ)
    process = None
    directory = Path(tempfile.mkdtemp(prefix='temporary-runner-', dir=os.environ['RUNNER_TEMP']))
    def interrupted(signum, frame):
        raise InterruptedError('Host workflow interrupted')
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    try:
        download_runner(directory, arch, host_platform)
        print('Pinned runner download verified.', flush=True)
        with (directory / 'host.log').open('wb') as log:
            # Runner diagnostics and console output stay on this disposable VM.
            # The target workflow controls its own logs and package storage.
            # A JIT credential can start only this pre-registered, one-job
            # runner. It cannot register additional runners for the repository.
            print('Starting temporary runner for one job.', flush=True)
            process = start_runner(directory, jit, env, log)
            jit = ''
            started = time.monotonic()
            assigned = False
            while process.poll() is None:
                assigned = assigned or any((directory / '_diag').glob('Worker_*.log'))
                elapsed = time.monotonic() - started
                # Do not hold an unused host for six hours. Once assigned,
                # allow the complete job to finish before the host deadline.
                if not assigned and elapsed >= 15 * 60:
                    raise TimeoutError('No job assigned within 15 minutes')
                if elapsed >= 350 * 60:
                    raise TimeoutError('Runner exceeded its execution deadline')
                time.sleep(2)
            if process.returncode != 0 or not assigned:
                raise RuntimeError('Temporary runner did not complete a job')
            print('Temporary runner finished its job.', flush=True)
    finally:
        stop(process)
        # Successful JIT runners deregister themselves. External cleanup uses
        # local admin credentials for interrupted/unassigned registrations.
        # Container workspaces can contain root-owned files; destroy only our
        # dedicated temporary tree, never the parent runner workspace.
        subprocess.run(['sudo', 'rm', '-rf', '--', str(directory)], check=False)


if __name__ == '__main__':
    try:
        if sys.argv[1:] == ['matrix']:
            result = matrix(os.environ['POOL'], os.environ['X64_COUNT'], os.environ['ARM64_COUNT'],
                            os.environ.get('POOL_PLATFORM', 'linux'))
            with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
                output.write('matrix=' + json.dumps(result, separators=(',', ':')) + '\n')
        elif sys.argv[1:] == ['serve']:
            serve()
        else:
            raise ValueError('Unknown command')
    except BaseException as error:
        # Exception strings can contain secret URLs or registration arguments.
        print(f'::error::Temporary runner failed ({type(error).__name__}); inspect the target job status.', file=sys.stderr)
        sys.exit(1)
