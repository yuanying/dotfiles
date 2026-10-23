#!/usr/bin/env python3
"""Explicit optional integration tests of preserved unmerged references, offline.

Usage: python3 test/kyojin_infer_references_test.py /absolute/notes
No model, GPU, service or CPU settings are touched.
"""
import io
import json
from pathlib import Path
import subprocess
import sys
import time
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'devbox/apps/llama-server'))
import kyojin_infer as infer
import kyojin_infer_guard as supervisor
refs=Path(sys.argv.pop(1))
cap=infer.pinned(refs/'reference-capbuild/evox2-capbuild-readerfix-once.py',supervisor.CAP_SHA)
guard=infer.pinned(refs/'reference-trial/qwen_trial_guard.py',cap.GUARD_SHA)
live=infer.pinned(refs/'reference-trial/qwen_stream_live.py',infer.LIVE_SHA)
collector=infer.pinned(refs/'reference-measure/stream_metrics.py',infer.COLLECTOR_SHA)

class ReferenceTests(unittest.TestCase):
    def test_memory_and_temperature(self):
        g=guard.Gate(0);self.assertIsNone(g.check(7*1024**3,0,40,0));self.assertEqual(g.check(7*1024**3,0,40,2),'memory')
        g=guard.Gate(0);self.assertIsNone(g.check(100*1024**3,0,95,0));self.assertEqual(g.check(100*1024**3,0,95,10),'temperature')
        self.assertEqual(guard.Gate(0).check(100*1024**3,0,None,0),'temperature_unavailable')
        self.assertEqual(guard.Gate(0).check(100*1024**3,513*1024**2,40,0),'swap')
    def test_kernel_whitespace_and_fault(self):
        c=cap.KernelCursor('[1] old \n');self.assertFalse(c.check('[1] old \n[2] new\n')['coverage_lost'])
        self.assertTrue(c.check('[2] new\n[3] amdgpu GPU fault\n')['faults'])
        self.assertTrue(c.check('[4] replacement\n')['coverage_lost'])
    def test_cooldown_continuity(self):
        clock=[0];rows=[0,0,1,0,0,0]
        def observe():
            return {'temperature':40,'gpu_busy_percent':rows.pop(0)}
        cap.wait_cooldown(observe,clock=lambda:clock[0],wait=lambda seconds:clock.__setitem__(0,clock[0]+seconds),seconds=2,limit=10)
        self.assertEqual(clock[0],5)
    def test_pid_identity_and_descendants(self):
        self.assertEqual(cap.alive({12:'old'},{12:dict(start='new',state='R')}),set())
        self.assertEqual(guard.descendants(1,{1:0,2:1,3:2,4:0}),{1,2,3})
    def test_actual_scoped_stop_leaves_other_process(self):
        other=subprocess.Popen([sys.executable,'-c','import time;time.sleep(30)'])
        child=subprocess.Popen([sys.executable,'-c','import time;time.sleep(30)'],start_new_session=True)
        try:
            table=guard.processes();guard.stop_tracked(child,{child.pid:table[child.pid]['start']})
            self.assertIsNotNone(child.poll());self.assertIsNone(other.poll())
        finally:
            if child.poll() is None:child.kill();child.wait()
            other.terminate();other.wait()
    def test_live_arrival_fragmented_utf8(self):
        events=[dict(choices=[dict(index=0,delta=dict(role='assistant'))]),dict(choices=[dict(index=0,delta=dict(content='赤'))]),dict(choices=[dict(index=0,delta={},finish_reason='stop')],usage=dict(prompt_tokens=1,completion_tokens=1,total_tokens=2))]
        raw=''.join('data: '+json.dumps(e,ensure_ascii=False)+'\n\n' for e in events)+'data: [DONE]\n\n'
        fragments=[bytes([b]) for b in raw.encode()]+[b''];clock=[0]
        def now():clock[0]+=1000000;return clock[0]
        class Response:
            status=200
            def read1(self,n):return fragments.pop(0)
        c=collector.Collector(0);saved=io.BytesIO();result=live.receive(Response(),c,saved,clock=now)
        self.assertEqual(saved.getvalue(),raw.encode());self.assertGreater(result['ttft_seconds']['content'],result['header_seconds'])
        self.assertIsNone(result['ttft_seconds']['reasoning'])
    def test_transport_abort_before_next_read(self):
        class Response:
            status=200
            def read1(self,n):raise AssertionError('read after abort')
        def abort():raise TimeoutError('synthetic_deadline')
        with self.assertRaises(TimeoutError):live.receive(Response(),collector.Collector(time.monotonic_ns()),io.BytesIO(),before_read=abort)

if __name__=='__main__':unittest.main()
