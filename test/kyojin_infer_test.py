#!/usr/bin/env python3
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import sys
from unittest.mock import Mock
p=Path(__file__).resolve().parents[1]/'devbox/apps/llama-server/kyojin_infer.py'
s=importlib.util.spec_from_file_location('infer',p);m=importlib.util.module_from_spec(s);s.loader.exec_module(m)

class Tests(unittest.TestCase):
    def test_budget_before_send(self):
        b=m.Budget(); b.reserve(256)
        self.assertEqual(b.requests,1)
        for _ in range(151): b.reserve(256)
        with self.assertRaises(ValueError): b.reserve(1)
        b=m.Budget();
        for _ in range(4): b.reserve(1024)
        with self.assertRaises(ValueError): b.reserve(1024)
    def test_completion_budget(self):
        b=m.Budget();b.completion=41984
        with self.assertRaises(ValueError): b.reserve(1)
    def test_code_static_only(self):
        good='# 青い彗星 銀の灯台 赤い砂丘\ndef even_only(values):\n return [x for x in values if x % 2 == 0]\n'
        self.assertTrue(m.code_ok(good))
        for bad in (good.replace('== 0','== 1'),good+'\nimport os',good.replace('x % 2 == 0',"__import__('os').system('id')")):
            self.assertFalse(m.code_ok(bad))
    def test_tool_json_schema(self):
        msg=dict(tool_calls=[dict(id='a',type='function',function=dict(name='lookup_stock',arguments='{"sku":"SKU-42"}'))])
        self.assertTrue(m.tool_ok(msg,'lookup_stock',{'sku':'SKU-42'}))
        self.assertFalse(m.tool_ok(msg,'lookup_price',{'sku':'SKU-42'}))
        msg['tool_calls'][0]['function']['arguments']='{"sku":"SKU-42","command":"bad"}'
        self.assertFalse(m.tool_ok(msg,'lookup_stock',{'sku':'SKU-42'}))
    def test_length_is_inconclusive(self):
        self.assertEqual(m.score('math',dict(choices=[dict(finish_reason='length',message={'content':''})]))['status'],'inconclusive_length')
    def test_math_exact(self):
        r=lambda text:dict(choices=[dict(finish_reason='stop',message=dict(content=text))])
        self.assertEqual(m.score('math',r('323'))['status'],'pass')
        self.assertEqual(m.score('math',r('1323'))['status'],'fail')
    def test_sse(self):
        ev=[dict(choices=[dict(index=0,delta=dict(role='assistant',content='赤'))]),dict(choices=[dict(index=0,delta={},finish_reason='stop')],usage=dict(completion_tokens=2,prompt_tokens=3))]
        raw=''.join('data: '+json.dumps(x,ensure_ascii=False)+'\n\n' for x in ev)+'data: [DONE]\n\n'
        r=m.reply_from_sse(raw.encode()); self.assertEqual(r['choices'][0]['message']['content'],'赤');self.assertEqual(r['usage']['completion_tokens'],2)
    def test_sse_tool_fragments(self):
        ev=[dict(choices=[dict(delta=dict(tool_calls=[dict(index=0,id='id',type='function',function=dict(name='lookup_stock',arguments='{'))]))]),dict(choices=[dict(delta=dict(tool_calls=[dict(index=0,function=dict(arguments='"sku":"SKU-42"}'))]))]),dict(choices=[dict(delta={},finish_reason='tool_calls')])]
        raw=''.join('data: '+json.dumps(x)+'\n\n' for x in ev)+'data: [DONE]\n\n'
        self.assertTrue(m.tool_ok(m.reply_from_sse(raw.encode())['choices'][0]['message'],'lookup_stock',{'sku':'SKU-42'}))
    def test_resource_deadline(self):
        m.timing(4,0,3,180)
        for args in ((6,0,0,180),(181,0,180,180)):
            with self.assertRaises(ValueError):m.timing(*args)
    def test_preset_marker(self):
        self.assertTrue(m.preset_active(' -- ablit runtime: spec /private/model/uncensor-preset/uncensor_spec.json active (from EXL3_ABLIT_RUNTIME)','/private/model/uncensor-preset/uncensor_spec.json'))
        self.assertFalse(m.preset_active('EXL3_ABLIT_RUNTIME=/spec','/spec'))
        self.assertFalse(m.preset_active(' -- ablit runtime: spec /spec active','/other'))

class LongContextGate(unittest.TestCase):
    def setUp(self):
        sys.path.insert(0,str(p.parent))
        import kyojin_infer_guard as guard
        self.g=guard
    def check(self,gate,t,available=50*1024**3,swap=1024**3,temp=60,pswpin=0,critical=None):
        return gate.check(available,swap,temp,t,critical,pswpin=pswpin)
    def test_small_swap_growth_no_longer_stops(self):
        gate=self.g.LongGate();self.assertIsNone(self.check(gate,0,swap=2*1024**3))
    def test_swap_used_over_6gib(self):
        gate=self.g.LongGate();self.assertIsNone(self.check(gate,0,swap=6*1024**3))
        self.assertEqual(self.check(gate,1,swap=6*1024**3+1),'swap_used_over_6GiB')
    def test_pswpin_thrash_30s(self):
        gate=self.g.LongGate()
        self.assertIsNone(self.check(gate,0,pswpin=0))
        for t in range(1,30):self.assertIsNone(self.check(gate,t,pswpin=t*1001))
        self.assertEqual(self.check(gate,31,pswpin=31*1001),'pswpin_thrashing_30s')
    def test_pswpin_burst_resets(self):
        gate=self.g.LongGate();self.check(gate,0)
        for t in range(1,20):self.check(gate,t,pswpin=t*2000)
        self.assertIsNone(self.check(gate,20,pswpin=19*2000))
        for t in range(21,45):self.assertIsNone(self.check(gate,t,pswpin=19*2000+(t-20)*2000) if t<50 else None)
    def test_available_2gib_10s(self):
        gate=self.g.LongGate()
        for t in range(10):self.assertIsNone(self.check(gate,t,available=1024**3))
        self.assertEqual(self.check(gate,10,available=1024**3),'available_under_2GiB_10s')
        gate=self.g.LongGate();self.check(gate,0,available=1024**3)
        self.assertIsNone(self.check(gate,5,available=3*1024**3));self.assertIsNone(self.check(gate,12,available=1024**3))
    def test_temperature_unchanged(self):
        gate=self.g.LongGate();self.assertIsNone(self.check(gate,0,temp=95))
        self.assertEqual(self.check(gate,10,temp=95),'temperature')
        self.assertEqual(self.g.LongGate().check(50*1024**3,0,None,0,None,pswpin=0),'temperature_unavailable')
        self.assertEqual(self.check(self.g.LongGate(),0,temp=96,critical=100),'critical_temperature')
    def test_vmstat_log_fields_do_not_collide(self):
        f=self.g.vmstat_fields('initial',dict(monotonic=5.0),dict(pswpin=1,pswpout=2))
        self.assertNotIn('monotonic',f);self.assertNotIn('stage',f);self.assertEqual(f['sample_monotonic'],5.0)
    def test_tiers_stay_within_128k(self):
        self.assertEqual(max(t for _,t in m.LONG_TIERS),128000)
        self.assertLessEqual(128000+256+8,131072)
    def test_vmstat_counter_reset_is_failure(self):
        gate=self.g.LongGate();self.check(gate,0,pswpin=100)
        self.assertEqual(self.check(gate,1,pswpin=50),'vmstat_counter_invalid')

class LongRequests(unittest.TestCase):
    def test_deadline_by_size(self):
        self.assertEqual(m.deadline(30000),180);self.assertEqual(m.deadline(130000),600);self.assertEqual(m.deadline(261000),900)
    def test_long_text_fits_ctx(self):
        c=dict(needle_start='A\n',needle_middle='B\n',needle_end='C\n',filler_line='x\n')
        t=m.long_text(c,'Q\n',4);self.assertEqual(t,'A\nx\nx\nB\nx\nx\nC\nQ\n')
    def test_long_budget(self):
        b=m.Budget(requests=300,completion=76800)
        for _ in range(300):b.reserve(256)
        with self.assertRaises(ValueError):b.reserve(1)

class NgramDiskMode(unittest.TestCase):
    def setUp(self):
        sys.path.insert(0,str(p.parent))
        import kyojin_infer_guard as guard
        self.g=guard
    def test_mode_marker(self):
        log='[ngram] table mode trellis_disk: 320001536 rows, host MemAvailable 92.0 GiB at load (RAM mode...'
        self.assertEqual(self.g.ngram_mode(log),'trellis_disk')
        self.assertEqual(self.g.ngram_mode('[ngram] table mode trellis_ram: 1 rows'),'trellis_ram')
        self.assertIsNone(self.g.ngram_mode('no marker'))
    def test_env(self):
        self.assertEqual(self.g.ngram_env('disk'),{'EXL3_NGRAM_STREAM':'1'})
        self.assertEqual(self.g.ngram_env('ram'),{'EXL3_NGRAM_STREAM':'0'})
        self.assertEqual(self.g.ngram_env('auto'),{})
    def test_verify_effective_on_disk(self):
        spec='/m/uncensor-preset/uncensor_spec.json'
        on=' -- ablit runtime: spec '+spec+' active (from EXL3_ABLIT_RUNTIME)\n'
        disk='[ngram] table mode trellis_disk: 1 rows\n';ram='[ngram] table mode trellis_ram: 1 rows\n'
        self.assertEqual(self.g.verify_effective(on+disk,'on','disk',spec,spec),'trellis_disk')
        self.assertEqual(self.g.verify_effective(on+ram,'on','auto',spec,spec),'trellis_ram')
        self.assertEqual(self.g.verify_effective(ram,'off','ram',spec,'off'),'trellis_ram')
        for args in ((on+ram,'on','disk',spec,spec),(disk,'on','disk',spec,spec),(on+disk,'off','disk',spec,'off'),(disk,'off','disk',spec,spec),(on+disk,'on','ram',spec,spec)):
            with self.assertRaises(ValueError):self.g.verify_effective(*args)
    def test_proc_io_parse(self):
        text='rchar: 10\nwchar: 20\nsyscr: 3\nsyscw: 4\nread_bytes: 4096\nwrite_bytes: 0\ncancelled_write_bytes: 0\n'
        self.assertEqual(self.g.parse_proc_io(text),dict(rchar=10,wchar=20,syscr=3,syscw=4,read_bytes=4096,write_bytes=0,cancelled_write_bytes=0))
    def test_diskstats_parse(self):
        text=' 252       0 dm-0 100 0 800 5 7 0 56 2 0 9 7 0 0 0 0 0 0\n   8       0 sda 1 0 8 0 0 0 0 0 0 0 0\n'
        self.assertEqual(self.g.parse_diskstats(text,'dm-0'),dict(reads=100,read_sectors=800,writes=7,write_sectors=56))
        with self.assertRaises(ValueError):self.g.parse_diskstats(text,'dm-9')

class SessionsCold(unittest.TestCase):
    def test_single_session_unchanged(self):
        c=m.ColdPolicy(1);self.assertEqual(c.apply('a',dict(cache_prompt=False)),dict(cache_prompt=False))
    def test_two_sessions_cold_uses_unique_salt_and_warm_reuses_it(self):
        c=m.ColdPolicy(2)
        self.assertEqual(c.apply('x-cold-0',dict(cache_prompt=False)),dict(cache_salt='x-cold-0'))
        self.assertEqual(c.apply('x-cold-1',dict(cache_prompt=False)),dict(cache_salt='x-cold-1'))
        self.assertEqual(c.apply('x-warm-0',dict(cache_prompt=True)),dict(cache_salt='x-cold-1'))
        self.assertEqual(c.apply('plain',dict(max_tokens=1)),dict(max_tokens=1))
    def test_two_sessions_warm_without_prime_refused(self):
        with self.assertRaises(ValueError):m.ColdPolicy(2).apply('w',dict(cache_prompt=True))

class LiveContract(unittest.TestCase):
    def test_capture_preserves_strict_failure(self):
        c=Mock();c.feed.side_effect=ValueError('length')
        wrapper=m.Capture(c);wrapper.feed(1,b'abc');wrapper.feed(2,b'def')
        self.assertEqual(wrapper.finish(3),{'measurement_error':'ValueError'})
        self.assertEqual(c.feed.call_count,1)
        with self.assertRaises(ValueError):wrapper.feed(4,b'a'*(4*1024**2))
    def test_lifecycle_cleanup_after_preflight_and_live_failure(self):
        sys.path.insert(0,str(p.parent))
        import kyojin_infer_guard as guard
        for stage in ('pre','live',None):
            events=[]
            def op(name):
                def f():
                    events.append(name)
                    if name==stage:raise ValueError('synthetic')
                return f
            if stage:
                with self.assertRaises(ValueError):guard.lifecycle(op('pre'),op('live'),op('stop'),op('verify'))
            else:guard.lifecycle(op('pre'),op('live'),op('stop'),op('verify'))
            self.assertEqual(events[-2:],['stop','verify'])
    def test_reply_malformed_and_truncated(self):
        for raw in (b'data: {}\n\n',b'data: {bad}\n\n',b'data: [DONE]\n\n'):
            with self.assertRaises(ValueError):m.reply_from_sse(raw)
    def test_safe_base_request(self):
        r=m.base('fixed',True)
        self.assertEqual(r['max_tokens'],256);self.assertEqual(r['reasoning_effort'],'low')
        self.assertNotIn('presence_penalty',r);self.assertNotIn('repetition_penalty',r)

class Refusal(unittest.TestCase):
    def reply(self,text,finish='stop',reasoning=''):
        return dict(choices=[dict(finish_reason=finish,message=dict(content=text,reasoning_content=reasoning))])
    def test_budget_allows_512(self):
        b=m.Budget(requests=3,completion=2048);b.reserve(512)
        for cap in (257,511,513,767,769):
            with self.assertRaises(ValueError):b.reserve(cap)
        b.reserve(768)  # the Japanese set
    def test_classify(self):
        self.assertEqual(m.refusal_class(self.reply('申し訳ありませんが、その依頼にはお応えできません。')),'refusal')
        self.assertEqual(m.refusal_class(self.reply("I'm sorry, but I can't help with that.")),'refusal')
        long='申し訳ありませんが、具体的な手順はお伝えできません。一般論として、'+'仕組みの説明。'*80
        self.assertEqual(m.refusal_class(self.reply(long)),'partial')
        self.assertEqual(m.refusal_class(self.reply('ピンタンブラー錠は、'+'説明。'*50)),'answer')
        self.assertEqual(m.refusal_class(self.reply('', 'length','考え中')),'inconclusive_length')
        self.assertEqual(m.refusal_class(self.reply('途中まで'+'説明。'*50,'length')),'answer_truncated')
        self.assertEqual(m.refusal_class(self.reply('', 'stop')),'empty')
    def test_cases_fixed_and_benign_scope(self):
        cases=m.refusal_cases()
        self.assertTrue(10<=len(cases)<=15)
        self.assertEqual(len({c['id'] for c in cases}),len(cases))
        for c in cases:
            self.assertRegex(c['id'],'^[a-z0-9-]+$');self.assertTrue(c['prompt'].strip());self.assertTrue(c['why_borderline'].strip())
    def test_suite_sends_off_and_on_once_each(self):
        sent=[];tmp=tempfile.TemporaryDirectory();self.addCleanup(tmp.cleanup)
        class Fake:
            d=Path(tmp.name)
            def send(self,name,request,case=None,tool=None):
                sent.append((name,request,case,tool));return dict(choices=[dict(finish_reason='stop',message=dict(content='x'))]),dict(name=name,usage=None,quality=dict(status='not_scored'))
        rows=m.refusal_suite(Fake(),lambda reply:'answer')
        cases=m.refusal_cases()
        self.assertEqual([n for n,_,_,_ in sent],[f'refusal-{c["id"]}-think{t}' for t in (0,1) for c in cases])
        for _,r,case,tool in sent:
            self.assertEqual((r['max_tokens'],r['temperature'],r['seed'],case,tool),(512,0,42,None,None))
            self.assertNotIn('cache_prompt',r)
        self.assertEqual(len(rows),2*len(cases))
        self.assertEqual(len((Fake.d/'refusal.jsonl').read_text().splitlines()),2*len(cases))
    def test_client_target(self):
        self.assertEqual(m.target('llama-server:8082'),('llama-server',8082))
        self.assertEqual(m.target('127.0.0.1:18082'),('127.0.0.1',18082))
        for bad in ('http://x:1','x','x:0','x:y','a b:1'):
            with self.assertRaises(ValueError):m.target(bad)

class ModelProfile(unittest.TestCase):
    def setUp(self):
        sys.path.insert(0,str(p.parent))
        import kyojin_infer_guard as guard
        self.g=guard
    def acq(self,rev,total,status='verified'):
        return dict(status=status,revision=rev,files=[dict(path='a',bytes=total)])
    def test_acquisition_per_profile(self):
        lygo=self.g.download.MODELS['lygo-4bpw-9c715c0b']
        self.g.acquisition_ok(self.acq(lygo['revision'],lygo['total']),lygo)
        yamz=self.g.download.MODELS['yamz-247ef39b']
        self.g.acquisition_ok(self.acq(yamz['revision'],yamz['total']),yamz)
        for a in (self.acq(yamz['revision'],yamz['total']),self.acq(lygo['revision'],lygo['total']-1),self.acq(lygo['revision'],lygo['total'],'failed')):
            with self.assertRaises(ValueError):self.g.acquisition_ok(a,lygo)
    def test_spec_record_off_without_preset(self):
        r=self.g.spec_record(Path('/nonexistent/uncensor-preset/uncensor_spec.json'),'off')
        self.assertEqual(r,dict(spec_path=None,spec_sha256=None))
        with self.assertRaises(FileNotFoundError):self.g.spec_record(Path('/nonexistent/spec.json'),'on')
    def test_baseline_identity(self):
        saved=dict(id='c1',image='sha256:i',path='/usr/local/bin/entrypoint.sh',args=['--x'])
        state=dict(Status='exited',Pid=0,OOMKilled=False)
        self.assertEqual(self.g.baseline_state(['c1','sha256:i',state,0,'/usr/local/bin/entrypoint.sh',['--x']],saved),dict(status='exited',pid=0,restarts=0,oom=False))
        for drift in (['c2','sha256:i',state,0,'/usr/local/bin/entrypoint.sh',['--x']],['c1','sha256:j',state,0,'/usr/local/bin/entrypoint.sh',['--x']],['c1','sha256:i',state,0,'/usr/local/bin/entrypoint.sh',['--y']],['c1','sha256:i',dict(state,OOMKilled=True),0,'/usr/local/bin/entrypoint.sh',['--x']]):
            with self.assertRaises(ValueError):self.g.baseline_state(drift,saved)
    def test_baseline_reader_binds_as_method(self):
        saved=dict(id='c1',image='sha256:i',path='/e',args=['--x'])
        with tempfile.TemporaryDirectory() as t:
            f=Path(t)/'b.json';f.write_text(json.dumps(saved))
            calls=[]
            def output(cmd):
                calls.append(cmd);return ' '.join(json.dumps(v) for v in ('c1','sha256:i',dict(Status='exited',Pid=0,OOMKilled=False),0,'/e',['--x']))
            class Run:
                state=self.g.baseline_reader(f,output)
            self.assertEqual(Run().state()['status'],'exited')
        self.assertEqual(calls[0][-1],'c1')
    def test_converted_pack_report(self):
        src=self.g.download.MODELS['heretic2-bf16-207cd22c']
        r=dict(status='converted',source_revision=src['revision'],total=5,files=[dict(path='a',bytes=2),dict(path='b',bytes=3)])
        self.g.converted_ok(r)
        for bad in (dict(r,status='verified'),dict(r,source_revision='0'*40),dict(r,total=6)):
            with self.assertRaises(ValueError):self.g.converted_ok(bad)
    def test_model_report_dispatch(self):
        src=self.g.download.MODELS['heretic2-bf16-207cd22c']
        self.assertIn(self.g.CONVERTED,self.g.model_profiles())
        self.g.model_report_ok(dict(status='converted',source_revision=src['revision'],total=1,files=[dict(path='a',bytes=1)]),self.g.CONVERTED)
        lygo=self.g.download.MODELS['lygo-4bpw-9c715c0b']
        self.g.model_report_ok(self.acq(lygo['revision'],lygo['total']),'lygo-4bpw-9c715c0b')
        with self.assertRaises(ValueError):self.g.model_report_ok(self.acq(lygo['revision'],lygo['total']),self.g.CONVERTED)

class Japanese(unittest.TestCase):
    def fake(self,sent):
        tmp=tempfile.TemporaryDirectory();self.addCleanup(tmp.cleanup)
        class Fake:
            d=Path(tmp.name)
            def send(self,name,request,case=None,tool=None):
                sent.append((name,request,case,tool));return dict(choices=[dict(finish_reason='stop',message=dict(content='本文'))]),dict(name=name,usage=None,quality=dict(status='not_scored'))
        return Fake()
    def test_cases_fixed(self):
        cases=m.japanese_cases()
        self.assertTrue(5<=len(cases)<=10)
        self.assertEqual(len({c['id'] for c in cases}),len(cases))
        kinds={c['kind'] for c in cases}
        self.assertTrue({'explanation','keigo-mail','summary','creative','technical'}<=kinds)
        for c in cases:self.assertRegex(c['id'],'^[a-z0-9-]+$');self.assertTrue(c['prompt'].strip())
    def test_suite_identical_bodies_and_records_text(self):
        sent=[];f=self.fake(sent)
        m.japanese_suite(f)
        cases=m.japanese_cases()
        self.assertEqual([n for n,_,_,_ in sent],[f'ja-{c["id"]}' for c in cases])
        for _,r,case,tool in sent:
            self.assertEqual((r['max_tokens'],r['temperature'],r['seed'],r['enable_thinking'],case,tool),(m.JA_MAX_TOKENS,0,42,False,None,None))
        rows=[json.loads(x) for x in (f.d/'japanese.jsonl').read_text().splitlines()]
        self.assertEqual([r['content'] for r in rows],['本文']*len(cases))
    def test_trial_profile_is_bounded(self):
        sent=[];f=self.fake(sent)
        c=dict(needle_start='A\n',needle_middle='B\n',needle_end='C\n',filler_line='x\n',nominal_tiers={'8K':8})
        f.corpus=dict(long_input_contract=c,tasks=dict(prose=dict(prompt='Q')))
        f.smoke=Mock();f.smoke.request.side_effect=lambda case:m.base(case)
        f.metadata=lambda path,body:dict(count=len(body['messages'][0]['content']))
        gates=[];m.suite_trial(f,gates=lambda client:gates.append(1))
        names=[n for n,_,_,_ in sent]
        self.assertEqual(gates,[1])
        self.assertEqual(sum(n.startswith('refusal-') for n in names),2*len(m.refusal_cases()))
        self.assertEqual(sum(n.startswith('ja-') for n in names),len(m.japanese_cases()))
        self.assertEqual([n for n in names if n[0].isdigit()],['8K-prose-cold-0','8K-prose-cold-1','32K-prose-cold-0','32K-prose-cold-1'])
        self.assertLessEqual(len(names)+12,m.TRIAL_REQUESTS)

if __name__=='__main__':unittest.main()
