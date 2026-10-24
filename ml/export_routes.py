"""Export the route model for the phone and the web.

    python ml/export_routes.py [--weights results/choice-map.json] [--pop fold] [--crop x0,y0,x1,y1] [--out name]

Writes ml/export/graphs/<name>.json (format "route-graph-1"): the path graph
with per-junction turn tables, and ml/export/route-model.json: the speed,
turning-back and leaving-the-paths tables plus the rollout settings.

Turn tables are compressed rows: for directed edge d, the options are
turnTo[turnOff[d] .. turnOff[d+1]) with probabilities turnP[...].
"""

import argparse
import json
from pathlib import Path

import numpy as np

import graph as G
import route_features as RF
from geo import origin

HERE = Path(__file__).parent
EXPORT = HERE / 'export'


def simplify(p, tol=2.0):
    """Ramer-Douglas-Peucker, keeping the end points."""
    keep = np.zeros(len(p), bool)
    keep[[0, -1]] = True
    stack = [(0, len(p) - 1)]
    while stack:
        i, j = stack.pop()
        if j <= i + 1:
            continue
        a, b = p[i], p[j]
        ab = b - a
        n = np.linalg.norm(ab)
        seg = p[i + 1:j]
        if n < 1e-9:
            dist = np.linalg.norm(seg - a, axis=1)
        else:
            dist = np.abs(ab[0] * (seg[:, 1] - a[1]) - ab[1] * (seg[:, 0] - a[0])) / n
        k = int(np.argmax(dist))
        if dist[k] > tol:
            keep[i + 1 + k] = True
            stack += [(i, i + 1 + k), (i + 1 + k, j)]
    return p[keep]


def turn_tables(g, weights, pop=None, keep=None):
    """CSR turn tables for every directed edge, softmax(features @ weights)."""
    off, to, prob = [0], [], []
    for d in range(2 * g.E):
        opts = [o for o in RF.options(g, d) if keep is None or keep[o // 2]]
        if keep is not None and not keep[d // 2]:
            opts = []
        if opts:
            u = RF.features(g, d, opts, pop) @ weights
            p = np.exp(u - u.max())
            p /= p.sum()
            to += opts
            prob += [round(float(x), 4) for x in p]
        off.append(len(to))
    return off, to, prob


def export_graph(area, weights, pop=None, crop=None, name=None, dest=None):
    g = G.load(area)
    keep = None
    if crop is not None:
        x0, y0, x1, y1 = crop
        keep = np.array([((e['poly'][:, 0] >= x0) & (e['poly'][:, 0] <= x1) &
                          (e['poly'][:, 1] >= y0) & (e['poly'][:, 1] <= y1)).all() for e in g.edges])
    eidx = np.flatnonzero(keep) if keep is not None else np.arange(g.E)
    new = {int(e): i for i, e in enumerate(eidx)}
    nodes_used = sorted({int(g.a[e]) for e in eidx} | {int(g.b[e]) for e in eidx})
    nmap = {n: i for i, n in enumerate(nodes_used)}
    names, name_idx = [], {}
    edges = []
    for e in eidx:
        ed = g.edges[e]
        nm = ed['name']
        if nm is not None and nm not in name_idx:
            name_idx[nm] = len(names)
            names.append(nm)
        poly = simplify(ed['poly'])
        edges.append([nmap[int(ed['a'])], nmap[int(ed['b'])], round(ed['len'], 1), int(ed['cls']),
                      name_idx.get(nm, -1), round(ed['route'], 2), [round(float(v), 1) for v in poly.ravel()]])
    off, to, prob = turn_tables(g, weights, pop, keep)
    # Re-index the tables to the exported edges.
    t_off, t_to, t_p = [0], [], []
    for e in eidx:
        for d in (2 * e, 2 * e + 1):
            for k in range(off[d], off[d + 1]):
                t_to.append(2 * new[to[k] // 2] + to[k] % 2)
                t_p.append(prob[k])
            t_off.append(len(t_to))
    lat0, lon0 = origin(area)
    out = {'format': 'route-graph-1', 'area': area, 'lat0': lat0, 'lon0': lon0,
           'classes': G.CLASSES, 'names': names,
           'nodes': [round(float(v), 1) for n in nodes_used for v in g.node_xy[n]],
           'edges': edges, 'turnOff': t_off, 'turnTo': t_to, 'turnP': t_p}
    dest = dest or EXPORT / 'graphs'
    dest.mkdir(parents=True, exist_ok=True)
    f = dest / f'{name or area}.json'
    f.write_text(json.dumps(out, separators=(',', ':')))
    print(f'{f.name}: {len(nodes_used)} nodes, {len(edges)} edges, {len(t_to)} turn entries, {f.stat().st_size / 1024:.0f} kB')
    return out


DEFAULT_MODEL = {
    'format': 'route-model-1',
    # Distance walked by time t (m), by recent speed (m/s). Placeholder until route_stats.py measures it.
    'speed': {'vEdges': [0.3, 0.7, 1.0, 1.3], 't': [0, 30, 60, 120, 180, 300, 420, 600],
              'q': {k: [[round(f * v * t, 1) for t in [0, 30, 60, 120, 180, 300, 420, 600]] for v in (0.2, 0.6, 0.9, 1.2, 1.5)]
                    for k, f in (('q10', 0.45), ('q50', 0.85), ('q90', 1.25))}},
    'back': {'moving': 0.08, 'stopped': 0.4},
    'offPath': {'t': [0, 60, 120, 300, 600], 'on': [0.0, 0.03, 0.05, 0.08, 0.12], 'off': [1.0, 0.7, 0.6, 0.5, 0.45]},
    'locate': {'minR': 25, 'accMul': 2.5, 'sigma0': 5, 'kappa': 2, 'maxStarts': 3, 'minShare': 0.1,
               'offPathM': 20, 'movedM': 10},
    'rollout': {'prune': 0.01, 'maxLeaves': 300, 'horizon': 600},
    'merge': {'minShare': 0.1, 'maxRoutes': 4, 'otherMin': 0.03, 'parallelM': 10, 'probeM': 25},
}


def export_model():
    stats = HERE / 'results' / 'route-stats.json'
    model = json.loads(json.dumps(DEFAULT_MODEL))
    if stats.exists():
        model.update(json.loads(stats.read_text()))
    (EXPORT / 'route-model.json').write_text(json.dumps(model, indent=1))
    print(f'route-model.json ({"measured tables" if stats.exists() else "placeholder tables"})')


def export_eval(area='hervanta'):
    """For runtime/eval-routes.mjs: the area's graph with each model's turn
    tables, and every held-out moment with 60 s before and 10 min after."""
    import pieces as PC
    import route_features as RF
    out = HERE / 'data' / 'eval'
    load = lambda k: np.array(json.loads((HERE / 'results' / f'choice-{k}.json').read_text())['weights'], np.float32)
    variants = {'uniform': (np.zeros(RF.N_FEAT, np.float32), None), 'straightest': (load('straightest'), None),
                'map': (load('map'), None)}
    for k in (0, 1):
        f = HERE / 'data' / 'popularity' / f'{area}-fold{k}.json'
        pop = {int(e): c for e, c in json.loads(f.read_text()).items()}
        variants[f'pop-from-fold{k}'] = (load('pop'), pop)
    for name, (w, pop) in variants.items():
        export_graph(area, w, pop, None, f'{area}-{name}', out)
    windows = []
    for p in PC.load(area):
        xy = p['xy'].astype(float)
        for c in range(60, len(xy) - 600, 30):
            windows.append({'hist': np.round(xy[c - 60:c + 1:2], 1).tolist(),
                            'fut': {t: np.round(xy[c + t], 1).tolist() for t in (120, 300, 600)},
                            'path': np.round(xy[c:c + 601], 1).tolist(),   # every second from the cut, for simulated signals
                            'fold': p['fold'], 'day': p['day']})
    (out / f'{area}-windows.json').write_text(json.dumps(windows))
    print(f'{len(windows)} held-out moments with 10 min after, from {len({w["day"] for w in windows})} days')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--eval', action='store_true', help='export graphs and moments for runtime/eval-routes.mjs')
    ap.add_argument('--area', default='hervanta')
    ap.add_argument('--weights', help='choice model JSON from choice.py (default: hand-set weights)')
    ap.add_argument('--pop', help='popularity counts JSON (undirected edge -> count)')
    ap.add_argument('--crop', help='x0,y0,x1,y1 in the area frame')
    ap.add_argument('--out')
    a = ap.parse_args()
    if a.eval:
        export_model()
        export_eval(a.area)
        return
    w = np.array(json.loads(Path(a.weights).read_text())['weights'], np.float32) if a.weights else RF.HAND_WEIGHTS
    pop = {int(k): v for k, v in json.loads(Path(a.pop).read_text()).items()} if a.pop else None
    crop = [float(v) for v in a.crop.split(',')] if a.crop else None
    export_graph(a.area, w, pop, crop, a.out)
    export_model()


if __name__ == '__main__':
    main()
