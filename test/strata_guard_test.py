#!/usr/bin/env python3
"""Offline Strata guard and trial contracts; no model/GPU/service."""
import importlib
import json
from pathlib import Path
import sys
import tempfile
import unittest

D=Path(__file__).resolve().parents[1]/'devbox/apps/llama-server'
sys.path.insert(0,str(D))
g=importlib.import_module('strata_guard')
t=importlib.import_module('strata_trial')
infer=importlib.import_module('kyojin_infer')
S=Path('/opt/strata');SDK=Path('/opt/rocm-7.14.1/install')


class BuildTests(unittest.TestCase):
    def test_build_command_both_targets_fixed_jobs(self):
        cmd=g.build_command(S,4)
        self.assertEqual(cmd[:2],['bash','-c'])
        self.assertIn('-C "$2/build-halo" -j "$3" strata;',cmd[2])
        self.assertIn('-C "$2/build-vision" -j "$3" strata-vision',cmd[2])
        self.assertTrue(cmd[2].startswith('set -euo pipefail; '))
        self.assertEqual(cmd[3:],['strata-build','/opt/strata/.venv/bin/ninja','/opt/strata','4'])
        for bad in (0,9,'4',None):
            with self.assertRaises(ValueError):g.build_command(S,bad)
    def test_ninja_jobs(self):
        self.assertEqual(g.ninja_jobs(['ninja','-C','b','-j','4','strata']),'4')
        self.assertEqual(g.ninja_jobs(['ninja','-j4']),'4')
        self.assertIsNone(g.ninja_jobs(['ninja','-C','b']))     # ninja's default: every core
        g.ninja_ok(['ninja','-j','4'],4)
        for bad in (['ninja'],['ninja','-j','8'],['ninja','-j']):
            with self.assertRaises(ValueError):g.ninja_ok(bad,4)
    def test_build_cooldown_ignores_the_serving_gpu(self):
        # Production keeps serving during the build: only the temperature decides, as long as capbuild's.
        self.assertTrue(g.build_ready(dict(temperature=84.9,gpu_busy_percent=99)))
        self.assertFalse(g.build_ready(dict(temperature=85,gpu_busy_percent=0)))
        self.assertFalse(g.build_ready(dict(temperature=None,gpu_busy_percent=0)))
    def test_wait_ready(self):
        now=[0.0]
        def clock():return now[0]
        def wait(s):now[0]+=s
        rows=iter([dict(temperature=90)]*5+[dict(temperature=60)]*100)
        g.wait_ready(lambda:next(rows),g.build_ready,clock=clock,wait=wait)
        self.assertEqual(now[0],65)      # 60 s in a row once cool
        now[0]=0.0;rows=iter([dict(temperature=90)]*400)
        with self.assertRaises(ValueError):g.wait_ready(lambda:next(rows),g.build_ready,clock=clock,wait=wait)
    def test_env_is_only_the_isolated_sdk(self):
        env=g.sdk_env(S,SDK,'/home/u','C.UTF-8')
        self.assertEqual(set(env),{'HOME','PATH','ROCM_PATH','HIP_PATH','HIP_PLATFORM','LD_LIBRARY_PATH','CCACHE_DISABLE','TMPDIR','LANG'})
        self.assertTrue(env['PATH'].startswith('/opt/strata/.venv/bin:/opt/rocm-7.14.1/install/bin:/opt/rocm-7.14.1/install/lib/llvm/bin:'))
        self.assertNotIn('/opt/rocm/',env['PATH']+env['LD_LIBRARY_PATH'])
        self.assertEqual(env['LD_LIBRARY_PATH'].split(':')[0],'/opt/rocm-7.14.1/install/lib')
        self.assertNotIn('LANG',g.sdk_env(S,SDK,'/home/u'))
    def test_serve_env_table_and_no_opt_in_switches(self):
        env=g.serve_env(S,SDK,'/home/u')
        self.assertEqual(env['STRATA_HIPBLASLT_TUNING'],'/opt/strata/tools/hip/gfx1151-hipblaslt-100401.txt')
        # docs/STRIX_HALO.md section 5: these change the output bits and stay off.
        for k in ('STRATA_PF_FUSED','STRATA_PF_GEMM','STRATA_HC_UPMIX','STRATA_PA_FAST','STRATA_HIP_WMMA','STRATA_SELECT_WMMA','STRATA_IGPU_PROMPT_SET','STRATA_PF_F16'):
            self.assertNotIn(k,env)
        self.assertEqual({k for k in env if k.startswith('STRATA_')},{'STRATA_HIPBLASLT_TUNING','STRATA_GGUF_PY'})


class ServeTests(unittest.TestCase):
    def config(self,**kw):
        args=dict(strata=S,pack=Path('/p'),gguf=Path('/m.gguf'),mtp=Path('/mtp/rt'),ctx=262144,expert_cache=8192,log=Path('/l.log'))
        args.update(kw);return g.server_config(**args)
    def test_server_config(self):
        cfg=self.config()
        a=cfg['args']
        self.assertEqual(a[a.index('--native')+1],'/m.gguf');self.assertEqual(a[a.index('--ple-gguf')+1],'/m.gguf')
        self.assertEqual(a[a.index('--max-context')+1],'262144');self.assertEqual(a[a.index('--expert-cache')+1],'8192')
        self.assertEqual(a[a.index('--kv')+1],'int8');self.assertEqual(a[a.index('--mtp')+1],'/mtp/rt')
        self.assertEqual(cfg['tokenizer'],'/p/tokenizer');self.assertEqual(cfg['model_name'],'qwen3.8-flash-next')
        self.assertEqual((cfg['host'],cfg['port']),('127.0.0.1',18083))
        self.assertNotIn('vision',cfg)
        self.assertEqual(g.cfg_ctx(cfg),262144)
    def test_server_config_vision(self):
        cfg=self.config(mmproj=Path('/mm.gguf'))
        self.assertEqual(cfg['vision'],dict(exe='/opt/strata/build-vision/bin/strata-vision',mmproj='/mm.gguf',model='/m.gguf',gpu=False,threads=8))
    def test_server_config_pool_workers(self):
        self.assertNotIn('--pool-workers',self.config()['args'])
        a=self.config(pool_workers=8)['args'];self.assertEqual(a[a.index('--pool-workers')+1],'8')
        for bad in (0,16,'8'):
            with self.assertRaises(ValueError):self.config(pool_workers=bad)
    def test_server_config_strix_profile(self):
        cfg=self.config(profile='strix',expert_cache=24576)
        a=cfg['args']
        # Every expert in the GPU's cache, read from the GGUF through the file cache: no RAM arena, no CPU experts.
        self.assertIn('--mmap-experts',a);self.assertEqual(a[a.index('--expert-cache')+1],'24576')
        for flag,value in (('--prefill','16384'),('--lookup-chain','3'),('--mtp-q4','all'),('--mtp-window','8192'),('--spec','4'),('--kv','int8')):
            self.assertEqual(a[a.index(flag)+1],value)
        self.assertEqual(a.count('--prefill'),1)
        env=cfg['env']
        for k in ('STRATA_PF_FUSED','STRATA_IGPU_PROMPT_SET','STRATA_PF_F16','STRATA_SH_STREAM','STRATA_REFILL_PARTS'):self.assertEqual(env[k],'1')
        self.assertEqual((env['STRATA_PF_SWITCH_MIN_T'],env['STRATA_PREFILL_STREAM_MIN']),('4096','128'))
        self.assertNotIn('env',self.config())
        with self.assertRaises(ValueError):self.config(profile='other')
    def test_serve_env_takes_the_config_switches(self):
        env=g.serve_env(S,SDK,'/home/u',extra={'STRATA_PF_FUSED':'1'})
        self.assertEqual(env['STRATA_PF_FUSED'],'1')
        with self.assertRaises(ValueError):g.serve_env(S,SDK,'/home/u',extra={'LD_PRELOAD':'x'})
    def test_server_config_limits(self):
        for kw in (dict(ctx=65536),dict(expert_cache=255),dict(expert_cache=24577),dict(expert_cache='auto')):
            with self.assertRaises(ValueError):self.config(**kw)
    def test_loaded(self):
        self.assertTrue(g.loaded({'status':'ok','loaded':True}))
        # /health answers ok before the engine is up.
        self.assertFalse(g.loaded({'status':'ok','loaded':False}))
        self.assertFalse(g.loaded({'status':'loading','loaded':True}))
    def test_run_root(self):
        with tempfile.TemporaryDirectory() as d:
            d=Path(d);(d/'b.json').write_text('{"id": "x"}\n')
            g.run_root(d/'root',d/'b.json')
            self.assertEqual(json.loads((d/'root/private/baseline.json').read_text()),{'id':'x'})
            self.assertEqual(json.loads((d/'root/private/binary-library-hashes.json').read_text()),[])
    def test_checkout_ok(self):
        answers={('rev-parse','/opt/strata'):g.STRATA_COMMIT,('rev-parse','/opt/strata/third_party/llama.cpp'):g.LLAMA_COMMIT}
        def output(cmd,dirty=''):
            return answers[(cmd[3],cmd[2])] if cmd[3]=='rev-parse' else dirty
        g.checkout_ok(output,S)
        with self.assertRaises(ValueError):g.checkout_ok(lambda c:'0'*40 if c[3]=='rev-parse' else '',S)
        with self.assertRaises(ValueError):g.checkout_ok(lambda c:output(c,' M src/x.cpp'),S)


class TrialTests(unittest.TestCase):
    def test_repetition(self):
        self.assertEqual(t.repetition('答えは '+'24 '*12)['unit'].strip(),'24')
        self.assertIsNone(t.repetition('|---|---|---|\n| 1 | 2 | 3 |\n'))
        self.assertIsNone(t.repetition('1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12'))
        self.assertIsNone(t.repetition('-'*20+'\n'+' '*80))
        self.assertEqual(t.repetition('x'+'!'*40)['unit'],'!')
        self.assertEqual(t.repetition('はいはいはいはいはいはいはいはいはいはい')['unit'],'はい')
        self.assertIsNone(t.repetition('ありがとうございます。'*3))
    def test_speed(self):
        s=t.speed(0,2*10**9,12*10**9,dict(prompt_tokens=8000,completion_tokens=501))
        self.assertEqual(s['ttft_s'],2);self.assertEqual(s['prefill_tps'],4000);self.assertEqual(s['decode_tps'],50)
        self.assertIsNone(t.speed(0,None,None,dict(prompt_tokens=1,completion_tokens=1)))
        self.assertIsNone(t.speed(0,1,2,None))
        self.assertIsNone(t.speed(0,10**9,10**9,dict(prompt_tokens=10,completion_tokens=1))['decode_tps'])
    def test_sse_times(self):
        ev=[(1,json.dumps(dict(choices=[dict(delta=dict(role='assistant'))]))),(2,json.dumps(dict(choices=[dict(delta=dict(reasoning_content='a'))]))),
            (5,json.dumps(dict(choices=[dict(delta=dict(content='b'))]))),(6,json.dumps(dict(choices=[],usage={}))),(7,'[DONE]')]
        self.assertEqual(t.sse_times(ev),(2,5))
    def test_lines_for(self):
        # 256 lines took 8,040 tokens with 40 fixed: 31.25 per line.
        n=t.lines_for(128000,256,8040,40)
        self.assertEqual(n%2,0);self.assertLessEqual(n*31.25+40,128000*0.98)
        with self.assertRaises(ValueError):t.lines_for(1000,256,40,40)
    def test_budget(self):
        b=t.Budget(2);b.reserve();b.reserve()
        with self.assertRaises(ValueError):b.reserve()
    def test_base_thinking_form(self):
        r=t.base('x');self.assertEqual(r['chat_template_kwargs'],{'enable_thinking':False});self.assertNotIn('reasoning_effort',r)
        r=t.base('x',True,1024);self.assertEqual((r['reasoning_effort'],r['max_tokens']),('low',1024))
    def test_trial_fits_the_request_budget(self):
        class Fake:
            def __init__(self):self.n=0;self.ctx=262144;self.d=Path(self.tmp)
            def bind(self,refs):
                self.smoke=type('S',(),{'request':staticmethod(lambda case:dict(t.base('q'),tools=[] if case=='tool' else None))})
                self.corpus=dict(tool_heavy=dict(tools=[],user_turns=['a','b','c'],synthetic_results=[{},{}]),
                                 vision=dict(questions=['a','b'],base64=''),tasks=dict(prose=dict(prompt='p')),
                                 long_input_contract=dict(nominal_tiers={'8K':256},needle_start='',needle_middle='',needle_end='',filler_line='f'))
                return self
            def get(self,path):return 200,{'images':True,'data':[]}
            def record(self,row):pass
            def post(self,name,req):self.n+=1;return 200,{},{}
            def send(self,name,req,case=None,tool=None,prompt_estimate=0):
                self.n+=1
                msg=dict(content='',tool_calls=[dict(id='c',type='function',function=dict(name='lookup_stock',arguments='{}'))])
                return dict(choices=[dict(message=msg,finish_reason='tool_calls')]),dict(name=name,usage=dict(prompt_tokens=8040),quality=dict(status='pass'))
        with tempfile.TemporaryDirectory() as d:
            Fake.tmp=d;f=Fake();t.suite_trial(f,None)
        self.assertLessEqual(f.n,100);self.assertGreaterEqual(f.n,60)
    def test_cold_prompts_differ_at_the_start(self):
        # Strata's conversation cache reuses a shared prefix: a cold repeat must differ from the first token.
        lc=dict(needle_start='A',needle_middle='B',needle_end='C',filler_line='f')
        a,b=t.cold_text(lc,'p',4,0),t.cold_text(lc,'p',4,1)
        self.assertNotEqual(a[:8],b[:8]);self.assertTrue(a.endswith('Ap'[1:]) and 'A' in a and a.index('A')<a.index('B')<a.index('C'))
    def test_perf_suite(self):
        sent=[]
        class Fake:
            ctx=262144
            def __init__(self):self.d=Path(self.tmp)
            def bind(self,refs):
                self.smoke=type('S',(),{'request':staticmethod(lambda case:t.base('q'))})
                self.corpus=dict(tasks=dict(prose=dict(prompt='p')),long_input_contract=dict(nominal_tiers={'8K':256},needle_start='A',needle_middle='B',needle_end='C',filler_line='f'))
                return self
            def get(self,path):return 200,{}
            def send(self,name,req,case=None,tool=None,prompt_estimate=0):
                sent.append((name,req['messages'][0]['content'],req['max_tokens'],prompt_estimate))
                return {},dict(name=name,usage=dict(prompt_tokens=8040),quality=dict(status='pass'))
        with tempfile.TemporaryDirectory() as d:
            Fake.tmp=d;t.suite_perf(Fake(),None,extras=False)
        names=[s[0] for s in sent]
        self.assertEqual([n for n in names if n.startswith('128K')],['128K-prose-cold-0','128K-prose-cold-1','128K-prose-cold-2','128K-prose-warm-0'])
        cold=[s for s in sent if s[0].startswith('128K-prose-cold')];warm=[s for s in sent if s[0]=='128K-prose-warm-0'][0]
        self.assertEqual(warm[1],cold[-1][1])                     # the warm one repeats the last cold prompt
        self.assertEqual(len({s[1][:8] for s in cold}),3)
        self.assertTrue(all(s[2]==768 and s[3]==127000 for s in cold))
        self.assertEqual(sum(n.startswith('8K') for n in names),2);self.assertEqual(sum(n.startswith('32K') for n in names),2)
        self.assertLessEqual(len(sent),60)
    def test_long_outputs(self):
        self.assertTrue(all(1024<=n<=2048 for _,_,n,_ in t.LONG_OUTPUTS))


class ClientTests(unittest.TestCase):
    """The streamed and plain requests against a local fake server (no model)."""
    def setUp(self):
        import http.server,threading
        bodies=self.bodies=[]
        class H(http.server.BaseHTTPRequestHandler):
            def log_message(self,*a):pass
            def do_POST(self):
                req=json.loads(self.rfile.read(int(self.headers['Content-Length'])));bodies.append(req)
                if not req.get('stream'):
                    data=json.dumps(dict(choices=[dict(message=dict(role='assistant',content='{}'),finish_reason='stop')])).encode()
                    self.send_response(400 if req.get('tool_choice')=='required' else 200);self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data);return
                self.send_response(200);self.send_header('Content-Type','text/event-stream');self.end_headers()
                for d in (dict(role='assistant'),dict(content='24 '*12),dict(content='。')):
                    self.wfile.write(b'data: '+json.dumps(dict(choices=[dict(index=0,delta=d)])).encode()+b'\n\n');self.wfile.flush()
                self.wfile.write(b'data: '+json.dumps(dict(choices=[dict(index=0,delta={},finish_reason='stop')])).encode()+b'\n\n')
                self.wfile.write(b'data: '+json.dumps(dict(choices=[],usage=dict(prompt_tokens=20,completion_tokens=13))).encode()+b'\n\ndata: [DONE]\n\n')
        self.server=http.server.ThreadingHTTPServer(('127.0.0.1',0),H)
        threading.Thread(target=self.server.serve_forever,daemon=True).start()
        self.tmp=tempfile.TemporaryDirectory();self.d=Path(self.tmp.name)
        self.c=t.Client(self.d,t.Budget(3),'127.0.0.1',self.server.server_address[1],32768)
    def tearDown(self):
        self.server.shutdown();self.server.server_close();self.tmp.cleanup()
    def test_stream(self):
        reply,row=self.c.send('a',t.base('q'))
        self.assertEqual(self.bodies[0]['stream_options'],{'include_usage':True})
        self.assertEqual(reply['choices'][0]['message']['content'],'24 '*12+'。')
        self.assertEqual(row['finish'],'stop');self.assertTrue(row['usage_in_stream'])
        self.assertEqual(row['repetition']['unit'].strip(),'24');self.assertIsNotNone(row['speed']['ttft_s'])
        self.assertFalse(row['thinking_requested'])
        self.assertTrue((self.d/'a.sse').is_file() and (self.d/'results.jsonl').is_file())
    def test_post_records_status(self):
        status,_,row=self.c.post('p',dict(t.base('q'),tool_choice='required'))
        self.assertEqual((status,row['status']),(400,400));self.assertFalse(self.bodies[0]['stream'])
    def test_budget_and_context(self):
        with self.assertRaises(ValueError):self.c.send('big',t.base('q',max_tokens=2048),prompt_estimate=31000)
        self.c.send('a',t.base('q'));self.c.send('b',t.base('q'));self.c.send('c',t.base('q'))
        with self.assertRaises(ValueError):self.c.send('d',t.base('q'))
        with self.assertRaises(ValueError):t.Client(self.d,t.Budget(9),'127.0.0.1',1,32768).send('a',t.base('q'))  # never resent


if __name__=='__main__':unittest.main()
