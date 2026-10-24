"""Build the self-contained route demo page: ml/demo/index.html.

    python ml/demo/build_routes.py [--weights ../results/choice-pop.json] [--pop-fold 0|1]

Inlines into routes-template.html: the route model tables, the Hervanta path
graph with turn tables (cropped to the demo walks), the OpenStreetMap layer
drawn underneath, results, and real walks from the held-out Hervanta forest
with 10 minutes of what really happened next.
"""

import argparse
import json
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).parent
ML = HERE.parent
sys.path.insert(0, str(ML))
sys.path.insert(0, str(HERE))

import graph as G  # noqa: E402
import pieces as PC  # noqa: E402
import route_features as RF  # noqa: E402
from build import vectors  # noqa: E402
from export_routes import EXPORT, export_graph, export_model  # noqa: E402

AREA = 'hervanta'
HIST_S, FUT_S = 60, 600
MARGIN = 1000


def pick_walks(n=10, seed=4, fold=1):
    """Walks from one fold of days; the demo's popularity comes from the other."""
    g = G.load(AREA)
    rng = np.random.default_rng(seed)
    walks = []
    for k in rng.permutation(len(ps := PC.load(AREA))):
        p = ps[k]
        xy = p['xy'].astype(float)
        if p['fold'] != fold or len(xy) < HIST_S + FUT_S + 1:
            continue
        cuts = [c for c in range(HIST_S, len(xy) - FUT_S, 30)
                if np.linalg.norm(xy[c] - xy[c - HIST_S]) >= 25 and g.near(xy[c], 15)]
        if not cuts:
            continue
        c = int(rng.choice(cuts))
        walks.append({'hist': np.round(xy[c - HIST_S:c + 1:2], 1).tolist(), 'fut': np.round(xy[c + 1:c + 1 + FUT_S], 1).tolist(),
                      'fold': p['fold'], 'day': p['day']})
        if len(walks) == n:
            break
    return walks


SCORE_JS = """
import { createRoutePredictor } from '%s';
let raw = '';
for await (const chunk of process.stdin) raw += chunk;
const d = JSON.parse(raw), rp = createRoutePredictor(d.model, d.graph);
const dist = (r, p) => Math.min(...r.line.slice(1).map((b, i) => {
  const a = r.line[i], vx = b[0] - a[0], vy = b[1] - a[1], L2 = vx * vx + vy * vy || 1e-9;
  const f = Math.max(0, Math.min(1, ((p[0] - a[0]) * vx + (p[1] - a[1]) * vy) / L2));
  return Math.hypot(a[0] + f * vx - p[0], a[1] + f * vy - p[1]);
}));
console.log(JSON.stringify(d.walks.map((w) => {
  const pred = rp.predictRoutes(w.hist, 4), truth = w.fut[299], last = w.hist[w.hist.length - 1];
  return { routes: pred.routes.length, top: pred.routes.length > 0 && dist(pred.routes[0], truth) <= 20,
           moved: Math.hypot(truth[0] - last[0], truth[1] - last[1]) };
})));
"""


def order_walks(walks, model, graph):
    """Moving walks where the top route was right at a fork first, misses last
    (they stay in: the page should show where the model fails too)."""
    import subprocess
    js = SCORE_JS % (ML / 'runtime' / 'route-model.js').as_uri()
    r = subprocess.run(['node', '--input-type=module', '-e', js], input=json.dumps({'walks': walks, 'model': model, 'graph': graph}),
                       capture_output=True, text=True, check=True)
    s = json.loads(r.stdout)
    key = lambda i: (not (s[i]['top'] and s[i]['routes'] >= 2 and s[i]['moved'] >= 100), not s[i]['top'], -s[i]['moved'])
    order = sorted(range(len(walks)), key=key)
    print('demo walks (top route right at 5 min, routes, metres moved):',
          [(s[i]['top'], s[i]['routes'], round(s[i]['moved'])) for i in order])
    return [walks[i] for i in order]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--weights')
    ap.add_argument('--pop', help='popularity counts JSON for the demo walks (from route_stats.py)')
    a = ap.parse_args()
    walks = pick_walks()
    pts = np.concatenate([np.array(w['hist'] + w['fut']) for w in walks])
    x0, y0 = pts.min(0) - MARGIN
    x1, y1 = pts.max(0) + MARGIN
    weights = np.array(json.loads(Path(a.weights).read_text())['weights'], np.float32) if a.weights else RF.HAND_WEIGHTS
    pop = {int(k): v for k, v in json.loads(Path(a.pop).read_text()).items()} if a.pop else None
    graph = export_graph(AREA, weights, pop, (x0, y0, x1, y1), 'hervanta-demo')
    export_model()
    model = json.loads((EXPORT / 'route-model.json').read_text())
    walks = order_walks(walks, model, graph)
    metrics_f = ML / 'results' / 'metrics-routes.json'
    metrics = json.loads(metrics_f.read_text()) if metrics_f.exists() else None
    runtime = (ML / 'runtime' / 'route-model.js').read_text().replace('export function', 'function')
    filt = (ML / 'runtime' / 'route-filter.js').read_text().replace('export function', 'function')
    fusion_f = ML / 'results' / 'metrics-fusion.json'
    fusion = json.loads(fusion_f.read_text()) if fusion_f.exists() else None
    vec = vectors((x0, y0, x1, y1))
    page = (HERE / 'routes-template.html').read_text()
    for key, val in [('/*MODEL*/', json.dumps(model)), ('/*GRAPH*/', json.dumps(graph, separators=(',', ':'))),
                     ('/*WALKS*/', json.dumps(walks, separators=(',', ':'))), ('/*VECTORS*/', json.dumps(vec, separators=(',', ':'))),
                     ('/*METRICS*/', json.dumps(metrics)), ('/*FUSION*/', json.dumps(fusion)),
                     ('/*RUNTIME*/', runtime), ('/*FILTER*/', filt)]:
        assert key in page, key
        page = page.replace(key, val)
    (HERE / 'index.html').write_text(page)
    print(f'wrote {HERE / "index.html"} ({len(page) / 1024:.0f} kB): {len(walks)} walks, '
          f'{len(graph["edges"])} graph edges, {len(vec["paths"])} paths drawn')


if __name__ == '__main__':
    main()
