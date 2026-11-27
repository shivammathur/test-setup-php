from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import os, threading, time, socketserver

class Stall(socketserver.BaseRequestHandler):
    def handle(self): time.sleep(40)

class HTTP(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/error': self.send_error(503); return
        data = b'not a deb archive'
        self.send_response(200)
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        if self.path == '/body':
            self.wfile.write(data[:1]); self.wfile.flush(); time.sleep(40)
        else:
            self.wfile.write(data)
    def log_message(self,*args): pass

temp=Path(os.environ['RUNNER_TEMP'])
tls=socketserver.ThreadingTCPServer(('127.0.0.1',0),Stall)
http=ThreadingHTTPServer(('127.0.0.1',0), HTTP)
threading.Thread(target=tls.serve_forever,daemon=True).start()
(temp/'ports.tmp').write_text(f'{tls.server_address[1]} {http.server_port}\n')
(temp/'ports.tmp').replace(temp/'qa-ports')
http.serve_forever()
