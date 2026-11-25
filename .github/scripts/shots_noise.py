"""Fails when the page background outside the cards is noisy.

The background is a smooth glow under a grain of a few percent. A strip of
the left and right margins, away from the cards, should differ little from
one pixel to the next; static (a broken grain tile, a dithering bug) shows
as a large mean difference between neighbours.
"""
import sys
from pathlib import Path

from PIL import Image

LIMIT = 6.0


def roughness(image, box):
    strip = image.crop(box).convert('L')
    width, height = strip.size
    px = strip.load()
    total = 0
    count = 0
    for y in range(height):
        for x in range(1, width):
            total += abs(px[x, y] - px[x - 1, y])
            count += 1
    return total / count if count else 0.0


def main(pages, out):
    lines = []
    failed = False
    shots = sorted(Path(pages).glob('*-home-*.png')) + sorted(Path(pages).glob('*-settings-*.png'))
    if not shots:
        print('no home or settings pages to check')
        return 1
    for shot in shots:
        image = Image.open(shot)
        w, h = image.size
        top, bottom = int(h * 0.25), int(h * 0.8)
        left = (int(w * 0.006), top, int(w * 0.045), bottom)
        right = (int(w * 0.955), top, int(w * 0.994), bottom)
        worst = max(roughness(image, left), roughness(image, right))
        bad = worst > LIMIT
        failed |= bad
        lines.append(f"{'FAIL' if bad else 'PASS'}  {shot.name}: background roughness {worst:.1f} (limit {LIMIT})")
    Path(out).write_text('\n'.join(lines) + '\n', encoding='utf-8')
    print('\n'.join(lines))
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1], sys.argv[2]))
