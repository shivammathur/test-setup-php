import argparse
import json
import sys
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import brotli
import zstandard


PAYLOADS = {
    "/brotli": "brotli payload ok\n",
    "/zstd": "zstd payload ok\n",
    "/identity": "identity payload ok\n",
    "/negotiate": "negotiate payload ok\n",
}


def parse_encodings(header_value):
    tokens = []
    for token in header_value.split(","):
        value = token.strip().split(";", 1)[0].strip().lower()
        if value:
            tokens.append(value)
    return tokens


class CurlEncodingHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    zstd_compressor = zstandard.ZstdCompressor(level=3)

    def log_message(self, fmt, *args):
        sys.stdout.write("%s - - [%s] %s\n" % (self.address_string(), self.log_date_time_string(), fmt % args))
        sys.stdout.flush()

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        accept_encoding = self.headers.get("Accept-Encoding", "")
        encodings = parse_encodings(accept_encoding)

        if path == "/healthz":
            self._send_text(200, "ok\n", accept_encoding, "identity")
            return

        if path == "/echo":
            body = json.dumps(
                {
                    "path": path,
                    "accept_encoding": accept_encoding,
                    "encodings": encodings,
                },
                indent=2,
                sort_keys=True,
            ).encode("utf-8")
            self._send_response(200, body, "application/json; charset=utf-8", accept_encoding, "identity")
            return

        if path == "/brotli":
            self._serve_encoded(path, "br", accept_encoding, encodings)
            return

        if path == "/zstd":
            self._serve_encoded(path, "zstd", accept_encoding, encodings)
            return

        if path == "/negotiate":
            selected = "br" if "br" in encodings else "zstd" if "zstd" in encodings else "identity"
            self._serve_encoded(path, selected, accept_encoding, encodings)
            return

        self._send_text(404, "not found\n", accept_encoding, "identity")

    def _serve_encoded(self, path, encoding, accept_encoding, encodings):
        if encoding != "identity" and encoding not in encodings:
            body = json.dumps(
                {
                    "accepted": False,
                    "path": path,
                    "required": encoding,
                    "accept_encoding": accept_encoding,
                    "encodings": encodings,
                },
                indent=2,
                sort_keys=True,
            ).encode("utf-8")
            self._send_response(406, body, "application/json; charset=utf-8", accept_encoding, "identity")
            return

        payload = PAYLOADS[path].encode("utf-8")
        headers = {"Vary": "Accept-Encoding"}

        if encoding == "br":
            body = brotli.compress(payload)
            headers["Content-Encoding"] = "br"
        elif encoding == "zstd":
            body = self.zstd_compressor.compress(payload)
            headers["Content-Encoding"] = "zstd"
        else:
            body = payload

        self._send_response(200, body, "text/plain; charset=utf-8", accept_encoding, encoding, headers)

    def _send_text(self, status_code, body, accept_encoding, selected_encoding):
        self._send_response(status_code, body.encode("utf-8"), "text/plain; charset=utf-8", accept_encoding, selected_encoding)

    def _send_response(self, status_code, body, content_type, accept_encoding, selected_encoding, extra_headers=None):
        self.send_response(status_code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.send_header("X-Accept-Encoding-Received", accept_encoding or "(none)")
        self.send_header("X-Selected-Encoding", selected_encoding)
        if extra_headers:
            for name, value in extra_headers.items():
                self.send_header(name, value)
        self.end_headers()
        self.wfile.write(body)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=18080)
    parser.add_argument("--ready-file")
    args = parser.parse_args()

    server = ThreadingHTTPServer((args.host, args.port), CurlEncodingHandler)
    if args.ready_file:
        with open(args.ready_file, "w", encoding="utf-8") as handle:
            handle.write(f"{args.host}:{args.port}\n")

    print(f"Listening on http://{args.host}:{args.port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
