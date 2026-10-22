#!/usr/bin/env python3
import importlib.util
import io
import pathlib
import unittest
import zipfile

MODULE = pathlib.Path(__file__).resolve().parents[1] / 'devbox/apps/llama-server/wheel_metadata.py'
spec = importlib.util.spec_from_file_location('wheel_metadata', MODULE)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class Response(io.BytesIO):
    def __init__(self, body, status=206, headers=None):
        super().__init__(body)
        self.status = status
        self.headers = headers or {}


class RangeTests(unittest.TestCase):
    def make(self, body, status=206, wrong_range=False, cap=1024 * 1024):
        calls = []
        def opener(req, timeout):
            calls.append(req)
            start, end = map(int, req.headers['Range'][6:].split('-'))
            return Response(body[start:end+1], status, {
                'Content-Range': 'bad' if wrong_range else f'bytes {start}-{end}/{len(body)}',
                'Content-Length': str(end-start+1), 'ETag': '"fixed"'})
        return m.RangeFile('https://example.org/a.whl', len(body), '"fixed"',
                           opener=opener, budget=cap), calls

    def test_zip_metadata_without_execution(self):
        buf = io.BytesIO()
        with zipfile.ZipFile(buf, 'w', zipfile.ZIP_DEFLATED) as z:
            z.writestr('a-1.dist-info/METADATA', 'Name: a\nVersion: 1\n')
            z.writestr('a-1.dist-info/WHEEL', 'Wheel-Version: 1.0\n')
            z.writestr('a/__init__.py', 'raise RuntimeError("never execute")')
        f, calls = self.make(buf.getvalue())
        result = m.inspect_metadata(f)
        self.assertIn('Name: a', result['members']['a-1.dist-info/METADATA']['text'])
        self.assertGreater(len(calls), 0)

    def test_200_is_closed_without_body_read(self):
        class NoRead(Response):
            def read(self, *args): raise AssertionError('must not read HTTP200')
        r = NoRead(b'huge', 200)
        f = m.RangeFile('https://example.org/a', 4, 'x', opener=lambda *a, **k: r)
        with self.assertRaisesRegex(ValueError, '206'): f.read(1)
        self.assertTrue(r.closed)

    def test_wrong_content_range(self):
        f, _ = self.make(b'abc', wrong_range=True)
        with self.assertRaisesRegex(ValueError, 'Content-Range'): f.read(1)

    def test_budget_before_request(self):
        f, calls = self.make(b'abc', cap=1)
        with self.assertRaisesRegex(ValueError, 'budget'): f.read(2)
        self.assertEqual(calls, [])

    def test_etag_change(self):
        f = m.RangeFile('https://example.org/a', 2, 'original', opener=lambda *a, **k:
                        Response(b'ab', headers={'ETag': 'changed'}))
        with self.assertRaises(ValueError): f.read(2)

    def test_request_count_cap(self):
        f, calls = self.make(b'abc')
        f.requests = 64
        with self.assertRaisesRegex(ValueError, 'budget'): f.read(1)
        self.assertEqual(calls, [])

    def test_compressed_response_is_rejected_without_read(self):
        class NoRead(Response):
            def read(self, *args): raise AssertionError('compressed body must not be read')
        r = NoRead(b'x', headers={'Content-Range': 'bytes 0-0/1',
                     'Content-Length': '1', 'ETag': 'x', 'Content-Encoding': 'gzip'})
        f = m.RangeFile('https://example.org/a', 1, 'x', opener=lambda *a, **k: r)
        with self.assertRaisesRegex(ValueError, 'encoding'): f.read(1)

    def test_paths_and_expansion_limits(self):
        for name, content in [('../a.dist-info/METADATA', 'x'),
                              ('a.dist-info/METADATA', 'x' * 1048577)]:
            buf = io.BytesIO()
            with zipfile.ZipFile(buf, 'w', zipfile.ZIP_DEFLATED) as z: z.writestr(name, content)
            f, _ = self.make(buf.getvalue())
            with self.assertRaises(ValueError): m.inspect_metadata(f)


if __name__ == '__main__': unittest.main()
