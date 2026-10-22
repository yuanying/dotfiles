#!/usr/bin/env python3
"""Offline inspection of one pinned v2 SDK; scoped streaming budget adjustment."""
import argparse
import hashlib
import importlib.util
import json
import pathlib

REFERENCE_SHA256 = '3a12637c49b98c5c33f8623e2ee44f5d9a165b083b2505f9a3c19028c2cfddce'
WHEEL_SHA256 = '78c4c209e4c65f3571674f12127043945ebd3293e899c8da2d8276cc77aa52be'
WHEEL_NAME = 'rocm_sdk_devel-7.13.0a20260411-py3-none-linux_x86_64.whl'
WHEEL_BYTES = 1710689059
REPLACEMENTS = {
    "require(result['regular_bytes'] <= 8 * 1024**3, 'nested tar aggregate budget exceeded')":
    "require(result['regular_bytes'] <= (12 if info.filename == 'rocm_sdk_devel/_devel.tar' else 8) * 1024**3, 'nested tar aggregate budget exceeded')",
    "require(i.file_size <= 8 * 1024**3 and i.file_size <= max(1, i.compress_size) * 2000, 'ZIP expansion budget exceeded')":
    "require(i.file_size <= (12 if i.filename == 'rocm_sdk_devel/_devel.tar' else 8) * 1024**3 and i.file_size <= max(1, i.compress_size) * 2000, 'ZIP expansion budget exceeded')",
}


def derive(source):
    if hashlib.sha256(source).hexdigest() != REFERENCE_SHA256:
        raise ValueError('reference source hash mismatch')
    text = source.decode('utf-8')
    for old, new in REPLACEMENTS.items():
        if text.count(old) != 1: raise ValueError('unexpected patch context')
        text = text.replace(old, new)
    return text.encode('utf-8')


def digest_file(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        while chunk := stream.read(1024 * 1024): h.update(chunk)
    return h.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference', required=True, type=pathlib.Path)
    parser.add_argument('--wheel', required=True, type=pathlib.Path)
    parser.add_argument('--derived-source', required=True, type=pathlib.Path)
    parser.add_argument('--report', required=True, type=pathlib.Path)
    args = parser.parse_args()
    if args.derived_source.exists() or args.report.exists():
        parser.error('refusing to overwrite evidence')
    if (args.wheel.is_symlink() or args.wheel.name != WHEEL_NAME or
            args.wheel.stat().st_size != WHEEL_BYTES or digest_file(args.wheel) != WHEEL_SHA256):
        parser.error('only the reviewed fixed SDK wheel is permitted')
    derived = derive(args.reference.read_bytes())
    args.derived_source.write_bytes(derived)
    spec = importlib.util.spec_from_file_location('scoped_sdk_verifier', args.derived_source)
    verifier = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(verifier)  # Our hash-pinned verifier, never candidate code.
    package = {'name': 'rocm-sdk-devel', 'version': '7.13.0a20260411',
               'artifact': {'size': WHEEL_BYTES, 'head_bytes': WHEEL_BYTES, 'hash': 'sha256:' + WHEEL_SHA256}}
    row = verifier.inspect_wheel(args.wheel, package, diagnostic=True)
    passed = not row['record_issues'] and not row['security_issues']
    result = {'reference_sha256': REFERENCE_SHA256,
              'derived_source_sha256': hashlib.sha256(derived).hexdigest(),
              'resource_adjustment_only': True, 'member_budget_gib': 12,
              'tar_regular_aggregate_budget_gib': 12, 'other_member_budget_gib': 8,
              'reason': 'pinned _devel.tar is 9252270080 bytes; read-only streaming, no extraction or link following',
              'whole_wheel_hash_origin': 'local SHA256 from official HTTPS/ETag acquisition, not publisher SHA256',
              'wheel_integrity_and_record_passed': passed, 'install_performed': False, 'row': row}
    args.report.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({key: val for key, val in result.items() if key != 'row'}))
    raise SystemExit(0 if passed else 1)


if __name__ == '__main__': main()
