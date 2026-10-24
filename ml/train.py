"""Train the movement model and score it against simple baselines on an area it
never saw during training.

    python ml/train.py            # -> ml/runs/<time>/model.pt + metrics.json

Scores, per horizon and per history quality:
  err50    median distance from the best single guess to where the person was
  cover90  how often the person was inside the predicted 90% area (want 0.90)
  area90   size of that 90% area in hectares: the area a search team would
           have to cover. Smaller is better, as long as cover90 holds. Each
           method's 90% line is calibrated on validation walks (split
           conformal), so all methods make the same promise.
  nll      negative log likelihood (lower is better)
"""

import json
import math
import os
import time
from pathlib import Path

import numpy as np
import torch

from model import (H_MAX, H_MIN, HIST_N, MovementModel, features, mixture_logpdf, mixture_mean,
                   mixture_sample, rotate)

HERE = Path(__file__).parent
DATA = HERE / 'data' / 'windows'
TEST_AREA = 'hervanta'
GPS_ACC = 4.0          # m, error of an ordinary phone GPS fix
NOISE_MAX = 25.0       # m, worst mesh estimate error we train on
NOISE_RHO = 0.9        # correlation of that error between 2 s steps
EVAL_H = (10, 30, 60, 120, 180)
EVAL_NOISE = {'gps': 0.0, 'mesh': 15.0}
CV_WINDOWS = (5, 10, 15, 30)   # history steps (10..60 s) the velocity baseline may average over
STEPS = int(os.environ.get('STEPS', 12000))
BATCH = 512


def load():
    rng = np.random.default_rng(0)
    train, val, test = [], [], None
    for f in sorted(DATA.glob('*.npz')):
        z = np.load(f)
        if f.stem == TEST_AREA:
            test = (z['hist'], z['fut'])
            continue
        traces = np.unique(z['trace'])
        held = np.isin(z['trace'], rng.choice(traces, max(1, len(traces) // 10), replace=False))
        val.append((z['hist'][held], z['fut'][held]))
        train.append((z['hist'][~held], z['fut'][~held]))
        print(f'{f.stem}: {(~held).sum()} train, {held.sum()} val windows')
    cat = lambda parts: tuple(np.concatenate(p) for p in zip(*parts))
    return cat(train), cat(val), test


def corrupt(hist, fut, rng, sigma=None, h=None, jitter=True):
    """Make a batch look like what a phone in the mesh would actually have."""
    B = len(hist)
    th = rng.uniform(0, 2 * math.pi, B)
    hist, fut = rotate(hist, th), rotate(fut, th)
    flip = rng.random(B) < 0.5
    hist[flip, :, 1] *= -1
    fut[flip, :, 1] *= -1
    if sigma is None:
        sigma = np.where(rng.random(B) < 0.35, 0.0, rng.uniform(0, NOISE_MAX, B))
    sigma = np.broadcast_to(sigma, (B,)).astype(float)
    e = np.empty((B, HIST_N, 2))
    e[:, 0] = rng.standard_normal((B, 2))
    for t in range(1, HIST_N):
        e[:, t] = NOISE_RHO * e[:, t - 1] + math.sqrt(1 - NOISE_RHO ** 2) * rng.standard_normal((B, 2))
    hist = hist + e * sigma[:, None, None]
    if jitter:   # sometimes only a short history exists: pad with the oldest known point
        first = np.where(rng.random(B) < 0.2, rng.integers(0, HIST_N - 1, B), 0)
        src = np.maximum(np.arange(HIST_N)[None], first[:, None])
        hist = hist[np.arange(B)[:, None], src]
    if h is None:
        h = np.round(np.exp(rng.uniform(math.log(H_MIN), math.log(H_MAX), B))).astype(int)
    h = np.broadcast_to(h, (B,)).astype(int)
    target = fut[np.arange(B), h - 1] - hist[:, -1]
    acc = np.sqrt(sigma ** 2 + GPS_ACC ** 2) * (np.exp(0.25 * rng.standard_normal(B)) if jitter else 1)
    x, head = features(hist, acc, h.astype(float))
    hist_rot = rotate(hist - hist[:, -1:], -head)
    return x, h.astype(np.float32), rotate(target, -head).astype(np.float32), hist_rot


def as_t(*a):
    return [torch.as_tensor(np.ascontiguousarray(v), dtype=torch.float32) for v in a]


def train(tr, va, out):
    torch.manual_seed(0)
    rng = np.random.default_rng(1)
    model = MovementModel()
    opt = torch.optim.AdamW(model.parameters(), lr=3e-3, weight_decay=1e-5)
    sched = torch.optim.lr_scheduler.OneCycleLR(opt, max_lr=3e-3, total_steps=STEPS, pct_start=0.05)
    vx, vh, vy, _ = corrupt(*va, np.random.default_rng(2))
    vx, vh, vy = as_t(vx, vh, vy)
    best, t0 = float('inf'), time.time()
    for step in range(1, STEPS + 1):
        i = rng.integers(0, len(tr[0]), BATCH)
        x, h, y, _ = corrupt(tr[0][i], tr[1][i], rng)
        x, h, y = as_t(x, h, y)
        loss = -mixture_logpdf(y, *model(x, h)).mean()
        opt.zero_grad()
        loss.backward()
        torch.nn.utils.clip_grad_norm_(model.parameters(), 5.0)
        opt.step()
        sched.step()
        if step % 500 == 0 or step == STEPS:
            with torch.no_grad():
                v = -mixture_logpdf(vy, *model(vx, vh)).mean().item()
            if v < best:
                best = v
                torch.save(model.state_dict(), out / 'model.pt')
            print(f'step {step}: train nll {loss.item():.3f}, val nll {v:.3f}{" *" if v == best else ""}'
                  f'  ({time.time() - t0:.0f} s)', flush=True)
    model.load_state_dict(torch.load(out / 'model.pt'))
    return model


def gaussian(mean, std):
    """A one-component mixture in the model's output format."""
    B = len(mean)
    return (torch.zeros(B, 1), mean[:, None].float(), std[:, None].float().clamp(min=0.5), torch.zeros(B, 1))


def fit_baselines(tr, sigma, h, rng):
    """Tune both baselines on training data for one (history quality, horizon)."""
    _, _, y, hr = corrupt(*tr, rng, sigma=sigma, h=h, jitter=False)
    y = torch.as_tensor(y)
    still = math.sqrt((y ** 2).mean().item())
    best = None
    for k in CV_WINDOWS:
        mean = torch.as_tensor(-hr[:, -1 - k] / (k * 2) * h).float()
        std = (y - mean).pow(2).mean(0).sqrt()
        nll = -mixture_logpdf(y, *gaussian(mean, std.expand_as(mean))).mean().item()
        if best is None or nll < best[0]:
            best = (nll, k, std)
    return still, best[1], best[2]


def score(params, y, thr, rng_seed=0, samples=2000):
    """err50, cover90, area90 (ha), nll for mixtures `params` and truths `y`.
    The 90% area is every point with log density >= thr, where thr was set on
    validation walks so that 90% of them fell inside."""
    gen = torch.Generator().manual_seed(rng_seed)
    errs, cov, area, nll = [], [], [], []
    for a in range(0, len(y), 256):
        p = [t[a:a + 256] for t in params]
        yy = y[a:a + 256]
        lp_true = mixture_logpdf(yy, *p)[:, 0]
        if p[0].shape[1] == 1:   # one Gaussian: the area is an exact ellipse
            sx, sy, r = p[2][:, 0, 0], p[2][:, 0, 1], p[3][:, 0]
            norm = 2 * math.pi * sx * sy * torch.sqrt(1 - r ** 2)
            c = (-2 * (thr + torch.log(norm))).clamp(min=0)
            area.append(math.pi * c * sx * sy * torch.sqrt(1 - r ** 2))
        else:                    # mixture: Monte Carlo, E_p[1{p >= t} / p]
            lp = mixture_logpdf(mixture_sample(samples, *p, gen=gen), *p)
            area.append(torch.where(lp >= thr, torch.exp(-lp), 0.0).mean(1))
        cov.append(lp_true >= thr)
        errs.append((mixture_mean(p[0], p[1]) - yy).norm(dim=1))
        nll.append(-lp_true)
    c = lambda v: torch.cat(v).float()
    return {'err50': c(errs).median().item(), 'cover90': c(cov).mean().item(),
            'area90': c(area).mean().item() / 1e4, 'nll': c(nll).mean().item()}


def methods(model, x, h, y, hr, still, k, cv_std):
    cv_mean = torch.as_tensor(-hr[:, -1 - k] / (k * 2) * h[0].item()).float()
    return [
        ('stand still', gaussian(torch.zeros_like(y), torch.full_like(y, still))),
        (f'same velocity ({2 * k} s avg)', gaussian(cv_mean, cv_std.expand_as(cv_mean))),
        ('model', model(x, h)),
    ]


@torch.no_grad()
def evaluate(model, tr, va, te):
    """Baselines are tuned on train, every method's 90% line is calibrated on
    validation walks, and everything is scored on the held-out area."""
    rows = []
    for qname, sigma in EVAL_NOISE.items():
        for h in EVAL_H:
            still, k, cv_std = fit_baselines(tr, sigma, h, np.random.default_rng(100 + h))
            sets = {}
            for split, data, seed in (('val', va, 1000 + h), ('test', te, h)):
                x, hh, y, hr = corrupt(*data, np.random.default_rng(seed), sigma=sigma, h=h, jitter=False)
                x, hh, y = as_t(x, hh, y)
                sets[split] = (y, methods(model, x, hh, y, hr, still, k, cv_std))
            for (name, pv), (_, params) in zip(sets['val'][1], sets['test'][1]):
                thr = torch.quantile(mixture_logpdf(sets['val'][0], *pv)[:, 0], 0.10).item()
                r = {'history': qname, 'h': h, 'method': name, **score(params, sets['test'][0], thr)}
                if name.startswith('same'):
                    r.update(cv_window_s=2 * k, cv_std=cv_std.tolist())
                rows.append(r)
                print(f"{qname:5} h={h:3d}s  {name:26} err50 {r['err50']:6.1f} m  cover90 {r['cover90']:.2f}  "
                      f"area90 {r['area90']:6.2f} ha  nll {r['nll']:.2f}", flush=True)
    return rows


def main():
    tr, va, te = load()
    print(f'train {len(tr[0])}, val {len(va[0])}, test ({TEST_AREA}) {len(te[0])} windows')
    out = HERE / 'runs' / time.strftime('%Y%m%d-%H%M%S')
    out.mkdir(parents=True)
    model = train(tr, va, out)
    model.eval()
    rows = evaluate(model, tr, va, te)
    (out / 'metrics.json').write_text(json.dumps(rows, indent=1))
    latest = HERE / 'runs' / 'latest'
    latest.unlink(missing_ok=True)
    latest.symlink_to(out.name)
    print(f'saved {out}')


if __name__ == '__main__':
    main()
