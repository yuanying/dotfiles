import importlib.util
from pathlib import Path
import unittest
import subprocess
import sys
spec = importlib.util.spec_from_file_location('guard', Path(__file__).resolve().parents[1] / 'devbox/apps/llama-server/qwen_trial_guard.py')
g = importlib.util.module_from_spec(spec); spec.loader.exec_module(g)


class GuardTests(unittest.TestCase):
    def test_thresholds(self):
        gate = g.Gate(100)
        self.assertIsNone(gate.check(7 * 1024**3, 100, 50, 0))
        self.assertEqual(gate.check(7 * 1024**3, 100, 50, 1), 'memory')
        self.assertEqual(g.Gate(0).check(100 * 1024**3, 513 * 1024**2, 50, 0), 'swap')
        self.assertEqual(g.Gate(0).check(100 * 1024**3, 0, 90, 0, critical=95), 'critical_temperature')

    def test_hot_time(self):
        gate = g.Gate(0)
        self.assertIsNone(gate.check(100 * 1024**3, 0, 95, 1))
        self.assertEqual(gate.check(100 * 1024**3, 0, 95, 11), 'temperature')

    def test_scoped_descendants(self):
        self.assertEqual(g.descendants(10, {10: 1, 11: 10, 12: 11, 99: 1}), {10, 11, 12})

    def test_stop_separate_process_group(self):
        child = subprocess.Popen([sys.executable, '-c', 'import subprocess,sys; p=subprocess.Popen([sys.executable,"-c","import time; time.sleep(120)"],start_new_session=True); print(p.pid,flush=True); p.wait()'], stdout=subprocess.PIPE, text=True, start_new_session=True)
        try:
            grandchild = int(child.stdout.readline())
            table = g.processes()
            tracked = {pid: table[pid]['start'] for pid in (child.pid, grandchild)}
            g.stop_tracked(child, tracked)
            self.assertFalse(g.live_tracked(tracked, g.processes()))
        finally:
            child.stdout.close()
            if child.poll() is None: child.kill(); child.wait()

    def test_no_sensor_fails_closed(self):
        self.assertEqual(g.Gate(0).check(100 * 1024**3, 0, None, 0), 'temperature_unavailable')

if __name__ == '__main__': unittest.main()
