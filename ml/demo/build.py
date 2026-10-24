"""Build the self-contained area demo page (v2): ml/demo/area.html.

    python ml/demo/build.py

Inlines into template.html: the v2 model weights, the JS runtime, the map
image the model reads (cropped to the demo walks), the OpenStreetMap paths,
roads and lakes drawn underneath, v2 results, and a handful of real walks
from the held-out Hervanta test set.
"""

import base64
import io
import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image

HERE = Path(__file__).parent
ML = HERE.parent
sys.path.insert(0, str(ML))

from geo import to_xy  # noqa: E402

AREA = 'hervanta'
MARGIN = 700   # m of map around the walks


def heading(hist):
    for k in (5, 15, 30):
        v = hist[-1] - hist[-1 - k]
        if np.hypot(*v) >= 3:
            return np.arctan2(v[1], v[0])
    return None


def describe(hist, fut):
    speed = np.hypot(*(hist[-1] - hist[0])) / 60
    th = heading(hist)
    end = fut[119] - hist[-1]
    if th is None:
        return 'Standing still', speed
    if np.hypot(*end) < 25:
        return 'Stops', speed
    a = np.degrees(np.arctan2(end[1], end[0]) - th)
    a = (a + 180) % 360 - 180
    return ('Keeps going' if abs(a) < 35 else 'Turns back' if abs(a) > 120
            else 'Turns left' if a > 0 else 'Turns right'), speed


def pick_walks():
    z = np.load(ML / 'data' / 'windows' / f'{AREA}.npz')
    o = z['origin'].astype(float)
    hist, fut = z['hist'].astype(float) + o[:, None], z['fut'].astype(float) + o[:, None]
    dest, trace = z['dest'].astype(float) + o, z['trace']
    rng = np.random.default_rng(3)
    want = {'Keeps going': 2, 'Turns left': 2, 'Turns right': 2, 'Turns back': 2, 'Stops': 1, 'Standing still': 1}
    got, used = [], set()
    for i in rng.permutation(len(hist)):
        if trace[i] in used:
            continue
        kind, speed = describe(hist[i], fut[i])
        moved = np.hypot(*(hist[i][-1] - hist[i][0]))
        if not want.get(kind, 0) or (kind == 'Standing still') != (moved < 3) or (kind != 'Standing still' and moved < 30):
            continue
        want[kind] -= 1
        used.add(trace[i])
        got.append((kind, speed, hist[i], fut[i], dest[i]))
        if not any(want.values()):
            break
    order = list(want)
    got.sort(key=lambda g: order.index(g[0]))
    r = lambda a: np.round(a, 1).tolist()
    return [{'kind': k, 'speed': round(s, 2), 'hist': r(h), 'fut': r(f),
             'dest': None if np.isnan(d[0]) else r(d)} for k, s, h, f, d in got]


def map_crop(walks):
    pts = np.concatenate([np.array(w['hist'] + w['fut']) for w in walks])
    x0, y0 = pts.min(0) - MARGIN
    x1, y1 = pts.max(0) + MARGIN
    meta = json.loads((ML / 'export' / 'maps' / f'{AREA}.json').read_text())
    img = np.asarray(Image.open(ML / 'export' / 'maps' / f'{AREA}.png'))
    c0 = max(0, int((x0 - meta['xMin']) // meta['res']))
    c1 = min(meta['width'], int((x1 - meta['xMin']) // meta['res']) + 1)
    r0 = max(0, int((meta['yMax'] - y1) // meta['res']))
    r1 = min(meta['height'], int((meta['yMax'] - y0) // meta['res']) + 1)
    crop = img[r0:r1, c0:c1]
    buf = io.BytesIO()
    Image.fromarray(crop, 'RGB').save(buf, 'PNG', optimize=True)
    meta.update(xMin=meta['xMin'] + c0 * meta['res'], yMax=meta['yMax'] - r0 * meta['res'],
                width=crop.shape[1], height=crop.shape[0])
    box = (meta['xMin'], meta['yMax'] - meta['height'] * meta['res'], meta['xMin'] + meta['width'] * meta['res'], meta['yMax'])
    return 'data:image/png;base64,' + base64.b64encode(buf.getvalue()).decode(), meta, box


def vectors(box):
    """OpenStreetMap lines and lakes inside the box, in whole metres."""
    m = json.loads((ML / 'data' / 'map' / f'{AREA}.json').read_text())
    from rasterize import rings
    m['water'] = rings(m['water'])
    x0, y0, x1, y1 = box
    out = {}
    for key in ('paths', 'roads', 'water', 'water_holes'):
        keep = []
        for line in m.get(key, []):
            xy = to_xy(*np.array(line).T, AREA)
            if ((xy[:, 0] >= x0) & (xy[:, 0] <= x1) & (xy[:, 1] >= y0) & (xy[:, 1] <= y1)).any():
                keep.append(np.round(xy).astype(int).ravel().tolist())
        out[key] = keep
    return out


def main():
    spec = (ML / 'export' / 'movement-model-v2.json').read_text()
    runtime = (ML / 'runtime' / 'movement-model.js').read_text().replace('export function', 'function')
    keep = ('history', 'h', 'method', 'area90_exact', 'err50', 'cover90', 'cv_std', 'cv_window_s')
    metrics = [{k: round(v, 3) if isinstance(v, float) else v for k, v in r.items() if k in keep}
               for r in json.loads((ML / 'results' / 'metrics-v2.json').read_text())]
    walks = pick_walks()
    png, meta, box = map_crop(walks)
    vec = vectors(box)
    page = (HERE / 'template.html').read_text()
    for key, val in [('/*SPEC*/', spec), ('/*RUNTIME*/', runtime), ('/*METRICS*/', json.dumps(metrics)),
                     ('/*WALKS*/', json.dumps(walks, separators=(',', ':'))), ('/*MAPMETA*/', json.dumps(meta)),
                     ('/*MAPPNG*/', json.dumps(png)), ('/*VECTORS*/', json.dumps(vec, separators=(',', ':')))]:
        assert key in page, key
        page = page.replace(key, val)
    (HERE / 'area.html').write_text(page)
    kinds = ', '.join(w['kind'] for w in walks)
    print(f'wrote {HERE / "area.html"} ({len(page) / 1024:.0f} kB): {len(walks)} walks ({kinds}), '
          f'{sum(w["dest"] is not None for w in walks)} with a destination; map {meta["width"]}x{meta["height"]} px, '
          f'{len(vec["paths"])} paths, {len(vec["roads"])} roads, {len(vec["water"])} lakes')


if __name__ == '__main__':
    main()
