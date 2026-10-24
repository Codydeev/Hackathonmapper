"""Write the walking windows Ghost Mode is fitted and scored on, as flat float64 files.

    python -I ghost/heldout/export_cases.py <ml-dir> <out-dir>

<ml-dir> is the movement model's ml/ folder (branch movement-model) after its
prepare.py has run: its data/windows/<area>.npz hold 60 s of history (every
2 s) and the next 180 s (every 1 s) of real walks from nine Finnish areas.

Same split as ml/train.py: Hervanta is held out for testing, the other eight
areas are for fitting. Every method later sees exactly the same histories:

  gps   the walk's own GPS track as recorded
  mesh  plus correlated error like a Bluetooth mesh estimate: 15 m per axis,
        AR(1) with rho 0.9 per 2 s step (ml/train.py NOISE_RHO, EVAL_NOISE)

Each record is 426 float64: origin x, y (the area's metre frame, which the map
uses), destination x, y relative to the cut (NaN if unknown), 31 history points
x, y relative to the true position at the cut (oldest first, noisy), and 180
future points x, y (true, relative to the same position).
"""
import json
import sys
from pathlib import Path

import numpy as np

TEST_AREA = 'hervanta'
NOISE = {'gps': 0.0, 'mesh': 15.0}
RHO = 0.9
TRAIN_N = 4000


def noisy(hist, sigma, rng):
    if sigma == 0:
        return hist.copy()
    n, steps, _ = hist.shape
    e = np.empty((n, steps, 2))
    e[:, 0] = rng.standard_normal((n, 2))
    for t in range(1, steps):
        e[:, t] = RHO * e[:, t - 1] + np.sqrt(1 - RHO ** 2) * rng.standard_normal((n, 2))
    return hist + sigma * e


def main():
    ml, out = Path(sys.argv[1]), Path(sys.argv[2])
    out.mkdir(parents=True, exist_ok=True)
    train, test, names, areas = [], None, [], []
    for f in sorted((ml / 'data' / 'windows').glob('*.npz')):
        z = np.load(f)
        rows = (z['origin'].astype(float), z['dest'].astype(float), z['hist'].astype(float), z['fut'].astype(float))
        if f.stem == TEST_AREA:
            test = rows
        else:
            train.append(rows)
            areas.append(np.full(len(rows[0]), len(names)))
            names.append(f.stem)
    train = tuple(np.concatenate(parts) for parts in zip(*train))
    areas = np.concatenate(areas)
    pick = np.sort(np.random.default_rng(0).choice(len(train[0]), TRAIN_N, replace=False))
    train = tuple(a[pick] for a in train)
    meta = {'record': 426, 'histN': 31, 'histStep': 2, 'futN': 180, 'testArea': TEST_AREA,
            'noise': NOISE, 'rho': RHO, 'trainAreaNames': names, 'trainArea': areas[pick].tolist(), 'files': {}}
    for split, (origin, dest, hist, fut) in (('train', train), ('test', test)):
        for q, (name, sigma) in enumerate(NOISE.items()):
            h = noisy(hist, sigma, np.random.default_rng(10 * q + (1 if split == 'test' else 0)))
            rec = np.concatenate([origin, dest, h.reshape(len(h), -1), fut.reshape(len(fut), -1)], 1)
            path = out / f'{split}-{name}.f64'
            rec.astype('<f8').tofile(path)
            meta['files'][f'{split}-{name}'] = {'path': path.name, 'count': len(rec), 'sigma': sigma}
            print(f'{split}-{name}: {len(rec)} windows')
    (out / 'meta.json').write_text(json.dumps(meta, indent=1))


if __name__ == '__main__':
    main()
