"""Snap real walks onto the path graph and read off every junction choice.

    python ml/match.py [areas...]     # -> ml/data/matched/<area>.pkl

Matching is a Viterbi over 2-second steps of a 5-second-smoothed track:
candidate edges within 20 m (distance cost, sigma 8 m, plus a heading cost
when moving), and an "off the paths" state. A step may only stay on its edge,
move to an edge sharing a junction, or go off/on the paths, so it never jumps
between unconnected paths.

A junction choice is recorded when the walker arrives along one edge and then
walks at least 15 m along another (or turns back at the junction). Choices
across an off-path stretch are not used.
"""

import math
import pickle
import sys
from pathlib import Path

import numpy as np

import graph as G
import pieces as PC

DATA = Path(__file__).parent / 'data'
STEP = 2            # s between matched points
SMOOTH = 5          # s moving average before matching
R = 20.0            # m, candidate edges
SIGMA = 8.0
HEADING_K = 2.0     # cost for walking across the edge direction
OFF_COST = R ** 2 / (2 * SIGMA ** 2)
SWITCH = 0.5        # cost to move to a connected edge
ON_OFF = 3.0        # cost to leave or rejoin the paths
MIN_RUN = 3         # steps; shorter runs are flicker
CHOICE_M = 15.0     # m walked along the exit edge before a choice counts


def smooth(xy):
    k = np.ones(SMOOTH) / SMOOTH
    pad = np.pad(xy, ((SMOOTH // 2, SMOOTH - 1 - SMOOTH // 2), (0, 0)), mode='edge')
    return np.stack([np.convolve(pad[:, i], k, 'valid') for i in range(2)], 1)


def candidates(g, z):
    """Per step: edges within R with distance, offset and tangent there."""
    out = []
    for p in z:
        best = {}
        for i in g.kd.query_ball_point(p, R):
            e = int(g.pt_edge[i])
            dist = float(np.hypot(*(g.pt_xy[i] - p)))
            if e not in best or dist < best[e][0]:
                best[e] = (dist, i)
        rows = []
        for e, (dist, i) in best.items():
            j0 = i - 1 if i > 0 and g.pt_edge[i - 1] == e else i
            j1 = i + 1 if i + 1 < len(g.pt_edge) and g.pt_edge[i + 1] == e else i
            t = g.pt_xy[j1] - g.pt_xy[j0]
            rows.append((e, dist, float(g.pt_off[i]), math.atan2(t[1], t[0])))
        out.append(rows)
    return out


def viterbi(g, z, cands):
    K = len(z)
    v = np.diff(z, axis=0, prepend=z[:1])
    v[0] = v[1] if K > 1 else v[0]
    speed = np.linalg.norm(v, axis=1) / STEP
    head = np.arctan2(v[:, 1], v[:, 0])
    states, costs, back = [], [], []
    for k in range(K):
        es = np.array([c[0] for c in cands[k]] + [-1])
        em = np.array([c[1] ** 2 / (2 * SIGMA ** 2) for c in cands[k]] + [OFF_COST])
        if speed[k] > 0.3:
            em[:-1] += HEADING_K * (1 - np.abs(np.cos(head[k] - np.array([c[3] for c in cands[k]]))))
        if k == 0:
            states.append(es); costs.append(em); back.append(None)
            continue
        pe = states[-1]
        pa, pb = np.where(pe >= 0, g.a[np.maximum(pe, 0)], -2), np.where(pe >= 0, g.b[np.maximum(pe, 0)], -3)
        ca, cb = np.where(es >= 0, g.a[np.maximum(es, 0)], -4), np.where(es >= 0, g.b[np.maximum(es, 0)], -5)
        same = pe[:, None] == es[None]
        adj = ((pa[:, None] == ca[None]) | (pa[:, None] == cb[None]) | (pb[:, None] == ca[None]) | (pb[:, None] == cb[None]))
        trans = np.full((len(pe), len(es)), np.inf)
        trans[adj] = SWITCH
        trans[same] = 0.0
        on_off = (pe[:, None] < 0) ^ (es[None] < 0)
        trans[on_off] = ON_OFF
        total = costs[-1][:, None] + trans
        arg = np.argmin(total, 0)
        states.append(es); costs.append(total[arg, np.arange(len(es))] + em); back.append(arg)
    path = [int(np.argmin(costs[-1]))]
    for k in range(K - 1, 0, -1):
        path.append(int(back[k][path[-1]]))
    path = path[::-1]
    edge = np.array([states[k][path[k]] for k in range(K)])
    off = np.array([next((c[2] for c in cands[k] if c[0] == edge[k]), np.nan) if edge[k] >= 0 else np.nan for k in range(K)])
    return edge, off


def runs_of(edge):
    out, k0 = [], 0
    for k in range(1, len(edge) + 1):
        if k == len(edge) or edge[k] != edge[k0]:
            out.append([int(edge[k0]), k0, k])
            k0 = k
    return out


def clean(edge):
    """Absorb flicker: runs shorter than MIN_RUN take their neighbour's edge."""
    edge = edge.copy()
    for _ in range(3):
        rs = runs_of(edge)
        changed = False
        for i, (e, k0, k1) in enumerate(rs):
            if k1 - k0 >= MIN_RUN or len(rs) == 1:
                continue
            prev = rs[i - 1] if i else None
            nxt = rs[i + 1] if i + 1 < len(rs) else None
            pick = max([r for r in (prev, nxt) if r], key=lambda r: r[2] - r[1])
            edge[k0:k1] = pick[0]
            changed = True
        if not changed:
            break
    return edge


def node_end(g, e, n):
    """Offset of node n along edge e (0 at a, len at b)."""
    return 0.0 if g.a[e] == n else float(g.length[e])


def decisions(g, edge, off):
    """Junction choices: (d_in, d_out) pairs."""
    out = []
    rs = runs_of(edge)
    for i, (e, k0, k1) in enumerate(rs):
        if e < 0:
            continue
        o = off[k0:k1]
        # Turning back at a junction within one run on the same edge.
        if len(o) >= 4:
            for kk, fn in ((int(np.argmax(o)), 'max'), (int(np.argmin(o)), 'min')):
                n = g.b[e] if fn == 'max' else g.a[e]
                end = node_end(g, e, n)
                if abs(o[kk] - end) < CHOICE_M and abs(o[kk] - o[0]) >= CHOICE_M and abs(o[kk] - o[-1]) >= CHOICE_M and g.degree[n] >= 3:
                    d_in = 2 * e if n == g.b[e] else 2 * e + 1
                    out.append((d_in, d_in ^ 1))
        if i + 1 >= len(rs) or rs[i + 1][0] < 0 or rs[i + 1][0] == e:
            continue
        e2, j0, j1 = rs[i + 1]
        shared = {int(g.a[e]), int(g.b[e])} & {int(g.a[e2]), int(g.b[e2])}
        if not shared:
            continue
        # The junction they passed: the shared node nearest to where they left e.
        n = min(shared, key=lambda n: abs(o[-1] - node_end(g, e, n)))
        if g.degree[n] < 3 or abs(o[-1] - node_end(g, e, n)) > R:
            continue
        if abs(o[0] - o[-1]) < CHOICE_M and k1 - k0 < 5:
            continue   # barely on e: not a real arrival
        o2 = off[j0:j1]
        if np.nanmax(np.abs(o2 - node_end(g, e2, n))) < min(CHOICE_M, 0.8 * g.length[e2]):
            continue   # did not really take e2
        d_in = 2 * e if n == g.b[e] else 2 * e + 1
        d_out = 2 * e2 if n == g.a[e2] else 2 * e2 + 1
        out.append((d_in, d_out))
    return out


def match_area(area):
    g = G.load(area)
    out = []
    on_steps = all_steps = 0
    for pi, p in enumerate(PC.load(area)):
        z = smooth(p['xy'].astype(float))[::STEP]
        if len(z) < 5:
            continue
        edge, off = viterbi(g, z, candidates(g, z))
        edge = clean(edge)
        off = np.where(edge >= 0, off, np.nan)
        # Offsets for steps whose cleaned edge differs from their candidate: project again.
        for k in np.flatnonzero((edge >= 0) & np.isnan(off)):
            near = g.near(z[k], 3 * R)
            off[k] = near[edge[k]][1] if edge[k] in near else np.nan
        on_steps += int((edge >= 0).sum())
        all_steps += len(edge)
        out.append({'piece': pi, 'fold': p['fold'], 'day': p['day'], 'z': z.astype(np.float32), 'edge': edge, 'off': off,
                    'decisions': decisions(g, edge, off)})
    (DATA / 'matched').mkdir(exist_ok=True)
    (DATA / 'matched' / f'{area}.pkl').write_bytes(pickle.dumps(out))
    n_dec = sum(len(m['decisions']) for m in out)
    n_u = sum(1 for m in out for d_in, d_out in m['decisions'] if d_out == d_in ^ 1)
    print(f'{area}: {on_steps / max(all_steps, 1):.0%} of walking matched to a path, {n_dec} junction choices '
          f'({n_u} turned back at a junction)', flush=True)


if __name__ == '__main__':
    from fetch_osm import AREAS
    for area in sys.argv[1:] or [a for a in AREAS if a not in PC.SKIP]:
        match_area(area)
