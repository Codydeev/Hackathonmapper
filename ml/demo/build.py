"""Build the self-contained demo page: ml/demo/index.html.

    python ml/demo/build.py

Inlines the exported weights, the JS runtime, the results and a handful of
real walks from the held-out Hervanta test set into template.html.
"""

import json
from pathlib import Path

import numpy as np

HERE = Path(__file__).parent
ML = HERE.parent


def heading(hist):
    for k in (5, 15, 30):
        v = hist[-1] - hist[-1 - k]
        if np.hypot(*v) >= 3:
            return np.arctan2(v[1], v[0])
    return None


def describe(hist, fut):
    speed = np.hypot(*(hist[-1] - hist[0])) / 60
    th = heading(hist)
    end = fut[119]
    d = np.hypot(*end)
    if th is None:
        kind = 'Standing still'
    elif d < 25:
        kind = 'Stops'
    else:
        a = np.degrees(np.arctan2(end[1], end[0]) - th)
        a = (a + 180) % 360 - 180
        kind = ('Keeps going' if abs(a) < 35 else 'Turns back' if abs(a) > 120
                else 'Turns left' if a > 0 else 'Turns right')
    return kind, speed


def pick_walks():
    z = np.load(ML / 'data' / 'windows' / 'hervanta.npz')
    hist, fut, trace = z['hist'].astype(float), z['fut'].astype(float), z['trace']
    rng = np.random.default_rng(3)
    want = {'Keeps going': 2, 'Turns left': 2, 'Turns right': 2, 'Turns back': 2, 'Stops': 1, 'Standing still': 1}
    got, used = [], set()
    for i in rng.permutation(len(hist)):
        if trace[i] in used:
            continue
        kind, speed = describe(hist[i], fut[i])
        moving = np.hypot(*hist[i][0]) >= 30
        if want.get(kind, 0) and (moving or kind == 'Standing still') and (kind != 'Standing still' or np.hypot(*hist[i][0]) < 3):
            want[kind] -= 1
            used.add(trace[i])
            got.append((kind, speed, hist[i], fut[i]))
        if not any(want.values()):
            break
    order = ['Keeps going', 'Turns left', 'Turns right', 'Turns back', 'Stops', 'Standing still']
    got.sort(key=lambda g: order.index(g[0]))
    r = lambda a: np.round(a, 1).tolist()
    return [{'kind': k, 'speed': round(s, 2), 'hist': r(h), 'fut': r(f)} for k, s, h, f in got]


def main():
    spec = (ML / 'export' / 'movement-model.json').read_text()
    runtime = (ML / 'runtime' / 'movement-model.js').read_text().replace('export function', 'function')
    keep = ('history', 'h', 'method', 'area90_exact', 'err50', 'cover90', 'cv_std', 'cv_window_s')
    metrics = [{k: round(v, 3) if isinstance(v, float) else v for k, v in m.items() if k in keep}
               for m in json.loads((ML / 'results' / 'metrics.json').read_text())]
    walks = pick_walks()
    page = (HERE / 'template.html').read_text()
    for key, val in [('/*SPEC*/', spec), ('/*RUNTIME*/', runtime), ('/*METRICS*/', json.dumps(metrics)),
                     ('/*WALKS*/', json.dumps(walks, separators=(',', ':')))]:
        assert key in page, key
        page = page.replace(key, val)
    (HERE / 'index.html').write_text(page)
    kinds = ', '.join(w['kind'] for w in walks)
    print(f'wrote {HERE / "index.html"} ({len(page) / 1024:.0f} kB): {len(walks)} walks: {kinds}')


if __name__ == '__main__':
    main()
