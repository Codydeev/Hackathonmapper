"""Train movement model v2 (map + destination) and compare it with v1 and the
simple baselines on the held-out Hervanta forest.

    python ml/train2.py                       # -> ml/runs/v2-<time>/
    python ml/train2.py --eval ml/runs/v2-latest

Rows in metrics.json:
  stand still, same velocity   tuned baselines (as in train.py)
  v1                           history only
  v2, no map                   v2 with the map switched off
  v2                           v2 with the map
  v2 (dest subset), v2 + destination
                               on test walks whose destination is known:
                               the same model without and with being told it
"""

import json
import math
import os
import sys
import time
from pathlib import Path

import numpy as np
import torch
from PIL import Image

import model as M
import model2 as M2
from train import (CV_WINDOWS, EVAL_H, EVAL_NOISE, GPS_ACC, NOISE_MAX, NOISE_RHO, TEST_AREA, as_t, fit_baselines,
                   gaussian, score)

HERE = Path(__file__).parent
DATA = HERE / 'data'
STEPS = int(os.environ.get('STEPS', 30000))
BATCH = 512
DEST_NOISE = 20.0      # m, how far off a planned destination may be
DEST_P = 0.5           # training: how often the destination is shown when known
MAP_P = 0.9            # training: how often the map is shown
UV = M2.patch_offsets()


def load_maps():
    maps = {}
    for meta_f in sorted((DATA / 'map').glob('*.meta.json')):
        meta = json.loads(meta_f.read_text())
        img = np.asarray(Image.open(DATA / 'map' / f'{meta["area"]}.png'), np.float32) / 255
        maps[meta['area']] = (torch.as_tensor(img).permute(2, 0, 1).contiguous(), meta)
    return maps


def load(maps):
    rng = np.random.default_rng(0)
    parts = {'train': [], 'val': [], 'test': []}
    names = []
    for f in sorted((DATA / 'windows').glob('*.npz')):
        if f.stem not in maps:
            print(f'{f.stem}: no map yet, skipped')
            continue
        z = dict(np.load(f))
        z['area'] = np.full(len(z['hist']), len(names))
        names.append(f.stem)
        if f.stem == TEST_AREA:
            parts['test'].append(z)
            continue
        traces = np.unique(z['trace'])
        held = np.isin(z['trace'], rng.choice(traces, max(1, len(traces) // 10), replace=False))
        parts['val'].append({k: v[held] for k, v in z.items()})
        parts['train'].append({k: v[~held] for k, v in z.items()})
    keys = ('hist', 'fut', 'origin', 'dest', 'area')
    out = {k: {key: np.concatenate([p[key] for p in v]) for key in keys} for k, v in parts.items()}
    return out, [maps[n] for n in names]


def sample_maps(rasters, area, pts):
    out = torch.zeros(len(pts), 3, M2.PATCH, M2.PATCH)
    for a in np.unique(area):
        sel = area == a
        out[torch.as_tensor(sel)] = M2.sample_map(*rasters[a], pts[sel])
    return out


def corrupt2(d, idx, rng, rasters, sigma=None, h=None, jitter=True, dest_p=DEST_P, map_p=MAP_P):
    """v1's corruption (rotation, mirror, mesh-like noise, short histories),
    plus the map patch and the destination seen through the same transform."""
    hist, fut = d['hist'][idx].astype(float), d['fut'][idx].astype(float)
    dest, origin, area = d['dest'][idx].astype(float), d['origin'][idx].astype(float), d['area'][idx]
    B = len(idx)
    th = rng.uniform(0, 2 * math.pi, B)
    flip = rng.random(B) < 0.5

    def fwd(a):
        a = M.rotate(a, th)
        a[flip, ..., 1] *= -1
        return a

    hist, fut, dest_c = fwd(hist), fwd(fut), fwd(np.nan_to_num(dest))
    if sigma is None:
        sigma = np.where(rng.random(B) < 0.35, 0.0, rng.uniform(0, NOISE_MAX, B))
    sigma = np.broadcast_to(sigma, (B,)).astype(float)
    e = np.empty((B, M.HIST_N, 2))
    e[:, 0] = rng.standard_normal((B, 2))
    for t in range(1, M.HIST_N):
        e[:, t] = NOISE_RHO * e[:, t - 1] + math.sqrt(1 - NOISE_RHO ** 2) * rng.standard_normal((B, 2))
    hist = hist + e * sigma[:, None, None]
    if jitter:
        first = np.where(rng.random(B) < 0.2, rng.integers(0, M.HIST_N - 1, B), 0)
        hist = hist[np.arange(B)[:, None], np.maximum(np.arange(M.HIST_N)[None], first[:, None])]
    if h is None:
        h = np.round(np.exp(rng.uniform(math.log(M.H_MIN), math.log(M.H_MAX), B))).astype(int)
    h = np.broadcast_to(h, (B,)).astype(int)
    now = hist[:, -1]
    target = fut[np.arange(B), h - 1] - now
    acc = np.sqrt(sigma ** 2 + GPS_ACC ** 2) * (np.exp(0.25 * rng.standard_normal(B)) if jitter else 1)
    x, head = M.features(hist, acc, h.astype(float))

    has_dest = ~np.isnan(dest[:, 0]) & (rng.random(B) < dest_p)
    seen = dest_c + DEST_NOISE * rng.standard_normal((B, 2)) - now
    dfeat = M2.dest_features(M.rotate(seen, -head), has_dest)

    has_map = rng.random(B) < map_p
    pts = now[:, None, None] + M.rotate(UV[None], head)       # walking frame -> this batch's frame
    pts[flip, ..., 1] *= -1
    pts = M.rotate(pts, -th) + origin[:, None, None]           # -> the area's map frame
    patch = sample_maps(rasters, area, pts)
    patch[torch.as_tensor(~has_map)] = 0

    x2 = np.concatenate([x, dfeat, has_map[:, None].astype(np.float32)], 1)
    return x2, patch, h.astype(np.float32), M.rotate(target, -head).astype(np.float32), M.rotate(hist - now[:, None], -head)


def train(data, rasters, out):
    torch.manual_seed(0)
    rng = np.random.default_rng(1)
    dev = torch.device('mps' if torch.backends.mps.is_available() else 'cpu')   # the map network wants a GPU
    model = M2.MovementModel2().to(dev)
    opt = torch.optim.AdamW(model.parameters(), lr=3e-3, weight_decay=1e-5)
    sched = torch.optim.lr_scheduler.OneCycleLR(opt, max_lr=3e-3, total_steps=STEPS, pct_start=0.05)
    va = data['val']
    vx, vp, vh, vy, _ = corrupt2(va, np.arange(len(va['hist'])), np.random.default_rng(2), rasters)
    vx, vh, vy, vp = [t.to(dev) for t in (*as_t(vx, vh, vy), vp)]
    best, t0 = float('inf'), time.time()
    tr = data['train']
    for step in range(1, STEPS + 1):
        i = rng.integers(0, len(tr['hist']), BATCH)
        x, p, h, y, _ = corrupt2(tr, i, rng, rasters)
        x, h, y, p = [t.to(dev) for t in (*as_t(x, h, y), p)]
        loss = -M.mixture_logpdf(y, *model(x, p, h)).mean()
        opt.zero_grad()
        loss.backward()
        torch.nn.utils.clip_grad_norm_(model.parameters(), 5.0)
        opt.step()
        sched.step()
        if step % 1000 == 0 or step == STEPS:
            with torch.no_grad():
                v = -M.mixture_logpdf(vy, *model(vx, vp, vh)).mean().item()
            if v < best:
                best = v
                torch.save({k: t.cpu() for k, t in model.state_dict().items()}, out / 'model.pt')
            print(f'step {step}: train nll {loss.item():.3f}, val nll {v:.3f}{" *" if v == best else ""}'
                  f'  ({time.time() - t0:.0f} s)', flush=True)
    model = model.cpu()
    model.load_state_dict(torch.load(out / 'model.pt'))
    return model


def record(rows, qname, h, name, params, y, yv, pv, extra=None):
    thr = torch.quantile(M.mixture_logpdf(yv, *pv)[:, 0], 0.10).item()
    r = {'history': qname, 'h': h, 'method': name, **score(params, y, thr)}
    exact = torch.quantile(M.mixture_logpdf(y, *params)[:, 0], 0.10).item()
    r['area90_exact'] = score(params, y, exact)['area90']
    r.update(extra or {})
    rows.append(r)
    print(f"{qname:5} h={h:3d}s  {name:22} err50 {r['err50']:6.1f} m  cover90 {r['cover90']:.2f}  "
          f"exact {r['area90_exact']:6.2f} ha  nll {r['nll']:.2f}", flush=True)


@torch.no_grad()
def evaluate(model, v1, data, rasters):
    rows = []
    tr = (data['train']['hist'], data['train']['fut'])
    te_dest = np.where(~np.isnan(data['test']['dest'][:, 0]))[0]
    for qname, sigma in EVAL_NOISE.items():
        for h in EVAL_H:
            still, k, cv_std = fit_baselines(tr, sigma, h, np.random.default_rng(100 + h))
            sets = {}
            for split, seed in (('val', 1000 + h), ('test', h)):
                d = data[split]
                idx = np.arange(len(d['hist']))
                runs = {}
                for tag, dp, mp in (('map', 0.0, 1.0), ('nomap', 0.0, 0.0), ('dest', 1.0, 1.0)):
                    x, p, hh, y, hr = corrupt2(d, idx, np.random.default_rng(seed), rasters, sigma=sigma, h=h,
                                               jitter=False, dest_p=dp, map_p=mp)
                    runs[tag] = (as_t(x, hh, y), p, hr)
                (x, hh, y), p, hr = runs['map']
                cv_mean = torch.as_tensor(-hr[:, -1 - k] / (k * 2) * h).float()
                sets[split] = {
                    'y': y,
                    'stand still': gaussian(torch.zeros_like(y), torch.full_like(y, still)),
                    f'same velocity': gaussian(cv_mean, cv_std.expand_as(cv_mean)),
                    'v1': v1(x[:, :M.N_IN], hh),
                    'v2, no map': model(runs['nomap'][0][0], runs['nomap'][1], hh),
                    'v2': model(x, p, hh),
                    'v2 + destination': model(runs['dest'][0][0], runs['dest'][1], hh),
                }
            v, t = sets['val'], sets['test']
            for name in ('stand still', 'same velocity', 'v1', 'v2, no map', 'v2'):
                extra = {'cv_window_s': 2 * k, 'cv_std': cv_std.tolist()} if name == 'same velocity' else None
                record(rows, qname, h, name, t[name], t['y'], v['y'], v[name], extra)
            # Destination: only walks where it is known, same model with and without it.
            vd = torch.as_tensor(np.where(~np.isnan(data['val']['dest'][:, 0]))[0])
            td = torch.as_tensor(te_dest)
            sub = lambda params, i: tuple(p[i] for p in params)
            record(rows, qname, h, 'v2 (dest subset)', sub(t['v2'], td), t['y'][td], v['y'][vd], sub(v['v2'], vd))
            record(rows, qname, h, 'v2 + destination', sub(t['v2 + destination'], td), t['y'][td], v['y'][vd],
                   sub(v['v2 + destination'], vd))
    return rows


def main():
    maps = load_maps()
    data, rasters = load(maps)
    print(f"train {len(data['train']['hist'])}, val {len(data['val']['hist'])}, test ({TEST_AREA}) "
          f"{len(data['test']['hist'])} windows")
    if len(sys.argv) > 2 and sys.argv[1] == '--eval':
        out = Path(sys.argv[2]).resolve()
        model = M2.MovementModel2()
        model.load_state_dict(torch.load(out / 'model.pt'))
    else:
        out = HERE / 'runs' / time.strftime('v2-%Y%m%d-%H%M%S')
        out.mkdir(parents=True)
        model = train(data, rasters, out)
    model.eval()
    v1 = M.MovementModel()
    v1.load_state_dict(torch.load(HERE / 'runs' / 'latest' / 'model.pt'))
    v1.eval()
    rows = evaluate(model, v1, data, rasters)
    (out / 'metrics.json').write_text(json.dumps(rows, indent=1))
    latest = HERE / 'runs' / 'v2-latest'
    latest.unlink(missing_ok=True)
    latest.symlink_to(out.name)
    print(f'saved {out}')


if __name__ == '__main__':
    main()
