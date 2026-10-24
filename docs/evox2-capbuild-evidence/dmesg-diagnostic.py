# Bounded read-only reader stability diagnostic. No settings/service/build operations.
import hashlib,json,os,pathlib,re,subprocess,time
D=pathlib.Path('/home/yuanying/.local/state/herdr-tasks/evo-x2-qwen38-optimization/artifacts/capbuild-dmesg-diagnostic-20261023')
os.umask(0o077)
sha=lambda value:hashlib.sha256(value).hexdigest()
pattern=re.compile(r'^(?:<\d+>)?\[\s*([0-9]+(?:\.[0-9]+)?)\]\s?(.*)$')
fault=re.compile(r'(?:amdgpu|kfd|GPU).*(?:reset|fault|timeout|error|failed)|out of memory|oom-kill|machine check|mce:|hardware error|critical temperature|thermal.*critical',re.I)
variants=[('default',['dmesg'],dict(os.environ)),('stable',['dmesg','--color=never','--nopager','--force-prefix'],dict(os.environ,LC_ALL='C',TERM='dumb',NO_COLOR='1')),('raw',['dmesg','--raw'],dict(os.environ,LC_ALL='C',TERM='dumb',NO_COLOR='1'))]
previous={};records=[];details=[]
for cycle in range(3):
 for variant,command,env in variants:
  start=time.monotonic();data=subprocess.check_output(command,env=env,timeout=5)
  assert len(data)<=4*1024**2
  text=data.decode('utf-8',errors='replace');lines=text.splitlines();stripped=text.strip().splitlines()
  parsed=[pattern.match(line) for line in lines]
  rows=[(float(m[1]),m[2],line) for m,line in zip(parsed,lines) if m]
  canonical={f'{stamp:.6f} {body.rstrip()}' for stamp,body,_ in rows}
  bodyset={body.rstrip() for _,body,_ in rows}
  record=dict(cycle=cycle,variant=variant,argv=command,elapsed_seconds=time.monotonic()-start,monotonic=start,stdout_bytes=len(data),stdout_sha256=sha(data),line_count=len(lines),parsed_count=len(rows),unparsed_lines=len(lines)-len(rows),first_timestamp=rows[0][0] if rows else None,last_timestamp=rows[-1][0] if rows else None,escape_count=data.count(b'\x1b'),last_line_trailing_whitespace=len(lines[-1])-len(lines[-1].rstrip()) if lines else 0,last_line_continuation=bool(lines and not parsed[-1]),locale={k:env.get(k) for k in ('LANG','LC_ALL','LC_TIME','TERM','NO_COLOR','CLICOLOR_FORCE')})
  detail=dict(cycle=cycle,variant=variant,last_lines=[repr(line[:200]) for line in lines[-3:]])
  if variant in previous:
   old=previous[variant];oldtail=old['stripped'][-1] if old['stripped'] else ''
   oldstamp=old['rows'][-1][0] if old['rows'] else None
   exact=set(lines)&set(old['lines']);norm={line.rstrip() for line in lines}&{line.rstrip() for line in old['lines']}
   new=canonical-old['canonical'];newfaults=[line for line in new if fault.search(line)]
   record.update(previous_exact_overlap=len(exact),previous_canonical_overlap=len(canonical&old['canonical']),previous_body_overlap=len(bodyset&old['bodyset']),previous_rstrip_overlap=len(norm),previous_tail_in_raw=oldtail in lines,previous_tail_in_stripped=oldtail in stripped,previous_tail_rstrip_present=oldtail.rstrip() in {line.rstrip() for line in lines},previous_tail_timestamp=oldstamp,same_tail_timestamp_different_text=sum(stamp==oldstamp and line!=oldtail for stamp,_,line in rows),previous_timestamp_range_overlap=sum(old['rows'][0][0]<=stamp<=oldstamp for stamp,_,_ in rows) if old['rows'] else 0,new_canonical_records=len(new),new_fault_count=len(newfaults))
   detail['new_fault_lines']=[line[:512] for line in newfaults[:8]]
   detail['same_timestamp_lines']=[repr(line[:200]) for stamp,_,line in rows if stamp==oldstamp][:5]
  previous[variant]={'lines':lines,'stripped':stripped,'rows':rows,'canonical':canonical,'bodyset':bodyset}
  records.append(record);details.append(detail)
  (D/'metadata.json').write_text(json.dumps(records,indent=2)+'\n')
  (D/'bounded-private-tail-details.json').write_text(json.dumps(details,indent=2)+'\n')
  time.sleep(.25)  # Active bounded stability sampling, not completion polling.
(D/'metadata.json').write_text(json.dumps(records,indent=2)+'\n');(D/'bounded-private-tail-details.json').write_text(json.dumps(details,indent=2)+'\n')
summary={'preceding_diagnostic_option_failure':{'argv':['dmesg','--color=never','--nopager','--raw','--force-prefix'],'exit_code':1,'reason':'--color and --raw mutually exclusive; first two read-only samples not persisted'},'reads':len(records),'read_only':True,'new_fault_count':sum(r.get('new_fault_count',0) for r in records),'tail_absent_cases':[r for r in records if r.get('previous_tail_in_raw') is False],'all_reads':[{k:r[k] for k in ('cycle','variant','stdout_bytes','stdout_sha256','line_count','first_timestamp','last_timestamp','last_line_trailing_whitespace','unparsed_lines','escape_count')} for r in records]}
(D/'summary.json').write_text(json.dumps(summary,indent=2)+'\n');print(json.dumps(summary,indent=2))
