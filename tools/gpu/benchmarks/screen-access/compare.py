#!/usr/bin/env python3
"""Compare local and remote runs; reject mismatched workloads or app binaries."""
import argparse, json, pathlib, statistics
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('local',type=pathlib.Path);p.add_argument('remote',type=pathlib.Path)
a=p.parse_args();local=json.loads(a.local.read_text());remote=json.loads(a.remote.read_text())
assert local['access']=='local' and remote['access'] in ['remote','headless'],'Pass local then remote results.json'
for key in ['binarySHA256','workloadSHA256','actualImageVersion','rendererFilesSHA256']:
 assert local[key]==remote[key],'Different '+key
assert local['image']==remote['image'],'Different image metadata'
print('Remote client:',remote['remoteClient'])
print('Backend | Case | Local | Remote | Remote / local')
common=set(local['results'])&set(remote['results'])
assert common,'No matching backends'
for backend in sorted(common):
 l=local['results'][backend];r=remote['results'][backend]
 assert l['passed'] and r['passed'],'Failed '+backend+' run'
 l=l['samples'][0];r=r['samples'][0]
 for name in ['draw_calls','720p_fill','1080p_shader']:
  x=statistics.median(row['elapsedMs'] for row in l['throughput'] if row['name']==name)
  y=statistics.median(row['elapsedMs'] for row in r['throughput'] if row['name']==name)
  print(f'{backend} | {name} ms | {x:.2f} | {y:.2f} | {y/x:.3f}')
 assert l['visible']['viewport']==r['visible']['viewport'],'Different visible viewport'
 for key in ['meanIntervalMs','p95IntervalMs','p99IntervalMs']:
  x=l['visible'][key];y=r['visible'][key]
  print(f'{backend} | {key} | {x:.2f} | {y:.2f} | {y/x:.3f}')
print('Lower milliseconds are better. This does not measure remote-client latency.')
