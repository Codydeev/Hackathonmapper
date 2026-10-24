"""Turn raw OSM traces into walking windows for the movement model.

    python ml/prepare.py

For every area in ml/data/raw/ this writes ml/data/windows/<area>.npz with:
  hist  (N, 31, 2)  positions over the 60 s before the cut, every 2 s, oldest
                    first, in metres east/north relative to the last one
  fut   (N, 180, 2) positions 1..180 s after the cut, same frame
  trace (N,)        which continuous walk the window came from (for splits)

Steps: cut traces at time gaps, drop GPS spikes, resample to 1 Hz, drop
stretches that move like a runner, bike or car, and keep walking with its
stops included.
"""

import hashlib
import json
from pathlib import Path

import numpy as np

DATA = Path(__file__).parent / 'data'
R_EARTH = 6371000.0

MAX_GAP = 10        # s, longer gaps cut the trace
SPIKE = 15          # m/s, a point this far from both neighbours is a GPS spike
VEHICLE = 2.6       # m/s, sustained 30 s median above this is not walking
VEHICLE_PAD = 60    # s, also drop this much around non-walking stretches
WALK = (0.5, 2.2)   # m/s, what counts as walking pace
MIN_WALKING = 0.3   # fraction of a piece that must be at walking pace
HIST_S, HIST_STEP, FUT_S = 60, 2, 180
STRIDE = 5          # s between window cuts


def to_xy(lat, lon):
    lat0 = np.radians(lat.mean())
    return np.stack([R_EARTH * np.cos(lat0) * np.radians(lon - lon.mean()),
                     R_EARTH * np.radians(lat - lat.mean())], 1)


def split_gaps(t, xy):
    cuts = np.where(np.diff(t) > MAX_GAP)[0] + 1
    return [(a, b) for a, b in zip(np.r_[0, cuts], np.r_[cuts, len(t)]) if b - a > 1]


def drop_spikes(t, xy):
    keep = np.ones(len(t), bool)
    dt = np.maximum(np.diff(t), 1e-3)
    v = np.linalg.norm(np.diff(xy, axis=0), axis=1) / dt
    keep[1:-1] = ~((v[:-1] > SPIKE) & (v[1:] > SPIKE))
    return t[keep], xy[keep]


def resample(t, xy):
    tt = np.arange(np.ceil(t[0]), np.floor(t[-1]) + 1)
    return np.stack([np.interp(tt, t, xy[:, 0]), np.interp(tt, t, xy[:, 1])], 1)


def rolling(a, w, fn):
    pad = np.pad(a, (w // 2, w - 1 - w // 2), mode='edge')
    return fn(np.lib.stride_tricks.sliding_window_view(pad, w), axis=1)


def walking_pieces(p):
    """Split a 1 Hz track into pieces that are walking (stops allowed)."""
    if len(p) < 10:
        return []
    speed = np.zeros(len(p))
    speed[2:-2] = np.linalg.norm(p[4:] - p[:-4], axis=1) / 4
    speed[:2], speed[-2:] = speed[2], speed[-3]
    fast = rolling(speed, 30, np.median) > VEHICLE
    bad = rolling(fast.astype(float), 2 * VEHICLE_PAD + 1, np.max) > 0
    pieces, start = [], None
    for i, b in enumerate(np.r_[bad, True]):
        if not b and start is None:
            start = i
        elif b and start is not None:
            s = speed[start:i]
            if np.mean((s > WALK[0]) & (s < WALK[1])) >= MIN_WALKING:
                pieces.append(p[start:i])
            start = None
    return pieces


def windows(p):
    hist_idx = np.arange(-HIST_S, 1, HIST_STEP)
    fut_idx = np.arange(1, FUT_S + 1)
    cuts = np.arange(HIST_S, len(p) - FUT_S, STRIDE)
    if len(cuts) == 0:
        return None, None
    o = p[cuts][:, None, :]
    return p[cuts[:, None] + hist_idx] - o, p[cuts[:, None] + fut_idx] - o


def process(area):
    segs = json.loads((DATA / 'raw' / f'{area}.json').read_text())
    seen, hists, futs, traces = set(), [], [], []
    walk_s = 0
    for seg in segs:
        a = np.array(seg, float)
        a = a[np.argsort(a[:, 0], kind='stable')]
        a = a[np.r_[True, np.diff(a[:, 0]) > 0]]
        key = hashlib.md5(a[:20].tobytes()).hexdigest()
        if key in seen or len(a) < 10:
            continue
        seen.add(key)
        xy = to_xy(a[:, 1], a[:, 2])
        for i, j in split_gaps(a[:, 0], xy):
            t, q = drop_spikes(a[i:j, 0], xy[i:j])
            if len(t) < 10:
                continue
            for piece in walking_pieces(resample(t, q)):
                walk_s += len(piece)
                h, f = windows(piece)
                if h is not None:
                    hists.append(h)
                    futs.append(f)
                    traces.append(np.full(len(h), len(traces)))
    out = DATA / 'windows'
    out.mkdir(exist_ok=True)
    if not hists:
        print(f'{area}: no walking windows')
        return
    np.savez_compressed(out / f'{area}.npz',
                        hist=np.concatenate(hists).astype(np.float32),
                        fut=np.concatenate(futs).astype(np.float32),
                        trace=np.concatenate(traces))
    n = sum(len(h) for h in hists)
    print(f'{area}: {walk_s / 3600:.1f} h walking, {len(hists)} walks, {n} windows')


if __name__ == '__main__':
    for f in sorted((DATA / 'raw').glob('*.json')):
        process(f.stem)
