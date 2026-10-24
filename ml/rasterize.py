"""Draw each area's map as a 3-channel image the model can look at.

    python ml/rasterize.py

Channels: 0 paths and trails, 1 roads, 2 water. 8 m per pixel, in the area's
metre frame (geo.py). Saves ml/data/map/<area>.png (RGB = the 3 channels)
plus <area>.meta.json with the frame, so phones can ship the same image.
"""

import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw
from scipy.ndimage import gaussian_filter

from geo import MAP_RES, map_extent, origin, to_xy

MAP = Path(__file__).parent / 'data' / 'map'
WIDTH = {'paths': 2, 'roads': 3}   # pixels; wider than the 10 m patch spacing so no line is missed
BLUR = 0.7                         # pixels


def rings(lines):
    """Big lakes arrive as several pieces of shoreline: join pieces that share
    end points into closed rings, and drop any that never close."""
    key = lambda p: (round(p[0], 7), round(p[1], 7))
    closed = [l for l in lines if len(l) >= 4 and key(l[0]) == key(l[-1])]
    open_ = [list(l) for l in lines if len(l) >= 2 and key(l[0]) != key(l[-1])]
    while open_:
        ring = open_.pop()
        grew = True
        while grew and key(ring[0]) != key(ring[-1]):
            grew = False
            for i, l in enumerate(open_):
                if key(l[0]) == key(ring[-1]):
                    ring += l[1:]
                elif key(l[-1]) == key(ring[-1]):
                    ring += l[::-1][1:]
                elif key(l[-1]) == key(ring[0]):
                    ring = l[:-1] + ring
                elif key(l[0]) == key(ring[0]):
                    ring = l[::-1][:-1] + ring
                else:
                    continue
                open_.pop(i)
                grew = True
                break
        if key(ring[0]) == key(ring[-1]) and len(ring) >= 4:
            closed.append(ring)
    return closed


def draw(area):
    m = json.loads((MAP / f'{area}.json').read_text())
    m['water'] = rings(m['water'])
    x0, y1, W, H = map_extent(area)
    px = lambda line: [((x - x0) / MAP_RES, (y1 - y) / MAP_RES) for x, y in to_xy(*np.array(line).T, area)]
    chans = []
    for key in ('paths', 'roads', 'water'):
        img = Image.new('L', (W, H), 0)
        d = ImageDraw.Draw(img)
        for line in m[key]:
            pts = px(line)
            if len(pts) < 2:
                continue
            if key == 'water':
                if len(pts) >= 3:
                    d.polygon(pts, fill=255)
            else:
                d.line(pts, fill=255, width=WIDTH[key], joint='curve')
        if key == 'water':   # islands
            for ring in m.get('water_holes', []):
                if len(ring) >= 3:
                    d.polygon(px(ring), fill=0)
        a = np.asarray(img, np.float32)
        chans.append(np.clip(gaussian_filter(a, BLUR), 0, 255).astype(np.uint8))
    rgb = np.stack(chans, -1)
    Image.fromarray(rgb, 'RGB').save(MAP / f'{area}.png', optimize=True)
    lat0, lon0 = origin(area)
    (MAP / f'{area}.meta.json').write_text(json.dumps({'area': area, 'lat0': lat0, 'lon0': lon0, 'xMin': x0, 'yMax': y1,
                                                        'res': MAP_RES, 'width': W, 'height': H}))
    kb = (MAP / f'{area}.png').stat().st_size / 1024
    cover = (rgb > 64).mean((0, 1))
    print(f'{area}: {W}x{H} px, {kb:.0f} kB, paths {cover[0]:.1%} roads {cover[1]:.1%} water {cover[2]:.1%} of pixels')


if __name__ == '__main__':
    for f in sorted(MAP.glob('*.json')):
        if not f.name.endswith('.meta.json'):
            draw(f.stem)
