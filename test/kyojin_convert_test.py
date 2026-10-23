#!/usr/bin/env python3
"""Offline conversion-guard contracts; no model/GPU/service."""
import importlib
import json
from pathlib import Path
import sys
import tempfile
import unittest

D=Path(__file__).resolve().parents[1]/'devbox/apps/llama-server'
sys.path.insert(0,str(D))
c=importlib.import_module('kyojin_convert_guard')
download=importlib.import_module('kyojin_infer_download')
GIB=1024**3


class ConvertTests(unittest.TestCase):
    def test_fixed_settings(self):
        argv=c.convert_argv(Path('/s'),Path('/o'),Path('/w'),resume=False)
        self.assertEqual(argv,['convert.py','-i','/s','-o','/o','-w','/w','-b','4.05','-hb','6','-mb','8','-ngb','6'])
        # Vision bits and calibration stay at the converter's defaults.
        self.assertNotIn('-vb',argv);self.assertNotIn('-cr',argv);self.assertNotIn('-cd',argv)
    def test_resume_restores_job_settings(self):
        self.assertEqual(c.convert_argv(Path('/s'),Path('/o'),Path('/w'),resume=True),['convert.py','-w','/w','-r'])
    def test_start_disk_gate(self):
        # Free space must cover what the job still writes, then keep 50 GiB.
        c.start_disk_gate(c.PEAK_BYTES+50*GIB,0)
        with self.assertRaises(ValueError):c.start_disk_gate(c.PEAK_BYTES+50*GIB-1,0)
        c.start_disk_gate(c.PEAK_BYTES-10**9+50*GIB,10**9)
        c.start_disk_gate(50*GIB,c.PEAK_BYTES+1)
        with self.assertRaises(ValueError):c.start_disk_gate(50*GIB-1,c.PEAK_BYTES+1)
    def test_run_disk_gate(self):
        c.run_disk_gate(50*GIB)
        with self.assertRaises(ValueError):c.run_disk_gate(50*GIB-1)
    def test_job_directories(self):
        with tempfile.TemporaryDirectory() as t:
            p=Path(t);out=p/'out';work=p/'work'
            c.job_directories(out,work,resume=False)
            with self.assertRaises(ValueError):c.job_directories(out,work,resume=True)
            work.mkdir()
            with self.assertRaises(ValueError):c.job_directories(out,work,resume=False)  # never reuse a work dir
            (work/'ckpt').mkdir();(work/'ckpt/job.json').write_text('{}')
            c.job_directories(out,work,resume=True)
            out.mkdir()
            with self.assertRaises(ValueError):c.job_directories(out,work,resume=False)
    def test_source_verified(self):
        h=download.MODELS['heretic2-bf16-207cd22c']
        with tempfile.TemporaryDirectory() as t:
            p=Path(t);(p/'a').write_bytes(b'x'*3)
            files=[dict(path='a',bytes=3)]
            report=dict(status='verified',revision=h['revision'],files=files)
            with self.assertRaises(ValueError):c.source_verified(p,report)  # total differs from the fixed profile
            files[0]['bytes']=h['total'];report['files']=files
            with self.assertRaises(ValueError):c.source_verified(p,report)  # size on disk drifted
            for bad in (dict(report,status='failed'),dict(report,revision='0'*40)):
                with self.assertRaises(ValueError):c.source_verified(p,bad)
    def test_finished(self):
        self.assertTrue(c.finished(' -- Writing config.json\n -- All done\n'))
        self.assertFalse(c.finished(' -- Saving checkpoint\n'))
    def test_output_settings(self):
        q=dict(quant_method='exl3',bits=4.05,head_bits=6,mtp_bits=8,vision_bits=6)
        c.output_settings(dict(quantization_config=q))
        for k,v in (('bits',4.0),('head_bits',4),('mtp_bits',6),('quant_method','fp8')):
            with self.assertRaises(ValueError):c.output_settings(dict(quantization_config=dict(q,**{k:v})))
    def test_output_index(self):
        with tempfile.TemporaryDirectory() as t:
            p=Path(t)
            for n in ('model-00001-of-00002.safetensors','model-00002-of-00002.safetensors','ngram_embedding.safetensors'):(p/n).write_bytes(b'x')
            idx=dict(weight_map={'a':'model-00001-of-00002.safetensors','b':'model-00002-of-00002.safetensors'})
            (p/'model.safetensors.index.json').write_text(json.dumps(idx))
            self.assertEqual(c.output_index(p),2)
            (p/'ngram_embedding.safetensors').unlink()
            with self.assertRaises(ValueError):c.output_index(p)
            (p/'ngram_embedding.safetensors').write_bytes(b'x');(p/'model-00002-of-00002.safetensors').unlink()
            with self.assertRaises(ValueError):c.output_index(p)
    def test_capped_lifecycle_order(self):
        for stage in ('pre','apply','live',None):
            events=[]
            def op(name):
                def f():
                    events.append(name)
                    if name==stage:raise ValueError('synthetic')
                return f
            ops=[op(n) for n in ('pre','apply','live','stop','restore','verify')]
            if stage:
                with self.assertRaises(ValueError):c.capped_lifecycle(*ops)
            else:c.capped_lifecycle(*ops)
            self.assertEqual(events[-3:],['stop','restore','verify'])
            if stage=='pre':self.assertNotIn('apply',events)
    def test_capped_lifecycle_verifies_after_restore_failure(self):
        events=[]
        def ok(name):return lambda:events.append(name)
        def bad():events.append('restore');raise RuntimeError('restore_failed')
        with self.assertRaises(RuntimeError):c.capped_lifecycle(ok('pre'),ok('apply'),ok('live'),ok('stop'),bad,ok('verify'))
        self.assertEqual(events,['pre','apply','live','stop','restore','verify'])
    def test_child_env_is_fixed(self):
        env=c.child_env(Path('/t'),{'HOME':'/h','PATH':'/p','EXL3_ABLIT_RUNTIME':'x','SECRET':'s'})
        self.assertEqual(env['EXL3_CKPT_KEEP_OLD'],'0')
        self.assertEqual(env['HF_HUB_OFFLINE'],'1')
        self.assertNotIn('SECRET',env);self.assertNotIn('EXL3_ABLIT_RUNTIME',env)


if __name__=='__main__': unittest.main()
