"""Measure what the route model needs from the matched walks.

    python ml/route_stats.py

Writes:
  data/popularity/<area>-fold<k>.json   how many walks used each path segment,
                                        from walks in fold k only ("where
                                        people usually walk")
  results/route-stats.json              from the training areas only (not
                                        Hervanta): distance walked by time t,
                                        how often people turn back, and how
                                        often they leave the paths
"""

import json
import pickle
from pathlib import Path

import numpy as np

import graph as G
import pieces as PC
from export_routes import DEFAULT_MODEL
from match import CHOICE_M, R, STEP, smooth, runs_of
from train import TEST_AREA

HERE = Path(__file__).parent
DATA = HERE / 'data'
HIST_S, CUT_EVERY = 60, 30
V_EDGES = DEFAULT_MODEL['speed']['vEdges']
T_GRID = DEFAULT_MODEL['speed']['t']
OFF_T = DEFAULT_MODEL['offPath']['t']
OFF_M = 25.0


def popularity(area):
    g = G.load(area)
    counts = [{}, {}]
    for m in pickle.loads((DATA / 'matched' / f'{area}.pkl').read_bytes()):
        used = set()
        for e, k0, k1 in runs_of(m['edge']):
            if e < 0:
                continue
            o = m['off'][k0:k1]
            if np.nanmax(o) - np.nanmin(o) >= min(CHOICE_M, 0.8 * g.length[e]):
                used.add(e)
        for e in used:
            counts[m['fold']][e] = counts[m['fold']].get(e, 0) + 1
    (DATA / 'popularity').mkdir(exist_ok=True)
    for k in (0, 1):
        (DATA / 'popularity' / f'{area}-fold{k}.json').write_text(json.dumps({str(e): c for e, c in counts[k].items()}))
    return [len(c) for c in counts]


def tables(areas):
    dist = {b: {t: [] for t in T_GRID} for b in range(len(V_EDGES) + 1)}
    back = {'moving': [], 'stopped': []}
    off = {'on': {t: [] for t in OFF_T}, 'off': {t: [] for t in OFF_T}}
    for area in areas:
        g = G.load(area)
        for p in PC.load(area):
            xy = p['xy'].astype(float)
            s = smooth(xy)
            for c in range(HIST_S, len(xy) - 60, CUT_EVERY):
                v = np.linalg.norm(xy[c] - xy[c - HIST_S]) / HIST_S
                b = int(np.searchsorted(V_EDGES, v, side='right'))
                # Distance walked along the track by time t (10 s steps of the smoothed track).
                for t in T_GRID:
                    if c + t >= len(xy):
                        break
                    pts = s[c:c + t + 1:10] if t else s[c:c + 1]
                    if t and (t % 10):
                        pts = np.vstack([pts, s[c + t]])
                    dist[b][t].append(float(np.linalg.norm(np.diff(pts, axis=0), axis=1).sum()) if len(pts) > 1 else 0.0)
                # Turned back within a minute: closer to where they were 30 s ago than they are now.
                moving = np.linalg.norm(xy[c] - xy[c - 20]) >= 10
                d_now = np.linalg.norm(xy[c] - xy[c - 30])
                d_fut = np.linalg.norm(xy[c + 60] - xy[c - 30])
                back['moving' if moving else 'stopped'].append(float(d_fut < d_now - 10))
                # On the paths now (median of the last 20 s), and off them later?
                recent = g.kd.query(s[c - 18:c + 1:STEP])[0]
                state = 'on' if np.median(recent) <= R else 'off'
                for t in OFF_T:
                    if c + t >= len(xy):
                        break
                    off[state][t].append(float(g.kd.query(s[c + t])[0] > OFF_M))
    q = {k: [[round(float(np.percentile(dist[b][t], pc)), 1) if dist[b][t] else 0.0 for t in T_GRID]
             for b in range(len(V_EDGES) + 1)] for k, pc in (('q10', 10), ('q50', 50), ('q90', 90))}
    n_speed = [len(dist[b][T_GRID[-1]]) for b in range(len(V_EDGES) + 1)]
    return {
        'speed': {'vEdges': V_EDGES, 't': T_GRID, 'q': q, 'n': n_speed},
        'back': {k: round(float(np.mean(v)), 3) for k, v in back.items()},
        'offPath': {'t': OFF_T, **{k: [round(float(np.mean(off[k][t])), 3) if off[k][t] else 0.0 for t in OFF_T] for k in off},
                    'n': {k: len(off[k][0]) for k in off}},
    }


def main():
    from fetch_osm import AREAS
    areas = [a for a in AREAS if a not in PC.SKIP]
    for a in areas:
        n = popularity(a)
        print(f'{a}: walks used {n[0]} segments in fold 0, {n[1]} in fold 1')
    st = tables([a for a in areas if a != TEST_AREA])
    (HERE / 'results' / 'route-stats.json').write_text(json.dumps(st, indent=1))
    q50 = st['speed']['q']['q50']
    print('median distance after 2 / 5 / 10 min by recent speed bin:',
          [(q50[b][T_GRID.index(120)], q50[b][T_GRID.index(300)], q50[b][T_GRID.index(600)]) for b in range(len(q50))])
    print('windows per speed bin (10 min):', st['speed']['n'])
    print('turned back within a minute:', st['back'], '| left the paths by 10 min:', st['offPath'])


if __name__ == '__main__':
    main()
