#!/usr/bin/env python3
"""Explicit fixed-revision public model acquisition, serial/no retry/no resume.

No model code is imported. Failure leaves evidence/partial bytes in place.
Redirect query strings, errors and response headers are never printed.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import time
import urllib.parse
import urllib.request

GIB = 1024**3


def profile(repo, revision, total, files, exclude, used_limit, free_after):
    return dict(repo=repo,revision=revision,total=total,files=files,exclude=exclude,used_limit=used_limit,free_after=free_after,
                base='https://huggingface.co/'+repo+'/resolve/'+revision+'/')


# Fixed revisions only; a profile is never resolved from a branch name.
MODELS = {
    # All old/new experiment artifacts <=260 GiB, filesystem free >=50 GiB.
    'yamz-247ef39b': profile('yamz-labs/Qwen3.8-Flash-Next-EXL3-Yamz','247ef39b06ff0b0fcba76026429e191b44e0e1f8',
                             95370160976,32,('assets/',),260*GIB,50*GIB),
    # Its own directory as the budget root, and >=400 GB left on the filesystem after acquisition.
    'lygo-4bpw-9c715c0b': profile('Lygodactylus/Qwen3.8-Flash-Next-Uncensored-exl3-4bpw','9c715c0b1a745b7db1c335347e8d45595b3cad3a',
                                  109123025060,24,(),103*GIB,400*10**9),
}
DEFAULT = MODELS['yamz-247ef39b']
REV = DEFAULT['revision']
TOTAL = DEFAULT['total']
BASE = DEFAULT['base']


def require(ok):
    if not ok: raise ValueError('acquisition_contract_failed')


def relative(name):
    require(isinstance(name,str) and bool(name) and re.fullmatch(r'[a-zA-Z0-9_./-]+',name))
    p=PurePosixPath(name)
    require(not p.is_absolute() and '..' not in p.parts and str(p)==name)
    return p


def safe_url(url):
    p=urllib.parse.urlsplit(url)
    require(p.scheme=='https' and not p.username and not p.password and p.port in (None,443))
    require(p.hostname in ('huggingface.co','cdn-lfs.huggingface.co','cdn-lfs.hf.co','cas-bridge.xethub.hf.co','us.aws.cdn.hf.co'))
    return p.hostname


class Redirect(urllib.request.HTTPRedirectHandler):
    def __init__(self): self.hosts=[]
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        self.hosts.append(safe_url(newurl))
        require(len(self.hosts)<=8)
        return super().redirect_request(req,fp,code,msg,headers,newurl)


def selected(manifest, model=DEFAULT):
    require(manifest['sha']==model['revision'])
    rows=[r for r in manifest['siblings'] if not r['rfilename'].startswith(model['exclude'])]
    require(len(rows)==model['files'] and sum(r['size'] for r in rows)==model['total'])
    require(len({r['rfilename'] for r in rows})==len(rows))
    for r in rows:
        relative(r['rfilename']); require(type(r['size']) is int and r['size']>=0)
        if r.get('lfs'): require(re.fullmatch('[0-9a-f]{64}',r['lfs']['sha256']) and r['lfs']['size']==r['size'])
        else: require(re.fullmatch('[0-9a-f]{40}',r['blobId']))
    return rows


def disk_gate(remaining, used, free, model=DEFAULT):
    require(used+remaining<=model['used_limit'] and free-remaining>=model['free_after'])


def acquire(row, root, open_url, base=BASE):
    rel=relative(row['rfilename']); root=root.resolve(); dest=root.joinpath(*rel.parts)
    require(dest.parent.resolve().is_relative_to(root))
    dest.parent.mkdir(parents=True,exist_ok=True)
    partial=dest.with_name(dest.name+'.partial')
    require(not dest.exists() and not dest.is_symlink() and not partial.exists() and not partial.is_symlink())
    sha=hashlib.sha256(); git=hashlib.sha1(b'blob '+str(row['size']).encode()+b'\0') if not row.get('lfs') else None
    count=0; start=time.monotonic()
    with open_url(base+urllib.parse.quote(str(rel))) as response, partial.open('xb') as out:
        if hasattr(response,'headers'):
            length=response.headers.get('Content-Length')
            require(length is None or int(length)==row['size'])
            require(response.headers.get('Content-Encoding','identity')=='identity')
            safe_url(response.geturl()); require(response.status==200)
        while True:
            require(time.monotonic()-start<3600)
            data=response.read(min(1024**2,row['size']-count+1))
            if not data: break
            count+=len(data); require(count<=row['size'])
            sha.update(data)
            if git is not None: git.update(data)
            out.write(data)
        require(count==row['size'])
        require(sha.hexdigest()==row['lfs']['sha256'] if row.get('lfs') else git.hexdigest()==row['blobId'])
        out.flush(); os.fsync(out.fileno())
    partial.rename(dest)
    return dict(path=str(rel),bytes=count,sha256=sha.hexdigest(),verification='lfs_sha256' if git is None else 'git_blob_sha1',seconds=time.monotonic()-start)


def verify_existing(row, root):
    """Recheck locally; never fetch or trust only an acquisition report."""
    p=root.joinpath(*relative(row['rfilename']).parts)
    require(not p.is_symlink() and p.resolve().is_relative_to(root.resolve()) and p.stat().st_size==row['size'])
    sha=hashlib.sha256(); git=hashlib.sha1(b'blob '+str(row['size']).encode()+b'\0')
    with p.open('rb') as f:
        for b in iter(lambda:f.read(1024**2),b''): sha.update(b);git.update(b)
    require(sha.hexdigest()==row['lfs']['sha256'] if row.get('lfs') else git.hexdigest()==row['blobId'])
    return dict(path=row['rfilename'],bytes=row['size'],sha256=sha.hexdigest(),verification='lfs_sha256' if row.get('lfs') else 'git_blob_sha1')


def continuation(rows, root, previous_report, failure_report, count, verified_bytes):
    """One approved continuation: the failed report's files must be the exact
    manifest prefix, are rehashed locally (never refetched), and no partial may
    exist. The failed report is preserved under a new name, never overwritten.
    """
    previous=json.loads(previous_report.read_text())
    require(previous['status']=='failed' and len(previous['files'])==count)
    require([r['path'] for r in previous['files']]==[r['rfilename'] for r in rows[:count]])
    require(sum(r['bytes'] for r in previous['files'])==verified_bytes==sum(r['size'] for r in rows[:count]))
    require(not list(root.rglob('*.partial')) and not failure_report.exists())
    files=[verify_existing(r,root) for r in rows[:count]]
    previous_report.rename(failure_report)
    return files,rows[count:]


def usage(root):
    return int(subprocess.check_output(['du','-sx','-B1',str(root)],text=True).split()[0])


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--manifest',type=Path,required=True);p.add_argument('--destination',type=Path,required=True)
    p.add_argument('--budget-root',type=Path,required=True);p.add_argument('--confirm-fixed-download',action='store_true')
    p.add_argument('--model-profile',choices=sorted(MODELS),default='yamz-247ef39b')
    # One explicitly approved continuation per invocation; no partial resume.
    p.add_argument('--continue-from');p.add_argument('--preserve-failure-as');p.add_argument('--report')
    p.add_argument('--expected-verified-files',type=int);p.add_argument('--expected-verified-bytes',type=int)
    a=p.parse_args();require(a.confirm_fixed_download)
    os.umask(0o077)
    model=MODELS[a.model_profile];total=model['total']
    rows=selected(json.loads(a.manifest.read_text()),model)
    require(a.destination.is_absolute() and a.destination.resolve()==a.destination)
    require(a.destination.is_relative_to(a.budget_root.resolve()))
    result=dict(repo=model['repo'],revision=model['revision'],expected_bytes=total,files=[],status='started',source_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest())
    if a.continue_from:
        names=(a.continue_from,a.preserve_failure_as,a.report)
        require(all(n and relative(n).parts==(n,) and n.endswith('.json') for n in names) and len(set(names))==3)
        report=a.destination/a.report
        require(not report.exists())
        result['files'],rows=continuation(rows,a.destination,a.destination/a.continue_from,a.destination/a.preserve_failure_as,
                                          a.expected_verified_files,a.expected_verified_bytes)
        result['continued_from']=a.preserve_failure_as
    else:
        require(not a.destination.exists());a.destination.mkdir(mode=0o700)
        report=a.destination/'acquisition.json'
    disk_gate(total-sum(r['bytes'] for r in result['files']),usage(a.budget_root),shutil.disk_usage(a.budget_root).free,model)
    try:
        for row in rows:
            remaining=total-sum(r['bytes'] for r in result['files'])
            disk_gate(remaining,usage(a.budget_root),shutil.disk_usage(a.budget_root).free,model)
            redirect=Redirect()
            opener=urllib.request.build_opener(redirect)
            def fetch(url):
                safe_url(url)
                return opener.open(urllib.request.Request(url,headers={'Accept-Encoding':'identity'}),timeout=180)
            item=acquire(row,a.destination,fetch,model['base'])
            item['redirect_hosts']=redirect.hosts
            result['files'].append(item)
            report.write_text(json.dumps(result,indent=2)+'\n')
            print(json.dumps(dict(verified=item['path'],bytes=item['bytes'],total_verified=sum(r['bytes'] for r in result['files']))),flush=True)
        result['status']='verified'
    except BaseException as error:
        result.update(status='failed',error_type=type(error).__name__)
        # Exception strings may contain signed URLs; never log them.
        print('fixed_acquisition_failed:'+type(error).__name__,flush=True)
        raise SystemExit(1) from None
    finally: report.write_text(json.dumps(result,indent=2)+'\n')

if __name__=='__main__': main()
