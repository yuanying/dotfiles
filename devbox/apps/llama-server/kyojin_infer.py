#!/usr/bin/env python3
"""Fixed synthetic scoring and serial live adapter; generated code/tools never run.

Requires preserved hash-pinned PR156/160/162/165 references, not copies.
Private replies are not printed. Resource supervision is a separate prerequisite.
"""
import argparse
import ast
import hashlib
import http.client
import importlib.util
import json
import os
from pathlib import Path
import re
import time

SMOKE_SHA='9364396b4882299d0e23b332eda7a89698f71c471e1d8027d4d16582f5844bab'
COLLECTOR_SHA='626a173a461267954275ecc85c34509ad74279d4581c17f0fd308d7f346c07e3'
CORPUS_SHA='81426b78ce8bf0bcb9b32e98e5ba10651119ab4d79453424e5268ee4663f65da'
LIVE_SHA='ca6a611d5b47da2b3a2ad6f5cd4250220cb3f4f182c29644d5894126535cde5c'
NEEDLES=('青い彗星','銀の灯台','赤い砂丘')


def require(ok,message='infer_contract'):
    if not ok: raise ValueError(message)


def pinned(path,digest):
    require(hashlib.sha256(Path(path).read_bytes()).hexdigest()==digest,'reference_hash')
    s=importlib.util.spec_from_file_location('reference_'+Path(path).stem,path)
    m=importlib.util.module_from_spec(s);s.loader.exec_module(m);return m


class Budget:
    def __init__(self,requests=152,completion=41984):
        self.requests=0; self.completion=0; self.long=0; self.max_requests=requests; self.max_completion=completion
    def reserve(self,cap):
        require(type(cap) is int and (1<=cap<=256 or cap==1024))
        require(self.requests<self.max_requests and self.completion+cap<=self.max_completion and (cap!=1024 or self.long<4),'budget_exceeded')
        self.requests+=1; self.completion+=cap; self.long+=int(cap==1024)


def deadline(prompt_tokens):
    """Per-request wall limit by actual prompt size (prefill ~1200+ tok/s)."""
    return 180 if prompt_tokens<=40000 else 600 if prompt_tokens<=140000 else 900


def long_text(c,prompt,lines):
    return c['needle_start']+c['filler_line']*(lines//2)+c['needle_middle']+c['filler_line']*(lines//2)+c['needle_end']+prompt


def timing(now,start,previous,limit):
    require(now-start<limit,'deadline');require(now-previous<=5,'monitor_gap')


def preset_active(log,path):
    return ' -- ablit runtime: spec '+str(path)+' active ' in log


def tool_ok(message,name,expected):
    try:
        calls=message['tool_calls'];require(len(calls)==1)
        c=calls[0];require(c['type']=='function' and bool(c['id'].strip()))
        return c['function']['name']==name and json.loads(c['function']['arguments'])==expected
    except (KeyError,ValueError,TypeError,AttributeError): return False


def code_ok(text):
    """Match a narrow expected AST, never compile/exec/eval model output."""
    try:
        require(all(n in text for n in NEEDLES) and [text.index(n) for n in NEEDLES]==sorted(text.index(n) for n in NEEDLES))
        text=re.sub(r'^```(?:python)?\s*\n|\n```\s*$','',text.strip())
        actual=ast.parse(text)
        expected=ast.parse('def even_only(values):\n return [x for x in values if x % 2 == 0]\n')
        return ast.dump(actual,include_attributes=False)==ast.dump(expected,include_attributes=False)
    except (SyntaxError,ValueError): return False


def score(case,reply):
    choice=reply['choices'][0];msg=choice['message'];finish=choice['finish_reason'];text=msg.get('content') or ''
    if finish=='length': return dict(status='inconclusive_length')
    if finish not in ('stop','tool_calls'): return dict(status='fail')
    if case=='math': ok=bool(re.fullmatch(r'(?:答えは\s*)?(?:17\s*[×*]\s*19\s*[=＝は]\s*)?(?:\*\*323\*\*|323)\s*(?:です)?[。.!！]?',text.strip()))
    elif case=='code': ok=finish=='stop' and code_ok(text)
    elif case=='prose':
        ok=finish=='stop' and all(n in text for n in NEEDLES) and [text.index(n) for n in NEEDLES]==sorted(text.index(n) for n in NEEDLES) and re.search('[ぁ-ん一-龯]',text) is not None
        return dict(status='needs_semantic_review' if ok else 'fail',rubric='Needles exact/in order; daytime land warms faster than sea; ascending land air draws sea breeze; no reversed claim')
    elif case=='red': ok=finish=='stop' and bool(re.fullmatch('赤(?:色)?[。.!！]?',text.strip()))
    elif case=='solid': ok=finish=='stop' and bool(re.fullmatch('はい[。.!！]?',text.strip()))
    elif case=='total': ok=finish=='stop' and re.search(r'(?<!\d)2,?100(?!\d)',text) is not None
    elif case=='japanese':
        ok=finish=='stop' and bool(text.strip()) and re.search('[ぁ-ん一-龯]',text) is not None
        return dict(status='needs_semantic_review' if ok else 'fail',rubric='Rayleigh scattering: shorter blue wavelengths scatter more in atmosphere; Japanese coherent nonempty answer')
    else: raise ValueError('unknown_score')
    return dict(status='pass' if ok else 'fail')


def reply_from_sse(raw):
    """Assemble saved bounded API fields for existing smoke validator, no execution."""
    require(len(raw)<=4*1024**2)
    msg=dict(role='assistant',content='',reasoning_content='');calls={};finish=None;usage=None;timings=None;done=False
    for event in raw.decode('utf-8').replace('\r\n','\n').split('\n\n'):
        data='\n'.join(line[5:].lstrip(' ') for line in event.splitlines() if line.startswith('data:'))
        if not data: continue
        if data=='[DONE]':done=True;continue
        e=json.loads(data);require('error' not in e,'server_error')
        if e.get('usage') is not None:usage=e['usage']
        if e.get('timings') is not None:timings=e['timings']
        for c in e.get('choices',[]):
            require(c.get('index',0)==0)
            delta=c.get('delta',{})
            for key in ('content','reasoning_content','reasoning'):
                if delta.get(key) is not None:
                    require(isinstance(delta[key],str));msg['reasoning_content' if key=='reasoning' else key]+=delta[key]
            for call in delta.get('tool_calls',[]):
                i=call.get('index',0);r=calls.setdefault(i,dict(id='',type='function',function=dict(name='',arguments='')))
                for k in ('id','type'):
                    if call.get(k):r[k]=call[k]
                for k in ('name','arguments'):
                    if call.get('function',{}).get(k):r['function'][k]+=call['function'][k]
            if c.get('finish_reason') is not None:finish=c['finish_reason']
    require(done and finish is not None,'truncated_stream')
    if calls:msg['tool_calls']=[calls[k] for k in sorted(calls)]
    return dict(choices=[dict(message=msg,finish_reason=finish)],usage=usage,timings=timings)


class ColdPolicy:
    """The fixed server rejects cache_prompt:false with --sessions>1. A new
    unique cache_salt drops the prompt cache instead (documented in SERVE.md);
    warm requests reuse the last cold salt so they hit that cache."""
    def __init__(self,sessions):self.sessions=sessions;self.salt=None
    def apply(self,name,request):
        if self.sessions==1 or 'cache_prompt' not in request:return request
        request=dict(request);cold=request.pop('cache_prompt') is False
        if cold:self.salt=name
        require(self.salt is not None,'warm_without_prime')
        request['cache_salt']=self.salt;return request


class Capture:
    """Preserve a budget-ended response while keeping strict collector errors.

    A collector rejection is retained, not made into a successful metric. The
    raw body continues only within the original byte/deadline limits so length
    can be reported as inconclusive rather than unsupported API.
    """
    def __init__(self,collector):self.c=collector;self.error=None;self.bytes=0
    def headers(self,*args):return self.c.headers(*args)
    def feed(self,at,chunk):
        self.bytes+=len(chunk);require(self.bytes<=4*1024**2,'stream_bytes')
        if self.error is None:
            try:self.c.feed(at,chunk)
            except Exception as error:self.error=type(error).__name__
    def finish(self,at):
        if self.error:return dict(measurement_error=self.error)
        try:return self.c.finish(at)
        except Exception as error:return dict(measurement_error=type(error).__name__)


class Client:
    def __init__(self,directory,refs,budget,ctx=32768,sessions=1):
        self.d=directory;self.budget=budget;self.rows=[];self.template_cache={};self.ctx=ctx;self.cold=ColdPolicy(sessions)
        self.smoke=pinned(refs/'reference-config/smoke.py',SMOKE_SHA)
        self.collector=pinned(refs/'reference-measure/stream_metrics.py',COLLECTOR_SHA)
        self.live=pinned(refs/'reference-trial/qwen_stream_live.py',LIVE_SHA)
        corpus=refs/'reference-plan/benchmark-cases.json'
        require(hashlib.sha256(corpus.read_bytes()).hexdigest()==CORPUS_SHA)
        self.corpus=json.loads(corpus.read_text())
    def metadata(self,path,body=None):
        conn=http.client.HTTPConnection('127.0.0.1',18082,timeout=120)
        try:
            conn.request('POST' if body else 'GET',path,body=json.dumps(body).encode() if body else None,headers={'Content-Type':'application/json'})
            r=conn.getresponse();data=r.read(8*1024**2+1);require(len(data)<=8*1024**2 and r.status==200,'metadata_error');return json.loads(data)
        finally:conn.close()
    def send(self,name,request,case=None,tool=None):
        require(not (self.d/'STOP').exists(),'external_abort')
        self.budget.reserve(request['max_tokens'])
        (self.d/'budget.json').write_text(json.dumps(vars(self.budget)))
        request=dict(self.cold.apply(name,request),stream=True,n=1)
        body=json.dumps(request,ensure_ascii=False).encode();require(len(body)<=4*1024**2)
        require(not (self.d/(name+'.request.json')).exists(),'duplicate_request')
        (self.d/(name+'.request.json')).write_bytes(body)
        # Actual renderer and tokenizer, no generation; record before sole send.
        has_image=any(isinstance(m.get('content'),list) for m in request['messages'])
        render_key=json.dumps({k:request[k] for k in ('messages','tools','chat_template_kwargs','enable_thinking','reasoning_effort') if k in request},sort_keys=True)
        if render_key not in self.template_cache:
            rendered=self.metadata('/apply-template',request)
            # Fixed server explicitly rejects image messages on /tokenize.
            # Placeholder count is pre-vision only, not actual image tokens.
            tokenized=self.metadata('/tokenize',dict(prompt=rendered['prompt'],add_special_tokens=False) if has_image else request)
            self.template_cache[render_key]=(rendered,tokenized)
        else:rendered,tokenized=self.template_cache[render_key]
        (self.d/(name+'.template.json')).write_text(json.dumps(rendered,ensure_ascii=False))
        # Server reply_room: ctx rounded to pages - prompt - 1 - draft window(7).
        require(tokenized['count']+request['max_tokens']+8+(4096 if has_image else 0)<=self.ctx//256*256,'context_budget')
        limit=deadline(tokenized['count'])
        conn=http.client.HTTPConnection('127.0.0.1',18082,timeout=limit)
        start=time.monotonic_ns();capture=Capture(self.collector.Collector(start,timeout_seconds=limit,max_output_tokens=request['max_tokens']))
        try:
            conn.request('POST','/v1/chat/completions',body=body,headers={'Content-Type':'application/json'})
            sock=conn.sock
            def remaining():
                require(not (self.d/'STOP').exists(),'external_abort')
                left=limit-(time.monotonic_ns()-start)/1e9
                if left<=0:raise TimeoutError('deadline')
                if sock:sock.settimeout(left)
            remaining();response=conn.getresponse()
            with (self.d/(name+'.sse')).open('xb') as raw:
                metrics=self.live.receive(response,capture,raw,before_read=remaining)
            require(response.status==200,'http_error')
        finally:conn.close()
        reply=reply_from_sse((self.d/(name+'.sse')).read_bytes())
        (self.d/(name+'.reply.json')).write_text(json.dumps(reply,ensure_ascii=False))
        require(reply['usage'] is not None and reply['usage']['completion_tokens']<=request['max_tokens'],'usage_budget')
        if not has_image:require(reply['usage']['prompt_tokens']==tokenized['count'],'token_count_mismatch')
        if 'measurement_error' in metrics:require(reply['choices'][0]['finish_reason']=='length','collector_error')
        quality=score(case,reply) if case else dict(status='not_scored')
        if tool:
            quality=dict(status='inconclusive_length' if reply['choices'][0]['finish_reason']=='length' else 'pass' if reply['choices'][0]['finish_reason']=='tool_calls' and tool_ok(reply['choices'][0]['message'],*tool) else 'fail')
        row=dict(name=name,preset=self.d.name,deadline_seconds=limit,request_sha256=hashlib.sha256(body).hexdigest(),template_sha256=hashlib.sha256(json.dumps(rendered,sort_keys=True).encode()).hexdigest(),input_tokens=reply['usage']['prompt_tokens'],prevision_or_text_tokens=tokenized['count'],usage=reply['usage'],timings=reply['timings'],quality=quality,metrics=metrics)
        thinking=request.get('enable_thinking',request.get('chat_template_kwargs',{}).get('enable_thinking',True))
        row['thinking_observed']=bool(reply['choices'][0]['message'].get('reasoning_content'))
        if case=='math' and row['quality']['status']=='pass' and row['thinking_observed']!=thinking:
            row['quality']['status']='fail_thinking_path'
        if isinstance(request.get('tool_choice'),dict):
            row['tool_control']='unsupported_ignored_by_fixed_server'
            row['quality']['observed_call_status']=row['quality']['status']
            row['quality']['status']='unsupported_forced_tool_choice'
        row['field_support']={'forced_tool_choice':'ignored_unsupported','penalties':'not_exposed_by_fixed_server; neutral engine defaults, not asserted request-effective'}
        self.rows.append(row)
        with (self.d/'results.jsonl').open('a') as out:out.write(json.dumps(row)+'\n')
        print(json.dumps(dict(completed=name,quality=quality['status'],usage=reply['usage'],metrics=metrics)),flush=True)
        return reply,row


def base(prompt,think=False):
    return dict(model='qwen3.8-flash-next',messages=[dict(role='user',content=prompt)],max_tokens=256,temperature=0,top_p=1,top_k=0,min_p=0,seed=42,enable_thinking=think,reasoning_effort='low' if think else 'none')


def suite(client,mode):
    # Short fixed gates before any 2K/8K workload. No failed request is resent.
    for case in ('japanese','thinking-off','thinking-on','tool'):
        req=client.smoke.request(case);req.update(stream=True,top_p=1,top_k=0,min_p=0)
        client.send(case,req,case='japanese' if case=='japanese' else 'math' if case.startswith('thinking') else None,tool=('get_temperature',{'city':'東京'}) if case=='tool' else None)
    req=client.smoke.request('tool');req['tool_choice']='auto';client.send('auto-tool',req,tool=('get_temperature',{'city':'東京'}))
    if mode=='on':
        th=client.corpus['tool_heavy'];messages=[];valid=True
        for i,prompt in enumerate(th['user_turns']):
            messages.append(dict(role='user',content=prompt));req=base(prompt);req.update(messages=messages.copy(),tools=th['tools'],tool_choice='auto')
            reply,row=client.send('tool-heavy-'+str(i),req,case='total' if i==2 else None,tool=(('lookup_stock' if i==0 else 'lookup_price'),{'sku':'SKU-42'}) if i<2 else None)
            if i<2:
                if row['quality']['status']!='pass':valid=False;break
                msg=reply['choices'][0]['message'];messages.append(msg)
                messages.append(dict(role='tool',tool_call_id=msg['tool_calls'][0]['id'],content=json.dumps(th['synthetic_results'][i])))
        for i,q in enumerate(client.corpus['vision']['questions']):
            req=base(q);req['messages'][0]['content']=[dict(type='text',text=q),dict(type='image_url',image_url=dict(url='data:image/png;base64,'+client.corpus['vision']['base64']))]
            client.send('vision-'+str(i),req,case='red' if i==0 else 'solid')
    # Fixed corpus, no prompt tuning. Native token counts are recorded per send.
    c=client.corpus['long_input_contract']
    for tier in ('2K','8K'):
        for task in (('prose','code') if mode=='on' else ('prose',)):
            n=c['nominal_tiers'][tier];text=c['needle_start']+c['filler_line']*(n//2)+c['needle_middle']+c['filler_line']*(n//2)+c['needle_end']+client.corpus['tasks'][task]['prompt']
            for think in ((False,True) if mode=='on' else (False,)):
                prefix=f'{tier}-{task}-think{int(think)}'
                for repeat in range(3):
                    req=base(text,think);req['cache_prompt']=False
                    client.send(prefix+'-cold-'+str(repeat),req,case=task)
                # Last cold is also the documented prime, then identical warm requests.
                for repeat in range(3):
                    req=base(text,think);req['cache_prompt']=True
                    client.send(prefix+'-warm-'+str(repeat),req,case=task)


def calibrate(client,task,target):
    """Largest filler count whose actual templated prompt is <= target tokens.
    Tokenizer-only (no generation); the chosen count and token total are recorded."""
    c=client.corpus['long_input_contract'];prompt=client.corpus['tasks'][task]['prompt']
    count=lambda n:client.metadata('/tokenize',base(long_text(c,prompt,n)))['count']
    one=max(1,(count(2048)-count(0))/2048)
    n=int((target-count(0))/one)//2*2
    for _ in range(8):
        tokens=count(n)
        if tokens<=target:break
        n-=int((tokens-target)/one)//2*2+2
    require(tokens<=target,'calibration_failed')
    with (client.d/'calibration.jsonl').open('a') as out:out.write(json.dumps(dict(task=task,target=target,lines=n,tokens=tokens))+'\n')
    return long_text(c,prompt,n)


def short_gates(client):
    for case in ('japanese','thinking-off','thinking-on'):
        req=client.smoke.request(case);req.update(stream=True,top_p=1,top_k=0,min_p=0)
        client.send('gate-'+case,req,case='japanese' if case=='japanese' else 'math')
    req=client.smoke.request('tool');req['tool_choice']='auto';client.send('gate-auto-tool',req,tool=('get_temperature',{'city':'東京'}))
    tool_heavy(client,'gate-tool-heavy')
    for i,q in enumerate(client.corpus['vision']['questions']):
        req=base(q);req['messages'][0]['content']=[dict(type='text',text=q),dict(type='image_url',image_url=dict(url='data:image/png;base64,'+client.corpus['vision']['base64']))]
        client.send(f'gate-vision-{i}',req,case='red' if i==0 else 'solid')


def tool_heavy(client,prefix):
    th=client.corpus['tool_heavy'];messages=[]
    for i,prompt in enumerate(th['user_turns']):
        messages.append(dict(role='user',content=prompt));req=base(prompt);req.update(messages=messages.copy(),tools=th['tools'],tool_choice='auto')
        reply,row=client.send(f'{prefix}-{i}',req,case='total' if i==2 else None,tool=(('lookup_stock' if i==0 else 'lookup_price'),{'sku':'SKU-42'}) if i<2 else None)
        if i<2:
            if row['quality']['status']!='pass':return  # no fabricated tool chain
            msg=reply['choices'][0]['message'];messages.append(msg)
            messages.append(dict(role='tool',tool_call_id=msg['tool_calls'][0]['id'],content=json.dumps(th['synthetic_results'][i])))


# User scope: daily use up to 128K. 128K prose quotes needle A at the very start (deepest).
LONG_TIERS=(('32K',32000),('128K',128000))


def suite_long(client,soak_seconds):
    short_gates(client)
    # Same frozen nominal-8K texts as the RAM-mode ctx32768 run, for a disk-mode comparison.
    c=client.corpus['long_input_contract']
    for task in ('prose','code'):
        text=long_text(c,client.corpus['tasks'][task]['prompt'],c['nominal_tiers']['8K'])
        for r in range(3):
            req=base(text);req['cache_prompt']=False;client.send(f'8K-{task}-think0-cold-{r}',req,case=task)
    texts={}
    for tier,target in LONG_TIERS:
        for task in ('prose','code'):texts[tier,task]=calibrate(client,task,target)
        for r in range(3):
            req=base(texts[tier,'prose']);req['cache_prompt']=False;client.send(f'{tier}-prose-cold-{r}',req,case='prose')
        for r in range(2):
            req=base(texts[tier,'prose']);req['cache_prompt']=True;client.send(f'{tier}-prose-warm-{r}',req,case='prose')
        req=base(texts[tier,'code']);req['cache_prompt']=False;client.send(f'{tier}-code-cold-0',req,case='code')
    # Mixed sustained use, bounded by time and the request budget. Fixed cycle.
    eight=long_text(client.corpus['long_input_contract'],client.corpus['tasks']['code']['prompt'],256)
    start=time.monotonic();cycle=0
    while time.monotonic()-start<soak_seconds:
        req=client.smoke.request('japanese');req.update(stream=True,top_p=1,top_k=0,min_p=0);client.send(f'soak{cycle}-japanese',req,case='japanese')
        req=client.smoke.request('tool');req['tool_choice']='auto';client.send(f'soak{cycle}-auto-tool',req,tool=('get_temperature',{'city':'東京'}))
        tool_heavy(client,f'soak{cycle}-tool-heavy')
        req=base(eight,True);client.send(f'soak{cycle}-8K-code-think1',req,case='code')
        req=base(texts['128K','prose']);req['cache_prompt']=False;client.send(f'soak{cycle}-128K-prose-cold',req,case='prose')
        if cycle%2==0:
            req=base(texts['32K','prose']);client.send(f'soak{cycle}-32K-prose',req,case='prose')
        else:
            req=base(texts['128K','code']);req['cache_prompt']=False;client.send(f'soak{cycle}-128K-code-cold',req,case='code')
        cycle+=1


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--directory',type=Path,required=True);p.add_argument('--references',type=Path,required=True);p.add_argument('--mode',choices=['on','off'],required=True)
    a=p.parse_args();os.umask(0o077);require(a.directory.stat().st_mode&0o077==0)
    client=Client(a.directory,a.references,Budget())
    suite(client,a.mode)

if __name__=='__main__':main()
