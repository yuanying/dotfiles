"""Offline fixtures only: no sysfs writes or privileged commands."""
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import subprocess
import sys
from unittest import mock
import errno

sys.dont_write_bytecode = True

SPEC = importlib.util.spec_from_file_location(
    "cpu_limit", Path(__file__).resolve().parents[1] / "bin/evox2-cpu-limit.py")
cpu = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(cpu)


def state():
    return {
        "identity": dict(cpu.IDENTITY), "boot_id": "fixture-boot",
        "online": "0-31", "boost": "1", "status": "active",
        "policies": {
            str(i): {"affected_cpus": str(i), "related_cpus": str(i),
                     "scaling_driver": "amd-pstate-epp",
                     "scaling_governor": "powersave",
                     "energy_performance_preference": "balance_performance",
                     "scaling_min_freq": "2000000",
                     "scaling_max_freq": "5187500",
                     "cpuinfo_min_freq": "625000",
                     "cpuinfo_max_freq": "5187500", "boost": "1"}
            for i in range(32)},
    }


class Memory:
    def __init__(self):
        self.value = state()
        self.writes = []
        self.fail = None
        self.fail_after = False

    def read(self):
        return copy.deepcopy(self.value)

    def write_max(self, index, value):
        self.writes.append((index, value))
        if self.fail == index:
            self.fail = None
            if self.fail_after:
                self.value['policies'][index]['scaling_max_freq'] = str(value)
            raise OSError('fixture write failure')
        self.value['policies'][index]['scaling_max_freq'] = str(value)


class LimitTests(unittest.TestCase):
    def setUp(self):
        self.io = Memory()
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / 'snapshot.json'

    def snapshot(self):
        cpu.snapshot(self.io, self.path)
        return json.loads(self.path.read_text())

    def test_plan_default_does_not_write(self):
        plan = cpu.plan(self.io.read())
        self.assertEqual(plan['target_khz'], 3000000)
        self.assertEqual(self.io.writes, [])
        self.assertFalse(self.path.exists())

    def test_snapshot_exclusive_and_private(self):
        self.snapshot()
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)
        with self.assertRaises(FileExistsError):
            self.snapshot()
        self.assertEqual(self.io.writes, [])

    def test_wrong_identity_and_policy_set_rejected(self):
        for kind in ['identity', 'missing', 'extra', 'mapping', 'driver', 'min']:
            s = state()
            if kind == 'identity': s['identity']['bios_version'] = 'other'
            if kind == 'missing': del s['policies']['31']
            if kind == 'extra': s['policies']['32'] = s['policies']['0']
            if kind == 'mapping': s['policies']['0']['related_cpus'] = '0 16'
            if kind == 'driver': s['policies']['0']['scaling_driver'] = 'acpi-cpufreq'
            if kind == 'min': s['policies']['0']['scaling_min_freq'] = '4000000'
            with self.subTest(kind=kind), self.assertRaises(cpu.Unsafe): cpu.plan(s)

    def test_never_increases_lower_existing_max(self):
        self.io.value['policies']['0']['scaling_max_freq'] = '2500000'
        self.snapshot()
        cpu.apply(self.io, self.path)
        self.assertNotIn(('0', 3000000), self.io.writes)
        self.assertEqual(self.io.value['policies']['0']['scaling_max_freq'], '2500000')
        cpu.restore(self.io, self.path)
        self.assertEqual(self.io.value['policies']['0']['scaling_max_freq'], '2500000')

    def test_apply_readback_and_restore(self):
        original = self.io.read()
        self.snapshot()
        cpu.apply(self.io, self.path)
        self.assertEqual(len(self.io.writes), 32)
        self.assertEqual({v['scaling_max_freq'] for v in self.io.value['policies'].values()}, {'3000000'})
        self.assertEqual(json.loads(self.path.read_text())['phase'], 'applied')
        cpu.restore(self.io, self.path)
        self.assertEqual(self.io.read(), original)
        self.assertEqual(json.loads(self.path.read_text())['phase'], 'restored')
        cpu.restore(self.io, self.path)  # idempotent, no additional writes
        self.assertEqual(len(self.io.writes), 64)

    def test_partial_failure_rolls_back_even_write_then_error(self):
        for after in [False, True]:
            with self.subTest(after=after):
                self.io = Memory()
                path = Path(self.tmp.name) / f'{after}.json'
                cpu.snapshot(self.io, path)
                self.io.fail, self.io.fail_after = '3', after
                with self.assertRaises(cpu.Unsafe): cpu.apply(self.io, path)
                self.assertEqual(self.io.read(), state())
                self.assertEqual(json.loads(path.read_text())['phase'], 'restored')
                self.assertFalse(any(int(i) > 3 for i, _ in self.io.writes))

    def test_readback_mismatch_rolls_back(self):
        self.snapshot()
        original_write = self.io.write_max
        def ignored(index, value):
            if index != '2' or value != 3000000: original_write(index, value)
        self.io.write_max = ignored
        with self.assertRaises(cpu.Unsafe): cpu.apply(self.io, self.path)
        self.assertEqual(self.io.read(), state())

    def test_changed_boot_or_policy_prevents_apply(self):
        for field in ['boot_id', 'online', 'boost', 'status', 'epp', 'max']:
            self.io = Memory()
            path = Path(self.tmp.name) / f'{field}.json'
            cpu.snapshot(self.io, path)
            if field == 'epp': self.io.value['policies']['0']['energy_performance_preference'] = 'power'
            elif field == 'max': self.io.value['policies']['0']['scaling_max_freq'] = '4000000'
            else: self.io.value[field] = 'changed'
            with self.subTest(field=field), self.assertRaises(cpu.Unsafe): cpu.apply(self.io, path)
            self.assertEqual(self.io.writes, [])

    def test_restore_skips_conflict_but_restores_other_owned_limits(self):
        # Updated contract: recover safe policies, never overwrite an external change.
        for kind in ('max', 'epp'):
            self.io = Memory()
            path = Path(self.tmp.name) / f'conflict-{kind}.json'
            cpu.snapshot(self.io, path)
            cpu.apply(self.io, path)
            field, value = ((cpu.MAX, '2800000') if kind == 'max'
                            else ('energy_performance_preference', 'power'))
            self.io.value['policies']['3'][field] = value
            count = len(self.io.writes)
            with self.assertRaises(cpu.Unsafe): cpu.restore(self.io, path)
            restores = self.io.writes[count:]
            self.assertEqual(len(restores), 31)
            self.assertFalse(any(i == '3' for i, _ in restores))
            self.assertEqual(self.io.value['policies']['3'][field], value)
            self.assertEqual(self.io.value['policies']['2'][cpu.MAX], '5187500')

    def test_journal_precedes_each_write(self):
        self.snapshot()
        original = self.io.write_max
        def checked(index, value):
            doc = json.loads(self.path.read_text())
            self.assertIn(index, doc['pending'])
            original(index, value)
        self.io.write_max = checked
        cpu.apply(self.io, self.path)
        cpu.restore(self.io, self.path)

    def test_corrupt_snapshot_and_symlink_rejected(self):
        self.path.write_text('{}')
        with self.assertRaises(cpu.Unsafe): cpu.apply(self.io, self.path)
        self.path.unlink()
        target = Path(self.tmp.name) / 'target'
        target.write_text('{}')
        self.path.symlink_to(target)
        with self.assertRaises(cpu.Unsafe): cpu.apply(self.io, self.path)
        self.assertEqual(self.io.writes, [])

    def test_interrupted_apply_restores_only_journaled_policies(self):
        doc = self.snapshot()
        doc['phase'], doc['pending'] = 'applying', ['0', '1']
        cpu.save(self.path, doc)
        self.io.value['policies']['0']['scaling_max_freq'] = '3000000'
        # Policy1 had durable intent but crashed before its write.
        cpu.restore(self.io, self.path)
        self.assertEqual(self.io.read(), state())
        self.assertEqual(self.io.writes, [('0', 5187500)])

    def test_restore_failure_retains_journal_and_can_retry(self):
        self.snapshot()
        cpu.apply(self.io, self.path)
        self.io.fail = '29'
        with self.assertRaises(OSError): cpu.restore(self.io, self.path)
        self.assertEqual(json.loads(self.path.read_text())['phase'], 'restore_failed')
        cpu.restore(self.io, self.path)
        self.assertEqual(self.io.read(), state())

    def test_unjournaled_max_change_during_restore_is_not_overwritten(self):
        doc = self.snapshot()
        doc['phase'], doc['pending'] = 'applying', ['0']
        cpu.save(self.path, doc)
        self.io.value['policies']['1']['scaling_max_freq'] = '3000000'
        with self.assertRaises(cpu.Unsafe): cpu.restore(self.io, self.path)
        self.assertEqual(self.io.writes, [])

    def test_apply_mid_transaction_external_change_stops_and_recovers_owned(self):
        self.snapshot()
        original_write = self.io.write_max
        def competing(index, value):
            original_write(index, value)
            if index == '2' and value == 3000000:
                self.io.value['policies']['1'][cpu.MAX] = '2800000'
        self.io.write_max = competing
        with self.assertRaises(cpu.Unsafe): cpu.apply(self.io, self.path)
        self.assertEqual(self.io.value['policies']['1'][cpu.MAX], '2800000')
        self.assertEqual(self.io.value['policies']['0'][cpu.MAX], '5187500')
        self.assertEqual(self.io.value['policies']['2'][cpu.MAX], '5187500')
        self.assertFalse(any(int(i) > 2 for i, _ in self.io.writes))

    def test_cli_apply_without_confirmation_refuses_before_backend_write(self):
        # An absent snapshot proves that no attempt to load it/write sysfs occurs.
        Path(self.tmp.name).chmod(0o700)
        result = subprocess.run([sys.executable, str(SPEC.origin), 'apply',
                                 '--snapshot', str(self.path)], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('real writes require root', result.stderr)
        self.assertFalse(self.path.exists())
        self.assertFalse(Path(str(self.path) + '.lock').exists())

    def test_mode_and_hardlink_rejected(self):
        self.snapshot()
        self.path.chmod(0o644)
        with self.assertRaises(cpu.Unsafe): cpu.apply(self.io, self.path)
        self.path.chmod(0o600)
        __import__('os').link(self.path, Path(self.tmp.name) / 'alias')
        with self.assertRaises(cpu.Unsafe): cpu.apply(self.io, self.path)
        self.assertEqual(self.io.writes, [])

    def test_trial_baseline_idle_restore_and_hold(self):
        clock = [0.0]
        stages = []
        def wait(seconds): clock[0] += seconds
        cpu.trial(self.io, self.path, lambda stage: stages.append(stage),
                  wait=wait, clock=lambda: clock[0], seconds=2)
        self.assertEqual(self.io.read(), state())
        self.assertEqual(set(stages), {'before', 'limited', 'restored'})
        self.assertGreaterEqual(clock[0], 6)
        self.assertEqual(len(self.io.writes), 64)

    def test_trial_idle_monitor_failure_still_restores(self):
        clock = [0.0]
        def observe(stage):
            if stage == 'limited': raise cpu.Unsafe('fixture health failure')
        with self.assertRaises(cpu.Unsafe):
            cpu.trial(self.io, self.path, observe,
                      wait=lambda s: clock.__setitem__(0, clock[0] + s),
                      clock=lambda: clock[0], seconds=2)
        self.assertEqual(self.io.read(), state())
        self.assertEqual(json.loads(self.path.read_text())['phase'], 'restored')

    def test_trial_active_timeout_disarms_before_cleanup(self):
        clock, events = [0.0], []
        def observe(stage):
            if stage == 'limited': raise cpu.Unsafe('fixture independent timeout')
        original = self.io.write_max
        def write(index, value):
            if value == 5187500: self.assertIn('disarm', events)
            original(index, value)
        self.io.write_max = write
        with self.assertRaises(cpu.Unsafe):
            cpu.trial(self.io, self.path, observe,
                      wait=lambda s: clock.__setitem__(0, clock[0] + s),
                      clock=lambda: clock[0], seconds=2,
                      arm=lambda: events.append('arm'), disarm=lambda: events.append('disarm'))
        self.assertEqual(events, ['arm', 'disarm'])
        self.assertEqual(self.io.read(), state())

    def test_trial_preflight_drift_never_applies(self):
        clock = [0.0]
        def observe(stage): self.io.value['policies']['0'][cpu.MAX] = '4000000'
        with self.assertRaises(cpu.Unsafe):
            cpu.trial(self.io, self.path, observe,
                      wait=lambda s: clock.__setitem__(0, clock[0] + s),
                      clock=lambda: clock[0], seconds=2)
        self.assertEqual(self.io.writes, [])

    def test_failure_journal_keeps_errno_operation_and_rollback(self):
        self.snapshot()
        def denied(index, value): raise OSError(errno.EPERM, 'fixture private text must not be logged')
        self.io.write_max = denied
        with self.assertRaises(cpu.Unsafe) as caught: cpu.apply(self.io, self.path)
        doc = json.loads(self.path.read_text())
        self.assertIn('errno=1', str(caught.exception))
        failure = [e for e in doc['events'] if e['outcome'] == 'error'][0]
        self.assertEqual(failure['operation'], 'write')
        self.assertEqual(failure['policy'], '0')
        self.assertEqual(failure['errno'], errno.EPERM)
        self.assertEqual(failure['requested_khz'], 3000000)
        self.assertEqual(failure['observed_khz'], 5187500)
        self.assertEqual(doc['events'][-1]['operation'], 'rollback')
        self.assertEqual(doc['events'][-1]['outcome'], 'ok')
        self.assertNotIn('fixture private text', self.path.read_text())

    def test_host_open_and_write_failure_diagnostics_without_sysfs(self):
        host = cpu.Host()
        for operation in ('open', 'write'):
            events = []
            host.trace = lambda **event: events.append(event)
            with mock.patch.object(cpu.os, 'open', return_value=123) as opening, \
                 mock.patch.object(cpu.os, 'write', return_value=8) as writing, \
                 mock.patch.object(cpu.os, 'close'):
                if operation == 'open': opening.side_effect = OSError(errno.EROFS, 'redacted')
                else: writing.side_effect = OSError(errno.EINVAL, 'redacted')
                with self.assertRaises(OSError): host.write_max('0', 3000000)
            failed = [e for e in events if e['outcome'] == 'error']
            self.assertEqual(failed[-1]['operation'], operation)
            self.assertEqual(failed[-1]['errno'], errno.EROFS if operation == 'open' else errno.EINVAL)

    def test_readback_mismatch_journal_contains_observation(self):
        self.snapshot()
        self.io.write_max = lambda index, value: None
        with self.assertRaises(cpu.Unsafe): cpu.apply(self.io, self.path)
        events = json.loads(self.path.read_text())['events']
        observed = [e for e in events if e['operation'] == 'readback']
        self.assertEqual(observed[0]['edge'], 'before')
        self.assertEqual(observed[0]['outcome'], 'ok')
        failed = [e for e in observed if e['outcome'] == 'error'][0]
        self.assertEqual(failed['edge'], 'after')
        self.assertEqual(failed['observed_khz'], 5187500)
        self.assertEqual(failed['requested_khz'], 3000000)

    def test_diagnostic_journal_is_bounded(self):
        doc = self.snapshot()
        for _ in range(600):
            cpu.event(self.path, doc, operation='readback', policy='0',
                      requested_khz=3000000, observed_khz=3000000, outcome='ok')
        self.assertEqual(len(doc['events']), cpu.EVENT_LIMIT)
        self.assertLess(self.path.stat().st_size, cpu.SNAPSHOT_LIMIT)

    def test_repeat_apply_and_non_snapshot_phase_refused(self):
        self.snapshot()
        cpu.apply(self.io, self.path)
        count = len(self.io.writes)
        with self.assertRaises(cpu.Unsafe): cpu.apply(self.io, self.path)
        self.assertEqual(len(self.io.writes), count)


if __name__ == '__main__':
    unittest.main()
