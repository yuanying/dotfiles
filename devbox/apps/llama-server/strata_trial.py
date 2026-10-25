#!/usr/bin/env python3
"""The short Strata trial: fixed requests against one running server, serial.

Same fixed sets as the Kyojin trial (kyojin_infer: smoke gates, tool-heavy,
over-refusal OFF/ON, the Japanese set, the needle corpus) plus long outputs
checked for repetition loops, 8K/32K/128K prompt speed and probes of the
OpenAI-compatible fields pi and natsumi send. Strata has no /tokenize, so
long prompts are sized from the 8K request's reported prompt tokens.
Generated code and tool calls never run; replies are kept privately.
"""
import argparse
import hashlib
import http.client
import json
from pathlib import Path
import re
import time

import kyojin_infer as infer

MODEL_ID='qwen3.8-flash-next'
SMOKE_SHA=infer.SMOKE_SHA
CORPUS_SHA=infer.CORPUS_SHA


class Budget:
    """Every POST counts, generated or not."""
    def __init__(self,requests=100):
        self.requests=0;self.max_requests=requests
    def reserve(self):
        infer.require(self.requests<self.max_requests,'budget_exceeded');self.requests+=1


def deadline(prompt_tokens):
    return 300 if prompt_tokens<=40000 else 900


# A unit of 2 to 16 characters repeated 10 times or more in a row ("24 24 24 ..."), or one non-space
# character 32 times; whitespace-only units do not count. Markdown rules and table rows stay below both.
LOOP_UNIT=re.compile(r'(.{2,16}?)\1{9,}',re.S)
LOOP_CHAR=re.compile(r'(\S)\1{31,}')


def repetition(text):
    """The first repetition loop in `text`, or None."""
    found=[]
    for m in LOOP_UNIT.finditer(text):
        # a run of one character is LOOP_CHAR's
        if m[1].strip() and len(set(m[1]))>1:found.append(m);break
    found+=[m for m in [LOOP_CHAR.search(text)] if m]
    if not found:return None
    m=min(found,key=lambda m:m.start())
    return dict(unit=m[1],count=len(m[0])//len(m[1]),at=m.start())


def base(prompt,think=False,max_tokens=256):
    # chat_template_kwargs is the form the production smoke and pi send.
    r=dict(model=MODEL_ID,messages=[dict(role='user',content=prompt)],max_tokens=max_tokens,temperature=0,top_p=1,top_k=0,min_p=0,seed=42,
           chat_template_kwargs=dict(enable_thinking=think))
    if think:r['reasoning_effort']='low'
    return r


def sse_times(raw_events):
    """(first visible delta, last delta) arrival in ns from [(t_ns, event_text)]."""
    first=last=None
    for t,data in raw_events:
        if not data or data=='[DONE]':continue
        e=json.loads(data)
        for c in e.get('choices',[]):
            d=c.get('delta',{})
            if any(d.get(k) for k in ('content','reasoning_content','reasoning','tool_calls')):
                first=t if first is None else first;last=t
    return first,last


def speed(start,first,last,usage):
    if first is None or not usage:return None
    out=dict(ttft_s=(first-start)/1e9,prompt_tokens=usage.get('prompt_tokens'),completion_tokens=usage.get('completion_tokens'))
    out['prefill_tps']=out['prompt_tokens']/out['ttft_s'] if out['prompt_tokens'] and out['ttft_s']>0 else None
    n=out['completion_tokens'] or 0
    out['decode_tps']=(n-1)/((last-first)/1e9) if n>1 and last>first else None
    return out


def lines_for(target,base_lines,base_tokens,fixed_tokens):
    """Filler lines for about `target` prompt tokens, from one measured request; 2 % under for safety."""
    per=(base_tokens-fixed_tokens)/base_lines
    infer.require(per>0,'calibration')
    return int((target*0.98-fixed_tokens)/per)//2*2


class Client:
    def __init__(self,directory,budget,host,port,ctx):
        self.d=directory;self.budget=budget;self.host=host;self.port=port;self.ctx=ctx;self.rows=[]
    def bind(self,refs):
        self.smoke=infer.pinned(refs/'reference-config/smoke.py',SMOKE_SHA)
        corpus=refs/'reference-plan/benchmark-cases.json'
        infer.require(hashlib.sha256(corpus.read_bytes()).hexdigest()==CORPUS_SHA,'corpus_hash')
        self.corpus=json.loads(corpus.read_text())
        return self
    def get(self,path):
        conn=http.client.HTTPConnection(self.host,self.port,timeout=30)
        try:
            conn.request('GET',path);r=conn.getresponse();data=r.read(1024**2)
            return r.status,json.loads(data) if data else None
        finally:conn.close()
    def save(self,name,request):
        infer.require(not (self.d/'STOP').exists(),'external_abort')
        self.budget.reserve();(self.d/'budget.json').write_text(json.dumps(vars(self.budget)))
        body=json.dumps(request,ensure_ascii=False).encode();infer.require(len(body)<=4*1024**2)
        infer.require(not (self.d/(name+'.request.json')).exists(),'duplicate_request')
        (self.d/(name+'.request.json')).write_bytes(body)
        return body
    def post(self,name,request):
        """Non-streamed: the status and body as the server answers them (API probes)."""
        body=self.save(name,dict(request,stream=False))
        conn=http.client.HTTPConnection(self.host,self.port,timeout=300)
        start=time.monotonic()
        try:
            conn.request('POST','/v1/chat/completions',body=body,headers={'Content-Type':'application/json'})
            r=conn.getresponse();data=r.read(4*1024**2)
        finally:conn.close()
        (self.d/(name+'.reply.json')).write_bytes(data)
        try:reply=json.loads(data)
        except ValueError:reply=None
        row=dict(name=name,status=r.status,seconds=time.monotonic()-start,keys=sorted(reply) if isinstance(reply,dict) else None)
        self.record(row);return r.status,reply,row
    def send(self,name,request,case=None,tool=None,prompt_estimate=0):
        infer.require(prompt_estimate+request['max_tokens']+8<=self.ctx,'context_budget')
        request=dict(request,stream=True,stream_options=dict(include_usage=True))
        body=self.save(name,request)
        limit=deadline(prompt_estimate)
        conn=http.client.HTTPConnection(self.host,self.port,timeout=limit)
        events=[];start=time.monotonic_ns();buf=b''
        try:
            conn.request('POST','/v1/chat/completions',body=body,headers={'Content-Type':'application/json'})
            r=conn.getresponse()
            with (self.d/(name+'.sse')).open('xb') as raw:
                while True:
                    infer.require(not (self.d/'STOP').exists(),'external_abort')
                    infer.require(time.monotonic_ns()-start<limit*1e9,'deadline')
                    chunk=r.read1(65536) if hasattr(r,'read1') else r.read(65536)
                    if not chunk:break
                    raw.write(chunk);buf+=chunk;now=time.monotonic_ns()
                    infer.require(len(buf)<=8*1024**2,'stream_bytes')
                    while b'\n\n' in buf:
                        event,buf=buf.split(b'\n\n',1)
                        data='\n'.join(l[5:].lstrip(' ') for l in event.decode('utf-8').replace('\r','').splitlines() if l.startswith('data:'))
                        events.append((now,data))
            infer.require(r.status==200,'http_error_%d'%r.status)
        finally:conn.close()
        reply=infer.reply_from_sse((self.d/(name+'.sse')).read_bytes())
        (self.d/(name+'.reply.json')).write_text(json.dumps(reply,ensure_ascii=False))
        first,last=sse_times(events)
        choice=reply['choices'][0];msg=choice['message'];text=msg.get('content') or ''
        quality=infer.score(case,reply) if case else dict(status='not_scored')
        if tool:
            quality=dict(status='inconclusive_length' if choice['finish_reason']=='length' else 'pass' if choice['finish_reason']=='tool_calls' and infer.tool_ok(msg,*tool) else 'fail')
        # kyojin_infer.base (the over-refusal set) names it at the top level, as before.
        think=request.get('chat_template_kwargs',{}).get('enable_thinking',request.get('enable_thinking',True))
        row=dict(name=name,request_sha256=hashlib.sha256(body).hexdigest(),usage=reply['usage'],finish=choice['finish_reason'],
                 speed=speed(start,first,last,reply['usage']),quality=quality,thinking_requested=think,
                 thinking_observed=bool(msg.get('reasoning_content')),usage_in_stream=reply['usage'] is not None,
                 repetition=repetition(text),reasoning_repetition=repetition(msg.get('reasoning_content') or ''),
                 extra=reply.get('timings'))
        if case=='math' and quality['status']=='pass' and row['thinking_observed']!=think:quality['status']='fail_thinking_path'
        self.record(row);return reply,row
    def record(self,row):
        self.rows.append(row)
        with (self.d/'results.jsonl').open('a') as out:out.write(json.dumps(row,ensure_ascii=False)+'\n')
        print(json.dumps(dict(done=row['name'],quality=row.get('quality',{}).get('status'),status=row.get('status'),speed=row.get('speed'),repetition=row.get('repetition'))),flush=True)


def gates(c,vision):
    for case in ('japanese','thinking-off','thinking-on'):
        req=c.smoke.request(case);req.update(top_p=1,top_k=0,min_p=0);req.pop('stream',None)
        c.send('gate-'+case,req,case='japanese' if case=='japanese' else 'math')
    req=c.smoke.request('tool');req['tool_choice']='auto';req.pop('stream',None)
    c.send('gate-auto-tool',req,tool=('get_temperature',{'city':'東京'}))
    th=c.corpus['tool_heavy'];messages=[]
    for i,prompt in enumerate(th['user_turns']):
        messages.append(dict(role='user',content=prompt));req=base(prompt);req.update(messages=messages.copy(),tools=th['tools'],tool_choice='auto')
        reply,row=c.send(f'gate-tool-heavy-{i}',req,case='total' if i==2 else None,tool=(('lookup_stock' if i==0 else 'lookup_price'),{'sku':'SKU-42'}) if i<2 else None)
        if i<2:
            if row['quality']['status']!='pass':break   # no fabricated tool chain
            msg=reply['choices'][0]['message'];messages.append(msg)
            messages.append(dict(role='tool',tool_call_id=msg['tool_calls'][0]['id'],content=json.dumps(th['synthetic_results'][i])))
    if vision:
        for i,q in enumerate(c.corpus['vision']['questions']):
            req=base(q);req['messages'][0]['content']=[dict(type='text',text=q),dict(type='image_url',image_url=dict(url='data:image/png;base64,'+c.corpus['vision']['base64']))]
            c.send(f'gate-vision-{i}',req,case='red' if i==0 else 'solid')


def probes(c):
    """The OpenAI-compatible fields as they are answered; recorded, not required."""
    status,models=c.get('/v1/models')
    c.record(dict(name='probe-models',status=status,ids=[m.get('id') for m in (models or {}).get('data',[])]))
    tool=c.smoke.request('tool');tool.pop('stream',None)
    c.post('probe-tool-forced',tool)
    c.post('probe-tool-required',dict(tool,tool_choice='required'))
    schema=dict(type='object',properties=dict(city=dict(type='string'),population=dict(type='integer')),required=['city','population'],additionalProperties=False)
    c.post('probe-json-schema',dict(base('東京の名前と人口（概数の整数）をJSONで返してください。'),response_format=dict(type='json_schema',json_schema=dict(name='city',strict=True,schema=schema))))
    c.post('probe-json-object',dict(base('東京の名前と人口をJSONオブジェクトで返してください。'),response_format=dict(type='json_object')))
    c.post('probe-logprobs',dict(base('日本の首都は？一語で。',max_tokens=8),logprobs=True,top_logprobs=2))
    # reasoning_effort alone, without chat_template_kwargs.
    r=base('17×19はいくつですか。日本語で短く答えてください。');r.pop('chat_template_kwargs');r['reasoning_effort']='none'
    c.send('probe-effort-none',r,case='math')


LONG_OUTPUTS=(
    ('long-history','日本の歴史を、縄文時代から令和まで時代ごとに見出しを付けて、できるだけ詳しく日本語で解説してください。',2048,False),
    ('long-table','1から120までの整数それぞれについて、その数・2乗・3乗・素数かどうかをMarkdownの表で一行ずつ書いてください。省略しないでください。',2048,False),
    ('long-story','港町を舞台にした長い短編小説を日本語で書いてください。登場人物の会話を多めにしてください。',1536,False),
    ('long-design','小さなWebアプリのREST APIを設計し、エンドポイントごとの仕様と例をできるだけ詳しく日本語で書いてください。',1536,True),
)


def long_outputs(c):
    for name,prompt,n,think in LONG_OUTPUTS:c.send(name,base(prompt,think,n),prompt_estimate=200)


def cold_text(lc,prompt,lines,run):
    """The needle text with a run tag first: Strata's conversation cache reuses a shared prefix, so a repeat
    that differed only at the end would be read warm."""
    return f'（測定 {run}）\n'+infer.long_text(lc,prompt,lines)


def prompt_speed(c,tiers=(('32K',32000,2),('128K',128000,1)),max_tokens=256,warm=False):
    """8K twice, then each tier sized from the 8K's prompt tokens; with `warm`, the last tier's last prompt again."""
    lc=c.corpus['long_input_contract'];prompt=c.corpus['tasks']['prose']['prompt']
    lines=lc['nominal_tiers']['8K'];run=0;measured=None
    for r in range(2):
        _,row=c.send(f'8K-prose-cold-{r}',base(cold_text(lc,prompt,lines,run),max_tokens=max_tokens),case='prose',prompt_estimate=9000)
        run+=1;measured=measured or row['usage']['prompt_tokens']
    fixed=40;text=None
    for tier,target,repeat in tiers:
        if target+max_tokens+300>c.ctx:continue
        n=lines_for(int(target/0.98),lines,measured,fixed)
        with (c.d/'calibration.jsonl').open('a') as out:out.write(json.dumps(dict(tier=tier,lines=n,base_lines=lines,base_tokens=measured))+'\n')
        for r in range(repeat):
            text=cold_text(lc,prompt,n,run);run+=1
            c.send(f'{tier}-prose-cold-{r}',base(text,max_tokens=max_tokens),case='prose',prompt_estimate=target)
    if warm and text is not None:
        c.send(f'{tier}-prose-warm-0',base(text,max_tokens=max_tokens),case='prose',prompt_estimate=target)


def japanese(c):
    for case in infer.japanese_cases():
        reply,row=c.send(f"ja-{case['id']}",base(case['prompt'],max_tokens=infer.JA_MAX_TOKENS))
        ch=reply['choices'][0]
        with (c.d/'japanese.jsonl').open('a') as out:
            out.write(json.dumps(dict(name=row['name'],kind=case['kind'],finish=ch['finish_reason'],usage=row['usage'],content=ch['message'].get('content')),ensure_ascii=False)+'\n')


def suite_trial(c,refs):
    c.bind(refs)
    _,health=c.get('/health')
    gates(c,bool((health or {}).get('images')))
    probes(c)
    infer.refusal_suite(c)
    japanese(c)
    long_outputs(c)
    prompt_speed(c)


def suite_smoke(c,refs):
    c.bind(refs)
    _,health=c.get('/health')
    gates(c,bool((health or {}).get('images')))


def suite_perf(c,refs,extras=True):
    """serve-3 (CPU capped): 128K cold three times and warm once, 8K and 32K to compare, then what serve-1 left."""
    c.bind(refs)
    for case in ('japanese','thinking-off'):
        req=c.smoke.request(case);req.update(top_p=1,top_k=0,min_p=0);req.pop('stream',None)
        c.send('gate-'+case,req,case='japanese' if case=='japanese' else 'math')
    prompt_speed(c,tiers=(('32K',32000,2),('128K',127000,3)),max_tokens=768,warm=True)
    if not extras:return
    for case in infer.refusal_cases():
        reply,row=c.send(f"refusal-{case['id']}-think1",dict(infer.base(case['prompt'],True),max_tokens=512))
        with (c.d/'refusal.jsonl').open('a') as out:out.write(json.dumps(dict(name=row['name'],refusal_class=infer.refusal_class(reply),finish=reply['choices'][0]['finish_reason'],usage=row['usage']))+'\n')
    japanese(c)
    long_outputs(c)


SUITES=dict(trial=suite_trial,smoke=suite_smoke,perf=suite_perf)


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--directory',type=Path,required=True);p.add_argument('--references',type=Path,required=True)
    p.add_argument('--target',type=infer.target,required=True,metavar='HOST:PORT')
    p.add_argument('--ctx',type=int,default=262144);p.add_argument('--suite',choices=sorted(SUITES),default='trial')
    p.add_argument('--max-requests',type=int,default=100)
    a=p.parse_args();infer.require(a.directory.stat().st_mode&0o077==0)
    SUITES[a.suite](Client(a.directory,Budget(a.max_requests),a.target[0],a.target[1],a.ctx),a.references)

if __name__=='__main__':main()
