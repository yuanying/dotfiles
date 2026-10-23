#!/usr/bin/env python3
"""One guarded candidate lifecycle, with no service or CPU writes and no rebuild.

Reuses the pinned, tested capbuild sensor/kernel/PID monitor and PR165 guard.
Native work is unprivileged. Host-level monitor needs read-only root visibility.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import pwd
import signal
import subprocess
import sys
import time
import types
import urllib.request

import kyojin_infer as infer

CAP_SHA='fd3e551f963535d12d41e8e4b50a429942d183884ddab7ee1d881b6e8ef494e9'
SO_SHA='52369c1e5b2d3dbb2f144b230c7a32e448cb8dccf6c998f60767f6690b19d984'
ENGINE='e09322da7209331c57e2a79cfc30d120f0299154'


class LongGate:
    """User-approved memory gate for a dedicated LLM host (256K context).

    Replaces only the swap-growth/8GiB rules. Temperature rules are unchanged.
    pswpin is the cumulative /proc/vmstat page counter.
    """
    def __init__(self):
        self.hot_since=None;self.low_since=None;self.thrash_since=None;self.previous=None
    def check(self,available,swap,temperature,now,critical=None,*,pswpin):
        if self.previous is not None:
            then,count=self.previous
            if pswpin<count or now<=then:return 'vmstat_counter_invalid'
            rate=(pswpin-count)/(now-then)
            self.thrash_since=(self.thrash_since if self.thrash_since is not None else then) if rate>1000 else None
        self.previous=(now,pswpin)
        if swap>6*1024**3:return 'swap_used_over_6GiB'
        if self.thrash_since is not None and now-self.thrash_since>=30:return 'pswpin_thrashing_30s'
        self.low_since=(self.low_since if self.low_since is not None else now) if available<2*1024**3 else None
        if self.low_since is not None and now-self.low_since>=10:return 'available_under_2GiB_10s'
        if temperature is None:return 'temperature_unavailable'
        if critical is not None and temperature>=critical-5:return 'critical_temperature'
        self.hot_since=(self.hot_since if self.hot_since is not None else now) if temperature>=95 else None
        if self.hot_since is not None and now-self.hot_since>=10:return 'temperature'
        return None


def vmstat():
    rows=dict(line.split() for line in Path('/proc/vmstat').read_text().splitlines())
    return {k:int(rows[k]) for k in ('pswpin','pswpout')}


def ngram_mode(log):
    import re
    m=re.search(r'^\[ngram\] table mode (\w+):',log,re.M)
    return m[1] if m else None


def ngram_env(mode):
    return {'disk':{'EXL3_NGRAM_STREAM':'1'},'ram':{'EXL3_NGRAM_STREAM':'0'}}.get(mode,{})


def parse_proc_io(text):
    return {k:int(v) for k,v in (line.split(': ') for line in text.splitlines() if line)}


def parse_diskstats(text,device):
    for line in text.splitlines():
        f=line.split()
        if len(f)>=10 and f[2]==device:
            return dict(reads=int(f[3]),read_sectors=int(f[5]),writes=int(f[7]),write_sectors=int(f[9]))
    raise ValueError('block_device_missing')


def block_device(path):
    # Device backing the model files (dm-N for LVM), read-only discovery.
    dev=os.stat(path).st_dev
    return Path(f'/sys/dev/block/{os.major(dev)}:{os.minor(dev)}').resolve().name


def verify_effective(text,mode,ngram,spec,ablit_env):
    """Preset and n-gram mode proof from the actual engine log; returns the observed n-gram mode."""
    if mode=='on':infer.require(infer.preset_active(text,spec),'uncensor_not_effective')
    else:infer.require('ablit runtime: spec ' not in text and ablit_env=='off','preset_off_not_confirmed')
    observed=ngram_mode(text)
    if ngram=='disk':infer.require(observed=='trellis_disk','ngram_disk_mode_not_effective')
    if ngram=='ram':infer.require(observed=='trellis_ram','ngram_ram_mode_not_effective')
    return observed


def vmstat_fields(stage,row,vm):
    # Run.log owns 'stage' and 'monotonic'; never pass them again.
    return dict(check_stage=stage,sample_monotonic=row['monotonic'],**vm)


def lifecycle(preflight,execute,stop,verify):
    try:
        preflight();return execute()
    finally:
        # No baseline start/CPU mutation path exists.
        try:stop()
        finally:verify()


def kfd_users():
    users=[]
    for proc in Path('/proc').glob('[0-9]*'):
        try:
            for fd in (proc/'fd').iterdir():
                try: target=os.readlink(fd)
                except FileNotFoundError:continue
                if target=='/dev/kfd':users.append(int(proc.name));break
        except (FileNotFoundError,ProcessLookupError):continue
    return users


def extension_gate(trial):
    so=trial/'src/exllamav3_ext.cpython-312-x86_64-linux-gnu.so'
    infer.require(so.stat().st_size==136685256 and hashlib.sha256(so.read_bytes()).hexdigest()==SO_SHA,'extension_changed')
    return dict(bytes=so.stat().st_size,sha256=SO_SHA)


def bootstrap():
    # This executes only under the host guard. Precompiled extension required;
    # torch's lazy native extension build entry point is explicitly disabled.
    import torch.utils.cpp_extension as cpp
    def forbidden(*args,**kwargs):raise RuntimeError('extension_rebuild_forbidden')
    cpp.load=forbidden;cpp.load_inline=forbidden
    import exllamav3_ext
    infer.require(Path(exllamav3_ext.__file__).resolve()==Path.cwd()/'exllamav3_ext.cpython-312-x86_64-linux-gnu.so','imported_extension_path')
    import torch
    props=torch.cuda.get_device_properties(0)
    infer.require(torch.__version__=='2.12.0a0+rocm7.13.0a20260411' and torch.version.hip=='7.13.60980' and props.gcnArchName.split(':')[0]=='gfx1151','native_ABI_drift')
    print('INFER_PRECOMPILED_EXTENSION',exllamav3_ext.__file__,torch.__version__,torch.version.hip,props.gcnArchName,flush=True)
    import runpy
    sys.argv=['tools/qwen/serve.py']+sys.argv[2:]
    runpy.run_path('tools/qwen/serve.py',run_name='__main__')


def child(a):
    os.umask(0o077)
    model=a.model;trial=a.trial;d=a.directory
    spec=model/'uncensor-preset/uncensor_spec.json'
    command=['bash','-c',
        'set -euo pipefail; cd "$1/src"; export EXL3_VENV="$1/venv" EXL3_ROCM_SDK="$1/venv/lib/python3.12/site-packages/_rocm_sdk_devel"; '
        'source tools/strix_halo/env.sh; exec "$EXL3_VENV/bin/python" "$2" --bootstrap '
        '--model "$3" --model-id qwen3.8-flash-next --host 127.0.0.1 --port 18082 -c "$5" --sessions "$7" '
        '--cache-bits "$6" --draft-policy mix --chat-template "$3/chat_template.jinja" --default-reasoning-effort xhigh '
        '--default-max-tokens 256 --slot-save-path "$4/slots"',
        'infer',str(trial),str(Path(__file__).resolve()),str(model),str(d),str(a.ctx),str(a.cache_bits),str(a.sessions)]
    env=dict({k:os.environ[k] for k in ('HOME','PATH','LANG','LC_ALL') if k in os.environ},
             EXL3_ROOT=str(trial/'src'),EXL3_HSA_LIB=str(trial/'venv/lib/python3.12/site-packages/_rocm_sdk_devel/lib/libhsa-runtime64.so.1'),
             HF_HUB_OFFLINE='1',TRANSFORMERS_OFFLINE='1',PYTHONUNBUFFERED='1',EXL3_ABLIT_RUNTIME=str(spec) if a.mode=='on' else 'off',
             TORCH_EXTENSIONS_DIR=str(trial/'cache/torch'),TMPDIR=str(trial/'tmp'),
             PIP_NO_INDEX='1',PIP_NO_DEPS='1',PIP_NO_CACHE_DIR='1',PIP_DISABLE_PIP_VERSION_CHECK='1',
             OMP_NUM_THREADS='1',MKL_NUM_THREADS='1',OPENBLAS_NUM_THREADS='1',MAX_JOBS='1',
             KYOJIN_HEALTH_DIR=str(d/'health'),KYOJIN_REQLOG_DIR=str(d/'request-logs'),
             EXL3_ABLIT_COST_ONLY='0',**ngram_env(a.ngram))
    # Never inherit unknown projection modifiers from a shell.
    infer.require(not any(k.startswith('EXL3_ABLIT_') and k not in ('EXL3_ABLIT_RUNTIME','EXL3_ABLIT_COST_ONLY') for k in env),'unknown_ablit_modifier')
    server=None
    def cancelled(sig,frame):raise RuntimeError('child_cancelled')
    signal.signal(signal.SIGTERM,cancelled);signal.signal(signal.SIGINT,cancelled)
    try:
        with (d/'server.log').open('xb') as log:
            server=subprocess.Popen(command,env=env,stdout=log,stderr=subprocess.STDOUT)
            (d/'server.pid').write_text(str(server.pid))
            start=time.monotonic();opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
            while True:
                infer.require(server.poll() is None,'server_exited_during_load')
                infer.require(time.monotonic()-start<1800,'load_timeout_1800')
                try:
                    with opener.open('http://127.0.0.1:18082/health',timeout=2) as r:health=json.loads(r.read(4096))
                    if health.get('status')=='ok':break
                except (OSError,ValueError):pass
                time.sleep(1)
            text=(d/'server.log').read_text(errors='replace')
            observed_ngram=verify_effective(text,a.mode,a.ngram,spec,env['EXL3_ABLIT_RUNTIME'])
            proof=dict(mode=a.mode,active_marker=infer.preset_active(text,spec),spec_sha256=hashlib.sha256(spec.read_bytes()).hexdigest(),
                       spec_path=str(spec),ngram_requested=a.ngram,ngram_mode=observed_ngram,extension=extension_gate(trial),load_seconds=time.monotonic()-start,health=health,
                       template_sha256=hashlib.sha256((model/'chat_template.jinja').read_bytes()).hexdigest(),
                       settings=dict(context=a.ctx,sessions=a.sessions,cache_bits=a.cache_bits,profile=a.profile,draft_policy='mix',default_effort='xhigh',request_effort='low_or_none',cpu_cap='unchanged',OMP_NUM_THREADS=1))
            (d/'effective.json').write_text(json.dumps(proof,indent=2)+'\n')
            print(json.dumps(dict(stage='READY',mode=a.mode,load_seconds=proof['load_seconds'],active_marker=proof['active_marker'])),flush=True)
            if a.profile=='long':infer.suite_long(infer.Client(d,a.references,infer.Budget(300,76800),a.ctx,a.sessions),a.soak_seconds)
            else:infer.suite(infer.Client(d,a.references,infer.Budget(),a.ctx),a.mode)
    finally:
        signal.signal(signal.SIGTERM,signal.SIG_IGN);signal.signal(signal.SIGINT,signal.SIG_IGN)
        if server is not None:
            server.terminate()
            try:server.wait(timeout=20)
            except subprocess.TimeoutExpired:server.kill();server.wait(timeout=5)


def monitor(a):
    infer.require(os.geteuid()==0 and a.confirm_single_candidate,'explicit_guard_required')
    cap=infer.pinned(a.references/'reference-capbuild/evox2-capbuild-readerfix-once.py',CAP_SHA)
    class Run(cap.Run):
        def __init__(self,args):
            self.vm=vmstat();self.blockdev=block_device(a.model)
            super().__init__(args)
            if a.profile=='long':
                # User-approved dedicated-host memory gate replaces swap growth/8GiB rules only.
                run=self;gate=LongGate()
                class Adapter:
                    def check(self,available,swap,temperature,now,critical=None):return gate.check(available,swap,temperature,now,critical,pswpin=run.vm['pswpin'])
                class NoOldPersistence:
                    def low(self,available,now):return False
                self.gate=Adapter();self.persistence=NoOldPersistence()
            self.result['gate_profile']=a.profile
        def read_sample(self,stage):
            pid=self.child.pid if self.child else None
            server_file=a.directory/'server.pid'
            if self.child and server_file.exists():
                server=int(server_file.read_text());table=self.guard.processes()
                if server in self.tracked and server in cap.alive(self.tracked,table):pid=server
            try:
                row=self.guard.sample(pid);self.vm=vmstat();self.log('vmstat',**vmstat_fields(stage,row,self.vm))
                disk=parse_diskstats(Path('/proc/diskstats').read_text(),self.blockdev)
                io=None
                if pid and pid!=(self.child.pid if self.child else None):
                    try:io=parse_proc_io(Path(f'/proc/{pid}/io').read_text())
                    except OSError:io=None
                self.log('io',check_stage=stage,sample_monotonic=row['monotonic'],device=self.blockdev,disk=disk,server_io=io)
            except BaseException as e:
                self.log('sample_read_error',check_stage=stage,source='pinned_guard.sample',error_type=type(e).__name__,errno=getattr(e,'errno',None));raise
            self.log('sample_observed',check_stage=stage,sample=cap.bounded_sample(row),rss_pid=pid)
            return row
        def preflight(self):
            infer.require(self.state()['status']=='exited' and self.state()['restarts']==0,'baseline_not_stopped')
            infer.require(self.initial['available']>=100*1024**3,'load_memory_gate')
            infer.require(cap.output(['git','-C',str(a.trial/'src'),'rev-parse','HEAD'])==ENGINE,'engine_revision')
            infer.require(not cap.output(['git','-C',str(a.trial/'src'),'status','--porcelain']),'source_dirty')
            infer.require(not kfd_users(),'other_GPU_process')
            self.no_compilers();self.result['extension_before']=extension_gate(a.trial)
            infer.require(all(p[self.cpu.MAX]=='5187500' for p in self.before['policies'].values()),'cpu_original_max_drift')
            # Model bytes already publisher-hashed by downloader, not rehashed
            # here a second time. Fixed small manifest and preset hashes retained.
            acquisition=json.loads((a.model/a.acquisition_report).read_text())
            infer.require(acquisition['status']=='verified' and acquisition['revision']=='247ef39b06ff0b0fcba76026429e191b44e0e1f8' and sum(r['bytes'] for r in acquisition['files'])==95370160976,'model_not_verified')
            for r in acquisition['files']:
                p=a.model/r['path'];infer.require(p.is_file() and p.stat().st_size==r['bytes'],'model_size_drift')
            self.log('infer_preflight',baseline=self.state(),sample=self.initial,cpu_state=self.before,extension=self.result['extension_before'])
            self.cooldown('before_model_load')
        def execute(self):
            u=pwd.getpwnam('yuanying');start=time.monotonic();previous=start
            command=[sys.executable,str(Path(__file__).resolve()),'--child','--trial',str(a.trial),'--model',str(a.model),'--directory',str(a.directory),'--references',str(a.references),'--mode',a.mode,'--ctx',str(a.ctx),'--cache-bits',str(a.cache_bits),'--sessions',str(a.sessions),'--ngram',a.ngram,'--profile',a.profile,'--soak-seconds',str(a.soak_seconds)]
            with (a.directory/'child.log').open('xb') as log:
                self.child=subprocess.Popen(command,stdout=log,stderr=subprocess.STDOUT,start_new_session=True,user=u.pw_uid,group=u.pw_gid,extra_groups=os.getgrouplist(u.pw_name,u.pw_gid),env=dict(os.environ,HOME=u.pw_dir))
                self.log('candidate_started',pid=self.child.pid,mode=a.mode,max_seconds=a.max_seconds,ctx=a.ctx,cache_bits=a.cache_bits,profile=a.profile)
                while self.child.poll() is None:
                    signal.setitimer(signal.ITIMER_REAL,5)
                    self.track(validate=False);row=self.observe('infer_'+a.mode)
                    infer.timing(time.monotonic(),start,previous,a.max_seconds);previous=time.monotonic()
                    signal.setitimer(signal.ITIMER_REAL,0)
                    time.sleep(1)
                self.result.update(child_exit=self.child.returncode,elapsed_seconds=time.monotonic()-start)
                infer.require(self.child.returncode==0,'candidate_child_failed')
        def verify_final(self):
            signal.signal(signal.SIGALRM,lambda sig,frame:(_ for _ in ()).throw(RuntimeError('cleanup_monitor_alarm')))
            self.cpu.equivalent(self.host.read(),self.before)
            infer.require(self.state()['status']=='exited','baseline_unexpected_restart')
            self.result['extension_after']=extension_gate(a.trial)
            self.result['cpu_unchanged']=True;self.result['baseline']=self.state()
            self.cooldown('after_candidate_stop')
            row=self.read_sample('release')
            self.result['release']=cap.bounded_sample(row)
            infer.require(row['available']>=100*1024**3 and row['mem_info_gtt_used']<=self.initial['mem_info_gtt_used']+256*1024**2 and not kfd_users(),'candidate_not_released')
            self.result['released']=True
        def run(self):
            try:return lifecycle(self.preflight,self.execute,self.stop_children,self.verify_final)
            except BaseException as e:
                self.result.update(error_type=type(e).__name__,error=str(e)[:128]);raise
            finally:
                (a.directory/'guard-result.json').write_text(json.dumps(self.result,indent=2)+'\n');self.stream.close()
    # Existing fixed CPU module is read-only; no apply/restore methods called.
    a.cpu=a.references/'reference-thermal/evox2-cpu-limit.py'
    a.guard=a.references/'reference-trial/qwen_trial_guard.py'
    for s in (signal.SIGALRM,signal.SIGTERM,signal.SIGINT):
        signal.signal(s,lambda sig,frame:(_ for _ in ()).throw(RuntimeError('monitor_signal_'+str(sig))))
    os.umask(0o077)
    import fcntl
    fd=os.open('/run/evox2-capbuild.lock',os.O_CREAT|os.O_RDWR|os.O_NOFOLLOW,0o600)
    fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
    Run(a).run()


def main():
    if len(sys.argv)>1 and sys.argv[1]=='--bootstrap':bootstrap();return
    p=argparse.ArgumentParser(description=__doc__)
    for name in ('trial','model','directory','references','progress'):p.add_argument('--'+name,type=Path,required=name!='progress')
    p.add_argument('--acquisition-report',default='acquisition-continuation-2.json',help='final verified report name in --model')
    p.add_argument('--ctx',type=int,choices=[32768,131072,262144],default=32768);p.add_argument('--cache-bits',type=int,choices=[0,8],default=0);p.add_argument('--sessions',type=int,choices=[1,2],default=1);p.add_argument('--ngram',choices=['auto','disk','ram'],default='auto')
    p.add_argument('--profile',choices=['short','long'],default='short');p.add_argument('--soak-seconds',type=int,default=2400);p.add_argument('--max-seconds',type=int,default=7200)
    p.add_argument('--mode',choices=['on','off'],required=True);p.add_argument('--child',action='store_true');p.add_argument('--confirm-single-candidate',action='store_true');a=p.parse_args()
    if a.child:child(a)
    else:
        infer.require(a.progress is not None and a.directory.stat().st_mode&0o077==0)
        monitor(a)

if __name__=='__main__':main()
