#!/usr/bin/env python3
"""
Minimal demo background service.

- Serves GET /healthz  -> {"status": "ok", "version": "..."}
- Serves GET /         -> plain text banner (useful to eyeball which version is live)
- Reads its version from the APP_VERSION environment variable, which the
  systemd unit populates via EnvironmentFile from the release's VERSION file.

To rehearse a FAILED update for the rollback demo, set APP_BROKEN=1
(the release-broken workflow / VERSION file does this) and the health
endpoint will return 500, which the update agent treats as a failed deploy.
"""
import http.server
import json
import os
import sys

VERSION = os.environ.get("APP_VERSION", "unknown")
BROKEN = os.environ.get("APP_BROKEN", "0") == "1"
PORT = int(os.environ.get("APP_PORT", "8080"))


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        # quieter default logging
        sys.stdout.write("%s - %s\n" % (self.address_string(), fmt % args))

    def do_GET(self):
        if self.path == "/healthz":
            if BROKEN:
                self.send_response(500)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps({"status": "error", "version": VERSION}).encode())
                return
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"status": "ok", "version": VERSION}).encode())
        elif self.path == "/":
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(f"[updated]pyupdate-demo running version {VERSION}\n".encode())
        else:
            self.send_response(404)
            self.end_headers()


if __name__ == "__main__":
    if BROKEN:
        print(f"[pyupdate-demo] Starting version {VERSION} in BROKEN mode (health check will fail)")
    else:
        print(f"[pyupdate-demo] Starting version {VERSION} on port {PORT}")
    server = http.server.HTTPServer(("0.0.0.0", PORT), Handler)
    server.serve_forever()
