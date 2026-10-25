"""Offline archive deployment gate fixtures; no candidate imports."""
import importlib.util
import io
from pathlib import Path
import tarfile
import unittest

spec = importlib.util.spec_from_file_location('trial', Path(__file__).resolve().parents[1] / 'devbox/apps/llama-server/kyojin_trial.py')
trial = importlib.util.module_from_spec(spec)
spec.loader.exec_module(trial)


def archive(entries):
    stream = io.BytesIO()
    with tarfile.open(fileobj=stream, mode='w') as out:
        for name, kind, target in entries:
            info = tarfile.TarInfo(name)
            info.type = kind
            info.linkname = target
            out.addfile(info)
    stream.seek(0)
    return tarfile.open(fileobj=stream, mode='r|')


class GateTests(unittest.TestCase):
    def check(self, entries):
        return trial.audit_tar(archive(entries))

    def test_internal_and_cross_package_links(self):
        self.assertEqual(self.check([('_rocm_sdk_devel/lib/x', tarfile.SYMTYPE, '../../_rocm_sdk_core/lib/x')])['links'], 1)

    def test_parent_escape(self):
        with self.assertRaises(ValueError):
            self.check([('a', tarfile.SYMTYPE, '../outside')])

    def test_absolute(self):
        with self.assertRaises(ValueError):
            self.check([('/absolute', tarfile.REGTYPE, '')])

    def test_link_parent_write(self):
        with self.assertRaises(ValueError):
            self.check([('a', tarfile.SYMTYPE, 'b'), ('a/payload', tarfile.REGTYPE, '')])

    def test_cycle(self):
        with self.assertRaises(ValueError):
            self.check([('a', tarfile.SYMTYPE, 'b'), ('b', tarfile.SYMTYPE, 'a')])

    def test_device_duplicate_and_budget(self):
        for entries in [[('a', tarfile.CHRTYPE, '')], [('a', tarfile.REGTYPE, ''), ('a', tarfile.REGTYPE, '')]]:
            with self.assertRaises(ValueError):
                self.check(entries)
        with self.assertRaises(ValueError):
            trial.audit_tar(archive([('a', tarfile.REGTYPE, '')]), max_members=0)


if __name__ == '__main__':
    unittest.main()
