import importlib.util
import sys
from pathlib import Path
import tempfile
import unittest
import os
import subprocess
import signal
import time
from unittest.mock import Mock

sys.dont_write_bytecode = True

spec = importlib.util.spec_from_file_location('cap', Path(__file__).parents[1] / 'bin/evox2-capbuild.py')
c = importlib.util.module_from_spec(spec)
spec.loader.exec_module(c)

class Tests(unittest.TestCase):
    def test_evidence_hashes_and_executed_source_reconstruction(self):
        import hashlib,json
        root=Path(__file__).parents[1]
        evidence=json.loads((root/'docs/evox2-capbuild-prebuild-result.json').read_text())
        latest=json.loads((root/'docs/evox2-capbuild-result.json').read_text())
        source=root/'bin/evox2-capbuild.py'
        self.assertEqual(hashlib.sha256(source.read_bytes()).hexdigest(),latest['source_sha256'])
        archive=root/'docs/evox2-capbuild-evidence'
        for file,key in (('restore-only.py','restore_only_sha256'),('finish-restoration.py','finish_restoration_sha256')):
            self.assertEqual(hashlib.sha256((archive/file).read_bytes()).hexdigest(),evidence['sources'][key])
        with tempfile.TemporaryDirectory() as d:
            copy=Path(d)/'runner.py';copy.write_bytes(source.read_bytes())
            subprocess.run(['patch','--quiet','-R',str(copy),str(archive/'executed-to-offline.patch')],check=True)
            self.assertEqual(hashlib.sha256(copy.read_bytes()).hexdigest(),evidence['sources']['resumed_executed_runner_sha256'])
        self.assertEqual(evidence['execution']['build_spawn_count'],0)
        self.assertEqual(evidence['execution']['cpu_sysfs_writes'],0)
        self.assertTrue(evidence['restoration']['restored'])

    def test_pin_refuses_changes(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d)/'source.py'; p.write_text('raise Exception()')
            with self.assertRaises(RuntimeError): c.pinned(p, '0'*64)

    def test_cleanup_order_success(self):
        events=[]
        c.lifecycle(lambda: events.append('stop-service'), lambda: events.append('apply'),
                    lambda: events.append('build'), lambda: events.append('stop-children'),
                    lambda: events.append('restore-cpu'), lambda: events.append('restore-service'))
        self.assertEqual(events, ['stop-service','apply','build','stop-children','restore-cpu','restore-service'])

    def test_cleanup_on_build_or_apply_failure(self):
        for phase in ('apply','build','stop-service'):
            events=[]
            def action(name):
                def run():
                    events.append(name)
                    if name==phase: raise ValueError(name)
                return run
            with self.assertRaises(ValueError):
                c.lifecycle(*(action(n) for n in ('stop-service','apply','build','stop-children','restore-cpu','restore-service')))
            self.assertEqual(events[-3:], ['stop-children','restore-cpu','restore-service'])

    def test_no_restore_over_live_children(self):
        calls=[]
        def stuck(): raise RuntimeError('live')
        with self.assertRaises(RuntimeError):
            c.lifecycle(lambda:None,lambda:None,lambda:None,stuck,lambda:calls.append('cpu'),lambda:calls.append('service'))
        self.assertEqual(calls, [])

    def test_cpu_restore_failure_still_checks_stopped_service(self):
        calls=[]
        def conflict(): raise RuntimeError('conflict')
        with self.assertRaises(RuntimeError):
            c.lifecycle(lambda:None,lambda:None,lambda:None,lambda:None,conflict,lambda:calls.append('service'))
        self.assertEqual(calls,['service'])

    def test_ninja_exact_one(self):
        for args in (['ninja','-v','-j','1'], ['ninja','-j1']): c.ninja_one(args)
        for args in (['ninja'],['ninja','-j','4'],['ninja','-j1','-j2'],['ninja','-j','1','-j','8']):
            with self.assertRaises(RuntimeError): c.ninja_one(args)

    def test_pid_reuse_not_signalled(self):
        self.assertEqual(c.alive({2:'100'}, {2:{'start':'101','state':'S'}}),set())
        self.assertEqual(c.alive({2:'100'}, {2:{'start':'100','state':'Z'}}),set())

    def test_deadline_and_gap(self):
        with self.assertRaises(RuntimeError): c.timing(3600,0,3599)
        with self.assertRaises(RuntimeError): c.timing(8,0,1)
        c.timing(1,0,0)

    def test_memory_persistence_is_time_not_two_fast_samples(self):
        p=c.Persistence()
        self.assertFalse(p.low(0,0)); self.assertFalse(p.low(0,0.1))
        self.assertTrue(p.low(0,2))
        self.assertFalse(p.low(9*1024**3,3))

    def test_sample_recorded_before_cpu_or_idle_decision(self):
        row={'temperature':33.0,'gpu_busy_percent':75,'available':120*1024**3,'swap':0}
        run=c.Run.__new__(c.Run);run.guard=Mock();run.guard.sample.return_value=row
        run.child=None;run.host=Mock();run.cpu=Mock();run.expected={}
        run.cpu.equivalent.side_effect=RuntimeError('CPU drift')
        run.log=Mock()
        with self.assertRaises(RuntimeError):run.observe('stopped_cooldown')
        self.assertEqual(run.log.call_args_list[0].args,('sample_observed',))
        self.assertEqual(run.log.call_args_list[0].kwargs['sample']['gpu_busy_percent'],75)
        self.assertEqual(run.log.call_args_list[0].kwargs['check_stage'],'stopped_cooldown')

    def test_never_start_baseline_in_cleanup_success_or_failure(self):
        for failed in (False,True):
            run=c.Run.__new__(c.Run);run.stopped=True;run.result={};run.log=Mock()
            run.state=Mock(return_value={'status':'exited','restarts':0,'oom':False})
            def build():
                if failed:raise ValueError('build failure')
            if failed:
                with self.assertRaises(ValueError):c.lifecycle(lambda:None,lambda:None,build,lambda:None,lambda:None,run.ensure_stopped)
            else:c.lifecycle(lambda:None,lambda:None,build,lambda:None,lambda:None,run.ensure_stopped)
            self.assertTrue(run.result['service_held_stopped'])
        self.assertFalse(hasattr(c.Run,'restore_service'))

    def test_cooldown_resets_continuous_timer_and_waits_not_immediate_abort(self):
        now=[0];samples=[]
        def observe():
            samples.append(now[0])
            return {'temperature':86 if now[0] in (0,4) else 30,'gpu_busy_percent':1 if now[0]==2 else 0}
        def wait(seconds):now[0]+=seconds
        c.wait_cooldown(observe,clock=lambda:now[0],wait=wait,seconds=3,limit=10)
        self.assertEqual(now[0],8)
        self.assertIn(4,samples)

    def test_cooldown_timeout_and_required_sensor_failure(self):
        now=[0]
        def wait(seconds):now[0]+=seconds
        with self.assertRaisesRegex(RuntimeError,'cooldown_timeout'):
            c.wait_cooldown(lambda:{'temperature':86,'gpu_busy_percent':0},clock=lambda:now[0],wait=wait,seconds=3,limit=5)
        self.assertEqual(now[0],5)
        def missing():raise OSError(2,'required sensor gone')
        with self.assertRaises(OSError):c.wait_cooldown(missing)

    def test_sensor_read_failure_is_recorded_with_source_and_errno(self):
        run=c.Run.__new__(c.Run);run.child=None;run.guard=Mock();run.log=Mock()
        run.guard.sample.side_effect=OSError(5,'sensor read failure')
        with self.assertRaises(OSError):run.read_sample('build')
        self.assertEqual(run.log.call_args.kwargs['errno'],5)
        self.assertEqual(run.log.call_args.kwargs['source'],'PR165.sample')

    def test_kernel_reader_preserves_whole_stdout_and_tail_across_append(self):
        from unittest.mock import patch
        before='[1.000000] earlier\n[2.000000] tail with space \n'
        after=before+'[3.000000] ordinary new line\n'
        run=c.Run.__new__(c.Run);run.log=Mock()
        with patch.object(c.subprocess,'check_output',side_effect=[before,after]):
            first=run.kernel_text();second=run.kernel_text()
        self.assertEqual(first,before)
        self.assertEqual(second,after)
        cursor=c.KernelCursor(first)
        result=cursor.check(second)
        self.assertFalse(result['coverage_lost'])
        self.assertFalse(result['faults'])
        result=cursor.check(after+'[1.500000] amdgpu delayed GPU fault\n')
        self.assertEqual(len(result['faults']),1)
        with self.assertRaises(RuntimeError):cursor.check('no timestamp')

    def test_generic_output_still_strips_other_commands(self):
        from unittest.mock import patch
        with patch.object(c.subprocess,'check_output',return_value=' text \n'):
            self.assertEqual(c.output(['git','status']),'text')

    def test_kernel_cursor_old_eviction_new_fault_and_ring_loss(self):
        cursor=c.KernelCursor('[1.0] old unrelated error\n[2.0] anchor')
        result=cursor.check('[2.0] anchor\n[3.0] harmless info')
        self.assertFalse(result['faults']);self.assertFalse(result['coverage_lost'])
        result=cursor.check('[2.0] anchor\n[3.0] harmless info\n[4.0] amdgpu GPU reset begin!')
        self.assertEqual(len(result['faults']),1)
        self.assertTrue(cursor.check('[8.0] after lost interval')['coverage_lost'])
        with self.assertRaises(RuntimeError):c.KernelCursor('timestamps unavailable')

    def test_sample_is_bounded_and_does_not_echo_unknown_content(self):
        row=c.bounded_sample({'temperature':33,'memory.events':'x'*10000,'unknown':'SECRET'})
        self.assertNotIn('unknown',row)
        self.assertLessEqual(len(__import__('json').dumps(row)),4096)

    def test_kernel_delayed_fault_older_timestamp_is_not_missed(self):
        cursor=c.KernelCursor('[2.0] anchor')
        self.assertEqual(len(cursor.check('[2.0] anchor\n[1.5] amdgpu VM fault')['faults']),1)

    def test_kernel_OOM_thermal_machinecheck_are_faults(self):
        for message in ('Out of memory: Killed process','thermal critical temperature','mce: Hardware Error','amdgpu GCVM_L2_PROTECTION_FAULT_STATUS'):
            cursor=c.KernelCursor('[1.0] anchor')
            self.assertEqual(len(cursor.check('[1.0] anchor\n[2.0] '+message)['faults']),1)

    def sensor_tree(self, root):
        for directory,name in (('hwmon0','k10temp'),('hwmon1','amdgpu')):
            p=root/directory; p.mkdir(); (p/'name').write_text(name); (p/'temp1_input').write_text('30000')
        (root/'hwmon4').mkdir()  # Unrelated directory with no readable name.

    def test_unrelated_missing_hwmon_name_is_bounded_skip(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d); self.sensor_tree(root)
            inventory,skips=c.sensors(root)
            self.assertEqual(len(inventory),2)
            self.assertEqual(skips,[{'hwmon':'hwmon4','reason':'name_unavailable','errno':2}])
            c.sensors(root,inventory)

    def test_required_sensor_loss_or_bad_value_stops(self):
        for target in ('name','temp1_input'):
            with tempfile.TemporaryDirectory() as d:
                root=Path(d); self.sensor_tree(root); inventory,_=c.sensors(root)
                (root/'hwmon0'/target).unlink()
                with self.assertRaises((RuntimeError,OSError)): c.sensors(root,inventory)
        with tempfile.TemporaryDirectory() as d:
            root=Path(d); self.sensor_tree(root)
            (root/'hwmon0'/'temp1_input').write_text('0')
            with self.assertRaises(RuntimeError): c.sensors(root)

    def test_all_temperature_unknown_and_critical_loss_stop(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d)
            with self.assertRaises(RuntimeError): c.sensors(root)
            self.sensor_tree(root)
            crit=root/'hwmon0'/'temp1_crit';crit.write_text('100000')
            inventory,_=c.sensors(root);crit.unlink()
            with self.assertRaises(RuntimeError):c.sensors(root,inventory)

    def test_pinned_guard_boundaries(self):
        source=os.environ.get('TEST_BUILD_GUARD_SOURCE')
        if not source: self.skipTest('pinned external guard not supplied')
        g=c.pinned(Path(source),c.GUARD_SHA)
        gate=g.Gate(0)
        self.assertIsNone(gate.check(9*1024**3,0,95,0))
        self.assertIsNone(gate.check(9*1024**3,0,95,9.9))
        self.assertEqual(gate.check(9*1024**3,0,95,10),'temperature')
        self.assertEqual(g.Gate(0).check(9*1024**3,0,90,0,95),'critical_temperature')
        self.assertEqual(g.Gate(0).check(9*1024**3,0,None,0),'temperature_unavailable')
        self.assertEqual(g.Gate(0).check(9*1024**3,513*1024**2,30,0),'swap')

    def test_monitor_error_unwinds_lifecycle(self):
        events=[]
        def missing(): raise OSError(5,'sensor unavailable')
        with self.assertRaises(OSError):
            c.lifecycle(lambda:None,lambda:None,missing,lambda:events.append('stop'),
                        lambda:events.append('cpu'),lambda:events.append('service'))
        self.assertEqual(events,['stop','cpu','service'])

    def test_scoped_separate_process_group_cleanup(self):
        source=os.environ.get('TEST_BUILD_GUARD_SOURCE')
        if not source: self.skipTest('pinned external guard not supplied')
        run=c.Run.__new__(c.Run)
        run.guard=c.pinned(Path(source),c.GUARD_SHA)
        run.tracked={}; run.pidfds={}; run.ninjas=[]; run.result={}
        run.log=lambda *a,**k:None; run.no_compilers=lambda:None
        other=subprocess.Popen(['sleep','60'])
        old={s:signal.getsignal(s) for s in (signal.SIGALRM,signal.SIGTERM,signal.SIGINT)}
        with tempfile.TemporaryDirectory() as d:
            marker=Path(d)/'child'
            code='import subprocess,time,sys; p=subprocess.Popen(["sleep","60"],start_new_session=True); open(sys.argv[1],"w").write(str(p.pid)); time.sleep(60)'
            run.child=subprocess.Popen(['python3','-c',code,str(marker)],start_new_session=True)
            try:
                end=time.monotonic()+3
                while not marker.exists() and time.monotonic()<end: time.sleep(.01)
                self.assertTrue(marker.exists())
                pid=int(marker.read_text())
                run.track()
                self.assertIn(pid,run.tracked)
                run.stop_children()
                self.assertFalse(c.alive(run.tracked,run.guard.processes()))
                self.assertIsNone(other.poll())
            finally:
                for s,h in old.items():signal.signal(s,h)
                if run.child.poll() is None: run.child.kill(); run.child.wait()
                other.terminate(); other.wait()

if __name__=='__main__': unittest.main()
