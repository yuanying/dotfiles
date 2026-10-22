"""Offline fixtures; never imports code from a candidate wheel."""
import base64
import hashlib
import importlib.util
import io
from pathlib import Path
import tempfile
import tarfile
import unittest
from unittest.mock import patch
import zipfile

SPEC = importlib.util.spec_from_file_location('verify', Path(__file__).resolve().parents[1] / 'devbox/apps/llama-server/verify_artifacts.py')
v = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(v)


def fixture(path, additions=None, metadata=None):
    members = {
        'demo/__init__.py': b'raise RuntimeError("never execute")',
        'demo-1.0.dist-info/METADATA': metadata or b'Metadata-Version: 2.4\nName: demo\nVersion: 1.0\nLicense-Expression: MIT\nRequires-Python: >=3.12\n',
        'demo-1.0.dist-info/WHEEL': b'Wheel-Version: 1.0\nTag: py3-none-any\n',
        'demo-1.0.dist-info/licenses/LICENSE': b'MIT License\nPermission is hereby granted',
    }
    members.update(additions or {})
    record = ''.join(f'{n},sha256={base64.urlsafe_b64encode(hashlib.sha256(b).digest()).decode().rstrip("=")},{len(b)}\n' for n, b in members.items())
    members['demo-1.0.dist-info/RECORD'] = (record + 'demo-1.0.dist-info/RECORD,,\n').encode()
    with zipfile.ZipFile(path, 'w', zipfile.ZIP_DEFLATED) as z:
        for n, b in members.items():
            z.writestr(n, b)
    return {'name': 'demo', 'version': '1.0', 'dependency_names': [], 'artifact': {'head_bytes': path.stat().st_size, 'hash': 'sha256:' + hashlib.sha256(path.read_bytes()).hexdigest()}}


class VerifyTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / 'demo-1.0-py3-none-any.whl'

    def test_positive(self):
        p = fixture(self.path)
        r = v.inspect_wheel(self.path, p)
        self.assertEqual(r['record_verified_members'], 4)
        self.assertEqual(r['name'], 'demo')

    def test_vendored_metadata_is_not_root_metadata(self):
        p = fixture(self.path, {'demo/_vendor/other-2.dist-info/METADATA': b'Name: other\nVersion: 2\n'})
        self.assertEqual(v.inspect_wheel(self.path, p)['name'], 'demo')

    def test_nested_tar_notice_read_without_extraction(self):
        buf = io.BytesIO()
        with tarfile.open(fileobj=buf, mode='w') as t:
            data = b'MIT License\nPermission is hereby granted'
            i = tarfile.TarInfo('share/LICENSE')
            i.size = len(data)
            t.addfile(i, io.BytesIO(data))
        p = fixture(self.path, {'demo/_devel.tar': buf.getvalue()})
        r = v.inspect_wheel(self.path, p)
        self.assertEqual(r['nested_archives'][0]['regular_bytes'], len(data))
        self.assertTrue(any('_devel.tar!share/LICENSE' in n['path'] for n in r['licenses']))

    def test_nested_tar_traversal_rejected(self):
        buf = io.BytesIO()
        with tarfile.open(fileobj=buf, mode='w') as t:
            i = tarfile.TarInfo('../LICENSE')
            i.size = 3
            t.addfile(i, io.BytesIO(b'bad'))
        p = fixture(self.path, {'demo/_devel.tar': buf.getvalue()})
        with self.assertRaisesRegex(v.Rejected, 'path'):
            v.inspect_wheel(self.path, p)

    def test_hash_mismatch(self):
        p = fixture(self.path)
        p['artifact']['hash'] = 'sha256:' + '0' * 64
        with self.assertRaisesRegex(v.Rejected, 'hash'):
            v.inspect_wheel(self.path, p)

    def test_size(self):
        p = fixture(self.path)
        p['artifact']['head_bytes'] -= 1
        with self.assertRaisesRegex(v.Rejected, 'size'):
            v.inspect_wheel(self.path, p)

    def test_traversal(self):
        p = fixture(self.path, {'../escape': b'bad'})
        with self.assertRaisesRegex(v.Rejected, 'path'):
            v.inspect_wheel(self.path, p)

    def test_metadata_budget(self):
        p = fixture(self.path, metadata=b'x' * (v.TEXT_CAP + 1))
        with self.assertRaisesRegex(v.Rejected, 'budget'):
            v.inspect_wheel(self.path, p)

    def test_dependency_mismatch(self):
        rows = [{'name': 'demo', 'requires_dist': ['missing>=1'], 'requires_python': '>=3.12'}]
        issues, _ = v.closure(rows, {'demo': '1.0'})
        self.assertTrue(any('missing' in x for x in issues))

    def test_marker_and_extra_propagation(self):
        rows = [{'name': 'demo', 'requires_dist': ['other[fast]>=1', 'win; sys_platform == "win32"']}, {'name': 'other', 'requires_dist': ['missing; extra == "fast"']}]
        issues, _ = v.closure(rows, {'demo': '1', 'other': '1'})
        self.assertTrue(any('missing' in x for x in issues))
        self.assertFalse(any('win' in x for x in issues))

    def test_undeclared_extra(self):
        rows = [{'name': 'demo', 'requires_dist': ['other[unknown]']}, {'name': 'other', 'requires_dist': [], 'provides_extra': []}]
        issues, _ = v.closure(rows, {'demo': '1', 'other': '1'})
        self.assertTrue(any('undeclared' in i for i in issues))

    def test_python_mismatch(self):
        issues, _ = v.closure([{'name': 'demo', 'requires_python': '>=3.13', 'requires_dist': []}], {'demo': '1'})
        self.assertTrue(issues)

    def test_amd_nonstandard_record_is_not_pass(self):
        p = fixture(self.path)
        with zipfile.ZipFile(self.path) as z:
            members = {i.filename: z.read(i) for i in z.infolist()}
        record = 'demo-1.0.dist-info/RECORD'
        members[record] = ''.join(f'{n},sha256={hashlib.sha256(b).hexdigest()},{len(b)}\n' for n, b in members.items() if n != record).encode()
        with zipfile.ZipFile(self.path, 'w') as z:
            for name, data in members.items():
                z.writestr(name, data)
        p['artifact']['head_bytes'] = self.path.stat().st_size
        p['artifact']['hash'] = 'sha256:' + hashlib.sha256(self.path.read_bytes()).hexdigest()
        with self.assertRaisesRegex(v.Rejected, 'RECORD'):
            v.inspect_wheel(self.path, p)
        r = v.inspect_wheel(self.path, p, diagnostic=True)
        self.assertEqual(r['record_verified_members'], 0)
        self.assertEqual(r['record_hex_verified_members'], 4)
        self.assertTrue(any('self row absent' in i for i in r['record_issues']))
        self.assertEqual(r['record_unlisted_files'], [])

    def test_directory_and_detached_signature_exceptions(self):
        p = fixture(self.path)
        with zipfile.ZipFile(self.path, 'a') as z:
            z.writestr('demo/subdir/', b'')
            z.writestr('demo-1.0.dist-info/RECORD.jws', b'not authenticated')
        p['artifact']['head_bytes'] = self.path.stat().st_size
        p['artifact']['hash'] = 'sha256:' + hashlib.sha256(self.path.read_bytes()).hexdigest()
        r = v.inspect_wheel(self.path, p)
        self.assertEqual(r['record_issues'], [])
        self.assertEqual(r['record_unlisted_files'], [])
        self.assertIn('demo-1.0.dist-info/RECORD.jws', r['record_unhashed'])

    def test_unlisted_real_file_remains_security_issue(self):
        p = fixture(self.path)
        with zipfile.ZipFile(self.path, 'a') as z:
            z.writestr('demo/suspicious.so', b'not in RECORD')
        p['artifact']['head_bytes'] = self.path.stat().st_size
        p['artifact']['hash'] = 'sha256:' + hashlib.sha256(self.path.read_bytes()).hexdigest()
        with self.assertRaisesRegex(v.Rejected, 'unlisted real files'):
            v.inspect_wheel(self.path, p)
        r = v.inspect_wheel(self.path, p, diagnostic=True)
        self.assertEqual(r['record_unlisted_files'], ['demo/suspicious.so'])
        self.assertTrue(r['security_issues'])

    def test_record_tampering(self):
        p = fixture(self.path)
        # Rewrite member but retain original RECORD; publisher hash alone now passes.
        with zipfile.ZipFile(self.path) as z:
            members = {i.filename: z.read(i) for i in z.infolist()}
        members['demo/__init__.py'] = b'x' * len(members['demo/__init__.py'])
        with zipfile.ZipFile(self.path, 'w') as z:
            for name, data in members.items():
                z.writestr(name, data)
        p['artifact']['head_bytes'] = self.path.stat().st_size
        p['artifact']['hash'] = 'sha256:' + hashlib.sha256(self.path.read_bytes()).hexdigest()
        with self.assertRaisesRegex(v.Rejected, 'RECORD hash'):
            v.inspect_wheel(self.path, p)

    def test_symlink(self):
        p = fixture(self.path)
        with zipfile.ZipFile(self.path, 'a') as z:
            i = zipfile.ZipInfo('link')
            i.create_system = 3
            i.external_attr = 0o120777 << 16
            z.writestr(i, 'target')
        p['artifact']['head_bytes'] = self.path.stat().st_size
        p['artifact']['hash'] = 'sha256:' + hashlib.sha256(self.path.read_bytes()).hexdigest()
        with self.assertRaisesRegex(v.Rejected, 'special file'):
            v.inspect_wheel(self.path, p)

    def test_snapshot_hash(self):
        self.path.write_text('{}')
        with self.assertRaisesRegex(v.Rejected, 'snapshot hash'):
            v.load_snapshot(self.path)

    def test_dependency_version_mismatch(self):
        issues, _ = v.closure([{'name': 'demo', 'requires_dist': ['other>=2']}], {'demo': '1', 'other': '1'})
        self.assertTrue(issues)

    def test_prior_attempt_never_retried(self):
        p = fixture(self.path)
        p['artifact']['url'] = 'https://files.pythonhosted.org/demo.whl'
        (Path(self.tmp.name) / 'demo.whl.attempt').write_text('attempted')
        with patch.object(v.shutil, 'disk_usage', return_value=type('Disk', (), {'free': v.RESERVE + v.CAP})()):
            with self.assertRaisesRegex(v.Rejected, 'no retry'):
                v.acquire([p], Path(self.tmp.name))

    def test_transfer_failure_persists_attempt(self):
        p = fixture(self.path)
        p['artifact']['url'] = 'https://files.pythonhosted.org/download.whl'
        dest = Path(self.tmp.name) / 'downloads'
        class Response(io.BytesIO):
            status = 200
            headers = {'Content-Length': str(p['artifact']['head_bytes'])}
            def geturl(self):
                return p['artifact']['url']
        # A truncated response must fail and a second call must not open HTTP.
        response = Response(b'truncated')
        with patch.object(v.shutil, 'disk_usage', return_value=type('Disk', (), {'free': v.RESERVE + v.CAP})()), patch.object(v.urllib.request, 'build_opener') as opener:
            opener.return_value.open.return_value = response
            with self.assertRaisesRegex(v.Rejected, 'size'):
                v.acquire([p], dest)
            self.assertTrue((dest / 'download.whl.attempt').exists())
            self.assertTrue((dest / 'download.whl.partial').exists())
            opener.return_value.open.reset_mock()
            with self.assertRaisesRegex(v.Rejected, 'no retry'):
                v.acquire([p], dest)
            opener.return_value.open.assert_not_called()

    def test_successful_cache_never_fetches(self):
        p = fixture(self.path)
        p['artifact']['url'] = 'https://files.pythonhosted.org/' + self.path.name
        with patch.object(v.shutil, 'disk_usage', return_value=type('Disk', (), {'free': v.RESERVE + v.CAP})()), patch.object(v.urllib.request, 'build_opener') as opener:
            self.assertEqual(v.acquire([p], Path(self.tmp.name)), 0)
            opener.return_value.open.assert_not_called()

    def test_redirect_rejected(self):
        with self.assertRaises(v.Rejected):
            v.NoRedirect().redirect_request(None, None, 302, '', {}, 'https://evil.invalid/a')


if __name__ == '__main__':
    unittest.main()
