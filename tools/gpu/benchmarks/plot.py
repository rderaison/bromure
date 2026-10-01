#!/usr/bin/env python3
"""Plot recorded results; requires matplotlib. No benchmark is rerun."""
import json
from pathlib import Path
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
root=Path(__file__).parent/'results'
j=json.loads((root/'comparison.json').read_text())
platforms=[('apple_vz','Apple VZ / llvmpipe','#9296a0'),('bromure','Bromure / VirGL Metal','#625dff'),('native_macos','Native macOS / Metal','#1685c9')]
fig,axes=plt.subplots(3,1,figsize=(9,6.7),sharex=True,layout='constrained')
for ax,(case,title) in zip(axes,[('draw_calls','2,048 draws at 64 × 64'),('720p_fill','64 draws at 1,280 × 720, 32 shader iterations'),('1080p_shader','24 draws at 1,920 × 1,080, 128 shader iterations')]):
 for y,(key,label,colour) in enumerate(platforms):
  s=j['platforms'][key]['summary'][case];m=s['medianMs']
  ax.barh(y,m,color=colour,height=.6)
  ax.errorbar(m,y,xerr=[[m-s['minMs']],[s['maxMs']-m]],fmt='none',ecolor='#222222',capsize=3)
  ax.text(s['maxMs']*1.12,y,f'{m:,.1f} ms',va='center',fontsize=10)
 ax.set_yticks(range(3),[p[1] for p in platforms]);ax.invert_yaxis();ax.set_xscale('log');ax.set_xlim(1,10000)
 ax.set_title(title,loc='left',fontsize=11);ax.grid(axis='x',alpha=.18);ax.set_axisbelow(True)
 for side in ['top','right']:ax.spines[side].set_visible(False)
axes[-1].set_xlabel('Median batch time in milliseconds, logarithmic scale — lower is better')
fig.suptitle('Bromure GPU vs Apple VZ and native macOS',fontsize=15)
fig.savefig(root/'comparison.png',dpi=180)
fig.savefig(root/'comparison.svg')
