import importlib.util
import io
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('live', Path(__file__).resolve().parents[1] / 'devbox/apps/llama-server/qwen_stream_live.py')
live = importlib.util.module_from_spec(spec)
spec.loader.exec_module(live)


class Response:
    status = 200
    def __init__(self):
        self.chunks = iter([b': heartbeat\n\n', b'data: {"choices":[{"index":0,"delta":{"content":"ok"},"finish_reason":null}]}\n\n', b'data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"completion_tokens":1}}\n\ndata: [DONE]\n\n', b''])
    def read1(self, size):
        return next(self.chunks)


class FakeCollector:
    def __init__(self, start): self.start = start; self.calls = []
    def headers(self, at, status): self.calls.append(('header', at, status))
    def feed(self, at, data): self.calls.append(('feed', at, data))
    def finish(self, at): return self.calls + [('end', at)]


class LiveTests(unittest.TestCase):
    def test_arrivals_and_private_copy(self):
        ticks = iter(range(100, 120)); c = FakeCollector(99); out = io.BytesIO()
        result = live.receive(Response(), c, out, lambda: next(ticks))
        self.assertEqual([x[0] for x in result], ['header', 'feed', 'feed', 'feed', 'end'])
        self.assertEqual(result[2][1], 102)
        self.assertIn(b'heartbeat', out.getvalue())

    def test_bad_budget(self):
        for request in ({}, {'stream': True, 'max_tokens': 257}, {'stream': False, 'max_tokens': 1}):
            with self.assertRaises(ValueError): live.validate_request(request)

    def test_hosts(self):
        live.validate_url('http://127.0.0.1:18082/v1/chat/completions')
        live.validate_url('http://llama-server:8082/v1/chat/completions')
        for url in ['https://example.com/v1/chat/completions', 'http://user:secret@localhost:8082/v1/chat/completions']:
            with self.assertRaises(ValueError): live.validate_url(url)


if __name__ == '__main__': unittest.main()
