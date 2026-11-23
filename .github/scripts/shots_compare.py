"""Puts each page photographed by two builds side by side.

Usage: shots_compare.py <before dir> <after dir> <out dir>
"""

import pathlib
import sys

from PIL import Image, ImageDraw

before, after, out = (pathlib.Path(p) for p in sys.argv[1:4])
out.mkdir(parents=True, exist_ok=True)
GAP, HEAD = 24, 28
names = sorted({p.name for p in before.glob('*.png')} | {p.name for p in after.glob('*.png')})
changed = 0
for name in names:
    shots = [Image.open(d / name).convert('RGB') if (d / name).exists() else None for d in (before, after)]
    width = sum(s.width if s else 200 for s in shots) + GAP
    height = max(s.height if s else 200 for s in shots) + HEAD
    sheet = Image.new('RGB', (width, height), (128, 128, 128))
    draw = ImageDraw.Draw(sheet)
    x = 0
    for label, shot in zip(('before', 'after'), shots):
        draw.text((x + 6, 6), label if shot else f'{label}: missing', fill=(255, 255, 255))
        if shot:
            sheet.paste(shot, (x, HEAD))
        x += (shot.width if shot else 200) + GAP
    if None in shots or shots[0].tobytes() != shots[1].tobytes():
        changed += 1
        sheet.save(out / name)
print(f'{len(names)} pages, {changed} changed (only those are in the comparison)')
