#!/usr/bin/env python3
"""Run one bounded multi-GPU trial and retain functional/performance evidence."""
import argparse, hashlib, json, pathlib, re, subprocess, time
p=argparse.ArgumentParser();p.add_argument('--binary',required=True);p.add_argument('--image',required=True);p.add_argument('--count',type=int,required=True);p.add_argument('--memory-gb',type=int,default=4);p.add_argument('--seconds',type=int,default=90);p.add_argument('--output',required=True)
a=p.parse_args();out=pathlib.Path(a.output);out.mkdir(parents=True,exist_ok=True)
probeSource=pathlib.Path(__file__).with_name('guest-multigpu-check.py').resolve()
probe=out.resolve()/'probe.py';probe.write_bytes(probeSource.read_bytes())
cmd=[a.binary,'multi-gpu-browser','--gpu-count',str(a.count),'--memory-gb',str(a.memory_gb),'--storage-dir',a.image,'--seconds',str(a.seconds),'--guest-probe',str(probe),'--input-check','--require-gpu-check','--url','about:blank','--allow-older-test-image']
samples=[];start=time.monotonic()
with (out/'run.log').open('w') as log:
 proc=subprocess.Popen(cmd,stdout=log,stderr=subprocess.STDOUT)
 while proc.poll() is None:
  if time.monotonic()-start>a.seconds+180:proc.terminate();proc.wait(timeout=15);break
  rows=[]
  for line in subprocess.check_output(['ps','-axo','pid,ppid,rss,%cpu,comm'],text=True).splitlines()[1:]:
   parts=line.strip().split(None,4)
   if len(parts)==5 and ('bromure' in parts[4].lower() or 'virtualization' in parts[4].lower()):
    rows.append({'pid':int(parts[0]),'ppid':int(parts[1]),'rssKiB':int(parts[2]),'cpuPercent':float(parts[3]),'command':parts[4]})
  samples.append({'elapsed':time.monotonic()-start,'processes':rows,'sumRSSKiB':sum(r['rssKiB'] for r in rows),'vmStat':subprocess.check_output(['vm_stat'],text=True)})
  time.sleep(2)
text=(out/'run.log').read_text();text=re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]','',text).replace('[multi-GPU guest] ','').replace('\r','')
def records(marker):
 result=[]
 for line in text.splitlines():
  if marker+' ' in line:
   try:result.append(json.JSONDecoder().raw_decode(line.split(marker+' ',1)[1])[0])
   except (ValueError,IndexError):pass
 return result
inputs=records('BROMURE_MULTIGPU_INPUT');screens=records('BROMURE_MULTIGPU_SCREEN');memory=records('BROMURE_MULTIGPU_GUEST_MEMORY')
result={'count':a.count,'guestMemoryGiB':a.memory_gb,'exitCode':proc.returncode,'wallSeconds':time.monotonic()-start,'accepted':proc.returncode==0 and 'BROMURE_MULTIGPU_ACCEPTANCE_PASS' in text,'lifecyclePassed':'lifecycle PASS' in text,'sourcePixelPasses':len(re.findall(r'source pixel PASS',text)),'screens':[{'index':r['index'],'render':r['render'],'pci':r['pci'],'gpu':r['gpu']['glRenderer'],'initialCrashCount':r['gpu']['processCrashCount']} for r in screens],'inputs':inputs,'animationFPS':[r['state']['animationFrames']*1000/r['state']['animationElapsed'] for r in inputs if r['state'].get('animationElapsed',0)>0],'guestMemory':memory,'diagnostics':records('BROMURE_MULTIGPU_DIAGNOSTICS'),'hostRSSScope':'All ps commands matching bromure or virtualization, including any unrelated existing sessions; summed RSS is not unique physical memory.','peakHostMatchedRSSMiB':max((s['sumRSSKiB']/1024 for s in samples),default=0),'hostSamples':samples,'binarySHA256':hashlib.sha256(pathlib.Path(a.binary).read_bytes()).hexdigest(),'probeSHA256':hashlib.sha256(probe.read_bytes()).hexdigest(),'logSHA256':hashlib.sha256((out/'run.log').read_bytes()).hexdigest(),'command':cmd}
(out/'results.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps({k:result[k] for k in ['count','guestMemoryGiB','exitCode','accepted','lifecyclePassed','sourcePixelPasses','animationFPS','peakHostMatchedRSSMiB']}),flush=True)
raise SystemExit(0 if result['accepted'] else 1)
