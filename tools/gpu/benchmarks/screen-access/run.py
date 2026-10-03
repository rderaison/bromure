#!/usr/bin/env python3
"""Repeatable visible local/remote benchmark using the actual Bromure bundle."""
import argparse, base64, datetime, hashlib, json, os, pathlib, platform, plistlib, re, subprocess, sys
ROOT = pathlib.Path(__file__).resolve().parent
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--app', required=True, type=pathlib.Path)
p.add_argument('--access', required=True, choices=['local', 'remote', 'headless'], help='Operator-labelled access condition; never inferred from monitor presence')
p.add_argument('--remote-client', default='')
p.add_argument('--storage-dir', type=pathlib.Path, default=pathlib.Path.home()/'Library/Application Support/Bromure')
p.add_argument('--backend', choices=['metal', 'apple', 'both'], default='both')
p.add_argument('--output', type=pathlib.Path, default=pathlib.Path.home()/'Desktop/Bromure benchmarks')
p.add_argument('--allow-candidate-image', action='store_true', help='Explicit private-image override; actual image metadata is retained')
a = p.parse_args()
binary = a.app/'Contents/MacOS/bromure'
if not binary.is_file(): p.error('Pass the Bromure.app directory')
if a.access == 'remote' and not a.remote_client: p.error('--remote-client is required for remote runs')
for name in ['linux-base.img', 'vmlinuz', 'initrd', 'image-version']:
    if not (a.storage_dir/name).is_file(): p.error('Missing image file: '+name)
metadata = {}
for name in ['image-version', 'image-state.json', 'graphics-capabilities.json']:
    f=a.storage_dir/name
    if f.exists(): metadata[name]=f.read_text()
state=json.loads(metadata.get('image-state.json', '{}'))
actual=str(state.get('version', metadata['image-version'].strip()))
if actual != '501' and not a.allow_candidate_image:
    p.error('This test requires actual image 501, not just an app-version cache stamp. Use --allow-candidate-image only for a verified private candidate.')
run=a.output/(datetime.datetime.now().strftime('%Y%m%d-%H%M%S')+'-'+a.access)
run.mkdir(parents=True, exist_ok=False)
def command(args):
    r=subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    return {'status':r.returncode, 'output':r.stdout}
manifest={'access':a.access, 'remoteClient':a.remote_client, 'host':platform.platform(),
    'app':str(a.app.resolve()), 'appVersion':plistlib.loads((a.app/'Contents/Info.plist').read_bytes()).get('CFBundleShortVersionString'), 'binarySHA256':hashlib.sha256(binary.read_bytes()).hexdigest(),
    'image':metadata, 'actualImageVersion':actual, 'candidateOverride':a.allow_candidate_image,
    'displays':command(['/usr/sbin/system_profiler','SPDisplaysDataType','-json']),
    'powerBefore':command(['/usr/bin/pmset','-g','therm']),
    'workloadSHA256':hashlib.sha256((ROOT/'visible.js').read_bytes()+(ROOT/'webgl2-workload.js').read_bytes()+(ROOT/'guest.py').read_bytes()).hexdigest(), 'results':{}}
# Scripts are delivered to the guest through the serial console, with no HTTP server/dependencies.
manifest['rendererFilesSHA256']={str(f.relative_to(a.app)):hashlib.sha256(f.read_bytes()).hexdigest() for f in sorted((a.app/'Contents/XPCServices').rglob('*')) if f.is_file() and (f.suffix in ['.dylib','.metallib'] or f.parent.name=='MacOS')}
probe=(ROOT/'guest.py').read_text().replace('__THROUGHPUT__',base64.b64encode((ROOT/'webgl2-workload.js').read_bytes()).decode()).replace('__VISIBLE__',base64.b64encode((ROOT/'visible.js').read_bytes()).decode())
probe_path=run/'guest-probe.py';probe_path.write_text(probe)
(run/'results.json').write_text(json.dumps(manifest,indent=2)+'\n')
for backend in (['metal','apple'] if a.backend=='both' else [a.backend]):
    args=[str(binary),'gpu-browser','--storage-dir',str(a.storage_dir),'--seconds','150','--check-timeout','140','--require-gpu-check','--url','about:blank','--guest-probe',str(probe_path)]
    if backend=='apple':args.append('--apple-virtio-gpu')
    if a.allow_candidate_image:args.append('--allow-older-test-image')
    print('Running',backend,'— keep this window visible; results:',run,flush=True)
    with (run/(backend+'.log')).open('w') as log:
        try:
            result=subprocess.run(args, stdout=log, stderr=subprocess.STDOUT, timeout=210)
        except subprocess.TimeoutExpired:
            result=subprocess.CompletedProcess(args,124)
            log.write('\nBROMURE_HOST_TIMEOUT: benchmark process exceeded 210 seconds\n')
    text=re.sub(r'\[VM \d+\] ', '', (run/(backend+'.log')).read_text(errors='replace'))
    rows=[]
    for line in text.splitlines():
        if 'BROMURE_SCREEN_RESULT ' in line:
            raw=line.split('BROMURE_SCREEN_RESULT ',1)[1]
            try:rows.append(json.JSONDecoder().raw_decode(raw)[0])
            except ValueError:pass
    expected='virgl' if backend=='metal' else 'llvmpipe'
    manifest['results'][backend]={'exitCode':result.returncode,'samples':rows,
        'passed':result.returncode==0 and len(rows)==1 and rows[0].get('passed',False) and expected in rows[0].get('renderer','').lower(),
        'deliveredFrames':re.findall(r'Frames delivered: (\d+)',text)}
    (run/'results.json').write_text(json.dumps(manifest,indent=2)+'\n')
manifest['powerAfter']=command(['/usr/bin/pmset','-g','therm'])
manifest['limitations']='rAF measures guest scheduling, not remote-client display latency. Delivered frames are host scanouts, not proven screen presentations. Record remote client, physical monitor/dummy plug, resolution, power mode and visibility; compare repeated runs on the same host. No audio/video decode benchmark in this suite.'
(run/'results.json').write_text(json.dumps(manifest,indent=2)+'\n')
print('Results:',run,flush=True)
sys.exit(0 if all(r['passed'] for r in manifest['results'].values()) else 1)
