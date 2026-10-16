import json
import os
from pathlib import Path
import socket
import subprocess
import time

php = '/opt/local/bin/php55'
extension = '/opt/local/lib/php55/extensions/no-debug-non-zts-20121212/imap.so'
hostname = socket.gethostname()
results = []


def measure(label):
    for name, options in [('imap', ['-n', '-d', 'extension=' + extension]), ('default', [])]:
        for trial in range(2):
            start = time.perf_counter()
            output = subprocess.run([php] + options + ['-r', 'echo PHP_VERSION;'],
                                    capture_output=True, text=True, timeout=20, check=True)
            assert output.stdout == '5.5.38' and not output.stderr, output
            result = dict(configuration=label, case=name, trial=trial+1,
                          seconds=round(time.perf_counter()-start, 3))
            results.append(result)
            print(json.dumps(result), flush=True)


def resolve(label):
    for family in (socket.AF_INET, socket.AF_INET6, socket.AF_UNSPEC):
        start = time.perf_counter()
        try:
            answer = socket.getaddrinfo(socket.gethostname(), None, family,
                                        socket.SOCK_STREAM, 0, socket.AI_CANONNAME)
        except OSError as error:
            answer = str(error)
        result = dict(configuration=label, family=int(family), answer=answer,
                      seconds=round(time.perf_counter()-start, 3))
        results.append(result)
        print(json.dumps(result), flush=True)


print('Original hostname: ' + hostname, flush=True)
measure('original')
resolve('original')
subprocess.run(['sudo', 'tee', '-a', '/etc/hosts'], text=True, check=True,
               input='\n127.0.0.1 ' + hostname + '\n::1 ' + hostname + '\n')
subprocess.run(['sudo', 'dscacheutil', '-flushcache'], check=True)
subprocess.run(['sudo', 'killall', '-HUP', 'mDNSResponder'], check=True)
measure('IPv4+IPv6 hosts')
resolve('IPv4+IPv6 hosts')
try:
    subprocess.run(['sudo', 'hostname', 'localhost'], check=True)
    measure('hostname localhost')
    resolve('hostname localhost')
finally:
    subprocess.run(['sudo', 'hostname', hostname], check=True)
(Path(os.environ['RUNNER_TEMP'])/'resolver-profile.json').write_text(json.dumps(results, indent=2))
