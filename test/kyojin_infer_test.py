#!/usr/bin/env python3
import importlib.util
import json
from pathlib import Path
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

if __name__=='__main__':unittest.main()
