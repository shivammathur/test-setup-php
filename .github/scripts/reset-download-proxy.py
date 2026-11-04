import select
import socket
import socketserver
import struct
import sys

class Proxy(socketserver.BaseRequestHandler):
    def handle(self):
        header = b''
        while b'\r\n\r\n' not in header and len(header) < 65536:
            chunk = self.request.recv(4096)
            if not chunk:
                return
            header += chunk
        method, destination, _ = header.split(b'\r\n', 1)[0].split(b' ', 2)
        if method != b'CONNECT':
            self.request.sendall(b'HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\n\r\n')
            return
        host, port = destination.decode().rsplit(':', 1)
        upstream = socket.create_connection((host, int(port)), timeout=30)
        try:
            self.request.sendall(b'HTTP/1.1 200 Connection Established\r\n\r\n')
            received = 0
            while True:
                readable, _, _ = select.select([self.request, upstream], [], [], 60)
                if not readable:
                    return
                for source in readable:
                    payload = source.recv(65536)
                    if not payload:
                        return
                    target = upstream if source is self.request else self.request
                    target.sendall(payload)
                    if source is upstream:
                        received += len(payload)
                        if host.lower() == 'download.microsoft.com' and received >= 262144:
                            print(f'RESET {host} after {received} bytes', flush=True)
                            self.request.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack('hh', 1, 0))
                            return
        except (ConnectionError, OSError) as error:
            print(f'{host}: {error}', flush=True)
        finally:
            upstream.close()

class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

with Server(('127.0.0.1', int(sys.argv[1])), Proxy) as server:
    print('Proxy ready', flush=True)
    server.serve_forever()
