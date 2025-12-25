#!/usr/bin/env python3
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs
import os, subprocess

TOKEN = os.environ.get("NOTIFY_TOKEN", "changeme")
PORT = int(os.environ.get("NOTIFY_PORT", "8989"))

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        qs = parse_qs(urlparse(self.path).query)
        token = (qs.get("token", [""])[0])
        if token != TOKEN:
            self.send_response(403); self.end_headers()
            self.wfile.write(b"forbidden")
            return

        title = qs.get("title", ["Claude Code"])[0]
        msg   = qs.get("msg",   ["done"])[0]
        sound = qs.get("sound", ["default"])[0]

        # terminal-notifier を起動
        cmd = [
            "terminal-notifier",
            "-title", title,
            "-message", msg,
            "-sound", sound,
        ]
        subprocess.run(cmd, check=False)

        self.send_response(200); self.end_headers()
        self.wfile.write(b"ok")

    def log_message(self, fmt, *args):
        # ログ不要なら黙らせる
        return

HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
