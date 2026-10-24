# Recovery only: no CPU writes, build, lifecycle or supervisor restart.
import hashlib,json,os,pathlib,subprocess,time,types,urllib.request
B=pathlib.Path('/home/yuanying/.local/state/herdr-tasks/evo-x2-qwen38-optimization')
D=B/'artifacts/capbuild-finish-restoration-20261023'; os.umask(0o077)
p=B/'worktrees/evo-x2-qwen38-optimization-capbuild/bin/evox2-capbuild.py'
data=p.read_bytes();assert hashlib.sha256(data).hexdigest()=='9e3c3ec14f86f0111053162f0442e0b5ba6bbfd6975c9ac155f755e7784f4bc5'
m=types.ModuleType('reference');exec(compile(data,str(p),'exec'),m.__dict__)
c=m.pinned(B/'notes/reference-thermal/evox2-cpu-limit.py',m.CPU_SHA)
g=m.pinned(B/'notes/reference-trial/qwen_trial_guard.py',m.GUARD_SHA)
s=m.pinned(B/'notes/reference-config/smoke.py',m.SMOKE_SHA)
before=c.load(B/'artifacts/cpuload-once-20261022/cpu.json')['before']
initial=g.sample();gate=g.Gate(initial['swap']);inventory,skips=m.sensors(pathlib.Path('/sys/class/hwmon'))
result={'mode':'restoration_only','initial':initial,'sensor_inventory':inventory,'skips':skips,'build_spawned':False,'cpu_writes':0}
stream=(D/'telemetry.jsonl').open('x')
def state():
 v=m.output(['docker','inspect','--format','{{.Id}} {{.Image}} {{.State.Status}} {{.State.OOMKilled}} {{.RestartCount}}',m.CID]).split()
 assert v[:2]==[m.CID,m.IMAGE] and v[3]=='false'; return v
kernel=m.output(['dmesg','--level=err,crit,alert,emerg'])
oom=next(x for x in pathlib.Path('/proc/vmstat').read_text().splitlines() if x.startswith('oom_kill '))
def observe(stage,idle=False):
 row=g.sample();c.equivalent(c.Host().read(),before);m.sensors(pathlib.Path('/sys/class/hwmon'),inventory)
 row['stage']=stage
 row['cpu_tctl_c']=int(pathlib.Path('/sys/class/hwmon/hwmon3/temp1_input').read_text())/1000
 row['gpu_c']=int(pathlib.Path('/sys/class/hwmon/hwmon5/temp1_input').read_text())/1000
 stream.write(json.dumps(row)+'\n');stream.flush()
 assert gate.check(row['available'],row['swap'],row['temperature'],row['monotonic'],row['critical']) is None
 assert row['memory.events']==initial['memory.events']
 assert not (set(m.output(['dmesg','--level=err,crit,alert,emerg']).splitlines())-set(kernel.splitlines()))
 assert next(x for x in pathlib.Path('/proc/vmstat').read_text().splitlines() if x.startswith('oom_kill '))==oom
 if idle: assert row['temperature']<85 and row['gpu_busy_percent']==0 and row['available']>=100*1024**3
 return row
try:
 # Already-started retained baseline: no additional service operation.
 assert state()[2]=='running'
 result['prior_recovery_cooldown_seconds']=60.07550851581618
 result['kernel_precheck']='zero current error lines; zero recent GPU/OOM/thermal fault lines'
 result['oom_kill_initial']=oom
 end=time.monotonic()+300;ready=0
 while time.monotonic()<end:
  observe('starting')
  try:m.health();ready+=1
  except (OSError,ValueError,RuntimeError):ready=0
  if ready>=5:break
  time.sleep(1)
 assert ready>=5 and state()[2]=='running'
 # Invoke only read-only hash verification from the reviewed runner, not Run/run/lifecycle.
 private=B/'artifacts/kyojin-trial/private'
 h=types.SimpleNamespace(old_hashes=json.loads((private/'binary-library-hashes.json').read_text()),
   entry_hash=hashlib.sha256((private/'entrypoint.sh').read_bytes()).hexdigest(),
   compose_hash=hashlib.sha256((B/'artifacts/capbuild-resume-once-20261023/compose.anietta.yaml').read_bytes()).hexdigest(),d=D)
 m.Run.hashes(h)
 restarts=state()[4];results=[]
 for case in s.CASES:
  req=D/(case+'-request.json');reply=D/(case+'-response.json');req.write_text(json.dumps(s.request(case)))
  code='import pathlib,sys,urllib.request; o=urllib.request.build_opener(urllib.request.ProxyHandler({})); r=urllib.request.Request("http://llama-server:8082/v1/chat/completions",data=pathlib.Path(sys.argv[1]).read_bytes(),headers={"Content-Type":"application/json"}); b=o.open(r,timeout=180).read(4194305); assert len(b)<=4194304; pathlib.Path(sys.argv[2]).write_bytes(b)'
  child=subprocess.Popen(['python3','-c',code,str(req),str(reply)]);start=time.monotonic()
  try:
   while child.poll() is None:
    observe('smoke_'+case);m.health();assert time.monotonic()-start<180;time.sleep(1)
   assert child.returncode==0
  finally:
   if child.poll() is None:child.terminate();child.wait(timeout=5)
  r=s.validate(case,json.loads(reply.read_text()));r['wall_seconds']=time.monotonic()-start;results.append(r)
  print(json.dumps(r),flush=True)
 result['smoke']=results
 start=time.monotonic()
 while True:
  observe('final_hold');m.health();assert state()[4]==restarts
  if time.monotonic()-start>=60:break
  time.sleep(1)
 m.Run.hashes(h);c.equivalent(c.Host().read(),before)
 result.update(restored=True,final_state=state(),final=g.sample(),all_cpu_fields_original=True,hashes_unchanged=True)
except BaseException as error:
 result.update(error_type=type(error).__name__,error=str(error));raise
finally:
 (D/'result.json').write_text(json.dumps(result,indent=2));stream.close();print(json.dumps(result),flush=True)
