#!/usr/bin/env python3
"""Fixed Stage-A artifact acquisition and offline ZIP verification. No install/import/build.

Uses only stdlib plus the *existing* pip-vendored packaging parser. Candidate
code is never loaded. Input is the separate, reviewed preflight snapshot.
"""
import argparse
import base64
import csv
from email.parser import BytesParser
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import sys
import tarfile
import urllib.parse
import urllib.request
import zipfile

from pip._vendor.packaging.markers import default_environment
from pip._vendor.packaging.requirements import Requirement
from pip._vendor.packaging.specifiers import SpecifierSet
from pip._vendor.packaging.tags import sys_tags, parse_tag
from pip._vendor.packaging.utils import canonicalize_name, parse_wheel_filename

SNAPSHOT_SHA256 = '64343f512b2037dc6a3f5e894ffdb5a17849442b92811d6edea12a5db5431162'
CAP = 3 * 1024**3
RESERVE = 50 * 1024**3
TEXT_CAP = 4 * 1024**2
NOTICE_CAP = 64 * 1024**2
EXPANDED_CAP = 32 * 1024**3
CHUNK = 1024**2
HOSTS = {'files.pythonhosted.org', 'rocm.nightlies.amd.com'}


class Rejected(ValueError):
    pass


def require(ok, reason):
    if not ok:
        raise Rejected(reason)


def digest_file(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        while block := f.read(CHUNK):
            h.update(block)
    return h.hexdigest()


def artifact_size(p):
    a = p['artifact']
    return a.get('size', a['head_bytes'])


def check_file(path, p):
    require(not path.is_symlink() and path.is_file(), 'not a regular artifact')
    require(path.stat().st_size == artifact_size(p), 'artifact size mismatch')
    require('sha256:' + digest_file(path) == p['artifact']['hash'], 'artifact hash mismatch')


def safe_name(n):
    require(n and '\\' not in n and '\x00' not in n and ':' not in n and not n.startswith('/') and '..' not in n.split('/') and '.' not in n.split('/'), 'unsafe ZIP path')
    return n


def bounded_read(z, info, cap):
    require(info.file_size <= cap, 'metadata/notice budget exceeded')
    with z.open(info) as f:
        data = f.read(cap + 1)
    require(len(data) == info.file_size and len(data) <= cap, 'metadata/notice budget exceeded')
    return data


def inspect_tar(z, info):
    """Stream an uncompressed nested tar. No extraction, link following or recursion.

    Parse fixed headers ourselves so PAX/long-name allocation has a text cap.
    TarInfo.frombuf only parses/checks one 512-byte header.
    """
    result = {'path': info.filename, 'members': 0, 'regular_bytes': 0, 'links': []}
    notices = []
    pending = {}
    globals_ = {}
    seen = set()
    with z.open(info) as f:
        def read_exact(n, retain=False):
            require(n >= 0 and n <= info.file_size, 'nested tar size budget exceeded')
            require(not retain or n <= TEXT_CAP, 'nested tar text budget exceeded')
            chunks = []
            left = n
            while left:
                b = f.read(min(left, CHUNK))
                require(bool(b), 'truncated nested tar')
                left -= len(b)
                if retain:
                    chunks.append(b)
            return b''.join(chunks)
        while True:
            header = f.read(512)
            require(len(header) == 512, 'truncated nested tar header')
            if not any(header):
                break
            member = tarfile.TarInfo.frombuf(header, 'utf-8', 'strict')
            result['members'] += 1
            require(result['members'] <= 100000 and member.size <= 8 * 1024**3, 'nested tar member budget exceeded')
            if member.type in (tarfile.XHDTYPE, tarfile.XGLTYPE, tarfile.GNUTYPE_LONGNAME, tarfile.GNUTYPE_LONGLINK):
                raw = read_exact(member.size, retain=True)
                read_exact((-member.size) % 512)
                if member.type in (tarfile.GNUTYPE_LONGNAME, tarfile.GNUTYPE_LONGLINK):
                    pending['path' if member.type == tarfile.GNUTYPE_LONGNAME else 'linkpath'] = raw.rstrip(b'\x00\n').decode('utf-8')
                else:
                    pos = 0
                    parsed = {}
                    while pos < len(raw):
                        space = raw.find(b' ', pos)
                        require(space > pos and raw[pos:space].isdigit(), 'invalid nested PAX')
                        length = int(raw[pos:space])
                        require(length > space - pos + 1 and pos + length <= len(raw), 'invalid nested PAX size')
                        key, sep, value = raw[space + 1:pos + length - 1].partition(b'=')
                        require(bool(sep), 'invalid nested PAX field')
                        parsed[key.decode()] = value.decode()
                        pos += length
                    require(not any(k.startswith('GNU.sparse') for k in parsed), 'nested sparse tar unsupported')
                    (globals_ if member.type == tarfile.XGLTYPE else pending).update(parsed)
                continue
            attrs = {**globals_, **pending}
            pending = {}
            name = attrs.get('path', member.name)
            while name.startswith('./'):
                name = name[2:]
            if name not in ('', '.') or not member.isdir():
                safe_name(name)
            require(name not in seen, 'duplicate nested tar path')
            seen.add(name)
            size = int(attrs.get('size', member.size))
            require(0 <= size <= 8 * 1024**3, 'nested tar size budget exceeded')
            if member.isreg():
                result['regular_bytes'] += size
                require(result['regular_bytes'] <= 8 * 1024**3, 'nested tar aggregate budget exceeded')
                is_notice = bool(re.search(r'(?i)(license|licence|copying|notice|copyright)', PurePosixPath(name).name))
                data = read_exact(size, retain=is_notice)
                if is_notice:
                    require(sum(n['bytes'] for n in notices) + size <= NOTICE_CAP, 'nested notice budget exceeded')
                    notices.append({'path': info.filename + '!' + name, 'bytes': size, 'sha256': hashlib.sha256(data).hexdigest(), 'text': data.decode('utf-8', errors='replace')})
            else:
                require(member.isdir() or member.issym() or member.islnk(), 'nested special file unsupported')
                if member.issym() or member.islnk():
                    result['links'].append({'path': name, 'target': attrs.get('linkpath', member.linkname), 'type': 'symlink' if member.issym() else 'hardlink', 'resolution': 'not_followed_not_deployment_validated'})
                read_exact(size)
            read_exact((-size) % 512)
    return result, notices


def inspect_wheel(path, p, diagnostic=False):
    check_file(path, p)
    # CPython's EOCD reader also handles ZIP64, without allocating the central
    # directory. Bound that allocation before ZipFile builds its member list.
    with path.open('rb') as f:
        end = zipfile._EndRecData(f)
    require(end is not None and end[zipfile._ECD_SIZE] <= 64 * 1024**2
            and end[zipfile._ECD_ENTRIES_TOTAL] <= 200000, 'ZIP directory budget exceeded')
    with zipfile.ZipFile(path) as z:
        infos = z.infolist()
        require(len(infos) <= 200000, 'ZIP entry budget exceeded')
        names = [i.filename for i in infos]
        require(len(names) == len(set(names)), 'duplicate ZIP path')
        expanded = sum(i.file_size for i in infos)
        require(expanded <= EXPANDED_CAP, 'expanded budget exceeded')
        for i in infos:
            safe_name(i.filename)
            mode = i.external_attr >> 16
            require(not stat.S_ISLNK(mode) and stat.S_IFMT(mode) in (0, stat.S_IFREG, stat.S_IFDIR), 'ZIP special file')
            require(not i.flag_bits & 1, 'encrypted ZIP')
            require(i.file_size <= 8 * 1024**3 and i.file_size <= max(1, i.compress_size) * 2000, 'ZIP expansion budget exceeded')
        meta = [i for i in infos if i.filename.endswith('.dist-info/METADATA') and i.filename.count('/') == 1]
        require(len(meta) == 1, 'METADATA count mismatch')
        root = meta[0].filename.rsplit('/', 1)[0]
        require('/' not in root, 'nested dist-info')
        m = BytesParser().parsebytes(bounded_read(z, meta[0], TEXT_CAP))
        require(canonicalize_name(m['Name'] or '') == canonicalize_name(p['name']) and m['Version'] == p['version'], 'METADATA identity mismatch')
        w = BytesParser().parsebytes(bounded_read(z, z.getinfo(root + '/WHEEL'), TEXT_CAP))
        require(w['Wheel-Version'] == '1.0', 'unsupported WHEEL version')
        tags = set().union(*(parse_tag(t) for t in w.get_all('Tag', [])))
        filename_tags = parse_wheel_filename(path.name)[3]
        require(tags == filename_tags and bool(tags & set(sys_tags())), 'ABI/platform tag mismatch')
        licenses = []
        notice_bytes = 0
        for i in infos:
            if i.is_dir() or not re.search(r'(?i)(license|licence|copying|notice|copyright)', PurePosixPath(i.filename).name):
                continue
            data = bounded_read(z, i, TEXT_CAP)
            notice_bytes += len(data)
            require(notice_bytes <= NOTICE_CAP, 'notice aggregate budget exceeded')
            licenses.append({'path': i.filename, 'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest(), 'text': data.decode('utf-8', errors='replace')})
        nested_archives = []
        for info in infos:
            if info.filename.endswith('.tar'):
                nested, notices = inspect_tar(z, info)
                nested_archives.append(nested)
                licenses.extend(notices)
                notice_bytes += sum(n['bytes'] for n in notices)
                require(notice_bytes <= NOTICE_CAP, 'notice aggregate budget exceeded')
        for declared in m.get_all('License-File', []):
            safe_name(declared)
            require(root + '/licenses/' + declared in names or root + '/' + declared in names, 'missing declared license')
        recpath = root + '/RECORD'
        record_data = bounded_read(z, z.getinfo(recpath), TEXT_CAP).decode('utf-8')
        records = list(csv.reader(io.StringIO(record_data)))
        require(all(len(row) == 3 for row in records), 'invalid RECORD row')
        record = {row[0]: row[1:] for row in records}
        require(len(record) == len(records), 'duplicate RECORD row')
        files = {i.filename for i in infos if not i.is_dir()}
        exempt = {recpath, recpath + '.jws', recpath + '.p7s'}
        unlisted = sorted(files - exempt - set(record))
        absent = sorted(set(record) - files)
        record_issues = []
        security_issues = []
        if recpath not in record:
            record_issues.append('RECORD self row absent')
        if unlisted:
            security_issues.append('RECORD unlisted real files')
        if absent:
            security_issues.append('RECORD references absent files')
        verified = hex_verified = 0
        unverified = []
        for name, (value, size) in record.items():
            safe_name(name)
            if name == recpath:
                if value or size:
                    record_issues.append('RECORD self hash/size not empty')
                continue
            if name not in files:
                continue
            info = z.getinfo(name)
            if not size.isdigit() or int(size) != info.file_size:
                security_issues.append('RECORD size mismatch: ' + name)
            algorithm, _, encoded = value.partition('=')
            if algorithm not in ('sha256', 'sha384', 'sha512') or not encoded:
                record_issues.append('RECORD unsupported/missing digest: ' + name)
                unverified.append(name)
                continue
            h = hashlib.new(algorithm)
            count = 0
            with z.open(info) as f:
                while block := f.read(CHUNK):
                    count += len(block)
                    require(count <= info.file_size, 'stream expansion exceeded')
                    h.update(block)
            require(count == info.file_size, 'stream size mismatch')
            if encoded == base64.urlsafe_b64encode(h.digest()).decode().rstrip('='):
                verified += 1
            elif encoded == h.hexdigest():
                # Diagnostic evidence only. Hex is NOT wheel-standard base64url.
                hex_verified += 1
                record_issues.append('RECORD nonstandard hex digest: ' + name)
            else:
                security_issues.append('RECORD hash mismatch: ' + name)
                unverified.append(name)
        if not diagnostic:
            require(not record_issues and not security_issues, '; '.join(record_issues + security_issues))
        return {'name': p['name'], 'version': p['version'], 'filename': path.name,
                'bytes': path.stat().st_size, 'sha256': digest_file(path),
                'expanded_bytes': expanded, 'compressed_member_bytes': sum(i.compress_size for i in infos),
                'record_verified_members': verified, 'record_hex_verified_members': hex_verified,
                'record_issues': record_issues, 'security_issues': security_issues,
                'record_unlisted_files': unlisted, 'record_absent_files': absent,
                'record_unverified_members': unverified + unlisted,
                'record_unhashed': sorted(files & exempt),
                'requires_python': m.get('Requires-Python'), 'requires_dist': m.get_all('Requires-Dist', []),
                'provides_extra': m.get_all('Provides-Extra', []), 'tags': sorted(map(str, tags)),
                'wheel_version': w.get('Wheel-Version'), 'root_is_purelib': w.get('Root-Is-Purelib'),
                'license_expression': m.get('License-Expression'), 'license': m.get('License'),
                'license_classifiers': [x for x in m.get_all('Classifier', []) if x.startswith('License ::')],
                'licenses': licenses, 'nested_archives': nested_archives}


def closure(rows, versions, initial_extras=None):
    """All selected packages are roots; propagate dependency extras to a fixed point.

    Explicit CPython3.12/Linux environment, never the evaluator's Python markers.
    The dynamic rocm sdist edges are separately supplied from its static review.
    """
    env = default_environment()
    env.update(python_version='3.12', python_full_version='3.12.10', sys_platform='linux',
               platform_system='Linux', platform_machine='x86_64', os_name='posix',
               implementation_name='cpython', implementation_version='3.12.10', platform_python_implementation='CPython')
    versions = {canonicalize_name(k): val for k, val in versions.items()}
    extras = {k: set() for k in versions}
    for k, val in (initial_extras or {}).items():
        extras[canonicalize_name(k)].update(val)
    issues = set()
    provided = {canonicalize_name(r['name']): set(map(canonicalize_name, r['provides_extra']))
                for r in rows if 'provides_extra' in r}
    evaluated = []
    changed = True
    while changed:
        changed = False
        evaluated = []
        for row in rows:
            name = canonicalize_name(row['name'])
            if row.get('requires_python') and not SpecifierSet(row['requires_python']).contains('3.12.10', prereleases=True):
                issues.add(name + ': Requires-Python mismatch')
            for raw in row.get('requires_dist', []):
                r = Requirement(raw)
                active = not r.marker or any(r.marker.evaluate({**env, 'extra': extra}) for extra in {''} | extras.get(name, set()))
                evaluated.append({'from': name, 'requirement': raw, 'active': active})
                if not active:
                    continue
                dep = canonicalize_name(r.name)
                if r.url or dep not in versions or not r.specifier.contains(versions[dep], prereleases=True):
                    issues.add(name + ': missing/incompatible ' + raw)
                else:
                    requested = set(map(canonicalize_name, r.extras))
                    if dep in provided and not requested <= provided[dep]:
                        issues.add(name + ': undeclared dependency extra ' + raw)
                    if not requested <= extras[dep]:
                        extras[dep].update(requested)
                        changed = True
    return sorted(issues), evaluated


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise Rejected('redirect forbidden; stop for review')


def load_snapshot(path):
    require(path.stat().st_size <= 1024**2 and digest_file(path) == SNAPSHOT_SHA256, 'fixed snapshot hash mismatch')
    data = json.loads(path.read_text())
    wheels = [p for p in data['packages'] if p['kind'] == 'wheel']
    require(len(wheels) == 54 and sum(artifact_size(p) for p in wheels) == 2412419726, 'fixed selection/count/size mismatch')
    names = set()
    for p in wheels:
        a = p['artifact']
        u = urllib.parse.urlsplit(a['url'])
        require(u.scheme == 'https' and u.hostname in HOSTS and not u.username and not u.password and not u.query and not u.fragment and u.port in (None, 443), 'artifact origin rejected')
        filename = urllib.parse.unquote(u.path.rsplit('/', 1)[1])
        safe_name(filename)
        require('/' not in filename and filename.endswith('.whl') and filename not in names, 'invalid artifact filename')
        names.add(filename)
        require(re.fullmatch('sha256:[0-9a-f]{64}', a['hash']) and artifact_size(p) > 0, 'invalid artifact declaration')
    return data, wheels


def acquire(wheels, dest):
    """One request per artifact, no redirect, retry, resume, or implicit proxy.

    The durable .attempt marker is written *before* opening the network. A failed
    transfer is left as .partial and cannot be retried by invoking this CLI again.
    """
    dest.mkdir(parents=True, exist_ok=True, mode=0o700)
    require(not dest.is_symlink(), 'symlink staging directory')
    expected = sum(artifact_size(p) for p in wheels)
    used = sum(p.stat().st_size for p in dest.iterdir() if p.is_file())
    require(used <= CAP and expected <= CAP, 'staging budget exceeded')
    require(shutil.disk_usage(dest).free >= RESERVE + expected, 'free disk reserve insufficient')
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    transferred = 0
    for p in wheels:
        filename = urllib.parse.unquote(urllib.parse.urlsplit(p['artifact']['url']).path.rsplit('/', 1)[1])
        target = dest / filename
        if target.exists() or target.is_symlink():
            check_file(target, p)
            continue
        attempt = dest / (filename + '.attempt')
        partial = dest / (filename + '.partial')
        require(not attempt.exists() and not attempt.is_symlink() and not partial.exists() and not partial.is_symlink(), 'previous attempt/partial exists; no retry permitted')
        with attempt.open('x') as f:
            f.write(p['artifact']['hash'] + '\n')
        req = urllib.request.Request(p['artifact']['url'], headers={'Accept-Encoding': 'identity', 'User-Agent': 'fixed-artifact-static-verifier/1'})
        with opener.open(req, timeout=120) as response:
            require(response.status == 200 and response.geturl() == p['artifact']['url'], 'unexpected response/redirect')
            require(response.headers.get('Content-Encoding', 'identity') == 'identity', 'encoded transfer rejected')
            require(int(response.headers.get('Content-Length', '-1')) == artifact_size(p), 'response size mismatch')
            count = 0
            with partial.open('xb') as f:
                while block := response.read(min(CHUNK, artifact_size(p) - count + 1)):
                    count += len(block)
                    transferred += len(block)
                    require(count <= artifact_size(p) and transferred <= CAP and used + len(block) <= CAP, 'transfer/staging size budget exceeded')
                    f.write(block)
                    used += len(block)
                f.flush()
                os.fsync(f.fileno())
        check_file(partial, p)
        partial.rename(target)
        print('acquired ' + p['name'] + ' ' + str(count), flush=True)
    return transferred


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--snapshot', type=Path, required=True)
    ap.add_argument('--directory', type=Path, required=True)
    ap.add_argument('--report', type=Path, required=True)
    ap.add_argument('--diagnose-offline', action='store_true', help='report nonconformances without converting them to PASS; forbids acquisition')
    ap.add_argument('--inventory', type=Path, help='optional compact evidence without full notice texts')
    ap.add_argument('--acquire', action='store_true', help='explicitly permit fixed 54-wheel network acquisition')
    args = ap.parse_args()
    report = {'snapshot_sha256': SNAPSHOT_SHA256, 'verifier_sha256': digest_file(Path(__file__)),
              'evaluator_python': sys.version.split()[0], 'status': 'incomplete', 'artifacts': []}
    try:
        data, wheels = load_snapshot(args.snapshot)
        report['target'] = data['target']
        require(not (args.acquire and args.diagnose_offline), 'offline diagnosis forbids acquisition')
        report['inspection_failures'] = []
        report['hash_inventory'] = []
        if args.acquire:
            report['transferred_bytes_this_run'] = acquire(wheels, args.directory)
        for p in wheels:
            filename = urllib.parse.unquote(urllib.parse.urlsplit(p['artifact']['url']).path.rsplit('/', 1)[1])
            path = args.directory / filename
            check_file(path, p)
            report['hash_inventory'].append({'name': p['name'], 'bytes': path.stat().st_size, 'sha256': digest_file(path)})
            try:
                row = inspect_wheel(path, p, diagnostic=args.diagnose_offline)
            except (Rejected, KeyError, zipfile.BadZipFile) as e:
                if not args.diagnose_offline:
                    raise
                report['inspection_failures'].append({'name': p['name'], 'reason': str(e) if isinstance(e, Rejected) else type(e).__name__})
                continue
            report['artifacts'].append(row)
            require(sum(r['expanded_bytes'] for r in report['artifacts']) <= EXPANDED_CAP, 'aggregate expansion budget exceeded')
            print('inspected ' + p['name'], flush=True)
        rows = report['artifacts']
        versions = {p['name']: p['version'] for p in data['packages']}
        static_rocm = {'name': 'rocm', 'requires_dist': data['rocm_sdist_review']['static_runtime_requires_for_selected_extras']}
        static_build = {'name': 'rocm-build', 'requires_dist': data['rocm_sdist_review']['build_system']['requires']}
        issues, edges = closure(rows + [static_rocm, static_build], versions)
        report['dependency_issues'] = issues
        report['evaluated_dependencies'] = edges
        report['pypi_metadata_differences'] = []
        report['pypi_semantic_metadata_differences'] = []
        report['lock_dependency_name_differences'] = []
        package_map = {p['name']: p for p in wheels}
        for row in rows:
            p = package_map[row['name']]
            pm = p.get('pypi_metadata')
            if pm and (sorted(pm.get('requires_dist') or []) != sorted(row['requires_dist']) or (pm.get('requires_python') or '') != (row['requires_python'] or '')):
                report['pypi_metadata_differences'].append(p['name'])
                if (set(map(Requirement, pm.get('requires_dist') or [])) != set(map(Requirement, row['requires_dist']))
                        or SpecifierSet(pm.get('requires_python') or '') != SpecifierSet(row['requires_python'] or '')):
                    report['pypi_semantic_metadata_differences'].append(p['name'])
            active = {canonicalize_name(Requirement(e['requirement']).name) for e in edges if e['from'] == canonicalize_name(p['name']) and e['active']}
            if active != set(map(canonicalize_name, p['dependency_names'])):
                report['lock_dependency_name_differences'].append({'name': p['name'], 'snapshot': p['dependency_names'], 'actual_active': sorted(active)})
        report['compressed_bytes'] = sum(r['bytes'] for r in rows)
        report['expanded_bytes'] = sum(r['expanded_bytes'] for r in rows)
        record_problem = any(r['record_issues'] for r in rows)
        security_problem = any(r['security_issues'] for r in rows)
        failed = bool(issues or record_problem or security_problem or report['inspection_failures']
                      or report['pypi_semantic_metadata_differences'] or report['lock_dependency_name_differences'])
        report['status'] = 'static_gate_not_passed' if failed else 'static_checks_complete_not_installable'
        report['stage_a_gate'] = 'not_passed' if failed else 'manual_license_review_required'
        report['license_review_required'] = True
        returncode = failed
    except Exception as e:
        # Never print remote URLs, headers, response bodies, proxy settings or tokens.
        report['failure'] = str(e) if isinstance(e, Rejected) else type(e).__name__
        returncode = 1
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2, ensure_ascii=False) + '\n')
    if args.inventory:
        compact = json.loads(json.dumps(report))
        compact['full_report_sha256'] = digest_file(args.report)
        for row in compact['artifacts']:
            hex_paths = [s.partition(': ')[2] for s in row['record_issues'] if s.startswith('RECORD nonstandard hex digest: ')]
            row['record_issues'] = [s for s in row['record_issues'] if not s.startswith('RECORD nonstandard hex digest: ')]
            row['nonstandard_hex_paths'] = {'count': len(hex_paths), 'samples': hex_paths[:5],
                                          'sha256_of_json_list': hashlib.sha256(json.dumps(hex_paths).encode()).hexdigest()}
            for nested in row['nested_archives']:
                links = nested.pop('links')
                nested['unresolved_links'] = {'count': len(links), 'samples': links[:5],
                                             'sha256_of_json_list': hashlib.sha256(json.dumps(links).encode()).hexdigest()}
            for notice in row['licenses']:
                notice.pop('text', None)
            header = row.pop('license', None)
            row['license_header'] = header if not header or len(header) <= 256 else None
            row['license_header_sha256'] = hashlib.sha256(header.encode()).hexdigest() if header else None
        args.inventory.parent.mkdir(parents=True, exist_ok=True)
        args.inventory.write_text(json.dumps(compact, indent=2, ensure_ascii=False) + '\n')
    print(report['status'] + (': ' + report['failure'] if 'failure' in report else ''), flush=True)
    return int(returncode)


if __name__ == '__main__':
    sys.exit(main())
