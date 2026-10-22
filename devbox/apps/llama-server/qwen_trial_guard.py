#!/usr/bin/env python3
"""Monitor one child process group, stopping only that group on safety breach.

One-second telemetry is an active safety monitor, not a completion wait loop.
Does not change OS/GPU/service settings or launch a second model.
"""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import time


class Gate:
    def __init__(self, swap):
        self.swap = swap
        self.low = 0
        self.hot_since = None

    def check(self, available, swap, temperature, now, critical=None):
        self.low = self.low + 1 if available < 8 * 1024**3 else 0
        if self.low >= 2: return 'memory'
        if swap - self.swap > 512 * 1024**2: return 'swap'
        if temperature is None: return 'temperature_unavailable'
        if critical is not None and temperature >= critical - 5: return 'critical_temperature'
        self.hot_since = (self.hot_since if self.hot_since is not None else now) if temperature >= 95 else None
        if self.hot_since is not None and now - self.hot_since >= 10: return 'temperature'
        return None


def sample(pid=None):
    mem = {line.split(':')[0]: int(line.split()[1]) * 1024 for line in Path('/proc/meminfo').read_text().splitlines() if line.startswith(('MemAvailable:', 'SwapTotal:', 'SwapFree:'))}
    temps, criticals = [], []
    for hw in Path('/sys/class/hwmon').glob('hwmon*'):
        try: name = (hw / 'name').read_text().strip()
        except OSError: continue
        if name not in ('amdgpu', 'k10temp'): continue
        for sensor in hw.glob('temp*_input'):
            temps.append(int(sensor.read_text()) / 1000)
            crit = sensor.with_name(sensor.name.replace('_input', '_crit'))
            if crit.exists(): criticals.append(int(crit.read_text()) / 1000)
    row = dict(monotonic=time.monotonic(), available=mem['MemAvailable'], swap=mem['SwapTotal']-mem['SwapFree'], temperature=max(temps) if temps else None, critical=min(criticals) if criticals else None)
    for name in ('mem_info_vram_used', 'mem_info_gtt_used', 'gpu_busy_percent'):
        p = Path('/sys/class/drm/card0/device') / name
        row[name] = int(p.read_text()) if p.exists() else None
    row['rss'] = None
    if pid:
        try:
            for line in Path(f'/proc/{pid}/status').read_text().splitlines():
                if line.startswith('VmRSS:'): row['rss'] = int(line.split()[1]) * 1024
        except OSError: pass
    for name in ('memory.current', 'memory.peak', 'memory.events'):
        p = Path('/sys/fs/cgroup') / name
        row[name] = p.read_text().strip() if p.exists() else None
    return row


def descendants(root, parents):
    result = {root}
    while True:
        expanded = result | {pid for pid, parent in parents.items() if parent in result}
        if expanded == result: return result
        result = expanded


def processes():
    result = {}
    for path in Path('/proc').iterdir():
        if not path.name.isdigit(): continue
        try:
            text = (path / 'stat').read_text()
            fields = text[text.rfind(')') + 2:].split()
            result[int(path.name)] = dict(parent=int(fields[1]), start=fields[19], state=fields[0])
        except (OSError, ValueError, IndexError): pass
    return result


def live_tracked(tracked, table):
    return {pid for pid, start in tracked.items() if pid in table and table[pid]['start'] == start and table[pid]['state'] != 'Z'}


def stop_tracked(child, tracked):
    table = processes()
    for pid in descendants(child.pid, {p: v['parent'] for p, v in table.items()}):
        if pid in table: tracked[pid] = table[pid]['start']
    # hipcc creates extra process groups; signal tracked descendants, not only PGID.
    for sig, grace in ((signal.SIGTERM, 20), (signal.SIGKILL, 20)):
        for pid in sorted(live_tracked(tracked, processes()), reverse=True):
            try: os.kill(pid, sig)
            except ProcessLookupError: pass
        end = time.monotonic() + grace
        while live_tracked(tracked, processes()) and time.monotonic() < end:
            time.sleep(0.2)
        if not live_tracked(tracked, processes()):
            child.wait(timeout=1)
            return
    raise RuntimeError('tracked_descendants_still_live_do_not_restore')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--telemetry', required=True)
    parser.add_argument('--log', required=True)
    parser.add_argument('--baseline-container', required=True)
    parser.add_argument('--max-seconds', type=int, default=5400)
    parser.add_argument('--ninja-jobs', type=int, choices=[1])
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    state = subprocess.check_output(['docker', 'inspect', '--format', '{{.State.Status}}', args.baseline_container], text=True).strip()
    if state != 'exited': raise SystemExit('baseline_not_stopped')
    initial = sample()
    if initial['available'] < 100 * 1024**3: raise SystemExit('load_memory_gate')
    gate = Gate(initial['swap'])
    reason = gate.check(initial['available'], initial['swap'], initial['temperature'], initial['monotonic'], initial['critical'])
    if reason: raise SystemExit(reason)
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    if not command: raise SystemExit('command_required')
    def cancelled(signum, frame):
        raise SystemExit(128 + signum)

    signal.signal(signal.SIGTERM, cancelled)
    signal.signal(signal.SIGINT, cancelled)
    child = None
    tracked = {}
    with open(args.telemetry, 'x') as telemetry, open(args.log, 'xb') as log:
        try:
            child = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            while child.poll() is None:
                table = processes()
                for pid in descendants(child.pid, {p: v['parent'] for p, v in table.items()}):
                    if pid in table: tracked[pid] = table[pid]['start']
                row = sample(child.pid)
                reason = gate.check(row['available'], row['swap'], row['temperature'], row['monotonic'], row['critical'])
                if row['memory.events'] != initial['memory.events']:
                    # Conservative: any cgroup event delta warrants inspection.
                    reason = 'cgroup_event'
                if row['monotonic'] - initial['monotonic'] > args.max_seconds: reason = 'time_budget'
                if args.ninja_jobs:
                    ninja_commands = []
                    for pid in live_tracked(tracked, table):
                        try: cmd = Path(f'/proc/{pid}/cmdline').read_bytes().decode().split('\0')
                        except OSError: continue
                        if cmd and Path(cmd[0]).name == 'ninja':
                            ninja_commands.append(cmd)
                            expected = str(args.ninja_jobs)
                            if not any(cmd[i] == '-j' and cmd[i + 1] == expected for i in range(len(cmd) - 1)) and '-j' + expected not in cmd:
                                reason = 'ninja_parallelism'
                    row['ninja_commands'] = ninja_commands
                row['stop_reason'] = reason
                telemetry.write(json.dumps(row) + '\n'); telemetry.flush()
                if reason: break
                time.sleep(1)
        finally:
            if child is not None:
                stop_tracked(child, tracked)
    print(json.dumps(dict(stop_reason=reason, child_exit=child.returncode)))
    return 1 if reason else child.returncode


if __name__ == '__main__':
    raise SystemExit(main())
