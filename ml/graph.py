"""The walkable path network of an area as a routable graph.

    python ml/graph.py [areas...]     # build and cache ml/data/graph/<area>.pkl

Nodes are junctions and dead ends (OSM junctions closer than 8 m are merged
into one, so a messy crossing is one decision point). Edges run from junction
to junction. Directed edge d is edge d // 2 travelled from a to b when d is
even and from b to a when d is odd.
"""

import json
import math
import pickle
import sys
from collections import defaultdict
from pathlib import Path

import numpy as np
from scipy.spatial import cKDTree

DATA = Path(__file__).parent / 'data'
MERGE_M = 8.0
MIN_LOOP_M = 30.0
PROBE_M = 25.0
SAMPLE_M = 2.0
DEAD_END_M = 150.0

CLASSES = ['path', 'track', 'footway', 'cycleway', 'road', 'steps']
CLASS_OF = {'path': 0, 'bridleway': 0, 'track': 1, 'footway': 2, 'pedestrian': 2, 'cycleway': 3, 'steps': 5}


def class_of(hw):
    return CLASS_OF.get(hw, 4)


def poly_len(p):
    return float(np.linalg.norm(np.diff(p, axis=0), axis=1).sum()) if len(p) > 1 else 0.0


def point_at(p, dist):
    """Point `dist` metres along polyline p (clamped to its end)."""
    seg = np.linalg.norm(np.diff(p, axis=0), axis=1)
    cum = np.r_[0, np.cumsum(seg)]
    if dist >= cum[-1]:
        return p[-1].copy()
    i = int(np.searchsorted(cum, dist, side='right') - 1)
    f = (dist - cum[i]) / max(seg[i], 1e-9)
    return p[i] + f * (p[i + 1] - p[i])


class Graph:
    def __init__(self, area, node_xy, edges):
        self.area = area
        self.node_xy = node_xy
        self.edges = edges                      # list of dicts: a, b, poly, len, cls, name, route, sac, way_a, way_b
        self.E = len(edges)
        self.a = np.array([e['a'] for e in edges])
        self.b = np.array([e['b'] for e in edges])
        self.length = np.array([e['len'] for e in edges])
        self.cls = np.array([e['cls'] for e in edges])
        self.out = defaultdict(list)            # node -> directed edges leaving it
        for i, e in enumerate(edges):
            self.out[e['a']].append(2 * i)
            self.out[e['b']].append(2 * i + 1)
        self.degree = np.array([len(self.out[n]) for n in range(len(node_xy))])
        # Sample points every 2 m for "which edge is near here".
        xs, es, offs = [], [], []
        for i, e in enumerate(edges):
            n = max(2, int(math.ceil(e['len'] / SAMPLE_M)) + 1)
            for d in np.linspace(0, e['len'], n):
                xs.append(point_at(e['poly'], d))
                es.append(i)
                offs.append(d)
        self.pt_xy = np.array(xs)
        self.pt_edge = np.array(es)
        self.pt_off = np.array(offs)
        self.kd = cKDTree(self.pt_xy)

    # Directed-edge helpers.
    def tail(self, d):
        return self.a[d // 2] if d % 2 == 0 else self.b[d // 2]

    def head(self, d):
        return self.b[d // 2] if d % 2 == 0 else self.a[d // 2]

    def poly(self, d):
        p = self.edges[d // 2]['poly']
        return p if d % 2 == 0 else p[::-1]

    def _memo(self, key, d, fn):
        cache = self.__dict__.setdefault('_cache', {})
        k = (key, d)
        if k not in cache:
            cache[k] = fn()
        return cache[k]

    def probe(self, d, dist=PROBE_M):
        if dist != PROBE_M:
            return point_at(self.poly(d), dist)
        return self._memo('probe', d, lambda: point_at(self.poly(d), PROBE_M))

    def heading_out(self, d):
        """Direction leaving the tail, looking PROBE_M along the edge."""
        def f():
            v = self.probe(d) - self.poly(d)[0]
            return math.atan2(v[1], v[0])
        return self._memo('out', d, f)

    def heading_in(self, d):
        """Direction arriving at the head, from PROBE_M before it."""
        def f():
            p = self.poly(d)[::-1]
            v = p[0] - point_at(p, PROBE_M)
            return math.atan2(v[1], v[0])
        return self._memo('in', d, f)

    def dead_end(self, d):
        return self.degree[self.head(d)] == 1 and self.length[d // 2] < DEAD_END_M

    def way_out(self, d):
        e = self.edges[d // 2]
        return e['way_a'] if d % 2 == 0 else e['way_b']

    def way_in(self, d):
        e = self.edges[d // 2]
        return e['way_b'] if d % 2 == 0 else e['way_a']

    def near(self, xy, r):
        """{edge: (distance, offset along edge)} for edges with a sample point within r."""
        out = {}
        for i in self.kd.query_ball_point(xy, r):
            e, dist = self.pt_edge[i], float(np.linalg.norm(self.pt_xy[i] - xy))
            if e not in out or dist < out[e][0]:
                out[e] = (dist, float(self.pt_off[i]))
        return out


def build(area):
    ways = json.loads((DATA / 'graph_raw' / f'{area}.json').read_text())['ways']
    use = defaultdict(int)
    pos = {}
    for w in ways:
        for nid, xy in zip(w['nodes'], w['xy']):
            use[nid] += 1
            pos[nid] = xy
        use[w['nodes'][0]] += 1          # way ends always split
        use[w['nodes'][-1]] += 1
    split = {nid for nid, c in use.items() if c >= 2}

    # Segments between split nodes.
    segs = []
    for w in ways:
        start = 0
        for k in range(1, len(w['nodes'])):
            if w['nodes'][k] in split:
                segs.append({'na': w['nodes'][start], 'nb': w['nodes'][k], 'poly': np.array(w['xy'][start:k + 1]),
                             'hw': w['hw'], 'name': w['name'], 'route': w['route'], 'sac': w['sac'] is not None,
                             'way': w['id']})
                start = k

    # Merge split nodes closer than MERGE_M (union-find).
    ids = sorted(split)
    idx = {nid: i for i, nid in enumerate(ids)}
    xy = np.array([pos[n] for n in ids], float)
    parent = list(range(len(ids)))

    def find(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i
    for i, j in cKDTree(xy).query_pairs(MERGE_M):
        ri, rj = find(i), find(j)
        if ri != rj:
            parent[ri] = rj
    roots = sorted({find(i) for i in range(len(ids))})
    rmap = {r: k for k, r in enumerate(roots)}
    cluster = np.array([rmap[find(i)] for i in range(len(ids))])
    node_xy = np.zeros((len(roots), 2))
    np.add.at(node_xy, cluster, xy)
    node_xy /= np.bincount(cluster, minlength=len(roots))[:, None]

    # Edges between merged nodes; contract pass-through (degree 2) nodes.
    edges = {}
    inc = defaultdict(set)
    for k, s in enumerate(segs):
        a, b = cluster[idx[s['na']]], cluster[idx[s['nb']]]
        p = s['poly'].astype(float).copy()
        p[0], p[-1] = node_xy[a], node_xy[b]
        L = poly_len(p)
        if a == b and L < MIN_LOOP_M:
            continue
        c = class_of(s['hw'])
        edges[k] = {'a': a, 'b': b, 'poly': p, 'len': L, 'parts': [(c, L, s['name'], s['route'], s['sac'])],
                    'way_a': s['way'], 'way_b': s['way']}
        inc[a].add(k)
        inc[b].add(k)

    def ends(k, n):
        e = edges[k]
        return (e['a'] == n) + (e['b'] == n)

    for n in list(inc):
        ks = list(inc[n])
        if len(ks) != 2 or any(ends(k, n) != 1 for k in ks):
            continue
        k1, k2 = ks
        e1, e2 = edges[k1], edges[k2]
        p1 = e1['poly'] if e1['b'] == n else e1['poly'][::-1]          # ends at n
        p2 = e2['poly'] if e2['a'] == n else e2['poly'][::-1]          # starts at n
        a1 = e1['a'] if e1['b'] == n else e1['b']
        b2 = e2['b'] if e2['a'] == n else e2['a']
        wa = e1['way_a'] if e1['b'] == n else e1['way_b']
        wb = e2['way_b'] if e2['a'] == n else e2['way_a']
        if a1 == b2 and poly_len(p1) + poly_len(p2) < MIN_LOOP_M:
            continue
        merged = {'a': a1, 'b': b2, 'poly': np.vstack([p1, p2[1:]]), 'len': e1['len'] + e2['len'],
                  'parts': e1['parts'] + e2['parts'], 'way_a': wa, 'way_b': wb}
        del edges[k1], edges[k2]
        edges[k1] = merged
        inc[n].clear()
        inc[a1].discard(k1); inc[a1].discard(k2); inc[a1].add(k1)
        inc[b2].discard(k1); inc[b2].discard(k2); inc[b2].add(k1)

    # Renumber nodes that still have edges, summarise the parts of each edge.
    used = sorted({e['a'] for e in edges.values()} | {e['b'] for e in edges.values()})
    nmap = {n: i for i, n in enumerate(used)}
    out = []
    for e in edges.values():
        L = max(e['len'], 1e-6)
        by_cls = defaultdict(float)
        for c, l, *_ in e['parts']:
            by_cls[c] += l
        names = [(l, nm) for c, l, nm, *_ in e['parts'] if nm]
        out.append({'a': nmap[e['a']], 'b': nmap[e['b']], 'poly': e['poly'], 'len': e['len'],
                    'cls': max(by_cls, key=by_cls.get),
                    'name': max(names)[1] if names else None,
                    'route': sum(l for c, l, nm, r, s in e['parts'] if r) / L,
                    'sac': any(s for *_, s in e['parts']),
                    'way_a': e['way_a'], 'way_b': e['way_b']})
    return Graph(area, node_xy[used], out)


def load(area):
    f = DATA / 'graph' / f'{area}.pkl'
    if f.exists():
        return pickle.loads(f.read_bytes())
    g = build(area)
    f.parent.mkdir(exist_ok=True)
    f.write_bytes(pickle.dumps(g))
    return g


if __name__ == '__main__':
    from fetch_osm import AREAS
    for area in sys.argv[1:] or list(AREAS):
        f = DATA / 'graph' / f'{area}.pkl'
        f.unlink(missing_ok=True)
        g = load(area)
        deg = np.bincount(g.degree)
        print(f'{area}: {len(g.node_xy)} nodes ({deg[3:].sum()} junctions of 3+, {deg[1] if len(deg) > 1 else 0} dead ends), '
              f'{g.E} edges, {g.length.sum() / 1000:.0f} km, median edge {np.median(g.length):.0f} m', flush=True)
