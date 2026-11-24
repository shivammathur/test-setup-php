import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

class Report(BaseHTTPRequestHandler):
    def do_POST(self):
        names = {"/start": "started", "/log": "transcript.log", "/done": "done"}
        name = names.get(self.path)
        length = int(self.headers.get("Content-Length", "0"))
        if not name or not 0 < length <= 4_000_000:
            self.send_error(400)
            return
        data = self.rfile.read(length)
        target = Path(sys.argv[2], name)
        tmp = target.with_suffix(".part")
        tmp.write_bytes(data)
        tmp.replace(target)
        self.send_response(200)
        self.end_headers()

HTTPServer((sys.argv[1], 18511), Report).serve_forever()
