#!/usr/bin/env python3
"""One guarded Strata build or one guarded Strata server trial on anietta.

Strata (Niko1221/Strata v0.2.4) is built and run from its own checkout with
its own ROCm (AMD TheRock 7.14.1 for gfx1151, extracted under the user's
home); the system ROCm, the Kyojin environment and production are not
changed. The monitor is the pinned capbuild Run with kyojin_infer_guard's
long memory gate (95 °C for 10 s, available < 2 GiB for 10 s, swap > 6 GiB,
swap-in thrashing, OOM/cgroup events, new kernel GPU faults); the build and
the server run unprivileged as the user.

- build: production keeps running. `--cpu-cap` lowers all 32 CPU max to
  min(original, 3 GHz) for the build and restores it on every exit.
- serve: production must already be stopped (`--baseline`). The server is
  started on 127.0.0.1:18083, the trial (strata_trial.py) runs against it,
  and the server is stopped; production is started again by hand.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import pwd
import re
import signal
import subprocess
import sys
import time
import urllib.request

import kyojin_infer as infer
import kyojin_infer_guard as guard

GIB=1024**3
STRATA_COMMIT='96ca4383c7b05a8a3e6064c65d9e9977d4b3bb59'
# llama.cpp at the revision third_party/ggml/VERSION.txt pins: ggml for the
# engine, mtmd for the vision encoder, gguf-py for the packer.
LLAMA_COMMIT='3cf03257f219afbe7334045ff7c6a06ac68c627d'
ROCM_TARBALL='therock-dist-linux-gfx1151-7.14.1.tar.gz'
ROCM_TARBALL_SHA='c40e8f2bd6630a7d11557c762b99c6fa8afb04c9bd0e51ed1675ee1ca24afb00'
# The hipBLASLt table for ROCm 7.14.1 (docs/STRIX_HALO.md section 3).
HIPBLASLT_TABLE='tools/hip/gfx1151-hipblaslt-100401.txt'
HOST='127.0.0.1'
PORT=18083
MODEL_ID='qwen3.8-flash-next'
# The engine, then the CPU vision encoder (tools/vision), both configured beforehand.
BUILDS=(('build-halo','strata'),('build-vision','strata-vision'))
MAX_JOBS=8
CONTEXTS=(32768,131072,262144)


def build_command(strata,jobs):
    infer.require(type(jobs) is int and 1<=jobs<=MAX_JOBS,'build_jobs')
    steps='; '.join(f'"$1" -C "$2/{d}" -j "$3" {t}' for d,t in BUILDS)
    return ['bash','-c','set -euo pipefail; '+steps,'strata-build',str(strata/'.venv/bin/ninja'),str(strata),str(jobs)]


def ninja_jobs(command):
    """The -j of one ninja command line; None when it has none (ninja's default is every core)."""
    jobs=[]
    for i,arg in enumerate(command):
        if arg=='-j':jobs.append(command[i+1] if i+1<len(command) else '')
        elif arg.startswith('-j'):jobs.append(arg[2:])
    return jobs[-1] if jobs else None


def ninja_ok(command,jobs):
    infer.require(ninja_jobs(command)==str(jobs),'ninja_jobs_drift')


def sdk_env(strata,sdk,home,lang=None):
    """Only the isolated SDK and the checkout's venv; nothing STRATA_*, ROCm or HIP is inherited."""
    env=dict(HOME=home,PATH=':'.join([str(strata/'.venv/bin'),str(sdk/'bin'),str(sdk/'lib/llvm/bin'),'/usr/local/bin','/usr/bin','/bin']),
             ROCM_PATH=str(sdk),HIP_PATH=str(sdk),HIP_PLATFORM='amd',
             LD_LIBRARY_PATH=':'.join(str(sdk/p) for p in ('lib','lib/rocm_sysdeps/lib','lib/llvm/lib')),
             # The build was configured with ccache found; keep the user's cache out of it.
             CCACHE_DISABLE='1',TMPDIR=str(strata/'tmp'))
    if lang:env['LANG']=lang
    return env


def serve_env(strata,sdk,home,lang=None,extra=None):
    env=sdk_env(strata,sdk,home,lang)
    # The config's engine switches (profile 'strix'); nothing but STRATA_* is taken from it.
    for k,v in (extra or {}).items():
        infer.require(k.startswith('STRATA_') and isinstance(v,str),'config_env')
        env[k]=v
    env.update(STRATA_HIPBLASLT_TUNING=str(strata/HIPBLASLT_TABLE),STRATA_GGUF_PY=str(strata/'third_party/llama.cpp/gguf-py'),
               PYTHONUNBUFFERED='1',HF_HUB_OFFLINE='1')
    return env


# docs/STRIX_HALO.md's measured configuration (section 6: section 5's fast switches on top of section 4's
# defaults, --spec 4 --mtp --lookup-chain 3 --mtp-q4 all --prefill 16384, int8 KV, all experts in the unified
# memory), with --mtp-window 8192 for long contexts, STRATA_PF_F16 and STRATA_REFILL_PARTS. Several of them
# round differently from the default path (STRIX.md lists which).
STRIX_ARGS=['--mmap-experts','--lookup-chain','3','--mtp-q4','all','--mtp-window','8192']
STRIX_ENV={'STRATA_PF_FUSED':'1','STRATA_IGPU_PROMPT_SET':'1','STRATA_PF_SWITCH_MIN_T':'4096','STRATA_PREFILL_STREAM_MIN':'128',
           'STRATA_PF_F16':'1','STRATA_SH_STREAM':'1','STRATA_REFILL_PARTS':'1'}


def server_config(strata,pack,gguf,mtp,ctx,expert_cache,log,mmproj=None,pool_workers=None,profile='exact'):
    """docs/ORCA.md's local server with the context, a fixed expert-cache size and the exact defaults only:
    none of the opt-in switches of docs/STRIX_HALO.md section 5, which change the output bits."""
    infer.require(ctx in CONTEXTS,'context')
    infer.require(type(expert_cache) is int and 256<=expert_cache<=24576,'expert_cache')
    args=['--pack',str(pack),'--native',str(gguf),'--ple-gguf',str(gguf),
          '--expert-profile',str(strata/'data/expert-profile.bin'),'--expert-cache',str(expert_cache),
          '--prefill','512','--spec','4','--spec-min-p','0.5','--mtp',str(mtp),'--max-context',str(ctx),'--kv','int8']
    # Fewer CPU expert workers than the default (every physical core but the host's): serve-1 stopped on the
    # temperature rule with 15. Each expert job is computed by one worker as in serial (src/kernels/cpu/pool_test.cpp).
    infer.require(profile in ('exact','strix'),'profile')
    if profile=='strix':
        # Every expert in the GPU's cache (24,576 slots), read from the GGUF through the file cache instead of a
        # RAM arena beside it, so no expert is left to the CPU pool.
        args[args.index('--prefill')+1]='16384'
        args+=STRIX_ARGS
    if pool_workers is not None:
        infer.require(type(pool_workers) is int and 1<=pool_workers<=15,'pool_workers')
        args+=['--pool-workers',str(pool_workers)]
    cfg=dict(exe=str(strata/'build-halo/strata'),args=args,cwd=str(strata),tokenizer=str(pack/'tokenizer'),
             model_name=MODEL_ID,log=str(log),host=HOST,port=PORT)
    # The CPU reader (tools/vision): the text model is opened for its vocabulary only.
    if profile=='strix':cfg['env']=dict(STRIX_ENV)
    if mmproj:cfg['vision']=dict(exe=str(strata/'build-vision/bin/strata-vision'),mmproj=str(mmproj),model=str(gguf),gpu=False,threads=8)
    return cfg


def build_ready(row):
    """capbuild's cooldown temperature; its idle-GPU condition does not apply while production serves."""
    return row['temperature'] is not None and row['temperature']<85


def wait_ready(observe,ready,*,clock=time.monotonic,wait=time.sleep,seconds=60,limit=300):
    """capbuild's wait_cooldown with another readiness rule; every observe() keeps the guard's gates."""
    start=clock();since=None
    while True:
        row=observe();now=clock()
        since=(now if since is None else since) if ready(row) else None
        if since is not None and now-since>=seconds:return
        infer.require(now-start<limit,'cooldown_timeout_300_seconds')
        wait(min(1,limit-(now-start)))


def loaded(health):
    return health.get('status')=='ok' and health.get('loaded') is True


def run_root(root,baseline):
    """The capbuild monitor reads <root>/private/{baseline,binary-library-hashes}.json at start. Its own
    production checks (hashes, fixed container id) are replaced here, so no library hashes are listed."""
    private=root/'private';private.mkdir(mode=0o700,parents=True,exist_ok=True)
    (private/'baseline.json').write_text(baseline.read_text())
    (private/'binary-library-hashes.json').write_text('[]\n')


def rocm_ok(sdk):
    tarball=sdk.parent/ROCM_TARBALL
    sha=hashlib.sha256()
    with tarball.open('rb') as f:
        for b in iter(lambda:f.read(16*1024**2),b''):sha.update(b)
    infer.require(sha.hexdigest()==ROCM_TARBALL_SHA,'rocm_tarball_changed')
    infer.require((sdk/'lib/llvm/bin/clang++').is_file() and (sdk/'lib/libhipblaslt.so.1').exists(),'rocm_incomplete')


def checkout_ok(output,strata):
    infer.require(output(['git','-C',str(strata),'rev-parse','HEAD'])==STRATA_COMMIT,'strata_revision')
    infer.require(not output(['git','-C',str(strata),'status','--porcelain','--untracked-files=no']),'strata_source_dirty')
    infer.require(output(['git','-C',str(strata/'third_party/llama.cpp'),'rev-parse','HEAD'])==LLAMA_COMMIT,'llama_revision')
    infer.require(not output(['git','-C',str(strata/'third_party/llama.cpp'),'status','--porcelain','--untracked-files=no']),'llama_source_dirty')


def file_record(path):
    sha=hashlib.sha256()
    with path.open('rb') as f:
        for b in iter(lambda:f.read(16*1024**2),b''):sha.update(b)
    return dict(path=str(path),bytes=path.stat().st_size,sha256=sha.hexdigest())


def health_check(port=PORT):
    opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(f'http://{HOST}:{port}/health',timeout=2) as r:return json.loads(r.read(4096))


def monitor(a):
    infer.require(os.geteuid()==0 and a.confirm_single_run,'explicit_guard_required')
    cap=infer.pinned(a.references/'reference-capbuild/evox2-capbuild-readerfix-once.py',guard.CAP_SHA)
    user=pwd.getpwnam('yuanying')
    production=a.mode=='build'
    class Run(cap.Run):
        def __init__(self,args):
            self.vm=guard.vmstat();self.production_states=[]
            super().__init__(args)
            run=self;gate=guard.LongGate()
            class Adapter:
                def check(self,available,swap,temperature,now,critical=None):return gate.check(available,swap,temperature,now,critical,pswpin=run.vm['pswpin'])
            class NoOldPersistence:
                def low(self,available,now):return False
            self.gate=Adapter();self.persistence=NoOldPersistence()
            self.result.update(gate_profile='long',mode=a.mode,cpu_cap=a.cpu_cap,strata_commit=STRATA_COMMIT)
        def read_sample(self,stage):
            pid=self.child.pid if self.child else None
            server_file=a.directory/'server.pid'
            if self.child and server_file.exists():
                server=int(server_file.read_text());table=self.guard.processes()
                if server in self.tracked and server in cap.alive(self.tracked,table):pid=server
            row=self.guard.sample(pid);self.vm=guard.vmstat()
            self.log('vmstat',**guard.vmstat_fields(stage,row,self.vm))
            self.log('sample_observed',check_stage=stage,sample=cap.bounded_sample(row),rss_pid=pid)
            return row
        state=guard.baseline_reader(a.baseline,cap.output)
        def observe(self,stage,service=None):
            # build: production keeps running (checked through Docker, not through its API); serve: it stays stopped.
            return super().observe(stage,production if service is None else service)
        def cooldown(self,stage):
            if not production:return super().cooldown(stage)
            def observe():
                signal.setitimer(signal.ITIMER_REAL,5)
                try:return self.observe(stage)
                finally:signal.setitimer(signal.ITIMER_REAL,0)
            wait_ready(observe,build_ready)
            self.log('cooldown_ready',check_stage=stage,continuous_seconds=60,max_wait_seconds=300,rule='temperature_only')
        def production_running(self):
            s=self.state();self.production_states.append(s['status'])
            infer.require(s['status']=='running','production_not_running')
        def preflight(self):
            s=self.state()
            if production:infer.require(s['status']=='running','baseline_not_running')
            else:
                infer.require(s['status']=='exited' and s['restarts']==0,'baseline_not_stopped')
                infer.require(self.initial['available']>=100*GIB,'load_memory_gate')
                infer.require(not guard.kfd_users(),'other_GPU_process')
            checkout_ok(cap.output,a.strata);rocm_ok(a.sdk)
            self.no_compilers()
            infer.require(all(p[self.cpu.MAX]=='5187500' for p in self.before['policies'].values()),'cpu_original_max_drift')
            if not production:
                self.result['engine']=file_record(a.strata/'build-halo/strata')
                infer.require(a.pack.is_dir() and any(a.pack.iterdir()),'pack_missing')
            self.log('strata_preflight',baseline=s,sample=self.initial,cpu_state=self.before)
            self.cooldown('before_'+a.mode)
        def spawn(self,command,log_name,env,cwd):
            log=(a.directory/log_name).open('xb')
            self.child=subprocess.Popen(command,cwd=cwd,env=env,stdout=log,stderr=subprocess.STDOUT,start_new_session=True,
                                        user=user.pw_uid,group=user.pw_gid,extra_groups=os.getgrouplist(user.pw_name,user.pw_gid))
            return log
        def supervise(self,stage):
            start=time.monotonic();previous=start
            while self.child.poll() is None:
                signal.setitimer(signal.ITIMER_REAL,5)
                self.track(validate=False)
                if a.mode=='build':
                    for cmd in self.ninja_commands():ninja_ok(cmd,a.jobs)
                self.observe(stage)
                infer.require(not (a.directory/'STOP').exists(),'external_abort')
                infer.timing(time.monotonic(),start,previous,a.max_seconds);previous=time.monotonic()
                signal.setitimer(signal.ITIMER_REAL,0)
                time.sleep(1)
            self.result.update(child_exit=self.child.returncode,elapsed_seconds=time.monotonic()-start)
        def ninja_commands(self):
            out=[]
            for pid in cap.alive(self.tracked,self.guard.processes()):
                try:cmd=Path(f'/proc/{pid}/cmdline').read_bytes().decode(errors='replace').rstrip('\0').split('\0')
                except OSError:continue
                if cmd and Path(cmd[0]).name=='ninja':out.append(cmd)
            return out
        def execute(self):
            env=sdk_env(a.strata,a.sdk,user.pw_dir,os.environ.get('LANG'))
            if a.mode=='build':
                # Made by the user beforehand: a directory this root monitor made would not be writable by the build.
                infer.require((a.strata/'tmp').is_dir() and (a.strata/'tmp').stat().st_uid==user.pw_uid,'user_tmp_missing')
                with self.spawn(build_command(a.strata,a.jobs),'build.log',env,str(a.strata)):
                    self.log('build_started',pid=self.child.pid,jobs=a.jobs,max_seconds=a.max_seconds)
                    self.supervise('build')
                infer.require(self.child.returncode==0,'build_failed')
                self.result['artifacts']=[file_record(a.strata/'build-halo/strata'),file_record(a.strata/'build-vision/bin/strata-vision')]
                return
            command=[sys.executable,str(Path(__file__).resolve()),'--child','--strata',str(a.strata),'--sdk',str(a.sdk),'--directory',str(a.directory),
                     '--references',str(a.references),'--config',str(a.config),'--max-requests',str(a.max_requests),'--suite',a.suite]
            with self.spawn(command,'child.log',dict(os.environ,HOME=user.pw_dir),'/'):
                self.log('candidate_started',pid=self.child.pid,config=str(a.config),max_seconds=a.max_seconds,max_requests=a.max_requests)
                self.supervise('serve')
            infer.require(self.child.returncode==0,'candidate_child_failed')
        def verify_final(self):
            signal.signal(signal.SIGALRM,lambda sig,frame:(_ for _ in ()).throw(RuntimeError('cleanup_monitor_alarm')))
            self.cpu.equivalent(self.host.read(),self.before)
            self.result['cpu_unchanged']=True
            s=self.state();self.result['baseline']=s
            if production:infer.require(s['status']=='running','production_not_running');return
            infer.require(s['status']=='exited','baseline_unexpected_restart')
            self.cooldown('after_candidate_stop')
            row=self.read_sample('release')
            self.result['release']=cap.bounded_sample(row)
            infer.require(row['available']>=100*GIB and row['mem_info_gtt_used']<=self.initial['mem_info_gtt_used']+256*1024**2 and not guard.kfd_users(),'candidate_not_released')
            self.result['released']=True
        def run(self):
            try:
                if a.cpu_cap:return guard_capped(self)
                return guard.lifecycle(self.preflight,self.execute,self.stop_children,self.verify_final)
            except BaseException as e:
                self.result.update(error_type=type(e).__name__,error=str(e)[:128]);raise
            finally:
                (a.directory/'guard-result.json').write_text(json.dumps(self.result,indent=2)+'\n');self.stream.close()
    # A module-level function of the pinned monitor, called by observe(service=True).
    run=None
    cap.health=lambda:run.production_running()
    a.cpu=a.references/'reference-thermal/evox2-cpu-limit.py'
    a.guard=a.references/'reference-trial/qwen_trial_guard.py'
    a.trial=a.root
    for s in (signal.SIGALRM,signal.SIGTERM,signal.SIGINT):
        signal.signal(s,lambda sig,frame:(_ for _ in ()).throw(RuntimeError('monitor_signal_'+str(sig))))
    os.umask(0o077)
    import fcntl
    fd=os.open('/run/evox2-capbuild.lock',os.O_CREAT|os.O_RDWR|os.O_NOFOLLOW,0o600)
    fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
    run=Run(a);run.run()


def guard_capped(run):
    # kyojin_convert_guard's order: never restore the CPU ceiling over live children.
    import kyojin_convert_guard as convert
    return convert.capped_lifecycle(run.preflight,run.apply,run.execute,run.stop_children,run.restore_cpu,run.verify_final)


def child(a):
    """The server, its load, the trial and the server's stop, as the user."""
    import strata_trial as trial
    os.umask(0o077)
    home=os.environ['HOME']
    cfg=json.loads(a.config.read_text())
    command=[str(a.strata/'.venv/bin/python'),'-m','serve.server','--engine','strata','--config',str(a.config),'--port',str(PORT),'--no-api-key']
    env=serve_env(a.strata,a.sdk,home,os.environ.get('LANG'),cfg.get('env'))
    server=None
    def cancelled(sig,frame):raise RuntimeError('child_cancelled')
    signal.signal(signal.SIGTERM,cancelled);signal.signal(signal.SIGINT,cancelled)
    try:
        with (a.directory/'server.log').open('xb') as log:
            server=subprocess.Popen(command,cwd=str(a.strata),env=env,stdout=log,stderr=subprocess.STDOUT)
            (a.directory/'server.pid').write_text(str(server.pid))
            start=time.monotonic();health=None
            while True:
                infer.require(server.poll() is None,'server_exited_during_load')
                infer.require(time.monotonic()-start<1800,'load_timeout_1800')
                try:
                    health=health_check()
                    if loaded(health):break
                except (OSError,ValueError):pass
                time.sleep(1)
            (a.directory/'effective.json').write_text(json.dumps(dict(load_seconds=time.monotonic()-start,health=health,config=cfg,
                                                                     env={k:v for k,v in env.items() if k.startswith('STRATA_')}),indent=2)+'\n')
            print(json.dumps(dict(stage='READY',load_seconds=time.monotonic()-start)),flush=True)
            client=trial.Client(a.directory,trial.Budget(a.max_requests),HOST,PORT,cfg_ctx(cfg))
            trial.SUITES[a.suite](client,a.references)
    finally:
        signal.signal(signal.SIGTERM,signal.SIG_IGN);signal.signal(signal.SIGINT,signal.SIG_IGN)
        if server is not None:
            server.terminate()
            try:server.wait(timeout=60)
            except subprocess.TimeoutExpired:server.kill();server.wait(timeout=10)


def write_config(argv):
    """The server config for --mode serve, written once (never over an existing file)."""
    p=argparse.ArgumentParser(prog='strata_guard.py --write-config')
    p.add_argument('out',type=Path)
    for name in ('strata','pack','gguf','mtp','log'):p.add_argument('--'+name,type=Path,required=True)
    p.add_argument('--mmproj',type=Path);p.add_argument('--pool-workers',type=int);p.add_argument('--profile',choices=['exact','strix'],default='exact')
    p.add_argument('--ctx',type=int,required=True);p.add_argument('--expert-cache',type=int,required=True)
    a=p.parse_args(argv)
    cfg=server_config(a.strata,a.pack,a.gguf,a.mtp,a.ctx,a.expert_cache,a.log,a.mmproj,a.pool_workers,a.profile)
    with a.out.open('x') as f:f.write(json.dumps(cfg,indent=2)+'\n')


def cfg_ctx(cfg):
    return int(cfg['args'][cfg['args'].index('--max-context')+1])


def main():
    # Before the production stop: record the running llama-server identity for --baseline.
    if len(sys.argv)==3 and sys.argv[1]=='--write-baseline':guard.write_baseline('llama-server',Path(sys.argv[2]));return
    if len(sys.argv)>1 and sys.argv[1]=='--write-config':write_config(sys.argv[2:]);return
    p=argparse.ArgumentParser(description=__doc__)
    for name in ('strata','sdk','directory','references'):p.add_argument('--'+name,type=Path,required=True)
    for name in ('root','progress','baseline','config','pack'):p.add_argument('--'+name,type=Path)
    p.add_argument('--mode',choices=['build','serve'])
    p.add_argument('--jobs',type=int,default=4);p.add_argument('--cpu-cap',action='store_true')
    p.add_argument('--max-seconds',type=int,default=5400);p.add_argument('--max-requests',type=int,default=100)
    p.add_argument('--suite',default='trial')
    p.add_argument('--child',action='store_true');p.add_argument('--confirm-single-run',action='store_true')
    a=p.parse_args()
    infer.require(all(x.is_absolute() for x in (a.strata,a.sdk,a.directory,a.references)),'absolute_paths')
    if a.child:child(a);return
    infer.require(a.mode is not None and a.root and a.progress and a.baseline,'monitor_arguments')
    infer.require(a.mode=='build' or (a.config and a.pack),'serve_arguments')
    infer.require(a.max_requests<=100 and a.max_seconds<=5400,'trial_limits')
    infer.require(a.directory.stat().st_mode&0o077==0)
    run_root(a.root,a.baseline)
    monitor(a)

if __name__=='__main__':main()
