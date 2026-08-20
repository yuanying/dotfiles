#!/usr/bin/env python3
"""A stand-in for the Cloudflare API, for the issuance test.

It signs the CSR it is handed with a throwaway CA, so the test can check that
what lands on disk is a certificate matching the key that stayed behind -- the
part of issuance that is this repository's to get right. Whether the real API
accepts the request body is not something a mock can tell anyone.
"""

import json
import os
import subprocess
import sys
import tempfile
from http.server import BaseHTTPRequestHandler, HTTPServer


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self) -> None:  # noqa: N802
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        with tempfile.TemporaryDirectory() as work:
            csr = os.path.join(work, "req.csr")
            with open(csr, "w") as handle:
                handle.write(body["csr"])
            ca_key = os.path.join(work, "ca.key")
            ca_crt = os.path.join(work, "ca.crt")
            subprocess.run(
                ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                 "-subj", "/CN=fake origin ca", "-keyout", ca_key, "-out", ca_crt],
                check=True, stderr=subprocess.DEVNULL)
            certificate = subprocess.run(
                ["openssl", "x509", "-req", "-in", csr, "-CA", ca_crt, "-CAkey", ca_key,
                 "-CAcreateserial", "-days", "1"],
                check=True, capture_output=True, text=True).stdout

        payload = json.dumps({
            "success": True,
            "errors": [],
            "result": {
                "id": "fake-certificate-id",
                "certificate": certificate,
                "hostnames": body["hostnames"],
                "request_type": body["request_type"],
            },
        }).encode()
        # Record what was asked for, so the test can assert on it.
        with open(sys.argv[2], "w") as handle:
            json.dump(body, handle)

        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, format: str, *args) -> None:  # noqa: A002
        pass


HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
