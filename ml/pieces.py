"""Continuous walking pieces with their time, for the route model.

    python ml/pieces.py        # -> ml/data/pieces/<area>.pkl

Same cleaning as prepare.py (gaps, GPS spikes, 1 Hz, no bikes or cars), but
keeps whole pieces in the area's metre frame with their start time and an
outing "fold". The OSM traces carry no user ids, so walks are grouped by UTC
day: popularity ("where people usually walk") for a walk is only ever counted
from walks on days in the other fold, so a walk never counts towards itself.
"""

import hashlib
import json
import pickle
from datetime import datetime, timezone
from pathlib import Path

import numpy as np

import prepare as P
from geo import to_xy

DATA = Path(__file__).parent / 'data'
SKIP = {'keskuspuisto'}   # 0.5 h of walking: too little to learn from


def pieces(area):
    segs = json.loads((DATA / 'raw' / f'{area}.json').read_text())
    seen, out = set(), []
    for seg in segs:
        a = np.array(seg, float)
        a = a[np.argsort(a[:, 0], kind='stable')]
        a = a[np.r_[True, np.diff(a[:, 0]) > 0]]
        key = hashlib.md5(a[:20].tobytes()).hexdigest()
        if key in seen or len(a) < 10:
            continue
        seen.add(key)
        xy = to_xy(a[:, 1], a[:, 2], area)
        for i, j in P.split_gaps(a[:, 0], xy):
            t, q = P.drop_spikes(a[i:j, 0], xy[i:j])
            if len(t) < 10:
                continue
            t0 = np.ceil(t[0])
            p = P.resample(t, q)
            # walking_pieces cuts p into sub-pieces; find where each starts so its time is known.
            for piece in P.walking_pieces(p):
                k = int(np.flatnonzero((p[:, 0] == piece[0, 0]) & (p[:, 1] == piece[0, 1]))[0])
                start = t0 + k
                day = datetime.fromtimestamp(start, timezone.utc).strftime('%Y-%m-%d')
                out.append({'xy': piece.astype(np.float32), 't0': float(start), 'day': day})
    days = sorted({p['day'] for p in out})
    fold = {d: i % 2 for i, d in enumerate(days)}
    for p in out:
        p['fold'] = fold[p['day']]
    return out, days


def load(area):
    return pickle.loads((DATA / 'pieces' / f'{area}.pkl').read_bytes())


if __name__ == '__main__':
    from fetch_osm import AREAS
    (DATA / 'pieces').mkdir(exist_ok=True)
    for area in AREAS:
        if area in SKIP:
            continue
        ps, days = pieces(area)
        (DATA / 'pieces' / f'{area}.pkl').write_bytes(pickle.dumps(ps))
        long = [p for p in ps if len(p['xy']) >= 660]
        h = sum(len(p['xy']) for p in ps) / 3600
        print(f'{area}: {len(ps)} pieces, {h:.1f} h, {len(days)} days, {len(long)} pieces with 60 s + 10 min')
