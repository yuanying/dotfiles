#!/usr/bin/env python3
"""One approved 3 GHz, single-CPU 30/120-second trial; no standalone apply.

Requires the exact PR166 CPU-limit API; does not copy or modify its sysfs logic.
All safety failures stop the sole workload before attempting safe restoration.
"""
import argparse
import copy
from contextlib import contextmanager, nullcontext
import hashlib
import json
import math
import os
from pathlib import Path
import resource
import signal
import stat
import subprocess
import sys
import time
import types

SOURCE_SHA256 = 'bd59f915a62609223507c6eabd38e6b0bfb52d48e866e51b8a9911582a7d5cb0'


def require(ok, message):
    if not ok: raise RuntimeError(message)


def load_api(path):
    data = Path(path).read_bytes()
    require(hashlib.sha256(data).hexdigest() == SOURCE_SHA256, 'CPU API source hash mismatch')
    module = types.ModuleType('pinned_cpu_limit')
    exec(compile(data, str(path), 'exec'), module.__dict__)
    return module


def interrupted(signum, frame):
    raise RuntimeError(f'trial interrupted: signal {signum}')


def proc_status(pid):
    # comm may contain spaces/parentheses: fields after the LAST closing paren.
    fields = Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()
    status = Path(f'/proc/{pid}/status').read_text().splitlines()
    rss = next((int(x.split()[1])*1024 for x in status if x.startswith('VmRSS:')), 0)
    threads = next(int(x.split()[1]) for x in status if x.startswith('Threads:'))
    return {'pid': pid, 'starttime': int(fields[19]), 'cpu_ticks': int(fields[11])+int(fields[12]),
            'rss_bytes': rss, 'threads': threads, 'state': fields[0]}


class Load:
    """One direct child, no grandchildren. pidfd + starttime prevents PID reuse."""
    def __init__(self, seconds, cpu):
        require(seconds in (30,120) and cpu in range(32), 'invalid workload parameters')
        self.started = time.monotonic()
        self.usage_before = resource.getrusage(resource.RUSAGE_CHILDREN)
        self.summary = None
        self.process = subprocess.Popen([sys.executable, str(Path(__file__).resolve()),
                                         '--worker', str(seconds), str(cpu)],
                                        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                        stderr=subprocess.DEVNULL, close_fds=True,
                                        preexec_fn=lambda: os.sched_setaffinity(0, {cpu}))
        self.pid = self.process.pid
        self.pidfd = None
        try:
            self.pidfd = os.pidfd_open(self.pid)
            self.starttime = proc_status(self.pid)['starttime']
            self.deadline = time.monotonic()+seconds+2
            self.cpu = cpu
        except BaseException:
            # Popen retains direct child identity until wait (no PID reuse).
            self.process.kill(); self.process.wait(timeout=2)
            if self.pidfd is not None: os.close(self.pidfd)
            raise

    def send(self, sig):
        require(proc_status(self.pid)['starttime'] == self.starttime, 'load PID identity changed')
        signal.pidfd_send_signal(self.pidfd, sig)

    def status(self):
        if self.process.poll() is not None:
            require(self.process.returncode == 0, 'workload exited abnormally')
            return {'pid':self.pid, 'starttime':self.starttime, 'exited':True, 'returncode':0}
        result = proc_status(self.pid)
        require(result['starttime'] == self.starttime, 'load PID identity changed')
        require(result['threads'] == 1 and result['rss_bytes'] <= 64*1024**2, 'load thread/memory bound violated')
        # Startup can precede sched_setaffinity; wait for worker readiness before
        # checking the affinity in status() (constructor does not burn CPU).
        result['affinity'] = sorted(os.sched_getaffinity(self.pid))
        require(result['affinity'] == [self.cpu], 'load affinity changed')
        require(time.monotonic() <= self.deadline, 'load timeout')
        return result

    def finish(self):
        self.process.wait(timeout=max(0.01,self.deadline-time.monotonic()))
        require(self.process.returncode == 0, 'workload exited abnormally')
        usage = resource.getrusage(resource.RUSAGE_CHILDREN)
        self.summary = {'pid':self.pid, 'starttime':self.starttime, 'cpu':self.cpu,
                        'wall_seconds':time.monotonic()-self.started,
                        'user_cpu_seconds':usage.ru_utime-self.usage_before.ru_utime,
                        'system_cpu_seconds':usage.ru_stime-self.usage_before.ru_stime,
                        'returncode':self.process.returncode}

    def stop(self):
        if self.process.poll() is None:
            self.send(signal.SIGTERM)
            try: self.process.wait(timeout=1)
            except subprocess.TimeoutExpired:
                self.send(signal.SIGKILL); self.process.wait(timeout=1)
        require(self.process.poll() is not None, 'load could not be stopped; restore withheld')
        if self.pidfd is not None:
            os.close(self.pidfd); self.pidfd = None


def worker(seconds, cpu):
    require(seconds in (30,120) and cpu in range(32), 'invalid worker arguments')
    os.sched_setaffinity(0, {cpu})
    resource.setrlimit(resource.RLIMIT_AS, (64*1024**2,64*1024**2))
    resource.setrlimit(resource.RLIMIT_CPU, (seconds+1,seconds+1))
    signal.signal(signal.SIGALRM, signal.SIG_DFL)
    signal.alarm(seconds+1)
    buffer = bytes(1024**2)
    end = time.monotonic()+seconds
    while time.monotonic() < end: hashlib.sha256(buffer).digest()


def check_oom(before, current):
    require(set(before) == set(current) and all(current[k] <= before[k] for k in before),
            'OOM/cgroup memory event increased or source changed')


def oom_counters():
    result = {}
    for line in Path('/proc/vmstat').read_text().splitlines():
        if line.startswith('oom_kill '): result['oom_kill'] = int(line.split()[1])
    require('oom_kill' in result, 'OOM telemetry unavailable')
    p = Path('/sys/fs/cgroup/memory.events')
    if p.exists():
        for line in p.read_text().splitlines():
            k,v = line.split()
            if k in ('oom','oom_kill','oom_group_kill','max'): result['cgroup_'+k] = int(v)
    return result


class Observer:
    def __init__(self, api, directory):
        self.api = api
        self.monitor = api.Monitor(directory/'monitor.jsonl')
        self.path = directory/'telemetry.jsonl'
        self.stream = open(self.path, 'x', opener=lambda p,f: os.open(p,f|os.O_NOFOLLOW,0o600))
        self.initial_oom = oom_counters()
        self.started = time.monotonic()
        self.previous_ticks = None

    def __call__(self, stage, child):
        # Existing monitor keeps stricter immediate 95C/8GiB aborts unchanged.
        self.monitor(stage)
        oom = oom_counters(); check_oom(self.initial_oom, oom)
        state = self.api.Host().read()
        cpu = [int(v) for v in Path('/proc/stat').read_text().splitlines()[0].split()[1:9]]
        utilization = None
        if self.previous_ticks is not None:
            delta = [v-p for v,p in zip(cpu,self.previous_ticks)]
            total = sum(delta)
            utilization = 100*(total-delta[3]-delta[4])/total if total else 0
        self.previous_ticks = cpu
        gpu = {}
        for p in Path('/sys/class/drm').glob('card*/device/gpu_busy_percent'):
            gpu[str(p)] = int(p.read_text())
        # k10temp Tctl already validated by Monitor, retain same sensor values.
        temps = [int((p/'temp1_input').read_text())/1000 for p in Path('/sys/class/hwmon').glob('*')
                 if (p/'name').exists() and (p/'name').read_text().strip()=='k10temp']
        row = {'stage':stage, 'elapsed':time.monotonic()-self.started,
               'tctl_c':max(temps), 'snapshot_fields':state, 'oom':oom,
               'cpu_utilization_percent':utilization, 'gpu_busy_percent':gpu,
               'load':child.status() if child else None}
        self.stream.write(json.dumps(row)+'\n'); self.stream.flush()
        return row

    def close(self):
        self.monitor.close(); self.stream.close()


def experiment(api, io, snapshot, observe, factory, cpu, *, clock=time.monotonic,
               wait=time.sleep, arm=lambda: None, disarm=lambda: None,
               cleanup=nullcontext):
    before = io.read()
    targets = api.plan(before)['max_khz']
    expected = copy.deepcopy(before)
    for i in api.POLICIES: expected['policies'][i][api.MAX] = str(targets[i])
    child = None

    def sample(stage, state):
        api.equivalent(io.read(), state)
        row = observe(stage, child)
        api.equivalent(io.read(), state)
        return row

    def hold(stage, state, seconds):
        end = clock()+seconds
        while True:
            sample(stage, state)
            if clock() >= end: return
            wait(min(1,end-clock()))

    hold('before', before, 60)
    api.snapshot(io, snapshot)
    require(api.load(snapshot)['before'] == before, 'snapshot changed before apply')
    second = False
    loads = []
    arm()
    try:
        api.apply(io, snapshot)
        hold('limited_idle', expected, 30)
        for seconds in (30,120):
            child = factory(seconds,cpu)
            try:
                # Child has independent wall deadline; parent takes samples at
                # 1Hz, then waits only within the child's small stopping grace.
                hold(f'load{seconds}', expected, seconds)
                child.finish()
                loads.append({'stage_seconds':seconds, 'usage':getattr(child,'summary',None)})
            finally:
                child.stop(); child = None
            if seconds == 120: break
            cool_start, cool_end = None, clock()+90
            while True:
                row = sample('cooldown', expected)
                if row['tctl_c'] < 85:
                    if cool_start is None: cool_start = clock()
                    if clock()-cool_start >= 60:
                        second = True; break
                else: cool_start = None
                if clock() >= cool_end: break
                wait(min(1,cool_end-clock()))
            if not second: break
    finally:
        # Mask further termination/alarm exceptions only during bounded child
        # termination and safe restoration, never while performing workload.
        with cleanup():
            disarm()
            if child is not None: child.stop(); child = None
            api.restore(io, snapshot)
    api.equivalent(io.read(), before)
    hold('restored', before, 60)
    return {'second_stage':second, 'restored':True, 'watt_cap':False, 'loads':loads}


def main():
    if len(sys.argv)==4 and sys.argv[1]=='--worker':
        worker(int(sys.argv[2]),int(sys.argv[3])); return
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--directory', type=Path, required=True)
    parser.add_argument('--confirm-host-change', action='store_true')
    args = parser.parse_args()
    require(os.geteuid()==0 and args.confirm_host_change, 'requires root and explicit confirmation')
    directory = args.directory
    require(directory.is_absolute() and directory.resolve()==directory, 'directory must be absolute without symlinks')
    s = directory.stat()
    require(s.st_uid==0 and stat.S_IMODE(s.st_mode)==0o700, 'directory must be root0700')
    require(not any(directory.iterdir()), 'new empty private directory required')
    api = load_api(args.source)
    cpus = sorted(os.sched_getaffinity(0) & set(range(32)))
    require(cpus, 'no allowed CPU')
    # Singleton across journals for this runner; no alternate host access route.
    with api.lock(Path('/run/evox2-cpu-load')):
        observer = Observer(api,directory)
        previous = {s: signal.signal(s,interrupted) for s in (signal.SIGALRM,signal.SIGTERM,signal.SIGINT)}
        @contextmanager
        def cleanup():
            oldmask = signal.pthread_sigmask(signal.SIG_BLOCK, set(previous))
            try: yield
            finally: signal.pthread_sigmask(signal.SIG_SETMASK, oldmask)
        try:
            result = experiment(api,api.Host(),directory/'cpu.json',observer,Load,cpus[0],
                                arm=lambda:signal.alarm(420),disarm=lambda:signal.alarm(0),
                                cleanup=cleanup)
            api.save(directory/'result.json',result)
            print(json.dumps(result))
        finally:
            signal.alarm(0)
            observer.close()
            for s,h in previous.items(): signal.signal(s,h)


if __name__=='__main__':
    main()
