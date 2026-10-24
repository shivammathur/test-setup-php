import argparse
import gzip
import zlib
import hashlib
import http.server
import json
import pathlib
import subprocess
import threading

p=argparse.ArgumentParser()
p.add_argument('--curl')
p.add_argument('--php')
p.add_argument('--ini')
p.add_argument('--fixtures',required=True)
p.add_argument('--report',required=True)
a=p.parse_args()
root=pathlib.Path(a.fixtures)
raw=(root/'payload.raw').read_bytes()
encoded=(root/'payload.br').read_bytes()

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body=b'\xff'*32 if self.path in ['/invalid','/gzip-invalid'] else gzip.compress(raw) if self.path.startswith('/gzip') else zlib.compress(raw) if self.path=='/deflate' else encoded
        self.send_response(200)
        self.send_header('Content-Encoding','gzip' if self.path.startswith('/gzip') else 'deflate' if self.path=='/deflate' else 'br')
        if self.path in ['/chunked','/gzip-chunked']:self.send_header('Transfer-Encoding','chunked')
        else:self.send_header('Content-Length',str(len(body)))
        self.end_headers()
        try:
            if self.path in ['/chunked','/gzip-chunked']:
                for i in range(0,len(body),7):
                    part=body[i:i+7];self.wfile.write(f'{len(part):x}\r\n'.encode()+part+b'\r\n')
                self.wfile.write(b'0\r\n\r\n')
            else:self.wfile.write(body)
        except (ConnectionResetError,BrokenPipeError):pass
    def log_message(self,*args):pass

server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
threading.Thread(target=server.serve_forever,daemon=True).start()
url=f'http://127.0.0.1:{server.server_port}'
results=[]
try:
    if a.curl:
        for path in ['/valid','/chunked','/invalid','/gzip','/gzip-chunked','/gzip-invalid','/deflate']:
            r=subprocess.run([a.curl,'--noproxy','*','--compressed','--silent','--show-error','--max-time','20',url+path],capture_output=True,timeout=30)
            ok=(r.returncode==61) if path in ['/invalid','/gzip-invalid'] else (r.returncode==0 and r.stdout==raw)
            results.append({'case':path,'ok':ok,'exit':r.returncode,'stderr':r.stderr.decode(errors='replace'),'sha256':hashlib.sha256(r.stdout).hexdigest()})
    if a.php:
        r=subprocess.run([a.php,'-c',a.ini,'tests/php-brotli.php',url,str(root/'payload.raw')],capture_output=True,timeout=90)
        results.append({'case':'php-curl','ok':r.returncode==0,'exit':r.returncode,'stdout':r.stdout.decode(errors='replace'),'stderr':r.stderr.decode(errors='replace')})
finally:server.shutdown()
pathlib.Path(a.report).write_text(json.dumps(results,indent=2))
print(json.dumps(results,indent=2))
if not results or not all(r['ok'] for r in results):raise SystemExit(1)
