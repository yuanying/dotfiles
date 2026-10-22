#!/usr/bin/env python3
"""Offline only: no host mutation or actual CPU workload."""
import copy
import io
import os
import importlib.util
from pathlib import Path
import signal
import subprocess
import time
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True

spec = importlib.util.spec_from_file_location('load', Path(__file__).resolve().parents[1] / 'bin/evox2-cpu-load.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

class Clock:
    now = 0
    def __call__(self): return self.now
    def wait(self, seconds): self.now += seconds

class API:
    MAX = 'max'
    POLICIES = tuple(str(i) for i in range(32))
    def __init__(self):
        self.state = {'policies': {i: {'max': '5187500', 'min': '2000000'} for i in self.POLICIES}}
        self.original = copy.deepcopy(self.state)
        self.events = []
    def read(self): return copy.deepcopy(self.state)
    def equivalent(self, a, b):
        if a != b: raise RuntimeError('conflict')
    def plan(self, before): return {'max_khz': {i: 3000000 for i in self.POLICIES}}
    def snapshot(self, io, path): self.events.append('snapshot')
    def load(self, path): return {'before': self.original}
    def apply(self, io, path):
        self.events.append('apply')
        for row in self.state['policies'].values(): row['max'] = '3000000'
    def restore(self, io, path):
        self.events.append('restore'); self.state = copy.deepcopy(self.original)

class Child:
    def __init__(self, seconds, cpu, clock, events):
        self.seconds, self.clock, self.events = seconds, clock, events
        self.start = clock(); events.append(('start', seconds))
    def status(self): return {'pid': 123, 'starttime': 42}
    def finish(self): self.events.append(('finish', self.seconds))
    def stop(self): self.events.append(('stop', self.seconds))

class Tests(unittest.TestCase):
    def setup_trial(self, observe=None):
        a, c = API(), Clock()
        obs = observe or (lambda stage, child: {'tctl_c': 40})
        factory = lambda seconds, cpu: Child(seconds, cpu, c, a.events)
        return a, c, obs, factory
    def run_trial(self, a, c, obs, factory):
        return m.experiment(a, a, Path('/unused'), obs, factory, 0,
                            clock=c, wait=c.wait, arm=lambda: a.events.append('arm'),
                            disarm=lambda: a.events.append('disarm'))
    def test_stages_and_stop_before_restore(self):
        a,c,o,f = self.setup_trial(); self.run_trial(a,c,o,f)
        self.assertEqual([e for e in a.events if isinstance(e,tuple) and e[0]=='start'], [('start',30),('start',120)])
        self.assertLess(a.events.index(('stop',120)), a.events.index('restore'))
        self.assertEqual(c(), 60+30+30+60+120+60)
        self.assertEqual(a.state,a.original)
    def test_hot_cooldown_skips_second(self):
        a,c,o,f = self.setup_trial(lambda s,p: {'tctl_c': 86 if s=='cooldown' else 40})
        result=self.run_trial(a,c,o,f)
        self.assertFalse(result['second_stage']); self.assertNotIn(('start',120),a.events)
        self.assertEqual(a.state,a.original)
    def test_signal_and_guard_and_conflict_restore(self):
        for kind in ('signal','guard','conflict','timeout'):
            a,c,o,f=self.setup_trial()
            def fail(stage, child):
                if stage=='load30':
                    if kind=='signal': m.interrupted(signal.SIGTERM, None)
                    raise RuntimeError(kind)
                return {'tctl_c':40}
            with self.assertRaises(RuntimeError): self.run_trial(a,c,fail,f)
            self.assertLess(a.events.index(('stop',30)),a.events.index('restore'))
            self.assertEqual(a.state,a.original)
    def test_partial_apply_failure_also_restores(self):
        a,c,o,f=self.setup_trial()
        def fail(*args):
            a.state['policies']['0']['max']='3000000'
            raise RuntimeError('partial')
        a.apply=fail
        with self.assertRaises(RuntimeError): self.run_trial(a,c,o,f)
        self.assertEqual(a.state,a.original)
    def test_unstoppable_child_blocks_restore(self):
        a,c,o,f=self.setup_trial()
        def factory(seconds,cpu):
            child=f(seconds,cpu)
            child.stop=lambda: (_ for _ in ()).throw(RuntimeError('unstoppable'))
            return child
        with self.assertRaises(RuntimeError): self.run_trial(a,c,o,factory)
        self.assertNotIn('restore',a.events)
    def test_pinned_source_rejects_changed_bytes(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/'source.py'; p.write_text('raise Exception("must not execute")')
            with self.assertRaises(RuntimeError): m.load_api(p)
    def test_pid_identity_and_scoped_signal(self):
        child=object.__new__(m.Load)
        child.pid=123; child.starttime=42; child.pidfd=9
        with patch.object(m,'proc_status',return_value={'starttime':43}), patch.object(signal,'pidfd_send_signal') as send:
            with self.assertRaises(RuntimeError): child.send(signal.SIGTERM)
            send.assert_not_called()
        with patch.object(m,'proc_status',return_value={'starttime':42}), patch.object(signal,'pidfd_send_signal') as send:
            child.send(signal.SIGTERM); send.assert_called_once_with(9,signal.SIGTERM)
    def test_child_timeout_and_bounds(self):
        child=object.__new__(m.Load)
        child.pid=123; child.starttime=42; child.cpu=0; child.deadline=0
        child.process=__import__('unittest.mock',fromlist=['Mock']).Mock()
        child.process.poll.return_value=None
        status={'starttime':42,'threads':1,'rss_bytes':1024}
        with patch.object(m,'proc_status',return_value=status), patch.object(m.os,'sched_getaffinity',return_value={0}):
            with self.assertRaisesRegex(RuntimeError,'timeout'): child.status()
            child.deadline=time.monotonic()+5
            for field,value in [('threads',2),('rss_bytes',65*1024**2),('starttime',43)]:
                with patch.object(m,'proc_status',return_value=dict(status,**{field:value})):
                    with self.assertRaises(RuntimeError): child.status()
    def test_scoped_stop_real_sleep_child_not_workload(self):
        # This is an idle sleep, not a CPU load or host configuration change.
        p=subprocess.Popen([__import__('sys').executable,'-c','import time; time.sleep(60)'])
        child=object.__new__(m.Load)
        child.process=p; child.pid=p.pid
        child.pidfd=m.os.pidfd_open(p.pid)
        child.starttime=m.proc_status(p.pid)['starttime']
        child.stop()
        self.assertIsNotNone(p.poll())
        self.assertEqual(p.returncode,-signal.SIGTERM)
    def test_oom_guard(self):
        with self.assertRaises(RuntimeError): m.check_oom({'oom_kill':1},{'oom_kill':2})
        m.check_oom({'oom_kill':1},{'oom_kill':1})

@unittest.skipUnless(os.environ.get('TEST_CPU_LIMIT_SOURCE'), 'set TEST_CPU_LIMIT_SOURCE for pinned API integration')
class PinnedGuardTests(unittest.TestCase):
    def test_temperature_memory_swap_health_and_sensor_fail_closed(self):
        api=m.load_api(Path(os.environ['TEST_CPU_LIMIT_SOURCE']))
        class Node:
            def __init__(self, name, values): self.name,self.values=name,values
            def __truediv__(self, name): return Node(self.name+'/'+name,self.values)
            def read_text(self):
                if self.name not in self.values: raise FileNotFoundError(self.name)
                return self.values[self.name]
            def glob(self, pattern):
                if self.name=='/sys/class/hwmon': return [Node('sensor',self.values)]
                if pattern=='temp*_crit': return [Node('critical',self.values)] if 'critical' in self.values else []
                return []
        base={'sensor/name':'k10temp','sensor/temp1_input':'40000',
              '/proc/meminfo':'MemAvailable: 16777216 kB\nSwapTotal: 8388608 kB\nSwapFree: 8388608 kB\n'}
        for kind in ('safe','95C','critical','sensor','memory','swap','health'):
            values=dict(base)
            if kind=='95C': values['sensor/temp1_input']='95000'
            if kind=='critical': values['critical']='45000'
            if kind=='sensor': del values['sensor/temp1_input']
            if kind=='memory': values['/proc/meminfo']=base['/proc/meminfo'].replace('16777216','8388607')
            if kind=='swap': values['/proc/meminfo']=base['/proc/meminfo'].replace('SwapFree: 8388608','SwapFree: 7864319')
            monitor=object.__new__(api.Monitor)
            monitor.stream=io.StringIO(); monitor.swap_initial=0; monitor.started=time.monotonic()
            response=__import__('unittest.mock',fromlist=['MagicMock']).MagicMock()
            response.__enter__.return_value.read.return_value=b'{"status":"bad"}' if kind=='health' else b'{"status":"ok"}'
            opener=__import__('unittest.mock',fromlist=['Mock']).Mock()
            opener.open.return_value=response
            host={'policies':{i:{api.MAX:'3000000'} for i in api.POLICIES}}
            with patch.object(api,'Path',side_effect=lambda p:Node(str(p),values)), patch.object(api.urllib.request,'build_opener',return_value=opener), patch.object(api.Host,'read',return_value=host):
                if kind=='safe': monitor('fixture')
                else:
                    with self.subTest(kind=kind),self.assertRaises(api.Unsafe): monitor('fixture')

if __name__=='__main__': unittest.main()
