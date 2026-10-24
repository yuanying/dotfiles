#!/usr/bin/env python3
"""Offline acquisition contract; no model/network/GPU."""
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest

P = Path(__file__).resolve().parents[1]/'devbox/apps/llama-server/kyojin_infer_download.py'
s = importlib.util.spec_from_file_location('download', P)
d = importlib.util.module_from_spec(s)
s.loader.exec_module(d)

class DownloadTests(unittest.TestCase):
    def row(self, data=b'abc', lfs=True):
        r = dict(rfilename='config.json', size=len(data), blobId=hashlib.sha1(b'blob '+str(len(data)).encode()+b'\0'+data).hexdigest())
        if lfs: r['lfs'] = dict(sha256=hashlib.sha256(data).hexdigest(), size=len(data))
        return r
    def test_lfs(self):
        with tempfile.TemporaryDirectory() as t:
            r=d.acquire(self.row(), Path(t), lambda u: io.BytesIO(b'abc'))
            self.assertEqual(r['verification'], 'lfs_sha256')
            self.assertEqual((Path(t)/'config.json').read_bytes(), b'abc')
    def test_git(self):
        with tempfile.TemporaryDirectory() as t:
            self.assertEqual(d.acquire(self.row(lfs=False),Path(t),lambda u:io.BytesIO(b'abc'))['verification'],'git_blob_sha1')
    def test_wrong_hash_retains_partial(self):
        with tempfile.TemporaryDirectory() as t:
            with self.assertRaises(ValueError): d.acquire(self.row(),Path(t),lambda u:io.BytesIO(b'bad'))
            self.assertFalse((Path(t)/'config.json').exists())
            self.assertTrue((Path(t)/'config.json.partial').exists())
    def test_size_bounds(self):
        for data in (b'a',b'abcd'):
            with tempfile.TemporaryDirectory() as t:
                with self.assertRaises(ValueError): d.acquire(self.row(),Path(t),lambda u:io.BytesIO(data))
    def test_paths(self):
        for p in ('../secret','/abs','a/../b','a//b','a\\b','a?b'):
            with self.assertRaises(ValueError): d.relative(p)
    def test_no_overwrite_or_resume(self):
        with tempfile.TemporaryDirectory() as t:
            p=Path(t); (p/'config.json.partial').write_bytes(b'a')
            with self.assertRaises(ValueError): d.acquire(self.row(),p,lambda u: self.fail('network attempted'))
    def test_redirect_origins(self):
        for u in ('https://huggingface.co/a','https://cas-bridge.xethub.hf.co/a?signature=secret','https://cdn-lfs.hf.co/a'):
            d.safe_url(u)
        for u in ('http://huggingface.co/a','https://evil.huggingface.co/a','https://xethub.hf.co.evil/a','https://user:pw@huggingface.co/a','https://huggingface.co:8443/a'):
            with self.assertRaises(ValueError): d.safe_url(u)
    def test_exact_new_cdn(self):
        d.safe_url('https://us.aws.cdn.hf.co/a?signature=secret')
        d.safe_url('https://us.aws.cdn.hf.co:443/a')
        for u in ('http://us.aws.cdn.hf.co/a','https://us.aws.cdn.hf.co:8443/a','https://user@us.aws.cdn.hf.co/a','https://us.aws.cdn.hf.co.evil/a','https://evil.us.aws.cdn.hf.co/a','https://other.hf.co/a','https://us.aws.cdn.hf.co@evil/a'):
            with self.assertRaises(ValueError): d.safe_url(u)
    def test_existing_recheck(self):
        with tempfile.TemporaryDirectory() as t:
            p=Path(t); (p/'config.json').write_bytes(b'abc')
            d.verify_existing(self.row(),p)
            (p/'config.json').write_bytes(b'bad')
            with self.assertRaises(ValueError): d.verify_existing(self.row(),p)
    def rows(self,n=3):
        out=[]
        for i in range(n):
            data=bytes([97+i])*(i+1);r=self.row(data);r['rfilename']=f'f{i}';out.append((r,data))
        return out
    def test_continuation_rechecks_prefix_and_keeps_report(self):
        with tempfile.TemporaryDirectory() as t:
            p=Path(t);pairs=self.rows();rows=[r for r,_ in pairs]
            for r,data in pairs[:2]:(p/r['rfilename']).write_bytes(data)
            prev=dict(status='failed',files=[dict(path=r['rfilename'],bytes=r['size']) for r in rows[:2]])
            (p/'old.json').write_text(json.dumps(prev))
            files,rest=d.continuation(rows,p,p/'old.json',p/'old-failure.json',2,3)
            self.assertEqual([f['path'] for f in files],['f0','f1']);self.assertEqual(rest,rows[2:])
            self.assertFalse((p/'old.json').exists());self.assertTrue((p/'old-failure.json').exists())
    def test_continuation_refusals(self):
        pairs=self.rows();rows=[r for r,_ in pairs]
        def setup(p,prev,partial=False,corrupt=False):
            for r,data in pairs[:2]:(p/r['rfilename']).write_bytes(b'z'*len(data) if corrupt else data)
            if partial:(p/'f2.partial').write_bytes(b'c')
            (p/'old.json').write_text(json.dumps(prev))
        good=dict(status='failed',files=[dict(path=r['rfilename'],bytes=r['size']) for r in rows[:2]])
        cases=[(good,dict(count=3,total=3)),(good,dict(count=2,total=4)),(dict(good,status='verified'),{}),
               (dict(good,files=list(reversed(good['files']))),{}),(good,dict(partial=True)),(good,dict(corrupt=True))]
        for prev,o in cases:
            with tempfile.TemporaryDirectory() as t:
                p=Path(t);setup(p,prev,o.get('partial',False),o.get('corrupt',False))
                with self.assertRaises(ValueError):d.continuation(rows,p,p/'old.json',p/'old-failure.json',o.get('count',2),o.get('total',3))
                self.assertTrue((p/'old.json').exists())
        with tempfile.TemporaryDirectory() as t:
            p=Path(t);setup(p,good);(p/'old-failure.json').write_text('{}')
            with self.assertRaises(ValueError):d.continuation(rows,p,p/'old.json',p/'old-failure.json',2,3)
    def test_disk_budget(self):
        d.disk_gate(20*1024**3,100*1024**3,200*1024**3)
        with self.assertRaises(ValueError): d.disk_gate(20*1024**3,241*1024**3,500*1024**3)
        with self.assertRaises(ValueError): d.disk_gate(20*1024**3,0,69*1024**3)
    def test_fixed_manifest(self):
        with self.assertRaises(ValueError): d.selected(dict(sha='main',siblings=[]))
    def manifest(self,profile,n=2):
        rows=[dict(rfilename=f'f{i}',size=0,blobId='0'*40) for i in range(n)]
        rows[0]['size']=profile['total']
        return dict(sha=profile['revision'],siblings=rows)
    def test_profiles_are_fixed_revisions(self):
        self.assertEqual(set(d.MODELS),{'yamz-247ef39b','lygo-4bpw-9c715c0b','heretic2-bf16-207cd22c'})
        for p in d.MODELS.values():
            self.assertRegex(p['revision'],'^[0-9a-f]{40}$')
            self.assertEqual(p['base'],'https://huggingface.co/'+p['repo']+'/resolve/'+p['revision']+'/')
        self.assertEqual(d.MODELS['yamz-247ef39b']['base'],d.BASE)
        lygo=d.MODELS['lygo-4bpw-9c715c0b']
        self.assertEqual((lygo['repo'],lygo['total'],lygo['files']),('Lygodactylus/Qwen3.8-Flash-Next-Uncensored-exl3-4bpw',109123025060,24))
    def test_lygo_manifest_selects_all_files(self):
        lygo=d.MODELS['lygo-4bpw-9c715c0b'];m=self.manifest(lygo,24)
        self.assertEqual(len(d.selected(m,lygo)),24)
        m['siblings'].append(dict(rfilename='assets/x',size=0,blobId='0'*40))
        with self.assertRaises(ValueError):d.selected(m,lygo)  # 25 files: not the fixed manifest
        with self.assertRaises(ValueError):d.selected(self.manifest(lygo,24),d.MODELS['yamz-247ef39b'])
        with self.assertRaises(ValueError):d.selected(dict(self.manifest(lygo,24),sha='main'),lygo)
    def test_lygo_disk_gate_keeps_400GB(self):
        lygo=d.MODELS['lygo-4bpw-9c715c0b'];t=lygo['total']
        d.disk_gate(t,0,t+400*10**9,lygo)
        with self.assertRaises(ValueError):d.disk_gate(t,0,t+400*10**9-1,lygo)
        with self.assertRaises(ValueError):d.disk_gate(t,lygo['used_limit']-t+1,10**15,lygo)
    def test_acquire_uses_profile_base(self):
        seen=[]
        def opener(u):seen.append(u);return io.BytesIO(b'abc')
        with tempfile.TemporaryDirectory() as t:
            d.acquire(self.row(),Path(t),opener,d.MODELS['lygo-4bpw-9c715c0b']['base'])
        self.assertEqual(seen,[d.MODELS['lygo-4bpw-9c715c0b']['base']+'config.json'])
    def test_heretic_committed_manifest_is_fixed(self):
        h=d.MODELS['heretic2-bf16-207cd22c']
        m=json.loads((P.parent/'heretic2-bf16-207cd22c-manifest.json').read_text())
        rows=d.selected(m,h)
        self.assertEqual((len(rows),sum(r['size'] for r in rows)),(53,360030721166))
        self.assertEqual(h['repo'],'trohrbaugh/Qwen3.8-Flash-Next-heretic-2')
        self.assertEqual(h['revision'],'207cd22c347a81e8d60e2f536c955da885641afb')
        self.assertTrue(any(r['rfilename']=='model-auxiliary.safetensors' for r in rows))
    def test_heretic_disk_gate_keeps_50GiB(self):
        h=d.MODELS['heretic2-bf16-207cd22c'];t=h['total']
        d.disk_gate(t,0,t+50*d.GIB,h)
        with self.assertRaises(ValueError):d.disk_gate(t,0,t+50*d.GIB-1,h)
        with self.assertRaises(ValueError):d.disk_gate(t,h['used_limit']-t+1,10**15,h)
    def test_file_deadline(self):
        # Default: one hour per file. A profile with a minimum rate scales the
        # deadline with the file size (the 102 GB BF16 shard), never below one hour.
        self.assertEqual(d.file_deadline(10**12,d.DEFAULT),3600)
        h=d.MODELS['heretic2-bf16-207cd22c']
        self.assertEqual(d.file_deadline(1,h),3600)
        self.assertEqual(d.file_deadline(102400512288,h),102400512288/h['min_rate'])
        self.assertGreater(d.file_deadline(102400512288,h),3600)
    def test_acquire_stops_at_deadline(self):
        clock=iter([0,0,5000,5000])
        orig=d.time.monotonic
        d.time.monotonic=lambda:next(clock)
        try:
            with tempfile.TemporaryDirectory() as t:
                with self.assertRaises(ValueError):d.acquire(self.row(),Path(t),lambda u:io.BytesIO(b'abc'),deadline=3600)
        finally:d.time.monotonic=orig
    def test_symlink_parent(self):
        with tempfile.TemporaryDirectory() as t:
            p=Path(t); (p/'link').symlink_to('/tmp')
            row=self.row(); row['rfilename']='link/file'
            with self.assertRaises(ValueError): d.acquire(row,p,lambda u:self.fail('network attempted'))

if __name__=='__main__': unittest.main()
