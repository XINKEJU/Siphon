#!/usr/bin/env python3
"""Header-echo fixture for CredentialScopeTests.

Usage: echo_server.py PORT

  /echo            -> JSON of the credential headers actually received
  /seg             -> "C=<cookie>;A=<authorization>\n" (SegmentAssembler output)
  /redirect-same   -> 302 to http://127.0.0.1:PORT/echo
  /redirect-cross  -> 302 to http://localhost:PORT/echo   (different site key)

Dual-stack so `localhost` works whether it resolves to ::1 or 127.0.0.1.
"""
import http.server
import json
import socket
import sys

PORT = int(sys.argv[1])
WATCHED = ["cookie", "authorization", "proxy-authorization", "referer",
           "user-agent", "accept", "x-hotlink-token"]


class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _received(self):
        return {k: self.headers.get(k) for k in WATCHED}

    def _send(self, code, body, ctype="application/json", extra=None):
        raw = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(raw)))
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/echo":
            self._send(200, json.dumps(self._received()))
        elif path == "/seg":
            r = self._received()
            body = "C=%s;A=%s\n" % (r["cookie"] or "-", r["authorization"] or "-")
            self._send(200, body, "text/plain")
        elif path == "/redirect-same":
            self._send(302, "", "text/plain",
                       {"Location": "http://127.0.0.1:%d/echo" % PORT})
        elif path == "/redirect-cross":
            self._send(302, "", "text/plain",
                       {"Location": "http://localhost:%d/echo" % PORT})
        elif path == "/ping":
            self._send(200, "{}")
        else:
            self._send(404, "{}")

    def log_message(self, *a):
        pass


class Server(http.server.ThreadingHTTPServer):
    address_family = socket.AF_INET6
    daemon_threads = True
    allow_reuse_address = True


if __name__ == "__main__":
    with Server(("::", PORT), H) as s:
        s.serve_forever()