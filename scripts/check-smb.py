"""Exercise exact curl/PHP binaries against a loopback-only SMB1 fixture."""
import argparse
import base64
import datetime
import hmac
import ipaddress
import json
from pathlib import Path
import ssl
import subprocess
import tempfile
import threading

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID
from impacket import ntlm, smb, smbserver
from impacket.nt_errors import STATUS_LOGON_FAILURE

parser = argparse.ArgumentParser()
group = parser.add_mutually_exclusive_group(required=True)
group.add_argument('--curl')
group.add_argument('--php')
parser.add_argument('--ini')
parser.add_argument('--expect-smb', choices=['true', 'false'], required=True)
parser.add_argument('--report', required=True)
args = parser.parse_args()
results = []


def certificate(root, name):
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, name)])
    now = datetime.datetime.now(datetime.timezone.utc)
    cert = (x509.CertificateBuilder().subject_name(subject).issuer_name(subject)
            .public_key(key.public_key()).serial_number(x509.random_serial_number())
            .not_valid_before(now - datetime.timedelta(minutes=5))
            .not_valid_after(now + datetime.timedelta(days=1))
            .add_extension(x509.SubjectAlternativeName([
                x509.DNSName('localhost'), x509.IPAddress(ipaddress.ip_address('127.0.0.1'))]), critical=False)
            .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
            .sign(key, hashes.SHA256()))
    certpath, keypath = root / (name + '.pem'), root / (name + '.key')
    certpath.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
    keypath.write_bytes(key.private_bytes(serialization.Encoding.PEM,
                        serialization.PrivateFormat.TraditionalOpenSSL, serialization.NoEncryption()))
    return certpath, keypath


def transfer(protocol, name, urls, ca, expected=b'', upload=None, password='curltest', code=0):
    if args.php:
        request = {'urls': urls, 'ca': str(ca), 'upload': str(upload) if upload else None, 'password': password}
        command = [args.php, '-c', args.ini, str(Path(__file__).resolve().parents[1] / 'tests/smb-client.php'), json.dumps(request)]
        proc = subprocess.run(command, capture_output=True, timeout=45)
        assert proc.returncode == 0, proc.stderr.decode(errors='replace')
        response = json.loads(proc.stdout)
        actual_code, error = response['code'], response['error']
        body = b''.join(base64.b64decode(x) for x in response['bodies'])
    else:
        command = [args.curl, '--silent', '--show-error', '--max-time', '15',
                   '--user', 'curltest:' + password, '--cacert', str(ca)]
        if upload:
            command += ['--upload-file', str(upload)]
        proc = subprocess.run(command + urls, capture_output=True, timeout=45)
        actual_code, error, body = proc.returncode, proc.stderr.decode(errors='replace'), proc.stdout
    passed = actual_code == code and (code != 0 or expected is None or body == expected)
    row = {'protocol': protocol, 'test': name, 'passed': passed,
           'code': actual_code, 'expected_code': code, 'bytes': len(body), 'error': error}
    results.append(row)
    assert passed, row


try:
    with tempfile.TemporaryDirectory(prefix='winlibs-smb-') as temporary:
        root = Path(temporary)
        payload = b'SMB compatibility check\n' * 10000
        (root / 'input.txt').write_bytes(payload)
        (root / 'space name.txt').write_bytes(b'escaped path\n')
        (root / 'empty.txt').write_bytes(b'')
        cert, key = certificate(root, 'localhost')
        other_ca, _ = certificate(root, 'untrusted-ca')
        for scheme in ['smb', 'smbs']:
            if args.expect_smb == 'false':
                transfer(scheme, 'unsupported protocol', [f'{scheme}://127.0.0.1:9/QA/input.txt'], cert, code=1)
                continue
            server = smbserver.SimpleSMBServer(listenAddress='127.0.0.1', listenPort=0)
            server.setSMB2Support(False)
            server.addShare('QA', str(root), readOnly='no')
            server.addCredential('curltest', 0, ntlm.compute_lmhash('curltest'), ntlm.compute_nthash('curltest'))
            listener = server.getServer()

            def authenticate(connection, instance, command, packet):
                # Impacket's standard-security SMB1 fixture does not verify
                # passwords itself; reject an incorrect NTLMv1 response here.
                parameters = smb.SMBSessionSetupAndX_Parameters(command['Parameters'])
                data = smb.SMBSessionSetupAndX_Data()
                data['AnsiPwdLength'] = parameters['AnsiPwdLength']
                data['UnicodePwdLength'] = parameters['UnicodePwdLength']
                data.fromString(command['Data'])
                state = instance.getConnectionData(connection, checkStatus=False)
                challenge = state.get('EncryptionKey', bytes.fromhex('1122334455667788'))
                expected = ntlm.get_ntlmv1_response(ntlm.compute_nthash('curltest'), challenge)
                response, packets, status = original_authenticate(connection, instance, command, packet)
                if not hmac.compare_digest(data['UnicodePwd'], expected):
                    state = instance.getConnectionData(connection, checkStatus=False)
                    state['Authenticated'] = False
                    instance.setConnectionData(connection, state)
                    status = STATUS_LOGON_FAILURE
                return response, packets, status

            original_authenticate = listener.hookSmbCommand(smb.SMB.SMB_COM_SESSION_SETUP_ANDX, authenticate)
            port = listener.socket.getsockname()[1]
            if scheme == 'smbs':
                context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
                context.load_cert_chain(cert, key)
                listener.socket = context.wrap_socket(listener.socket, server_side=True)
            worker = threading.Thread(target=server.start, daemon=True)
            worker.start()
            base = f'{scheme}://127.0.0.1:{port}/QA/'
            try:
                transfer(scheme, 'download 240 KB', [base + 'input.txt'], cert, payload)
                transfer(scheme, 'connection reuse', [base + 'input.txt'] * 2, cert, payload * 2)
                transfer(scheme, 'escaped path', [base + 'space%20name.txt'], cert, b'escaped path\n')
                transfer(scheme, 'empty file', [base + 'empty.txt'], cert)
                transfer(scheme, 'upload', [base + 'uploaded.txt'], cert, expected=None, upload=root / 'input.txt')
                assert (root / 'uploaded.txt').read_bytes() == payload
                transfer(scheme, 'missing file', [base + 'absent.txt'], cert, code=78)
                transfer(scheme, 'incorrect credentials', [base + 'input.txt'], cert, password='wrong-test-password', code=67)
                if scheme == 'smbs':
                    transfer(scheme, 'untrusted TLS certificate', [base + 'input.txt'], other_ca, code=60)
            finally:
                listener.shutdown()
                listener.server_close()
                worker.join(timeout=5)
finally:
    report = Path(args.report)
    report.parent.mkdir(parents=True, exist_ok=True)
    report.write_text(json.dumps(results, indent=2))
    print(json.dumps({'passed': sum(x['passed'] for x in results), 'total': len(results)}))
