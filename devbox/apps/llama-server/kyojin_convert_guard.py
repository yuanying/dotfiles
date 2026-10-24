#!/usr/bin/env python3
"""One guarded EXL3 conversion of the heretic-2 BF16 source, with no service or
CPU writes and no rebuild.

Same pinned capbuild monitor as kyojin_infer_guard with its long-profile memory
gate (95 °C for 10 s, available < 2 GiB for 10 s, swap > 6 GiB, swap-in
thrashing, OOM/cgroup events, new kernel GPU faults), plus a 50 GiB filesystem
floor. Production is stopped by hand before and started by hand after.
A stop (guard rule, deadline, `STOP` file in the output directory) ends the run;
resuming from the converter's checkpoint is a separate explicit invocation.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import pwd
import shutil
import signal
import subprocess
import sys
import time

import kyojin_infer as infer
import kyojin_infer_download as download
import kyojin_infer_guard as guard

GIB=1024**3
SOURCE=download.MODELS['heretic2-bf16-207cd22c']
# Language model 4.05 bpw like the turboderp and Lygodactylus 4bpw packs; lm_head 6,
# MTP 8, n-gram table K=6. Vision bits (architecture default) and calibration
# (bundled corpus, 250 x 2048) stay at the converter's defaults.
SETTINGS=('-b','4.05','-hb','6','-mb','8','-ngb','6')
EXPECTED=dict(quant_method='exl3',bits=4.05,head_bits=6,mtp_bits=8)
# Bytes the job writes outside the source, at most: quantized tensors in the work
# directory (~66 GB), one checkpoint (~21 GB) and the compiled pack (~107 GB,
# n-gram table included) coexist during compile.
PEAK_BYTES=200*10**9
FREE_FLOOR=50*GIB


def convert_argv(source,out,work,resume):
    # A resumed job restores every setting from its checkpoint.
    if resume:return ['convert.py','-w',str(work),'-r']
    return ['convert.py','-i',str(source),'-o',str(out),'-w',str(work),*SETTINGS]


def start_disk_gate(free,written):
    infer.require(free-max(0,PEAK_BYTES-written)>=FREE_FLOOR,'disk_reserve_for_conversion')


def run_disk_gate(free):
    infer.require(free>=FREE_FLOOR,'disk_free_under_50GiB')


def job_directories(out,work,resume):
    if resume:infer.require((work/'ckpt/job.json').is_file(),'no_checkpoint_to_resume')
    else:infer.require(not out.exists() and not work.exists(),'job_directories_exist')


def source_verified(source,report):
    guard.acquisition_ok(report,SOURCE)
    for r in report['files']:
        p=source/r['path'];infer.require(p.is_file() and not p.is_symlink() and p.stat().st_size==r['bytes'],'source_size_drift')


def finished(log):
    return ' -- All done' in log


def output_settings(config):
    q=config['quantization_config']
    infer.require(all(q.get(k)==v for k,v in EXPECTED.items()),'output_settings_mismatch')


def output_index(out):
    """Every shard named by the index exists, and the n-gram table is there."""
    shards=set(json.loads((out/'model.safetensors.index.json').read_text())['weight_map'].values())
    infer.require(all((out/s).is_file() for s in shards) and (out/'ngram_embedding.safetensors').is_file(),'output_incomplete')
    return len(shards)


def capped_lifecycle(preflight,apply,execute,stop,restore,verify):
    """With the CPU ceiling: never restore it over live converter processes (as capbuild)."""
    try:
        preflight();apply();return execute()
    finally:
        stop()
        try:restore()
        finally:verify()


def child_env(trial,environ):
    env={k:environ[k] for k in ('HOME','PATH','LANG','LC_ALL') if k in environ}
    env.update(EXL3_ROOT=str(trial/'src'),EXL3_HSA_LIB=str(trial/'venv/lib/python3.12/site-packages/_rocm_sdk_devel/lib/libhsa-runtime64.so.1'),
               HF_HUB_OFFLINE='1',TRANSFORMERS_OFFLINE='1',PYTHONUNBUFFERED='1',
               TORCH_EXTENSIONS_DIR=str(trial/'cache/torch'),TMPDIR=str(trial/'tmp'),
               PIP_NO_INDEX='1',PIP_NO_DEPS='1',PIP_NO_CACHE_DIR='1',PIP_DISABLE_PIP_VERSION_CHECK='1',
               OMP_NUM_THREADS='4',MKL_NUM_THREADS='4',OPENBLAS_NUM_THREADS='4',MAX_JOBS='1',
               # Disk-tight: drop the previous checkpoint once the new one is in place.
               EXL3_CKPT_KEEP_OLD='0')
    return env


def usage(path):
    return int(subprocess.check_output(['du','-sx','-B1',str(path)],text=True,timeout=600).split()[0]) if path.exists() else 0


def free_bytes(path):
    return shutil.disk_usage(path).free


def output_report(out):
    files=[]
    for p in sorted(out.iterdir()):
        sha=hashlib.sha256()
        with p.open('rb') as f:
            for b in iter(lambda:f.read(16*1024**2),b''):sha.update(b)
        files.append(dict(path=p.name,bytes=p.stat().st_size,sha256=sha.hexdigest()))
    return files


def monitor(a):
    infer.require(os.geteuid()==0 and a.confirm_single_conversion,'explicit_guard_required')
    cap=infer.pinned(a.references/'reference-capbuild/evox2-capbuild-readerfix-once.py',guard.CAP_SHA)
    out=a.out;work=a.work
    class Run(cap.Run):
        def __init__(self,args):
            self.vm=guard.vmstat()
            super().__init__(args)
            run=self;gate=guard.LongGate()
            class Adapter:
                def check(self,available,swap,temperature,now,critical=None):return gate.check(available,swap,temperature,now,critical,pswpin=run.vm['pswpin'])
            class NoOldPersistence:
                def low(self,available,now):return False
            self.gate=Adapter();self.persistence=NoOldPersistence()
            self.result.update(gate_profile='long',settings=list(SETTINGS),resume=a.resume,cpu_cap=a.cpu_cap)
        def read_sample(self,stage):
            row=super().read_sample(stage)
            self.vm=guard.vmstat();self.log('vmstat',**guard.vmstat_fields(stage,row,self.vm))
            return row
        state=guard.baseline_reader(a.baseline,cap.output)
        def preflight(self):
            infer.require(self.state()['status']=='exited' and self.state()['restarts']==0,'baseline_not_stopped')
            infer.require(self.initial['available']>=100*GIB,'load_memory_gate')
            infer.require(cap.output(['git','-C',str(a.trial/'src'),'rev-parse','HEAD'])==guard.ENGINE,'engine_revision')
            infer.require(not cap.output(['git','-C',str(a.trial/'src'),'status','--porcelain']),'source_dirty')
            infer.require(not guard.kfd_users(),'other_GPU_process')
            self.no_compilers();self.result['extension_before']=guard.extension_gate(a.trial)
            infer.require(all(p[self.cpu.MAX]=='5187500' for p in self.before['policies'].values()),'cpu_original_max_drift')
            source_verified(a.source,json.loads((a.source/'acquisition.json').read_text()))
            job_directories(out,work,a.resume)
            written=usage(out)+usage(work);free=free_bytes(out.parent)
            start_disk_gate(free,written)
            self.result['disk_start']=dict(free=free,written=written)
            self.log('convert_preflight',baseline=self.state(),sample=self.initial,cpu_state=self.before,extension=self.result['extension_before'],disk=self.result['disk_start'])
            self.cooldown('before_conversion')
        def execute(self):
            u=pwd.getpwnam('yuanying');start=time.monotonic();previous=start
            command=['bash','-c',
                'set -euo pipefail; cd "$1/src"; export EXL3_VENV="$1/venv" EXL3_ROCM_SDK="$1/venv/lib/python3.12/site-packages/_rocm_sdk_devel"; '
                'source tools/strix_halo/env.sh; shift; exec "$EXL3_VENV/bin/python" "$@"',
                'convert',str(a.trial),str(Path(__file__).resolve()),'--bootstrap',*convert_argv(a.source,out,work,a.resume)[1:]]
            log_path=a.directory/'convert.log'
            with log_path.open('xb') as log:
                self.child=subprocess.Popen(command,cwd='/',env=child_env(a.trial,os.environ|{'HOME':u.pw_dir}),stdout=log,stderr=subprocess.STDOUT,start_new_session=True,
                                            user=u.pw_uid,group=u.pw_gid,extra_groups=os.getgrouplist(u.pw_name,u.pw_gid))
                self.log('conversion_started',pid=self.child.pid,max_seconds=a.max_seconds,resume=a.resume)
                while self.child.poll() is None:
                    signal.setitimer(signal.ITIMER_REAL,5)
                    self.track(validate=False);self.observe('convert')
                    run_disk_gate(free_bytes(out.parent))
                    infer.require(not (a.directory/'STOP').exists(),'external_abort')
                    infer.timing(time.monotonic(),start,previous,a.max_seconds);previous=time.monotonic()
                    signal.setitimer(signal.ITIMER_REAL,0)
                    time.sleep(1)
            self.result.update(child_exit=self.child.returncode,elapsed_seconds=time.monotonic()-start)
            infer.require(self.child.returncode==0 and finished(log_path.read_text(errors='replace')),'conversion_failed')
        def verify_final(self):
            signal.signal(signal.SIGALRM,lambda sig,frame:(_ for _ in ()).throw(RuntimeError('cleanup_monitor_alarm')))
            self.cpu.equivalent(self.host.read(),self.before)
            infer.require(self.state()['status']=='exited','baseline_unexpected_restart')
            self.result['extension_after']=guard.extension_gate(a.trial)
            self.result['cpu_unchanged']=True;self.result['baseline']=self.state()
            self.cooldown('after_conversion_stop')
            row=self.read_sample('release')
            self.result['release']=cap.bounded_sample(row)
            infer.require(row['available']>=100*GIB and not guard.kfd_users(),'conversion_not_released')
            self.result['released']=True
        def run(self):
            try:
                # User-approved temporary ceiling: all 32 max to min(original, 3 GHz),
                # snapshot first, restored on every exit (capbuild's apply/restore).
                if a.cpu_cap:return capped_lifecycle(self.preflight,self.apply,self.execute,self.stop_children,self.restore_cpu,self.verify_final)
                return guard.lifecycle(self.preflight,self.execute,self.stop_children,self.verify_final)
            except BaseException as e:
                self.result.update(error_type=type(e).__name__,error=str(e)[:128]);raise
            finally:
                self.result['disk_end']=dict(free=free_bytes(out.parent))
                (a.directory/'guard-result.json').write_text(json.dumps(self.result,indent=2)+'\n');self.stream.close()
    a.cpu=a.references/'reference-thermal/evox2-cpu-limit.py'
    a.guard=a.references/'reference-trial/qwen_trial_guard.py'
    for s in (signal.SIGALRM,signal.SIGTERM,signal.SIGINT):
        signal.signal(s,lambda sig,frame:(_ for _ in ()).throw(RuntimeError('monitor_signal_'+str(sig))))
    os.umask(0o077)
    import fcntl
    fd=os.open('/run/evox2-capbuild.lock',os.O_CREAT|os.O_RDWR|os.O_NOFOLLOW,0o600)
    fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
    Run(a).run()


def verify_output(out):
    """Offline, after a successful run: settings, index and a local hash list."""
    output_settings(json.loads((out/'config.json').read_text()))
    shards=output_index(out)
    files=output_report(out)
    report=dict(status='converted',source_repo=SOURCE['repo'],source_revision=SOURCE['revision'],settings=list(SETTINGS),
                shards=shards,total=sum(f['bytes'] for f in files),files=files)
    (out/'conversion.json').open('x').write(json.dumps(report,indent=2)+'\n')
    return report


def main():
    if len(sys.argv)>1 and sys.argv[1]=='--bootstrap':guard.bootstrap('convert.py');return
    if len(sys.argv)==3 and sys.argv[1]=='--verify-output':
        r=verify_output(Path(sys.argv[2]));print(json.dumps(dict(shards=r['shards'],total=r['total'],files=len(r['files']))));return
    p=argparse.ArgumentParser(description=__doc__)
    for name in ('trial','source','out','work','directory','references','progress','baseline'):p.add_argument('--'+name,type=Path,required=True)
    p.add_argument('--max-seconds',type=int,default=8*3600)
    p.add_argument('--resume',action='store_true',help='continue the work directory from its last checkpoint')
    p.add_argument('--cpu-cap',action='store_true',help='temporary all-CPU max min(original,3GHz) during the run, restored after')
    p.add_argument('--confirm-single-conversion',action='store_true');a=p.parse_args()
    infer.require(all(x.is_absolute() for x in (a.source,a.out,a.work,a.directory)),'absolute_paths')
    infer.require(a.directory.stat().st_mode&0o077==0)
    monitor(a)

if __name__=='__main__':main()
