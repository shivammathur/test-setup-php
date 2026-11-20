"""Loopback LDAP fixture: verified TLS, simple bind, search, and StartTLS.

This is a protocol fixture, not an AD/Kerberos/SASL authentication server.
"""
import datetime
import ipaddress
import json
import socket
import ssl
import threading

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID


def tlv(tag, value):
    size = len(value)
    length = bytes([size]) if size < 128 else bytes([0x80 | ((size.bit_length() + 7) // 8)]) + size.to_bytes((size.bit_length() + 7) // 8, "big")
    return bytes([tag]) + length + value


def integer(value):
    return tlv(2, value.to_bytes(max(1, (value.bit_length() + 8) // 8), "big"))


def string(value):
    return tlv(4, value.encode())


def fields(data):
    offset = 0
    while offset < len(data):
        tag, size = data[offset:offset + 2]
        offset += 2
        if size & 128:
            count = size & 127
            size = int.from_bytes(data[offset:offset + count], "big")
            offset += count
        yield tag, data[offset:offset + size]
        offset += size


def exact(sock, size):
    result = b""
    while len(result) < size:
        chunk = sock.recv(size - len(result))
        if not chunk:
            raise EOFError()
        result += chunk
    return result


def message(sock):
    tag, size = exact(sock, 2)
    if tag != 0x30:
        raise ValueError("Expected LDAPMessage")
    if size & 128:
        size = int.from_bytes(exact(sock, size & 127), "big")
    values = list(fields(exact(sock, size)))
    return int.from_bytes(values[0][1], "big"), values[1][0], values[1][1]


def reply(sock, msgid, tag, body):
    sock.sendall(tlv(0x30, integer(msgid) + tlv(tag, body)))


def result(code=0):
    return tlv(10, bytes([code])) + string("") + string("")


def certificate(root, prefix):
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "localhost")])
    now = datetime.datetime.now(datetime.timezone.utc)
    cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name)
            .public_key(key.public_key()).serial_number(x509.random_serial_number())
            .not_valid_before(now - datetime.timedelta(minutes=5))
            .not_valid_after(now + datetime.timedelta(days=2))
            .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
            .add_extension(x509.SubjectAlternativeName([x509.DNSName("localhost"), x509.IPAddress(ipaddress.ip_address("127.0.0.1"))]), critical=False)
            .sign(key, hashes.SHA256()))
    certfile, keyfile = root / f"{prefix}.pem", root / f"{prefix}-key.pem"
    certfile.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
    keyfile.write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(certfile, keyfile)
    return context


class Fixture:
    def __init__(self, root):
        self.root = root
        self.lock = threading.Lock()
        self.listeners = []
        self.context = certificate(root, "ca")
        self.untrusted = certificate(root, "untrusted")
        self.ports = {}
        for name, tls, context in [("ldaps", True, self.context), ("starttls", False, self.context), ("untrusted", True, self.untrusted)]:
            listener = socket.socket()
            listener.bind(("127.0.0.1", 0))
            listener.listen()
            self.listeners.append(listener)
            self.ports[name] = listener.getsockname()[1]
            threading.Thread(target=self.accept, args=(listener, tls, context), daemon=True).start()

    def log(self, **event):
        with self.lock, (self.root / "ldap-server.jsonl").open("a") as f:
            f.write(json.dumps(event) + "\n")

    def accept(self, listener, tls, context):
        while True:
            sock, _ = listener.accept()
            threading.Thread(target=self.serve, args=(sock, tls, context), daemon=True).start()

    def serve(self, sock, tls, context):
        bound = False
        try:
            sock.settimeout(10)
            if tls:
                sock = context.wrap_socket(sock, server_side=True)
                self.log(event="tls", protocol=sock.version())
            while True:
                msgid, tag, body = message(sock)
                if tag == 0x77:  # ExtendedRequest: StartTLS.
                    oid = list(fields(body))[0][1]
                    if oid != b"1.3.6.1.4.1.1466.20037":
                        raise ValueError("Unexpected extended request")
                    reply(sock, msgid, 0x78, result())
                    sock = context.wrap_socket(sock, server_side=True)
                    self.log(event="starttls", protocol=sock.version())
                elif tag == 0x60:
                    values = list(fields(body))
                    bound = values[1][1] == b"cn=test,dc=example,dc=test" and values[2] == (0x80, b"fixture-password")
                    reply(sock, msgid, 0x61, result(0 if bound else 49))
                    self.log(event="bind", success=bound)
                elif tag == 0x63:
                    if bound:
                        attrs = tlv(0x30, string("cn") + tlv(0x31, string("fixture-user")))
                        reply(sock, msgid, 0x64, string("cn=fixture-user,dc=example,dc=test") + tlv(0x30, attrs))
                    reply(sock, msgid, 0x65, result(0 if bound else 50))
                    self.log(event="search", success=bound)
                elif tag == 0x42:
                    return
                else:
                    raise ValueError(f"Unexpected LDAP operation {tag}")
        except EOFError:
            pass
        except Exception as error:
            self.log(event="connection-ended", error=str(error))
        finally:
            sock.close()
