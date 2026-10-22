#!/usr/bin/env python3
"""One serial local synthetic SSE request, no retries; requires pinned PR162 collector.

Raw SSE is saved only in a caller-created private directory. Stdout contains
body-free metrics. Timeout does NOT prove a server job has stopped.
"""
import argparse
import hashlib
import http.client
import importlib.util
import json
import os
from pathlib import Path
import time
from urllib.parse import urlsplit

COLLECTOR_SHA256 = '626a173a461267954275ecc85c34509ad74279d4581c17f0fd308d7f346c07e3'


def validate_request(request):
    if request.get('stream') is not True or type(request.get('max_tokens')) is not int or not 0 < request['max_tokens'] <= 256:
        raise ValueError('request_budget')


def validate_url(url):
    parsed = urlsplit(url)
    if parsed.scheme != 'http' or parsed.hostname not in ('127.0.0.1', 'localhost', 'llama-server') or parsed.username or parsed.password or parsed.path != '/v1/chat/completions' or parsed.query or parsed.fragment:
        raise ValueError('local_endpoint_required')
    return parsed


def receive(response, collector, raw, clock=time.monotonic_ns, before_read=None):
    collector.headers(clock(), response.status)
    while True:
        if before_read is not None:
            before_read()
        chunk = response.read1(16384)
        at = clock()
        if not chunk:
            return collector.finish(at)
        # Enforce collector byte/clock/schema limits before saving received data.
        collector.feed(at, chunk)
        raw.write(chunk)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--collector', required=True)
    p.add_argument('--url', required=True)
    p.add_argument('--request', required=True)
    p.add_argument('--raw', required=True)
    args = p.parse_args()
    endpoint = validate_url(args.url)
    source = Path(args.collector)
    if hashlib.sha256(source.read_bytes()).hexdigest() != COLLECTOR_SHA256:
        raise ValueError('collector_hash')
    spec = importlib.util.spec_from_file_location('stream_metrics', source)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    body = Path(args.request).read_bytes()
    if len(body) > 1024 * 1024:
        raise ValueError('request_bytes')
    validate_request(json.loads(body))
    raw_path = Path(args.raw)
    if raw_path.parent.stat().st_mode & 0o077:
        raise ValueError('private_directory_required')
    conn = http.client.HTTPConnection(endpoint.hostname, endpoint.port, timeout=180)
    try:
        with os.fdopen(os.open(raw_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'wb') as raw:
            start = time.monotonic_ns()
            collector = module.Collector(start)
            conn.request('POST', endpoint.path, body=body, headers={'Content-Type': 'application/json'})
            transport_socket = conn.sock

            def remaining_timeout():
                remaining = 180 - (time.monotonic_ns() - start) / 1e9
                if remaining <= 0:
                    raise TimeoutError('deadline')
                if transport_socket is not None:
                    transport_socket.settimeout(remaining)

            remaining_timeout()
            response = conn.getresponse()
            result = receive(response, collector, raw, before_read=remaining_timeout)
        result['request_sha256'] = hashlib.sha256(body).hexdigest()
        print(json.dumps(result, allow_nan=False))
    finally:
        conn.close()


if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        # Do not print potentially sensitive exception messages or server bodies.
        raise SystemExit('live_measurement_failed: ' + type(exc).__name__) from None
