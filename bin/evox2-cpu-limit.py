#!/usr/bin/env python3
"""Temporary Evo-X2 CPU frequency ceiling; default is read-only, NOT a watt cap.

No EC/SMU/module operations. Real writes require explicit confirmation and root.
The backend argument exists for unit fixtures only; CLI paths are not configurable.
"""
import argparse
from contextlib import contextmanager
import copy
import fcntl
import json
import os
from pathlib import Path
import stat
import sys
import tempfile
import time
import signal
import urllib.request

IDENTITY = {
    'sys_vendor': 'GMKtec', 'product_name': 'NucBox_EVO-X2',
    'board_vendor': 'GMKtec', 'board_name': 'GMKtec',
    'board_version': 'Version 1.0', 'bios_version': 'EVO-X2 1.04',
    'bios_date': '05/14/2025', 'ec_firmware_release': '1.1',
}
POLICIES = tuple(str(i) for i in range(32))
FIELDS = ('affected_cpus', 'related_cpus', 'scaling_driver', 'scaling_governor',
          'energy_performance_preference', 'scaling_min_freq', 'scaling_max_freq',
          'cpuinfo_min_freq', 'cpuinfo_max_freq', 'boost')
MAX = 'scaling_max_freq'
TARGET = 3000000
EVENT_LIMIT = 512
SNAPSHOT_LIMIT = 2 * 1024 * 1024


class Unsafe(RuntimeError):
    pass


def require(condition, message):
    if not condition:
        raise Unsafe(message)


def integer(value):
    require(isinstance(value, str) and value.isascii() and value.isdecimal(),
            'invalid numeric sysfs value')
    return int(value)


def validate(value):
    require(set(value) == {'identity', 'boot_id', 'online', 'boost', 'status', 'policies'},
            'unexpected state fields')
    require(value['identity'] == IDENTITY, 'DMI/BIOS/EC identity mismatch')
    require(isinstance(value['boot_id'], str) and value['boot_id'], 'missing boot ID')
    require(value['online'] == '0-31', 'CPU online set mismatch')
    require(value['boost'] in ('0', '1') and value['status'] == 'active',
            'unexpected global CPU state')
    require(set(value['policies']) == set(POLICIES), 'policy set mismatch')
    for index, row in value['policies'].items():
        require(set(row) == set(FIELDS), 'unexpected policy fields')
        require(row['affected_cpus'] == row['related_cpus'] == index, 'CPU mapping mismatch')
        require(row['scaling_driver'] == 'amd-pstate-epp', 'driver mismatch')
        require(row['scaling_governor'] == 'powersave', 'governor mismatch')
        require(row['energy_performance_preference'] == 'balance_performance', 'EPP mismatch')
        require(row['boost'] in ('0', '1'), 'invalid boost')
        lo, hi = integer(row['scaling_min_freq']), integer(row[MAX])
        require(0 < integer(row['cpuinfo_min_freq']) <= lo <= hi <= integer(row['cpuinfo_max_freq']) <= 10000000,
                'invalid frequency bounds')
        require(lo <= TARGET, 'minimum frequency exceeds ceiling')


def plan(value):
    validate(value)
    return {'target_khz': TARGET, 'watt_cap': False,
            'max_khz': {i: min(TARGET, integer(value['policies'][i][MAX])) for i in POLICIES}}


class Host:
    """Fixed, allowlisted sysfs paths only; never accepts a caller-provided root."""
    ROOT = Path('/sys/devices/system/cpu/cpufreq')

    def read(self):
        value = {
            'identity': {n: (Path('/sys/class/dmi/id') / n).read_text().strip() for n in IDENTITY},
            'boot_id': Path('/proc/sys/kernel/random/boot_id').read_text().strip(),
            'online': Path('/sys/devices/system/cpu/online').read_text().strip(),
            'boost': (self.ROOT / 'boost').read_text().strip(),
            'status': Path('/sys/devices/system/cpu/amd_pstate/status').read_text().strip(),
            'policies': {},
        }
        names = {p.name for p in self.ROOT.glob('policy*')}
        require(names == {'policy' + i for i in POLICIES}, 'host policy set mismatch')
        for i in POLICIES:
            d = self.ROOT / ('policy' + i)
            require(d.resolve() == d, 'policy directory must not be redirected')
            link = Path('/sys/devices/system/cpu') / ('cpu' + i) / 'cpufreq'
            require(link.resolve() == d, 'CPU policy symlink target mismatch')
            require(all((d / n).resolve() == d / n for n in FIELDS),
                    'policy attribute must not be redirected')
            value['policies'][i] = {n: (d / n).read_text().strip() for n in FIELDS}
        return value

    def write_max(self, index, value):
        require(index in POLICIES and type(value) is int and 0 < value <= 10000000,
                'invalid write target')
        trace = getattr(self, 'trace', lambda **event: None)
        self.last_operation = 'open'
        try:
            # No O_CREAT/O_TRUNC; no alternate path or generic file access.
            fd = os.open(self.ROOT / ('policy' + index) / MAX, os.O_WRONLY | os.O_NOFOLLOW)
        except OSError as error:
            trace(operation='open', outcome='error', errno=error.errno)
            raise
        try:
            trace(operation='open', outcome='ok')
            self.last_operation = 'write'
            data = f'{value}\n'.encode('ascii')
            try:
                require(os.write(fd, data) == len(data), 'short sysfs write')
            except BaseException as error:
                trace(operation='write', outcome='error', errno=getattr(error, 'errno', None))
                raise
            trace(operation='write', outcome='ok')
            # os.write is unbuffered. fsync/flush is neither needed nor supported
            # by this sysfs interface; never retry using a different write API.
            trace(operation='flush', outcome='not_applicable')
        finally:
            os.close(fd)


def file_check(fd):
    s = os.fstat(fd)
    require(stat.S_ISREG(s.st_mode) and s.st_nlink == 1, 'snapshot must be a regular single-link file')
    require(s.st_uid == os.geteuid() and s.st_mode & 0o777 == 0o600,
            'snapshot/lock must be owned by current effective user and mode0600')


@contextmanager
def lock(path):
    fd = os.open(str(path) + '.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        file_check(fd)
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield
    finally:
        os.close(fd)


def save(path, doc):
    """Atomic durable journal replacement, including write intent before sysfs."""
    fd, name = tempfile.mkstemp(prefix='.' + path.name + '.', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(doc, stream, indent=2, sort_keys=True)
            stream.write('\n')
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
        dfd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(dfd)
        finally:
            os.close(dfd)
    finally:
        if os.path.exists(name): os.unlink(name)


def snapshot(io, path):
    path = Path(path)
    with lock(path):
        value = io.read()
        targets = plan(value)['max_khz']
        fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
        os.close(fd)
        save(path, {'version': 2, 'before': value, 'targets': targets,
                    'pending': [], 'phase': 'snapshot', 'events': []})


def load(path):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    except OSError as error:
        raise Unsafe('snapshot cannot be opened safely') from error
    try:
        file_check(fd)
        require(os.fstat(fd).st_size <= SNAPSHOT_LIMIT, 'oversized snapshot')
        with os.fdopen(fd, 'r', closefd=False) as stream:
            doc = json.load(stream)
    except (ValueError, TypeError) as error:
        raise Unsafe('invalid snapshot JSON') from error
    finally:
        os.close(fd)
    if isinstance(doc, dict) and doc.get('version') == 1:
        require(set(doc) == {'version', 'before', 'targets', 'pending', 'phase'}, 'invalid legacy snapshot')
        doc = dict(doc, version=2, events=[])
    require(isinstance(doc, dict) and set(doc) == {'version', 'before', 'targets', 'pending', 'phase', 'events'},
            'invalid snapshot schema')
    require(doc['version'] == 2, 'snapshot version mismatch')
    require(isinstance(doc['events'], list) and len(doc['events']) <= EVENT_LIMIT,
            'invalid diagnostic journal')
    require(doc['targets'] == plan(doc['before'])['max_khz'], 'snapshot targets mismatch')
    require(isinstance(doc['pending'], list) and len(doc['pending']) <= 32
            and all(i in POLICIES for i in doc['pending'])
            and len(set(doc['pending'])) == len(doc['pending']), 'invalid pending policies')
    require(doc['phase'] in ('snapshot', 'applying', 'applied', 'restoring', 'restored', 'restore_failed'),
            'invalid transaction phase')
    return doc


def event(path, doc, *, operation, policy=None, requested_khz=None,
          observed_khz=None, outcome, errno=None, observed_fields=None, edge=None):
    require(operation in ('open', 'write', 'flush', 'readback', 'rollback'), 'invalid diagnostic operation')
    require(policy is None or policy in POLICIES, 'invalid diagnostic policy')
    require(outcome in ('ok', 'error', 'not_applicable'), 'invalid diagnostic outcome')
    item = {'operation': operation, 'policy': policy, 'phase': doc['phase'],
            'errno': errno, 'requested_khz': requested_khz,
            'observed_khz': observed_khz, 'outcome': outcome}
    if policy is not None:
        item['path'] = f'/sys/devices/system/cpu/cpufreq/policy{policy}/{MAX}'
    if edge is not None:
        require(edge in ('before', 'after'), 'invalid diagnostic edge')
        item['edge'] = edge
    if observed_fields is not None:
        item['observed_fields'] = {k: str(observed_fields[k])[:80]
                                   for k in FIELDS if k in observed_fields}
    doc['events'] = (doc['events'] + [item])[-EVENT_LIMIT:]
    save(path, doc)


def observed(io, index):
    try:
        row = io.read()['policies'][index]
        value = integer(row[MAX])
        return value, row
    except (OSError, Unsafe, KeyError, TypeError, ValueError):
        return None, None


def write_and_readback(io, path, doc, index, target, expected_row):
    pre = io.read()
    restore_context(pre, doc['before'])
    required = copy.deepcopy(doc['before']['policies'][index])
    if doc['phase'] == 'restoring': required[MAX] = str(doc['targets'][index])
    pre_row = pre['policies'][index]
    event(path, doc, operation='readback', policy=index, requested_khz=target,
          observed_khz=integer(pre_row[MAX]), observed_fields=pre_row, edge='before',
          outcome='ok' if pre_row == required else 'error')
    require(pre_row == required, f'policy{index} changed immediately before write')
    previous = getattr(io, 'trace', None)
    last = [None]
    def trace(**fields):
        last[0] = fields
        value, row = observed(io, index) if fields['outcome'] == 'error' else (None, None)
        event(path, doc, policy=index, requested_khz=target,
              observed_khz=value, observed_fields=row, **fields)
    io.trace = trace
    try:
        try:
            io.write_max(index, target)
        except BaseException as error:
            # Fixture/other backend errors still identify the fixed policy and
            # operation; never include str(error) or arbitrary exception content.
            if last[0] is None or last[0]['outcome'] != 'error':
                value, row = observed(io, index)
                event(path, doc, operation=getattr(io, 'last_operation', 'write'), policy=index, requested_khz=target,
                      observed_khz=value, observed_fields=row, outcome='error',
                      errno=getattr(error, 'errno', None))
            raise
        try:
            actual = io.read()
            row = actual['policies'][index]
            value = integer(row[MAX])
        except BaseException as error:
            event(path, doc, operation='readback', policy=index, requested_khz=target,
                  outcome='error', errno=getattr(error, 'errno', None))
            raise
        event(path, doc, operation='readback', policy=index, requested_khz=target,
              observed_khz=value, observed_fields=row, edge='after',
              outcome='ok' if row == expected_row else 'error')
        require(row == expected_row, f'policy{index} readback differs from requested/saved state')
        return actual
    finally:
        if previous is None: del io.trace
        else: io.trace = previous


def error_label(error):
    # Preserve original class/errno in user-visible failure without leaking its
    # message (which could contain arbitrary backend text or paths).
    return f'{type(error).__name__}(errno={getattr(error, "errno", None)})'


def equivalent(actual, expected):
    validate(actual)
    require(actual == expected, 'host state changed: refuse overwriting competing settings')


def surroundings(row):
    return {k: v for k, v in row.items() if k != MAX}


def restore_context(live, before):
    # Identity/boot/topology/global changes make every candidate unsafe.
    require({k: v for k, v in live.items() if k != 'policies'} ==
            {k: v for k, v in before.items() if k != 'policies'},
            'global state changed: restore refused')
    require(set(live['policies']) == set(POLICIES), 'restore policy set changed')


def _restore(io, path, doc):
    before = doc['before']
    restore_context(io.read(), before)
    doc['phase'] = 'restoring'
    save(path, doc)
    conflicts = []
    for i in reversed(doc['pending']):
        # Re-read immediately before each write, not just once per transaction.
        live = io.read()
        restore_context(live, before)
        row, old_row = live['policies'][i], before['policies'][i]
        old, target = integer(old_row[MAX]), doc['targets'][i]
        if surroundings(row) != surroundings(old_row):
            event(path, doc, operation='rollback', policy=i, requested_khz=old,
                  observed_khz=integer(row[MAX]), observed_fields=row, outcome='error')
            conflicts.append(i)
            continue
        if row[MAX] == str(old): continue
        if row[MAX] != str(target):
            event(path, doc, operation='rollback', policy=i, requested_khz=old,
                  observed_khz=integer(row[MAX]), observed_fields=row, outcome='error')
            conflicts.append(i)
            continue
        save(path, doc)  # Retain original durable intent through restoration.
        after = write_and_readback(io, path, doc, i, old, old_row)
        restore_context(after, before)
        require(after['policies'][i] == old_row, f'restore readback mismatch: policy{i}')
    # Report all remaining drift, including an unjournaled external change.
    require(not conflicts, 'restore skipped external changes: policies ' + ','.join(conflicts))
    equivalent(io.read(), before)
    doc['phase'] = 'restored'
    save(path, doc)


def restore(io, path):
    path = Path(path)
    with lock(path):
        doc = load(path)
        try:
            _restore(io, path, doc)
        except Exception:
            doc['phase'] = 'restore_failed'
            save(path, doc)
            raise


def apply(io, path):
    path = Path(path)
    with lock(path):
        doc = load(path)
        require(doc['phase'] == 'snapshot' and not doc['pending'], 'fresh snapshot required')
        equivalent(io.read(), doc['before'])
        expected = copy.deepcopy(doc['before'])
        try:
            doc['phase'] = 'applying'
            save(path, doc)
            for i in POLICIES:
                target = doc['targets'][i]
                if integer(expected['policies'][i][MAX]) == target: continue
                equivalent(io.read(), expected)
                doc['pending'].append(i)
                save(path, doc)  # Intent first, including write-then-error/crash case.
                expected['policies'][i][MAX] = str(target)
                actual = write_and_readback(io, path, doc, i, target, expected['policies'][i])
                equivalent(actual, expected)
            equivalent(io.read(), expected)
            doc['phase'] = 'applied'
            save(path, doc)
        except BaseException as error:
            try:
                _restore(io, path, doc)
                event(path, doc, operation='rollback', outcome='ok')
            except BaseException as recovery:
                doc['phase'] = 'restore_failed'
                event(path, doc, operation='rollback', outcome='error', errno=getattr(recovery, 'errno', None))
                raise Unsafe(f'apply failed: {error_label(error)}; rollback incomplete: '
                             f'{error_label(recovery)}; retain snapshot') from error
            raise Unsafe(f'apply failed: {error_label(error)}; snapshot limits restored') from error


def stable(io, expected, stage, observe, wait, clock, seconds):
    end = clock() + seconds
    while True:
        equivalent(io.read(), expected)
        observe(stage)
        equivalent(io.read(), expected)
        remaining = end - clock()
        if remaining <= 0: return
        wait(min(1.0, remaining))


def trial(io, path, observe, *, wait=time.sleep, clock=time.monotonic, seconds=60,
          arm=lambda: None, disarm=lambda: None):
    """Bounded idle experiment; alarm hooks are installed only by the root CLI."""
    before = io.read()
    targets = plan(before)['max_khz']
    stable(io, before, 'before', observe, wait, clock, seconds)
    equivalent(io.read(), before)
    snapshot(io, path)
    require(load(Path(path))['before'] == before, 'state changed during snapshot; no apply')
    expected = copy.deepcopy(before)
    for i in POLICIES: expected['policies'][i][MAX] = str(targets[i])
    arm()
    try:
        apply(io, path)
        stable(io, expected, 'limited', observe, wait, clock, seconds)
    finally:
        # Never let the active-phase alarm interrupt cleanup itself.
        disarm()
        restore(io, path)
    stable(io, before, 'restored', observe, wait, clock, seconds)


class Monitor:
    """Body-free telemetry: no chat requests or workloads, health GET only."""
    def __init__(self, path):
        self.stream = open(path, 'x', opener=lambda p, flags: os.open(p, flags | os.O_NOFOLLOW, 0o600))
        self.swap_initial = None
        self.started = time.monotonic()

    def __call__(self, stage):
        temperatures, critical = [], []
        for d in Path('/sys/class/hwmon').glob('*'):
            try:
                if (d / 'name').read_text().strip() != 'k10temp': continue
                temperatures.append(int((d / 'temp1_input').read_text()) / 1000)
                for p in d.glob('temp*_crit'): critical.append(int(p.read_text()) / 1000)
            except FileNotFoundError:
                continue
        require(temperatures and all(0 < t < 95 for t in temperatures), 'CPU temperature missing/unsafe')
        require(not critical or max(temperatures) < min(critical) - 5, 'CPU critical margin unsafe')
        mem = {line.split(':')[0]: int(line.split()[1]) * 1024
               for line in Path('/proc/meminfo').read_text().splitlines()
               if line.startswith(('MemAvailable:', 'SwapTotal:', 'SwapFree:'))}
        swap = mem['SwapTotal'] - mem['SwapFree']
        if self.swap_initial is None: self.swap_initial = swap
        require(mem['MemAvailable'] >= 8 * 1024**3, 'insufficient available memory')
        require(swap - self.swap_initial <= 512 * 1024**2, 'swap increase unsafe')
        # Fixed local baseline endpoint; do not inherit root proxy settings.
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open('http://llama-server:8082/health', timeout=2) as response:
            health = json.loads(response.read(4096))
        require(health == {'status': 'ok'}, 'baseline health failed')
        observed = Host().read()
        self.stream.write(json.dumps({'stage': stage, 'elapsed': time.monotonic() - self.started,
                                      'tctl_c': max(temperatures), 'available_bytes': mem['MemAvailable'],
                                      'swap_bytes': swap, 'health': 'ok',
                                      'max_khz': {i: integer(observed['policies'][i][MAX]) for i in POLICIES}}) + '\n')
        self.stream.flush()

    def close(self):
        self.stream.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', nargs='?', choices=('plan', 'snapshot', 'apply', 'restore', 'trial'), default='plan')
    parser.add_argument('--snapshot', type=Path)
    parser.add_argument('--telemetry', type=Path)
    parser.add_argument('--confirm-host-change', action='store_true')
    args = parser.parse_args()
    try:
        io = Host()
        if args.action == 'plan':
            print(json.dumps(plan(io.read()), indent=2))
            return 0
        require(args.snapshot is not None, '--snapshot path required')
        # Apply/restore accept root-owned files only; never trust user-owned root input.
        # Use the same private root directory for snapshot and all subsequent operations.
        parent = args.snapshot.parent
        require(parent.is_absolute() and parent.resolve() == parent, 'use absolute path without directory symlinks')
        s = parent.stat()
        require(s.st_uid == os.geteuid() and stat.S_IMODE(s.st_mode) == 0o700,
                'snapshot parent must be owned by current effective user and mode0700')
        if args.action in ('apply', 'restore', 'trial'):
            require(args.confirm_host_change and os.geteuid() == 0,
                    'real writes require root and --confirm-host-change after approval')
        if args.action == 'trial':
            require(args.telemetry is not None and args.telemetry.parent == parent,
                    'trial requires new --telemetry file in the snapshot directory')
            def interrupted(signum, frame):
                raise Unsafe(f'experiment interrupted: signal {signum}')
            previous = {s: signal.signal(s, interrupted) for s in
                        (signal.SIGALRM, signal.SIGTERM, signal.SIGINT)}
            monitor = None
            try:
                monitor = Monitor(args.telemetry)
                trial(io, args.snapshot, monitor, arm=lambda: signal.alarm(180),
                      disarm=lambda: signal.alarm(0))
            finally:
                signal.alarm(0)
                if monitor is not None: monitor.close()
                for s, handler in previous.items(): signal.signal(s, handler)
        else:
            globals()[args.action](io, args.snapshot)
        print(json.dumps({'action': args.action, 'result': 'ok', 'watt_cap': False}))
        return 0
    except (Unsafe, OSError, ValueError, KeyError, TypeError) as error:
        print(f'REFUSED/FAILED: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
