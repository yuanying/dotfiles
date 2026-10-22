#!/usr/bin/env python3
import hashlib
import importlib.util
import pathlib
import unittest
from unittest.mock import patch

PATH = pathlib.Path(__file__).resolve().parents[1] / 'devbox/apps/llama-server/verify_v2_sdk.py'
spec = importlib.util.spec_from_file_location('verify_v2_sdk', PATH)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class BudgetTests(unittest.TestCase):
    def test_exact_scoped_resource_changes_only(self):
        source = '\n'.join(m.REPLACEMENTS)
        digest = hashlib.sha256(source.encode()).hexdigest()
        with patch.object(m, 'REFERENCE_SHA256', digest):
            derived = m.derive(source.encode()).decode()
        for old, new in m.REPLACEMENTS.items():
            self.assertIn(new, derived)
            self.assertNotIn(old, derived)
        self.assertIn("i.filename == 'rocm_sdk_devel/_devel.tar'", derived)
        self.assertIn("info.filename == 'rocm_sdk_devel/_devel.tar'", derived)

    def test_source_hash_mismatch_stops(self):
        with self.assertRaisesRegex(ValueError, 'source hash'): m.derive(b'bad')

    def test_missing_or_duplicate_patch_context_stops(self):
        for source in ['', '\n'.join(m.REPLACEMENTS) * 2]:
            with patch.object(m, 'REFERENCE_SHA256', hashlib.sha256(source.encode()).hexdigest()):
                with self.assertRaisesRegex(ValueError, 'patch context'): m.derive(source.encode())


if __name__ == '__main__': unittest.main()
