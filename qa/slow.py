import http.server,subprocess,threading,time,tempfile,sys
from pathlib import Path
hits=[]
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        hits.append(self.path)
        self.send_response(200); self.send_header('Content-Length',str(1024*18)); self.end_headers()
        for i in range(18):
            self.wfile.write(b'x'*1024); self.wfile.flush()
            if i!=17: time.sleep(1)
    def log_message(self,*args): pass
s=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
threading.Thread(target=s.serve_forever,daemon=True).start()
with tempfile.TemporaryDirectory() as tmp:
    target=Path(tmp)/'pkg'
    start=time.monotonic()
    subprocess.run(['bash','-c','source "$1/src/scripts/linux.sh"; preferred_ppa_root="$2"; download_ppa_file pkg "$3" && test "$preferred_ppa_root" = "$2"','bash',sys.argv[1],f'http://127.0.0.1:{s.server_port}',str(target)],timeout=30,check=True)
    elapsed=time.monotonic()-start
    assert elapsed>15 and target.read_bytes()==b'x'*(18*1024) and hits==['/pkg']
    print(f'PASS: healthy transfer took {elapsed:.1f}s with no failover')
