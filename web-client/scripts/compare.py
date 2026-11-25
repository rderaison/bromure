#!/usr/bin/env python3
"""Side-by-side + diff of a native reference render and a web render.

  python3 scripts/compare.py .reference/editor-general.png /tmp/web.png OUT.png [--crop x,y,w,h] [--scale 0.5]

OUT.png = [native | web | diff-heatmap] (crop in POINTS = reference px / 2).
Prints the mean absolute difference (0 = identical) so you can track progress.
"""
import sys
from PIL import Image, ImageChops, ImageOps

args = sys.argv[1:]
ref, web, out = args[0], args[1], args[2]
crop = None; scale = 0.5
if '--crop' in args:
    crop = [int(v) * 2 for v in args[args.index('--crop') + 1].split(',')]
if '--scale' in args:
    scale = float(args[args.index('--scale') + 1])
a = Image.open(ref).convert('RGB'); b = Image.open(web).convert('RGB')
if crop:
    x, y, w, h = crop
    a = a.crop((x, y, x + w, y + h)); b = b.crop((x, y, x + w, y + h))
if b.size != a.size:
    b = b.resize(a.size)
d = ImageChops.difference(a, b)
g = ImageOps.grayscale(d)
hist = g.histogram()
total = sum(hist)
mad = sum(i * c for i, c in enumerate(hist)) / max(total, 1)
heat = ImageOps.colorize(ImageOps.autocontrast(g), black='white', white='red')
W, H = a.size
canvas = Image.new('RGB', (W * 3 + 20, H), 'white')
canvas.paste(a, (0, 0)); canvas.paste(b, (W + 10, 0)); canvas.paste(heat, (2 * W + 20, 0))
if scale != 1:
    canvas = canvas.resize((int(canvas.width * scale), int(canvas.height * scale)))
canvas.save(out)
print(f'mean abs diff: {mad:.2f}  (size {W}x{H})  → {out}')
