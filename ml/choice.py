"""Learn which way people go at a junction, and test it on Hervanta.

    python ml/choice.py

A conditional logit: every option gets a score features @ weights, and the
probability of an option is softmax over the options at that junction.
Options that run side by side count as one choice. Two models:
  map          only the map: turn angle, path type, dead ends, hiking routes...
  map + where people walk
               also how many walks (on other days) used each option
Baselines get the same treatment with a single feature each, so their
temperature is fitted and the log-loss comparison is fair.

Writes results/choice-map.json, results/choice-pop.json (weights) and
results/choice-metrics.json (Hervanta junction metrics with 90% intervals
from resampling outing days).
"""

import json
import pickle
from pathlib import Path

import numpy as np
import torch

import graph as G
import pieces as PC
import route_features as RF
from train import TEST_AREA

HERE = Path(__file__).parent
DATA = HERE / 'data'
POP = RF.NAMES.index('popular')


def load_pop(area, fold):
    f = DATA / 'popularity' / f'{area}-fold{fold}.json'
    c = {int(k): v for k, v in json.loads(f.read_text()).items()} if f.exists() else {}
    return c or None


def junctions(area):
    """One row per choice: features of every option, option groups, chosen group, day."""
    g = G.load(area)
    pops = [load_pop(area, 1), load_pop(area, 0)]   # walks in fold k see popularity from the other fold
    rows = []
    for m in pickle.loads((DATA / 'matched' / f'{area}.pkl').read_bytes()):
        for d_in, d_out in m['decisions']:
            opts = RF.options(g, d_in)
            if d_out not in opts or len(opts) < 2:
                continue
            group = RF.option_groups(g, opts)
            if len(set(group)) < 2:
                continue
            rows.append({'F': RF.features(g, d_in, opts, pops[m['fold']]), 'group': np.array(group),
                         'chosen': group[opts.index(d_out)], 'day': m['day'], 'area': area})
    return rows


def pack(rows, cols):
    K = max(len(r['group']) for r in rows)
    F = np.zeros((len(rows), K, len(cols)), np.float32)
    mask = np.zeros((len(rows), K), bool)
    pick = np.zeros((len(rows), K), bool)
    for i, r in enumerate(rows):
        n = len(r['group'])
        F[i, :n] = r['F'][:, cols]
        mask[i, :n] = True
        pick[i, :n] = r['group'] == r['chosen']
    return torch.as_tensor(F), torch.as_tensor(mask), torch.as_tensor(pick)


def log_probs(w, F, mask):
    u = (F @ w).masked_fill(~mask, -1e9)
    return torch.log_softmax(u, 1)


def fit(rows, cols, l2=1e-3):
    F, mask, pick = pack(rows, cols)
    w = torch.zeros(len(cols), requires_grad=True)
    opt = torch.optim.LBFGS([w], max_iter=200, line_search_fn='strong_wolfe')

    def closure():
        opt.zero_grad()
        lp = log_probs(w, F, mask)
        loss = -torch.logsumexp(lp.masked_fill(~pick, -1e9), 1).mean() + l2 * (w ** 2).sum()
        loss.backward()
        return loss
    opt.step(closure)
    return w.detach()


@torch.no_grad()
def scores(w, rows, cols):
    """Per choice: log-probability of the chosen group, and whether it was ranked first."""
    F, mask, pick = pack(rows, cols)
    p = log_probs(w, F, mask).exp() if w is not None else mask.float() / mask.sum(1, keepdim=True)
    ll, top = [], []
    for i, r in enumerate(rows):
        gp = {}
        for k, gr in enumerate(r['group']):
            gp[gr] = gp.get(gr, 0.0) + float(p[i, k])
        ll.append(np.log(max(gp[r['chosen']], 1e-9)))
        top.append(max(gp, key=gp.get) == r['chosen'])
    return np.array(ll), np.array(top, float)


def by_day_interval(values, days, rng, n=2000):
    days = np.array(days)
    uniq = np.unique(days)
    idx = {d: np.flatnonzero(days == d) for d in uniq}
    stats = [np.mean(np.concatenate([values[idx[d]] for d in rng.choice(uniq, len(uniq))])) for _ in range(n)]
    return [round(float(np.percentile(stats, 5)), 3), round(float(np.percentile(stats, 95)), 3)]


def main():
    from fetch_osm import AREAS
    areas = [a for a in AREAS if a not in PC.SKIP]
    data = {a: junctions(a) for a in areas}
    train = [r for a in areas if a != TEST_AREA for r in data[a]]
    test = data[TEST_AREA]
    # Uniform among *groups* is the honest "no idea" baseline.
    for r in test:
        r['n_groups'] = len(set(r['group']))
    print(f'{len(train)} training choices, {len(test)} Hervanta choices '
          f'(median {int(np.median([r["n_groups"] for r in test]))} ways to go)')
    all_cols = list(range(RF.N_FEAT))
    map_cols = [c for c in all_cols if c != POP]
    models = {
        'uniform': None,
        'straightest': [RF.NAMES.index('turn')],
        'same path continues': [RF.NAMES.index('same_way')],
        'most walked': [POP],
        'map': map_cols,
        'map + where people walk': all_cols,
    }
    rng = np.random.default_rng(0)
    out, fitted = {}, {}
    for name, cols in models.items():
        w = fit(train, cols) if cols is not None else None
        ll, top = scores(w, test, cols if cols is not None else [0])
        days = [r['day'] for r in test]
        out[name] = {'top1': round(float(top.mean()), 3), 'top1_90': by_day_interval(top, days, rng),
                     'logloss': round(float(-ll.mean()), 3), 'logloss_90': [-x for x in by_day_interval(ll, days, rng)][::-1]}
        if cols is not None:
            fitted[name] = (cols, w)
        print(f"{name:26} top-1 {out[name]['top1']:.0%} {out[name]['top1_90']}   log-loss {out[name]['logloss']:.3f}")
    for key, name in (('map', 'map'), ('pop', 'map + where people walk'), ('straightest', 'straightest')):
        cols, w = fitted[name]
        full = np.zeros(RF.N_FEAT)
        full[cols] = w.numpy()
        (HERE / 'results' / f'choice-{key}.json').write_text(json.dumps(
            {'names': RF.NAMES, 'weights': [round(float(v), 4) for v in full], 'trained_on': len(train)}, indent=1))
    (HERE / 'results' / 'choice-metrics.json').write_text(json.dumps({'n_test': len(test), 'n_train': len(train), 'models': out}, indent=1))
    _, w = fitted['map + where people walk']
    print('weights (map + where people walk):', {n: round(float(v), 2) for n, v in zip(RF.NAMES, w)})


if __name__ == '__main__':
    main()
