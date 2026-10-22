#!/usr/bin/env python3
"""Read-only SDK tar deployment audit. Does not extract or execute packages."""
import argparse
import json
import posixpath
import tarfile
import zipfile


def contained(path):
    if not path or path.startswith('/') or '\\' in path:
        raise ValueError('absolute/invalid archive path')
    normalized = posixpath.normpath(path)
    if normalized == '..' or normalized.startswith('../'):
        raise ValueError('archive path escapes isolation root')
    return normalized


def audit_tar(archive, max_members=100000, max_bytes=12 * 1024**3):
    """Validate links relative to a shared isolated site-packages root.

    No member may be written underneath another member's link. Link chains,
    including links used as parents of targets, must resolve within that root.
    Cross-package relative links are allowed; dangling internal links are counted,
    not claimed to be ABI-compatible. No filesystem writes occur here.
    """
    entries, links = {}, {}
    size = 0
    for member in archive:
        name = contained(member.name)
        if name in entries or len(entries) >= max_members:
            raise ValueError('duplicate path/member budget')
        if not (member.isdir() or member.isreg() or member.issym() or member.islnk()):
            raise ValueError('unsupported member type')
        size += member.size
        if size > max_bytes:
            raise ValueError('archive byte budget')
        entries[name] = member.type
        if member.issym() or member.islnk():
            if member.linkname.startswith('/'):
                raise ValueError('absolute link')
            target = member.linkname if member.islnk() else posixpath.join(posixpath.dirname(name), member.linkname)
            links[name] = contained(target)
    for name in entries:
        parent = posixpath.dirname(name)
        while parent and parent != '.':
            if parent in links:
                raise ValueError('member would write through a link')
            parent = posixpath.dirname(parent)

    def resolve(path, active):
        parts = path.split('/')
        for i in range(1, len(parts) + 1):
            prefix = '/'.join(parts[:i])
            if prefix in links:
                if prefix in active:
                    raise ValueError('link cycle')
                replacement = contained(posixpath.join(links[prefix], *parts[i:]))
                return resolve(replacement, active | {prefix})
        return path

    dangling = 0
    for name, target in links.items():
        resolved = resolve(target, {name})
        dangling += resolved not in entries
    return dict(members=len(entries), regular_bytes=size, links=len(links),
                dangling_in_archive=dangling, containment='passed', extracted=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('wheel')
    args = parser.parse_args()
    with zipfile.ZipFile(args.wheel) as wheel:
        with wheel.open('rocm_sdk_devel/_devel.tar') as stream:
            with tarfile.open(fileobj=stream, mode='r|') as archive:
                print(json.dumps(audit_tar(archive), indent=2))


if __name__ == '__main__':
    main()
