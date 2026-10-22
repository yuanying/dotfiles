#!/usr/bin/env python3
"""Bounded, non-executing ZIP metadata preview; NOT a wheel integrity verifier."""
import argparse
import hashlib
import io
import json
import pathlib
import urllib.request
import zipfile


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        raise ValueError('redirect prohibited')


OPEN = urllib.request.build_opener(NoRedirect()).open


class RangeFile(io.RawIOBase):
    def __init__(self, url, size, etag, *, opener=OPEN, budget=4 * 1024 * 1024):
        if not url.startswith('https://') or size <= 0 or not etag:
            raise ValueError('HTTPS, positive size and stable ETag required')
        self.url, self.size, self.etag = url, size, etag
        self.opener, self.budget = opener, budget
        self.pos = self.used = self.requests = 0

    def seekable(self): return True
    def tell(self): return self.pos

    def seek(self, offset, whence=0):
        pos = offset + (0 if whence == 0 else self.pos if whence == 1 else self.size if whence == 2 else -self.size-1)
        if whence not in (0, 1, 2) or not 0 <= pos <= self.size:
            raise ValueError('seek outside file')
        self.pos = pos
        return pos

    def read(self, size=-1):
        n = self.size-self.pos if size < 0 else min(size, self.size-self.pos)
        if n == 0: return b''
        if n > 2 * 1024 * 1024 or self.used+n > self.budget or self.requests >= 64:
            raise ValueError('Range metadata budget exceeded')
        start, end = self.pos, self.pos+n-1
        req = urllib.request.Request(self.url, headers={
            'Range': f'bytes={start}-{end}', 'If-Match': self.etag, 'Accept-Encoding': 'identity'})
        self.requests += 1
        with self.opener(req, timeout=60) as response:
            if response.status != 206:
                raise ValueError('Range requires HTTP206; body not read')
            if response.headers.get('Content-Range') != f'bytes {start}-{end}/{self.size}':
                raise ValueError('Content-Range mismatch')
            if response.headers.get('ETag') != self.etag:
                raise ValueError('ETag changed')
            if response.headers.get('Content-Length') != str(n):
                raise ValueError('Content-Length mismatch')
            if response.headers.get('Content-Encoding', 'identity') != 'identity':
                raise ValueError('unexpected content encoding')
            body = response.read(n+1)
        self.used += len(body)
        if len(body) != n: raise ValueError('Range size mismatch')
        self.pos += n
        return body


def inspect_metadata(source):
    members = {}
    with zipfile.ZipFile(source) as archive:
        names = archive.namelist()
        if len(names) != len(set(names)): raise ValueError('duplicate ZIP path')
        for item in archive.infolist():
            path = pathlib.PurePosixPath(item.filename)
            if path.is_absolute() or '..' in path.parts or '\\' in item.filename:
                raise ValueError('unsafe ZIP path')
            if len(path.parts) != 2 or not path.parts[0].endswith('.dist-info'):
                continue
            if path.name not in ('METADATA', 'WHEEL', 'LICENSE', 'LICENSE.txt', 'NOTICE'):
                continue
            if item.file_size > 1024 * 1024: raise ValueError('member expansion budget exceeded')
            content = archive.read(item)
            members[item.filename] = {'sha256': hashlib.sha256(content).hexdigest(),
                                      'size': len(content), 'text': content.decode('utf-8')}
    return {'preview_only': True, 'whole_wheel_sha256_verified': False,
            'record_verified': False, 'members': members,
            'range_body_bytes': source.used, 'range_requests': source.requests}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('url')
    parser.add_argument('output', type=pathlib.Path)
    args = parser.parse_args()
    if not args.url.startswith('https://rocm.nightlies.amd.com/v2/gfx1151/'):
        parser.error('only official v2/gfx1151 URLs permitted')
    if args.output.exists(): parser.error('output exists; refusing overwrite')
    with OPEN(urllib.request.Request(args.url, method='HEAD'), timeout=60) as response:
        size, etag = int(response.headers['Content-Length']), response.headers['ETag']
    source = RangeFile(args.url, size, etag)
    result = inspect_metadata(source)
    result.update(url=args.url, compressed_bytes=size, etag=etag,
                  publisher_sha256=None)
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({key: result[key] for key in ('compressed_bytes', 'range_body_bytes', 'range_requests')}))


if __name__ == '__main__': main()
