#!/usr/bin/env python3
"""Synthetic transport only: never contacts a model."""
import base64
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'devbox/apps/llama-server/stream_metrics.py'
spec = importlib.util.spec_from_file_location('stream_metrics', SCRIPT)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


def event(delta=None, finish=None, **extra):
    obj = {'choices': [] if delta is None else [
        {'index': 0, 'delta': delta, 'finish_reason': finish}]}
    return ('data: ' + json.dumps(dict(obj, **extra), ensure_ascii=False) + '\n\n').encode()


def run(chunks, end=5, **kwargs):
    c = m.Collector(start_ns=0, **kwargs)
    c.headers(100_000_000, 200)
    for t, data in chunks:
        c.feed(int(t * 1e9), data)
    return c.finish(int(end * 1e9))


DONE = b'data: [DONE]\n\n'


class MetricsTest(unittest.TestCase):
    def test_arrival_not_headers_role_or_heartbeat(self):
        r = run([(0.2, b': heartbeat\n\n'), (0.4, event({'role': 'assistant'})),
                 (1, event({'reasoning_content': 'r'})),
                 (2, event({'content': '日本語'})), (3, event({'content': 'x'}, 'stop')),
                 (4, event(usage={'completion_tokens': 6, 'prompt_tokens': 8})), (4.5, DONE)])
        self.assertEqual(r['ttft_seconds'], {'reasoning': 1, 'content': 2, 'tool': None, 'any': 1})
        self.assertEqual(r['header_seconds'], .1)
        self.assertEqual(r['final_seconds'], 3)
        self.assertEqual(r['done_seconds'], 4.5)
        self.assertEqual(r['wall_seconds'], 5)
        self.assertEqual(r['client_decode_tokens_per_second'], 3)
        self.assertIsNone(r['server_timings'])
        self.assertNotIn('日本語', json.dumps(r, ensure_ascii=False))

    def test_reasoning_tool_only_and_single_chunk(self):
        for delta, kind, finish in [({'reasoning_content': 'x'}, 'reasoning', 'stop'),
                                     ({'tool_calls': [{'index': 0, 'function': {'name': 'f', 'arguments': '{}'}}]}, 'tool', 'tool_calls')]:
            r = run([(1, event(delta, finish)), (2, DONE)])
            self.assertEqual(r['ttft_seconds'][kind], 1)
            self.assertIsNone(r['ttft_seconds']['content'])
            self.assertIsNone(r['client_decode_tokens_per_second'])
        # Call IDs/index/type with no function payload are not generated text.
        r = run([(1, event({'tool_calls': [{'index': 0, 'id': 'id', 'type': 'function'}]})),
                 (2, event({}, 'tool_calls')), (3, DONE)])
        self.assertIsNone(r['ttft_seconds']['tool'])

    def test_fragmented_utf8_multiline_crlf(self):
        data = b'data: {"choices":\r\ndata: [{"index":0,"delta":{"content":"' + '赤'.encode() + b'"},"finish_reason":"stop"}]}\r\n\r\n'
        chunks = [(1 + i / 1000, bytes([b])) for i, b in enumerate(data)]
        r = run(chunks + [(2, DONE)])
        self.assertAlmostEqual(r['ttft_seconds']['content'], chunks[-1][0])

    def test_usage_is_not_tokens_and_server_allowlist(self):
        r = run([(1, event({'content': 'abc'})), (2, event({'content': 'def'}, 'stop')),
                 (3, event(usage={'completion_tokens': 4}, timings={'predicted_n': 4, 'predicted_ms': 250, 'prompt_ms': 50, 'prompt_n': 10, 'secret': 'NO'})), (4, DONE)])
        self.assertEqual(r['client_decode_tokens_per_second'], 4)
        self.assertEqual(r['server_timings']['predicted_ms'], 250)
        self.assertNotIn('secret', r['server_timings'])
        r = run([(1, event({'content': 'a'})), (2, event({'content': 'b'}, 'stop')), (3, DONE)])
        self.assertIsNone(r['usage'])
        self.assertIsNone(r['client_decode_tokens_per_second'])

    def test_fail_closed(self):
        invalid = [b'data: {bad}\n\n', b'data: {"error":{"message":"SECRET"}}\n\n',
                   b'data: {"choices":[{"index":1,"delta":{}}]}\n\n',
                   b'data: {"choices":[{"index":0,"delta":{"content":3}}]}\n\n',
                   b'data: {"choices":[],"usage":{"completion_tokens":true}}\n\n',
                   b'event: error\ndata: {}\n\n', b'data: \xff\n\n']
        for data in invalid:
            with self.subTest(data=data), self.assertRaises(m.MetricError):
                run([(1, data), (2, DONE)])
        for chunks in [[(1, event({'content': 'a'}))], [(1, DONE)],
                       [(1, event({}, 'length')), (2, DONE)],
                       [(1, event({}, 'stop')), (2, b'data: {}')]]:
            with self.assertRaises(m.MetricError):
                run(chunks)

    def test_timeout_budget_clock_and_http(self):
        with self.assertRaises(m.MetricError):
            run([(2, event({}, 'stop')), (3, DONE)], timeout_seconds=1)
        with self.assertRaises(m.MetricError):
            run([(1, event({}, 'stop', usage={'completion_tokens': 9})), (2, DONE)], max_output_tokens=8)
        c = m.Collector(10)
        with self.assertRaises(m.MetricError):
            c.headers(11, 503)
        with self.assertRaises(m.MetricError):
            c.feed(9, b'')
        with self.assertRaises(m.MetricError):
            run([(2, event({})), (1, event({}, 'stop')), (3, DONE)])
        with self.assertRaises(m.MetricError):
            run([(1, b'x' * 100)], max_bytes=32)

    def test_nonfinite_empty_usage_and_coalesced_events(self):
        with self.assertRaises(m.MetricError):
            run([(1, event({}, 'stop', timings={'prompt_ms': float('nan')})), (2, DONE)])
        r = run([(1, event({'content': ''})),
                 (2, event({'reasoning': 'r'}) + event({'content': 'a'}, 'stop') + event(usage=None) + DONE)])
        self.assertEqual(r['ttft_seconds']['any'], 2)
        self.assertIsNone(r['client_decode_tokens_per_second'])
        with self.assertRaises(m.MetricError):
            run([(1, event({}, 'stop')), (2, DONE), (3, event({}))])

    def test_preflight_metadata_contract(self):
        doc = json.loads((SCRIPT.parent / 'kyojin-preflight.json').read_text())
        self.assertEqual(doc['status'], 'incomplete_not_installable')
        packages = {p['name']: p for p in doc['packages']}
        for name in ['torch', 'tokenizers', 'numpy', 'rich', 'typing-extensions',
                     'safetensors', 'ninja', 'pillow', 'pyyaml', 'marisa-trie',
                     'pydantic', 'llguidance', 'aiohttp', 'jinja2', 'huggingface-hub',
                     'setuptools', 'wheel', 'rocm-sdk-devel']:
            self.assertIn(name, packages)
        total = 0
        for p in packages.values():
            a = p['artifact']
            self.assertRegex(a['hash'], r'^sha256:[0-9a-f]{64}$')
            self.assertEqual(a['head_status'], 200)
            self.assertTrue(a['url'].startswith('https://'))
            self.assertNotIn('@', a['url'])
            total += a.get('size', a['head_bytes'])
            for dep in p['dependency_names']:
                self.assertIn(dep, packages)
        self.assertEqual(doc['known_artifact_bytes'], total)
        self.assertEqual(packages['rocm']['kind'], 'sdist_or_missing')
        self.assertTrue(doc['blockers'])
        review = doc['rocm_sdist_review']
        self.assertTrue(review['archive_sha256_verified'])
        self.assertFalse(review['source_or_backend_executed'])
        self.assertEqual(review['build_system']['build-backend'], 'setuptools.build_meta')
        self.assertEqual(review['proposed_build_pins'], {
            'setuptools': packages['setuptools']['version'],
            'wheel': packages['wheel']['version'],
            'packaging': packages['packaging']['version']})
        self.assertEqual(review['proposed_build_environment'], {'ROCM_SDK_TARGET_FAMILY': 'gfx1151'})

    def test_summary_preserves_missing_and_rejects_mixed_failure(self):
        rows = [run([(n, event({'content': 'a'}, 'stop')), (4, DONE)]) for n in [1, 3, 2]]
        s = m.summarize(rows)
        self.assertEqual(s['content_ttft_seconds'], {'n': 3, 'missing': 0, 'median': 2, 'min': 1, 'max': 3})
        self.assertEqual(s['reasoning_ttft_seconds']['missing'], 3)
        self.assertIsNone(s['reasoning_ttft_seconds']['median'])

    def test_cli_replay_redacts_error_and_has_no_network_mode(self):
        fixture = {'synthetic': True, 'start_ns': 0, 'headers_ns': 1, 'status': 200,
                   'end_ns': 3_000_000_000, 'chunks': [
                       {'at_ns': 1_000_000_000, 'base64': base64.b64encode(event({'content': 'SAFE'}, 'stop')).decode()},
                       {'at_ns': 2_000_000_000, 'base64': base64.b64encode(DONE).decode()}]}
        p = subprocess.run([sys.executable, str(SCRIPT), 'replay'], input=json.dumps(fixture), text=True, capture_output=True)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertNotIn('SAFE', p.stdout + p.stderr)
        fixture['chunks'][0]['base64'] = base64.b64encode(b'data: SECRET\n\n').decode()
        p = subprocess.run([sys.executable, str(SCRIPT), 'replay'], input=json.dumps(fixture), text=True, capture_output=True)
        self.assertNotEqual(p.returncode, 0)
        self.assertNotIn('SECRET', p.stdout + p.stderr)
        self.assertNotIn('Traceback', p.stderr)


if __name__ == '__main__':
    unittest.main()
