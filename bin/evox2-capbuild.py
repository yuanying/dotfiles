#!/usr/bin/env python3
"""One explicitly approved capped Kyojin build; no download, retries or persistence.

Unmerged PR166/165 implementations are required as pinned external sources.
The retained baseline stays STOPPED until a separate human restoration order.
SIGKILL/power failure cannot be recovered by userspace: retain the root journal.
"""
import argparse
import copy
import hashlib
import json
import math
import os
from pathlib import Path
import pwd
import re
import signal
import stat
import subprocess
import time
import types
import urllib.request

CPU_SHA = 'bd59f915a62609223507c6eabd38e6b0bfb52d48e866e51b8a9911582a7d5cb0'
GUARD_SHA = 'fe1d8d148e71a973931d6474b3bc58208fcfc42b5a3fe1b832b8ef76cee9c404'
SMOKE_SHA = '9364396b4882299d0e23b332eda7a89698f71c471e1d8027d4d16582f5844bab'
ENGINE = 'e09322da7209331c57e2a79cfc30d120f0299154'
CID = '2c6869e0c3f228cb4d93ef762cad5e81b17b49486f0f0e426ee97f13f5ad2ec1'
IMAGE = 'sha256:666aff830114424a149aa5cec477e96469570d16d468546782c4dda8d5fd3e63'


def require(ok, message):
    if not ok: raise RuntimeError(message)


def pinned(path, digest):
    source = Path(path).read_bytes()
    require(hashlib.sha256(source).hexdigest() == digest, 'reference_hash_mismatch')
    module = types.ModuleType('reference')
    exec(compile(source, str(path), 'exec'), module.__dict__)
    return module


def lifecycle(stop_service, apply, build, stop_children, restore_cpu, ensure_stopped):
    try:
        stop_service()
        apply()
        return build()
    finally:
        # Never restore CPU over live compilers; never start the baseline here.
        stop_children()
        try: restore_cpu()
        finally: ensure_stopped()


def ninja_one(command):
    jobs = []
    for i, arg in enumerate(command):
        if arg == '-j': jobs.append(command[i+1] if i+1 < len(command) else '')
        elif arg.startswith('-j'): jobs.append(arg[2:])
    require(jobs == ['1'], 'ninja_not_exactly_j1')


def alive(tracked, table):
    return {p for p, start in tracked.items() if p in table and
            table[p]['start'] == start and table[p]['state'] != 'Z'}


def timing(now, start, previous):
    require(now-start < 3600, 'build_timeout_3600')
    require(now-previous <= 5, 'monitor_gap_over_5_seconds')


class Persistence:
    def __init__(self): self.since = None
    def low(self, available, now):
        self.since = (now if self.since is None else self.since) if available < 8*1024**3 else None
        return self.since is not None and now-self.since >= 2


def bounded_sample(row):
    """Persist fixed numeric/counter fields before any safety decision (<=4 KiB)."""
    result={}
    numeric=('monotonic','available','swap','temperature','critical','mem_info_vram_used',
             'mem_info_gtt_used','gpu_busy_percent','rss')
    for key in numeric:
        value=row.get(key)
        valid=(type(value) is int and value.bit_length()<=64) or (type(value) is float and math.isfinite(value))
        result[key]=value if value is None or valid else 'invalid_numeric'
    for key in ('memory.current','memory.peak','memory.events'):
        value=row.get(key)
        result[key]=value[:256] if isinstance(value,str) and re.fullmatch(r'[a-z_0-9 \n]*',value) else None
    require(len(json.dumps(result))<=4096,'sample_record_exceeds_bound')
    return result


def wait_cooldown(observe, *, clock=time.monotonic, wait=time.sleep, seconds=60, limit=300):
    start=clock(); since=None
    while True:
        row=observe()  # All original safety gates remain active while waiting.
        now=clock()
        ready=row['temperature'] is not None and row['temperature']<85 and row['gpu_busy_percent']==0
        since=(now if since is None else since) if ready else None
        if since is not None and now-since>=seconds: return
        require(now-start<limit,'cooldown_timeout_300_seconds')
        wait(min(1,limit-(now-start)))


class KernelCursor:
    """Kernel timestamp cursor, independent of the userspace monotonic clock.

    Old ring lines can disappear normally; loss of the previous tail anchor
    means coverage cannot be verified and must not be reported as fault-free.
    """
    FAULT=re.compile(r'(?:amdgpu|kfd|GPU).*(?:reset|fault|timeout|error|failed)|'
                     r'out of memory|oom-kill|oom_reaper|machine check|mce:|hardware error|'
                     r'critical temperature|thermal.*critical',re.I)

    @staticmethod
    def parse(text):
        result=[]
        for line in text.splitlines():
            match=re.match(r'^\[\s*([0-9]+(?:\.[0-9]+)?)\]\s*(.*)$',line)
            require(match is not None,'kernel_timestamp_unavailable')
            result.append((float(match[1]),line))
        return result

    def __init__(self,text):
        rows=self.parse(text)
        require(rows,'kernel_timestamp_unavailable')
        self.cursor=max(stamp for stamp,_ in rows);self.anchor=rows[-1][1]
        self.seen={line for _,line in rows}

    def check(self,text):
        rows=self.parse(text);lines={line for _,line in rows}
        lost=self.anchor not in lines
        # Deferred printk records can arrive with an older timestamp. Include
        # newly observed text too, rather than silently dropping such faults.
        new=[(stamp,line) for stamp,line in rows if line not in self.seen]
        faults=[line[:512] for _,line in new if self.FAULT.search(line)][:16]
        result=dict(cursor_before=self.cursor,new_lines=len(new),faults=faults,coverage_lost=lost,
                    clock_relation='kernel_cursor_not_assumed_equal_to_userspace_monotonic')
        if rows:
            self.cursor=max(self.cursor,max(stamp for stamp,_ in rows));self.anchor=rows[-1][1]
            self.seen=lines
        result['cursor_after']=self.cursor
        return result


def sensors(root, expected=None):
    """Skip unidentified unrelated directories, never proceed without CPU/GPU.

    Once identified, the exact required directory/input/critical inventory must
    persist. A missing name cannot hide loss of a previously identified sensor.
    """
    inventory={}; skips=[]
    for directory in sorted(Path(root).glob('hwmon*')):
        try: name=(directory/'name').read_text().strip()
        except OSError as error:
            if len(skips)<16:
                skips.append(dict(hwmon=directory.name,reason='name_unavailable',errno=error.errno))
            continue
        if name not in ('k10temp','amdgpu'): continue
        inputs=sorted(p.name for p in directory.glob('temp*_input'))
        criticals=sorted(p.name for p in directory.glob('temp*_crit'))
        require('temp1_input' in inputs,'required_temperature_input_missing')
        for field in inputs+criticals:
            value=int((directory/field).read_text())
            require(0<value<200000,'required_temperature_value_invalid')
        inventory[str(directory)]={'name':name,'inputs':inputs,'criticals':criticals}
    require({item['name'] for item in inventory.values()}=={'k10temp','amdgpu'},'required_CPU_or_GPU_sensor_missing')
    if expected is not None: require(inventory==expected,'required_sensor_inventory_changed')
    return inventory,skips


def output(command):
    return subprocess.check_output(command, text=True, timeout=90 if command[:3]==['docker','container','stop'] else 10).strip()


def health():
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open('http://llama-server:8082/health', timeout=2) as response:
        require(json.loads(response.read(4096)) == {'status':'ok'}, 'health_failed')


class Run:
    def __init__(self, args):
        self.a = args; self.d = args.directory; self.root = args.trial
        self.cpu = pinned(args.cpu, CPU_SHA); self.guard = pinned(args.guard, GUARD_SHA)
        self.host = self.cpu.Host(); self.before = self.host.read(); self.cpu.plan(self.before)
        self.expected = self.before; self.snapshot = self.d/'cpu.json'
        self.child = None; self.tracked = {}; self.pidfds = {}; self.ninjas = []
        self.stopped = False; self.applied = False; self.restored = False
        self.stream = (self.d/'telemetry.jsonl').open('x')
        self.progress_stage = None; self.progress_time = 0
        self.initial = self.read_sample('initial'); self.gate = self.guard.Gate(self.initial['swap'])
        self.persistence = Persistence(); self.oom = self.oom_count()
        self.kernel = KernelCursor(self.kernel_text()); self.result = {'build_spawned':False,'cpu_apply_attempted':False}
        self.old_hashes = json.loads((self.root/'private/binary-library-hashes.json').read_text())
        self.saved = json.loads((self.root/'private/baseline.json').read_text())
        self.entry_hash = None; self.compose_hash = None
        self.sensor_inventory,self.sensor_skips=self.read_sensors('initial')

    def log(self, stage, **fields):
        self.stream.write(json.dumps(dict(stage=stage, monotonic=time.monotonic(), **fields))+'\n')
        self.stream.flush()
        now=time.monotonic()
        if stage in ('build_processes','sample_observed','kernel_delta'): return
        if stage != self.progress_stage or now-self.progress_time >= 60:
            sample=fields.get('sample',{})
            with self.a.progress.open('a') as progress:
                progress.write(f"- {time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime())}: {stage}; T={sample.get('temperature')}°C available={sample.get('available')} bytes stop={fields.get('stop_reason')}\n")
            self.progress_stage=stage; self.progress_time=now

    def state(self):
        # Selected Docker fields only: do not export environment/secrets.
        raw = output(['docker','inspect','--format',
            '{{json .Id}} {{json .Image}} {{json .State}} {{json .RestartCount}} {{json .Path}} {{json .Args}}', CID])
        decoder=json.JSONDecoder(); parts=[]
        while raw:
            item, end=decoder.raw_decode(raw); parts.append(item); raw=raw[end:].lstrip()
        ident,image,state,restarts,path,args=parts
        require(ident==CID and image==IMAGE and path==self.saved['path'] and args==self.saved['args'], 'baseline_identity_drift')
        require(not state['OOMKilled'], 'baseline_oom')
        return dict(status=state['Status'], pid=state['Pid'], restarts=restarts, oom=state['OOMKilled'])

    def hashes(self):
        for row in self.old_hashes:
            digest = output(['docker','exec',CID,'sha256sum',row['path']]).split()[0]
            require(digest==row['sha256'], 'baseline_binary_library_changed')
        entry = output(['docker','exec',CID,'sha256sum','/usr/local/bin/entrypoint.sh']).split()[0]
        if self.entry_hash is not None: require(entry==self.entry_hash, 'entrypoint_changed')
        self.entry_hash=entry
        compose=Path('/home/yuanying/dotfiles/devbox/apps/compose.anietta.yaml').read_bytes()
        digest=hashlib.sha256(compose).hexdigest()
        if self.compose_hash is not None: require(digest==self.compose_hash, 'compose_changed')
        else: (self.d/'compose.anietta.yaml').write_bytes(compose)
        self.compose_hash=digest
        # Verify actual loaded libraries, not only inactive files.
        maps=output(['docker','exec',CID,'python3','-c',
            "from pathlib import Path; matches=[]\nfor p in Path('/proc').glob('[0-9]*'):\n try:\n  if (p/'exe').resolve().name=='llama-server': matches.append(p)\n except OSError: pass\nassert len(matches)==1; print((matches[0]/'maps').read_text())"])
        # Require the active server's mapped library identities too.
        for row in self.old_hashes:
            if row['path'].endswith('/llama-server'): continue
            require(row['path'] in maps, 'mapped_library_missing')

    def oom_count(self):
        return int(next(line.split()[1] for line in Path('/proc/vmstat').read_text().splitlines() if line.startswith('oom_kill ')))

    def read_sample(self,stage):
        try: row=self.guard.sample(self.child.pid if self.child else None)
        except BaseException as error:
            self.log('sample_read_error',check_stage=stage,source='PR165.sample',error_type=type(error).__name__,errno=getattr(error,'errno',None))
            raise
        self.log('sample_observed',check_stage=stage,sample=bounded_sample(row))
        return row

    def read_sensors(self,stage):
        try: return sensors(Path('/sys/class/hwmon'),getattr(self,'sensor_inventory',None))
        except BaseException as error:
            self.log('sample_read_error',check_stage=stage,source='CPU_GPU_sensor_inventory',error_type=type(error).__name__,errno=getattr(error,'errno',None))
            raise

    def kernel_text(self):
        try:
            # Do not whole-output strip: a last line's trailing space must
            # remain identical when a later append makes it an interior line.
            text=subprocess.check_output(['dmesg'],text=True,timeout=10)
            require(len(text.encode())<=4*1024**2,'kernel_read_budget_exceeded')
            return text
        except BaseException as error:
            self.log('sample_read_error',source='dmesg',error_type=type(error).__name__,errno=getattr(error,'errno',None))
            raise

    def observe(self, stage, service=False):
        row=self.read_sample(stage)
        self.cpu.equivalent(self.host.read(), self.expected)
        reason=self.gate.check(row['available'],row['swap'],row['temperature'],row['monotonic'],row['critical'])
        # PR165 counts two samples; retain that conservative gate and add elapsed persistence.
        if self.persistence.low(row['available'],row['monotonic']): reason='memory_2_seconds'
        if row['memory.events'] != self.initial['memory.events'] or self.oom_count()!=self.oom: reason='oom_or_cgroup_event'
        try: kernel=self.kernel.check(self.kernel_text())
        except BaseException as error:
            self.log('sample_read_error',check_stage=stage,source='KernelCursor.check',error_type=type(error).__name__,errno=getattr(error,'errno',None))
            raise
        if kernel['new_lines'] or kernel['coverage_lost']:
            self.log('kernel_delta',**kernel)
        if kernel['coverage_lost']: reason='kernel_coverage_lost'
        if kernel['faults']: reason='new_kernel_fault'
        require(row['gpu_busy_percent'] is not None, 'GPU_sensor_missing')
        # Unknown unrelated hwmon/name failures are bounded and recorded, but
        # disappearance of an identified CPU/GPU input or critical is fatal.
        _,skips=self.read_sensors(stage)
        if service: health()
        else: require(self.state()['status']=='exited', 'baseline_unexpected_restart')
        self.log(stage, sample=row, stop_reason=reason, cpu_state=self.host.read(),sensor_skips=skips)
        require(reason is None, 'guard_'+str(reason))
        return row

    def hold(self, stage, seconds, service=False):
        start=time.monotonic(); previous=start
        while True:
            # An independent sampling alarm also interrupts blocked reads/monitor errors.
            signal.setitimer(signal.ITIMER_REAL, 5)
            self.observe(stage,service)
            signal.setitimer(signal.ITIMER_REAL, 0)
            now=time.monotonic(); require(now-previous<5, 'monitor_stalled'); previous=now
            if now-start >= seconds: return
            time.sleep(min(1,seconds-(now-start)))

    def cooldown(self,stage):
        def observe():
            signal.setitimer(signal.ITIMER_REAL,5)
            try: return self.observe(stage)
            finally: signal.setitimer(signal.ITIMER_REAL,0)
        wait_cooldown(observe)
        self.log('cooldown_ready',check_stage=stage,continuous_seconds=60,max_wait_seconds=300)

    def preflight(self):
        require(self.state()['status']=='running', 'baseline_not_running')
        health(); self.hashes()
        require(output(['git','-C',str(self.root/'src'),'rev-parse','HEAD'])==ENGINE, 'engine_revision')
        require(not output(['git','-C',str(self.root/'src'),'status','--porcelain']), 'dirty_engine_source')
        require(os.statvfs(self.root).f_bavail*os.statvfs(self.root).f_frsize>50*1024**3,'disk_reserve')
        # No compiler/candidate remnants, independent of process groups.
        self.no_compilers()
        self.log('preflight', baseline=self.state(), sample=self.initial,
                 sensor_inventory=self.sensor_inventory,sensor_skips=self.sensor_skips,
                 source_sha={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in
                             (self.a.cpu,self.a.guard,self.root/'build-once-j1.sh',self.root/'install.lock')})
        self.hold('original_stability',60,service=True)

    def no_compilers(self):
        offenders=[]
        for p in Path('/proc').glob('[0-9]*/comm'):
            try: name=p.read_text().strip()
            except OSError: continue
            compiler=bool(re.fullmatch(r'(ninja|hipcc|clang.*|cc1.*|g\+\+|cc1plus|kyojin)',name))
            candidate=False
            if name.startswith('python') and int(p.parent.name)!=os.getpid():
                try:
                    command=(p.parent/'cmdline').read_bytes().decode(errors='replace')
                    candidate=str(self.root) in command or 'exllamav3' in command
                except OSError: pass
            if compiler or candidate: offenders.append(p.parent.name)
        require(not offenders,'existing_compiler_or_candidate:'+','.join(offenders))

    def stop_service(self):
        # Set intent first, including partial stop errors; recovery re-identifies exact ID.
        self.stopped=True
        output(['docker','container','stop','--time','60',CID])
        require(self.state()['status']=='exited','baseline_stop_failed')
        row=self.read_sample('memory_release')
        require(row['available']>=100*1024**3 and row['available']-self.initial['available']>=60*1024**3,'memory_release_gate')
        self.cooldown('stopped_cooldown')
        self.no_compilers()

    def apply(self):
        self.cpu.equivalent(self.host.read(),self.before)
        self.cpu.snapshot(self.host,self.snapshot)
        require(self.cpu.load(self.snapshot)['before']==self.before,'snapshot_race')
        self.result['cpu_apply_attempted']=True
        self.applied=True  # Restore even after partial apply failure.
        self.cpu.apply(self.host,self.snapshot)
        self.expected=copy.deepcopy(self.before)
        for i in self.cpu.POLICIES:
            self.expected['policies'][i][self.cpu.MAX]=str(min(3000000,int(self.before['policies'][i][self.cpu.MAX])))
        self.cooldown('capped_cooldown')

    def track(self, validate=True):
        table=self.guard.processes()
        roots=alive(self.tracked,table)
        if self.child.pid not in self.tracked and self.child.poll() is None:
            roots.add(self.child.pid)
        for root in roots:
            for pid in self.guard.descendants(root,{p:v['parent'] for p,v in table.items()}):
                if pid not in table: continue
                start=table[pid]['start']
                if pid not in self.tracked:
                    try: fd=os.pidfd_open(pid)
                    except ProcessLookupError: continue
                    fresh=self.guard.processes()
                    if pid not in fresh or fresh[pid]['start']!=start:
                        os.close(fd); continue
                    self.tracked[pid]=start; self.pidfds[pid]=fd
        commands=[]
        for pid in alive(self.tracked,table):
            try: cmd=Path(f'/proc/{pid}/cmdline').read_bytes().decode(errors='replace').rstrip('\0').split('\0')
            except OSError: continue
            if cmd and Path(cmd[0]).name=='ninja':
                if validate: ninja_one(cmd)
                commands.append(cmd)
                if cmd not in self.ninjas: self.ninjas.append(cmd)
        return commands

    def build(self):
        # No privileged compiler: keep existing source/cache ABI and ownership.
        user=pwd.getpwnam('yuanying')
        command=['bash','-c',
            'set -euo pipefail; bash "$1/build-once-j1.sh"; cd "$1/src"; '
            'export EXL3_VENV="$1/venv" EXL3_ROCM_SDK="$1/venv/lib/python3.12/site-packages/_rocm_sdk_devel"; '
            'source tools/strix_halo/env.sh; "$EXL3_VENV/bin/python" -c '
            "'import torch, exllamav3_ext; print(\"CAPBUILD_IMPORT_OK\", torch.__version__, torch.version.hip, exllamav3_ext.__file__)'",
            'capbuild',str(self.root)]
        env=dict(os.environ,MAX_JOBS='1',CMAKE_BUILD_PARALLEL_LEVEL='1',MAKEFLAGS='-j1',
                 OMP_NUM_THREADS='1',MKL_NUM_THREADS='1',OPENBLAS_NUM_THREADS='1',HOME=user.pw_dir)
        start=time.monotonic(); previous=start
        with (self.d/'build.log').open('xb') as log:
            self.child=subprocess.Popen(command,env=env,stdout=log,stderr=subprocess.STDOUT,
                start_new_session=True,user=user.pw_uid,group=user.pw_gid,extra_groups=[])
            self.result['build_spawned']=True
            self.log('build_started',pid=self.child.pid,max_seconds=3600,MAX_JOBS=1,CMAKE_BUILD_PARALLEL_LEVEL=1)
            self.track()
            try:
                while self.child.poll() is None:
                    signal.setitimer(signal.ITIMER_REAL,min(5,max(.001,3600-(time.monotonic()-start))))
                    commands=self.track(); row=self.observe('build')
                    now=time.monotonic(); timing(now,start,previous); previous=now
                    self.log('build_processes',tracked=self.tracked,ninja_commands=commands,elapsed=now-start)
                    signal.setitimer(signal.ITIMER_REAL,0)
                    time.sleep(min(1,max(0,3600-(time.monotonic()-start))))
                timing(time.monotonic(),start,previous)
                require(self.child.returncode==0,'build_exit_'+str(self.child.returncode))
                require(self.ninjas,'actual_ninja_not_observed')
                require(b'CAPBUILD_IMPORT_OK' in (self.d/'build.log').read_bytes(),'extension_import_not_confirmed')
                artifacts=list((self.root/'src').glob('exllamav3_ext*.so'))
                require(artifacts,'extension_artifact_missing')
                self.result['artifacts']=[dict(path=str(p),bytes=p.stat().st_size,sha256=hashlib.sha256(p.read_bytes()).hexdigest()) for p in artifacts]
                self.result['build']='success'
            finally:
                signal.setitimer(signal.ITIMER_REAL,0)
                self.result.update(build_seconds=time.monotonic()-start,ninja_commands=self.ninjas)

    def stop_children(self):
        signal.setitimer(signal.ITIMER_REAL,0)
        # Cleanup cannot be interrupted by a second TERM/alarm.
        for s in (signal.SIGALRM,signal.SIGTERM,signal.SIGINT): signal.signal(s,signal.SIG_IGN)
        if self.child:
            self.track(validate=False)
            for sig in (signal.SIGTERM,signal.SIGKILL):
                for pid in alive(self.tracked,self.guard.processes()):
                    try: signal.pidfd_send_signal(self.pidfds[pid],sig)
                    except ProcessLookupError: pass
                end=time.monotonic()+20
                while alive(self.tracked,self.guard.processes()) and time.monotonic()<end: time.sleep(.2)
                if not alive(self.tracked,self.guard.processes()): break
            require(not alive(self.tracked,self.guard.processes()),'children_stuck_DO_NOT_RESTORE')
            self.child.wait(timeout=2)
            for fd in self.pidfds.values(): os.close(fd)
        self.no_compilers()
        self.result['children_gone']=True
        self.log('children_gone',tracked=self.tracked)

    def restore_cpu(self):
        if self.applied: self.cpu.restore(self.host,self.snapshot)
        self.cpu.equivalent(self.host.read(),self.before)
        self.expected=self.before; self.restored=True
        self.log('cpu_restored',cpu_state=self.host.read())
        self.result['cpu_restored']=True
        if self.stopped: self.cooldown('restored_cooldown')

    def ensure_stopped(self):
        state=self.state()
        self.result['final_service_state']=state
        if self.stopped: require(state['status']=='exited','baseline_not_held_stopped')
        self.result['service_held_stopped']=self.stopped and state['status']=='exited'
        self.log('service_preserved_without_start',baseline=state)

    def run(self):
        try:
            self.preflight()
            return lifecycle(self.stop_service,self.apply,self.build,self.stop_children,self.restore_cpu,self.ensure_stopped)
        except BaseException as error:
            chain=[];current=error
            while current is not None and len(chain)<5:
                chain.append(dict(type=type(current).__name__,errno=getattr(current,'errno',None),message=str(current)[:256]))
                current=current.__cause__ or current.__context__
            self.result.update(error_type=type(error).__name__,error=str(error)[:256],errno=getattr(error,'errno',None),error_chain=chain)
            self.log('failure',**self.result)
            raise
        finally:
            (self.d/'result.json').write_text(json.dumps(self.result,indent=2)+'\n')
            self.stream.close()


def main():
    p=argparse.ArgumentParser(description=__doc__)
    for name in ('cpu','guard','trial','directory','progress'): p.add_argument('--'+name,type=Path,required=True)
    p.add_argument('--confirm-single-build',action='store_true'); a=p.parse_args()
    require(a.confirm_single_build and os.geteuid()==0,'explicit_approval_and_root_required')
    require(a.directory.is_absolute() and a.directory.resolve()==a.directory,'private_path_no_symlinks')
    info=a.directory.stat()
    require(info.st_uid==0 and stat.S_IMODE(info.st_mode)==0o700 and not any(a.directory.iterdir()),'new_empty_root0700_required')
    os.umask(0o077)
    # Singleton is never a substitute for human coordination with other workloads.
    import fcntl
    fd=os.open('/run/evox2-capbuild.lock',os.O_CREAT|os.O_RDWR|os.O_NOFOLLOW,0o600)
    info=os.fstat(fd)
    require(stat.S_ISREG(info.st_mode) and info.st_uid==0 and stat.S_IMODE(info.st_mode)==0o600 and info.st_nlink==1,'unsafe_singleton_lock')
    fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
    def interrupted(signum, frame): raise RuntimeError('monitor_alarm_or_signal_'+str(signum))
    for s in (signal.SIGALRM,signal.SIGTERM,signal.SIGINT): signal.signal(s,interrupted)
    Run(a).run()

if __name__=='__main__': main()
