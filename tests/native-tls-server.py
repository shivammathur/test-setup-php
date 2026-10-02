"""Exercise packaged TLS clients against a local independently observed peer."""
import json, pathlib, socket, ssl, subprocess, sys, threading, time

exe, openssl, output = sys.argv[1:]
root = pathlib.Path(output).resolve()
root.mkdir(parents=True, exist_ok=True)
for name in ('trusted', 'untrusted'):
    subprocess.run([openssl, 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
                    '-keyout', str(root / (name + '.key')), '-out', str(root / (name + '.pem')),
                    '-days', '1', '-subj', '/CN=localhost', '-addext', 'subjectAltName=DNS:localhost'],
                   check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

results = []
for name, host, ca, expect in [('trusted', 'localhost', 'trusted', 'success'),
                               ('wrong-host', '127.0.0.1', 'trusted', 'failure'),
                               ('untrusted', 'localhost', 'untrusted', 'failure')]:
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(root / 'trusted.pem', root / 'trusted.key')
    listener = socket.socket()
    listener.bind(('127.0.0.1', 0))
    listener.listen(8)
    listener.settimeout(0.2)
    port = listener.getsockname()[1]
    stop = threading.Event()
    observations = []

    def serve():
        while not stop.is_set():
            try:
                raw, _ = listener.accept()
            except TimeoutError:
                continue
            raw.settimeout(2)
            try:
                with context.wrap_socket(raw, server_side=True) as stream:
                    observations.append({'handshake': True, 'protocol': stream.version(),
                                         'cipher': stream.cipher()[0]})
                    data = stream.recv(4096)
                    observations[-1]['applicationBytes'] = len(data)
                    if 'rabbitmq' in pathlib.Path(exe).name:
                        observations[-1]['amqpHeader'] = data.hex()
                        if data == b'AMQP\x00\x00\x09\x01':
                            # A valid heartbeat frame acknowledges receipt over the authenticated channel.
                            stream.sendall(b'\x08\x00\x00\x00\x00\x00\x00\xce')
            except (ssl.SSLError, OSError) as error:
                observations.append({'handshake': False, 'error': str(error)})
                raw.close()

    thread = threading.Thread(target=serve)
    thread.start()
    try:
        client = subprocess.run([exe, host, str(port), str(root / (ca + '.pem')), expect],
                                capture_output=True, text=True, timeout=15)
    finally:
        stop.set()
        thread.join(timeout=5)
        listener.close()
    assert not thread.is_alive(), 'TLS server did not stop'
    successes = [r for r in observations if r['handshake']]
    row = {'case': name, 'returncode': client.returncode, 'stdout': client.stdout,
           'stderr': client.stderr, 'server': observations}
    results.append(row)
    (root / 'results.json').write_text(json.dumps(results, indent=2))
    print(json.dumps(row), flush=True)
    assert client.returncode == 0, row
    assert observations, 'Client never reached the TLS server'
    if expect == 'success':
        assert successes, 'No successful TLS handshake'
        assert any(r.get('applicationBytes', 0) > 0 for r in successes), 'No application protocol traffic'
        if 'rabbitmq' in pathlib.Path(exe).name:
            assert any(r.get('amqpHeader') == '414d515000000901' for r in successes), 'Invalid AMQP protocol header'
    else:
        assert not successes, 'Client accepted an invalid certificate'
