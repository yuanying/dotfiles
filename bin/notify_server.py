#!/usr/bin/env python3
import shutil, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs
import os, subprocess, datetime, traceback

TOKEN = os.environ.get("NOTIFY_TOKEN", "changeme")
PORT  = int(os.environ.get("NOTIFY_PORT", "8989"))
LOG   = os.environ.get("NOTIFY_LOG",  "/tmp/notify.log")
TN    = os.environ.get("TERMINAL_NOTIFIER") or shutil.which("terminal-notifier") or "/opt/homebrew/bin/terminal-notifier"

def log(line):
    ts = datetime.datetime.now().isoformat(timespec="seconds")
    print(f"[{ts}] {line}")

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        try:
            qs = parse_qs(urlparse(self.path).query)
            token = qs.get("token", [""])[0]
            if token != TOKEN:
                log(f"DENY from {self.client_address}")
                self.send_response(403); self.end_headers()
                return

            title = qs.get("title", ["Claude Code"])[0]
            msg   = qs.get("msg",   ["done"])[0]
            sound = qs.get("sound", ["default"])[0]

            log(f"REQ from {self.client_address} title={title!r} msg={msg!r}")

            cmd = [
                TN,
                "-title", title,
                "-message", msg,
                "-sound", sound,
            ]

            p = subprocess.run(
                cmd, capture_output=True, text=True
            )

            log(f"NOTIFY rc={p.returncode} stderr={p.stderr.strip()!r}")

            self.send_response(200); self.end_headers()
            self.wfile.write(b"ok")

        except Exception:
            log("ERROR\n" + traceback.format_exc())
            self.send_response(500); self.end_headers()

    def log_message(self, fmt, *args):
        pass

HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
