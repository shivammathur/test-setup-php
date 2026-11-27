from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time

requests = []
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        requests.append(self.path)
        stalled = self.path == '/primary/payload'
        self.send_response(200)
        self.send_header('Content-Length', '6')
        self.end_headers()
        if stalled:
            self.wfile.write(b'x')
            self.wfile.flush()
            time.sleep(35)
        else:
            self.wfile.write(b'mirror')

    def log_message(self, *_):
        pass

server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
probe = '''
  source "$1/src/scripts/linux.sh"
  port=$2
  curl() {
    local last=${!#} args=("${@:1:$#-1}")
    case "$last" in
      https://packages.sury.org/php/*) url=http://127.0.0.1:$port/primary/${last##*/};;
      https://ppa.setup-php.com/sury/*) url=http://127.0.0.1:$port/mirror/${last##*/};;
      *) return 1;;
    esac
    command curl "${args[@]}" "$url"
  }
  download_ppa_file payload "$3" && test "$preferred_ppa_root" = https://ppa.setup-php.com/sury
'''
with tempfile.TemporaryDirectory() as tmp:
    dest = Path(tmp) / 'payload'
    start = time.monotonic()
    subprocess.run(['bash','-c',probe,'bash',sys.argv[1],str(server.server_port),str(dest)],check=True,timeout=30)
    elapsed = time.monotonic()-start
    assert 14 <= elapsed < 30 and dest.read_bytes() == b'mirror'
    assert requests == ['/primary/payload','/mirror/payload']
    print(f'PASS: primary stalled after headers and one body byte, mirror completed at {elapsed:.1f}s')
