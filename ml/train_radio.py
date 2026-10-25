"""Train a neural position estimator on simulated Bluetooth and UWB, on the GPU.

    python ml/train_radio.py                 # -> ml/runs/radio-<time>/, results/metrics-radio.json

The lost person walks real recorded walks (training areas only; Hervanta is
the test); everything about the radios is simulated (radio_sim.py), so the
results say what the sensors could do under those assumptions, not what real
phones do. Compared with a classic least-squares fix on the same readings.

Model: every reading in the last 30 s is a token (anchor position, RSSI, UWB
range, time, the lost phone's own step displacement to now); a small
transformer reads them and outputs the position now with an uncertainty.
"""

import json
import math
import os
import sys
import time
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn

import pieces as PC
from radio_sim import N_FEAT, WINDOW, simulate
from train import TEST_AREA

HERE = Path(__file__).parent
DEV = torch.device('mps' if torch.backends.mps.is_available() else 'cpu')
STEPS = int(os.environ.get('STEPS', 20000))
BATCH = 512


def walk_windows(areas, stride):
    out = []
    for a in areas:
        for p in PC.load(a):
            xy = p['xy'].astype(np.float32)
            for c in range(WINDOW - 1, len(xy), stride):
                out.append(xy[c - WINDOW + 1:c + 1])
    return torch.as_tensor(np.stack(out))


class RadioNet(nn.Module):
    def __init__(self, d=128, layers=3):
        super().__init__()
        self.inp = nn.Linear(N_FEAT, d)
        self.cls = nn.Parameter(torch.zeros(1, 1, d))
        enc = nn.TransformerEncoderLayer(d, 4, 2 * d, dropout=0.0, batch_first=True, norm_first=True)
        self.enc = nn.TransformerEncoder(enc, layers)
        self.head = nn.Sequential(nn.LayerNorm(d), nn.Linear(d, d), nn.GELU(), nn.Linear(d, 3))

    def forward(self, tokens, mask):
        x = torch.cat([self.cls.expand(len(tokens), 1, -1), self.inp(tokens)], 1)
        pad = torch.cat([torch.zeros(len(mask), 1, dtype=torch.bool, device=mask.device), ~mask], 1)
        h = self.enc(x, src_key_padding_mask=pad)[:, 0]
        o = self.head(h)
        return o[:, :2] * 50, torch.exp(o[:, 2].clamp(-8, 3)) * 50 + 0.02


def thin(tok, mask, stride=2):
    """Keep every 2nd second (always including now): half the tokens, same information to within a second."""
    T = WINDOW
    sel = (torch.arange(tok.shape[1], device=tok.device) % T) % stride == (T - 1) % stride
    return tok[:, sel], mask[:, sel]


def nll(mean, sigma, target):
    return (((target - mean) ** 2).sum(1) / (2 * sigma ** 2) + 2 * torch.log(sigma)).mean()


def least_squares(extra, ref, iters=12):
    """Classic fix: ranges from UWB (or RSSI inverted with a nominal path-loss
    model), each placed where the person was at that second using the step
    track when there is one (else only the last 2 s), Gauss-Newton from the anchors' centre."""
    rep, B = extra['reported'], extra['reported'].shape[0]
    T = rep.shape[2]
    use_uwb = extra['uwb_ok']
    r_ble = 10 ** ((-59 - extra['rssi']) / 25)
    rng = torch.where(use_uwb, extra['uwb'], r_ble)
    sig = torch.where(use_uwb, torch.full_like(rng, 0.3), 0.45 * r_ble)
    ok = use_uwb | extra['ble_ok']
    has_steps = extra['to_now'].abs().sum((1, 2)) > 0
    recent = torch.arange(T, device=rep.device) >= T - 2
    ok = ok & (has_steps[:, None, None] | recent[None, None])
    w = ok.float() / sig ** 2
    shift = extra['to_now'][:, None]                                       # person at t = P - to_now[t]
    P = ref + 1.0
    for _ in range(iters):
        pos_t = P[:, None, None] - shift
        diff = pos_t - rep
        dist = torch.linalg.norm(diff, dim=-1).clamp(min=0.1)
        res = dist - rng
        J = diff / dist[..., None]
        JtJ = torch.einsum('bkti,bktj,bkt->bij', J, J, w) + 1e-3 * torch.eye(2, device=rep.device)
        Jtr = torch.einsum('bkti,bkt->bi', J, w * res)
        P = P - torch.linalg.solve(JtJ, Jtr)
    return P


def refine(extra, start, iters=10, huber=0.3):
    """Hybrid: start from the network's estimate, then fit the UWB ranges
    exactly (Gauss-Newton with Huber weights, so blocked readings that read
    long count less). Uses the last 2 s, or the whole window aligned by the
    lost phone's steps when it has them. Without UWB, keeps the network's answer."""
    rep, T = extra['reported'], extra['reported'].shape[2]
    ok = extra['uwb_ok']
    has_steps = extra['to_now'].abs().sum((1, 2)) > 0
    recent = torch.arange(T, device=rep.device) >= T - 2
    ok = ok & (has_steps[:, None, None] | recent[None, None])
    acc = extra['gps_sigma'][:, None, None]
    shift = extra['to_now'][:, None]
    P = start.clone()
    for _ in range(iters):
        diff = P[:, None, None] - shift - rep
        dist = torch.linalg.norm(diff, dim=-1).clamp(min=0.1)
        res = dist - extra['uwb']
        w = ok.float() / (0.08 ** 2 + acc ** 2) * torch.where(res.abs() <= huber, 1.0, huber / res.abs().clamp(min=1e-6))
        J = diff / dist[..., None]
        JtJ = torch.einsum('bkti,bktj,bkt->bij', J, J, w) + 1e-3 * torch.eye(2, device=rep.device)
        P = P - torch.linalg.solve(JtJ, torch.einsum('bkti,bkt->bi', J, w * res))
    enough = ok.sum((1, 2)) >= 3          # need at least three ranges to pin a point
    return torch.where(enough[:, None], P, start)


SCENARIOS = {
    'Bluetooth, 1 phone nearby (GPS)': {'anchors': 1, 'ble': True, 'uwb': False, 'rtk': False, 'steps': False},
    'Bluetooth, 4 phones nearby (GPS)': {'anchors': 4, 'ble': True, 'uwb': False, 'rtk': False, 'steps': False},
    'UWB, 1 phone nearby (GPS)': {'anchors': 1, 'ble': False, 'uwb': True, 'rtk': False, 'steps': False},
    'UWB, 4 phones nearby (GPS)': {'anchors': 4, 'ble': False, 'uwb': True, 'rtk': False, 'steps': False},
    'UWB, 1 phone nearby (RTK)': {'anchors': 1, 'ble': False, 'uwb': True, 'rtk': True, 'steps': False},
    'UWB, 2 phones nearby (RTK)': {'anchors': 2, 'ble': False, 'uwb': True, 'rtk': True, 'steps': False},
    'UWB, 4 phones nearby (RTK)': {'anchors': 4, 'ble': False, 'uwb': True, 'rtk': True, 'steps': False},
    'UWB + steps, 1 phone nearby (RTK)': {'anchors': 1, 'ble': False, 'uwb': True, 'rtk': True, 'steps': True},
    'UWB + steps, 2 phones nearby (RTK)': {'anchors': 2, 'ble': False, 'uwb': True, 'rtk': True, 'steps': True},
}


@torch.no_grad()
def evaluate(net, test):
    net.eval()
    rows = {}
    for k, (name, cfg) in enumerate(SCENARIOS.items()):
        errs, ls_errs, hy_errs = [], [], []
        g = torch.Generator(device=DEV).manual_seed(1000 + k)
        for a in range(0, len(test), 1024):
            walks = test[a:a + 1024].to(DEV)
            tok, mask, target, ref, extra = simulate(walks, g, cfg)
            mean, _ = net(*thin(tok, mask))
            errs.append(torch.linalg.norm(mean - target, dim=1).cpu())
            ls_errs.append(torch.linalg.norm(least_squares(extra, ref) - ref - target, dim=1).cpu())
            hy_errs.append(torch.linalg.norm(refine(extra, mean + ref) - ref - target, dim=1).cpu())
        e, l, h = torch.cat(errs).numpy(), torch.cat(ls_errs).numpy(), torch.cat(hy_errs).numpy()
        rows[name] = {'median': float(np.median(e)), 'p90': float(np.percentile(e, 90)), 'under1': float((e < 1).mean()),
                      'under3': float((e < 3).mean()), 'ls_median': float(np.median(l)), 'ls_under1': float((l < 1).mean()),
                      'hybrid_median': float(np.median(h)), 'hybrid_p90': float(np.percentile(h, 90)), 'hybrid_under1': float((h < 1).mean())}
        r = rows[name]
        print(f"  {name:36} network {r['median']:6.2f} m ({100 * r['under1']:3.0f}% <1 m)   least squares {r['ls_median']:6.2f} m "
              f"({100 * r['ls_under1']:3.0f}%)   hybrid {r['hybrid_median']:6.2f} m (90%: {r['hybrid_p90']:5.1f} m, {100 * r['hybrid_under1']:3.0f}% <1 m)", flush=True)
    net.train()
    return rows


def main():
    from fetch_osm import AREAS
    areas = [a for a in AREAS if a not in PC.SKIP and (HERE / 'data' / 'pieces' / f'{a}.pkl').exists()]
    test_w = walk_windows([TEST_AREA], 15)
    if len(sys.argv) > 2 and sys.argv[1] == '--eval':   # re-score a trained run
        net = RadioNet().to(DEV)
        net.load_state_dict(torch.load(Path(sys.argv[2]) / 'model.pt', map_location=DEV))
        print('Hervanta (held out), simulated radios:')
        rows = evaluate(net, test_w)
        (HERE / 'results' / 'metrics-radio.json').write_text(json.dumps({'n_test': len(test_w), 'run': Path(sys.argv[2]).name, 'results': rows}, indent=1))
        return
    train_w = walk_windows([a for a in areas if a != TEST_AREA], 5).to(DEV)
    print(f'{len(train_w)} training windows from {len(areas) - 1} areas, {len(test_w)} Hervanta test windows, device {DEV}')
    torch.manual_seed(0)
    net = RadioNet().to(DEV)
    opt = torch.optim.AdamW(net.parameters(), lr=3e-4, weight_decay=1e-4)
    sched = torch.optim.lr_scheduler.OneCycleLR(opt, max_lr=3e-4, total_steps=STEPS, pct_start=0.05)
    g = torch.Generator(device=DEV).manual_seed(1)
    out = HERE / 'runs' / time.strftime('radio-%Y%m%d-%H%M%S')
    out.mkdir(parents=True)
    # Live view (ml/live/index.html): progress written every 25 steps, a quick
    # held-out check every 500.
    live = HERE / 'runs' / 'live' / 'progress.json'
    live.parent.mkdir(parents=True, exist_ok=True)
    quick = {k: SCENARIOS[k] for k in ('Bluetooth, 4 phones nearby (GPS)', 'UWB, 4 phones nearby (GPS)',
                                       'UWB, 2 phones nearby (RTK)', 'UWB + steps, 1 phone nearby (RTK)')}
    progress = {'steps': STEPS, 'batch': BATCH, 'device': str(DEV), 'trainWindows': len(train_w), 'testWindows': len(test_w),
                'started': time.time(), 'step': 0, 'curve': [], 'checks': [], 'status': 'training'}
    sample_test = test_w[torch.randperm(len(test_w), generator=torch.Generator().manual_seed(0))[:1024]].to(DEV)

    def write_live():
        progress['updated'] = time.time()
        tmp = live.with_suffix('.tmp')
        tmp.write_text(json.dumps(progress))
        tmp.replace(live)

    @torch.no_grad()
    def quick_check(step):
        net.eval()
        row = {'step': step}
        for k, (name, cfg) in enumerate(quick.items()):
            gq = torch.Generator(device=DEV).manual_seed(500 + k)
            tok, mask, target, ref, extra = simulate(sample_test, gq, cfg)
            mean, _ = net(*thin(tok, mask))
            row[name] = torch.linalg.norm(mean - target, dim=1).median().item()
            row[name + ' · least squares'] = torch.linalg.norm(least_squares(extra, ref) - ref - target, dim=1).median().item()
        net.train()
        progress['checks'].append(row)

    quick_check(0)
    write_live()
    t0 = time.time()
    for step in range(1, STEPS + 1):
        idx = torch.randint(0, len(train_w), (BATCH,), device=DEV, generator=g)
        walks = train_w[idx]
        th = 2 * math.pi * torch.rand(BATCH, device=DEV, generator=g)        # any heading
        c, s = torch.cos(th)[:, None], torch.sin(th)[:, None]
        walks = torch.stack([c * walks[..., 0] - s * walks[..., 1], s * walks[..., 0] + c * walks[..., 1]], -1)
        tok, mask, target, _, _ = simulate(walks, g)
        mean, sigma = net(*thin(tok, mask))
        loss = nll(mean, sigma, target)
        opt.zero_grad()
        loss.backward()
        torch.nn.utils.clip_grad_norm_(net.parameters(), 1.0)
        opt.step()
        sched.step()
        if step % 25 == 0 or step == STEPS:
            med = torch.linalg.norm(mean - target, dim=1).median().item()
            progress['step'] = step
            progress['elapsed'] = time.time() - t0
            progress['curve'].append([step, round(loss.item(), 4), round(med, 3), round(sched.get_last_lr()[0], 7)])
            if step % 500 == 0 or step == STEPS:
                quick_check(step)
            write_live()
            if step % 1000 == 0 or step == STEPS:
                print(f'step {step}: loss {loss.item():.3f}, median error this batch {med:.2f} m ({time.time() - t0:.0f} s)', flush=True)
    torch.save(net.state_dict(), out / 'model.pt')
    progress['status'] = 'evaluating'
    write_live()
    print('Hervanta (held out), simulated radios:')
    rows = evaluate(net, test_w)
    (HERE / 'results' / 'metrics-radio.json').write_text(json.dumps({'n_test': len(test_w), 'steps': STEPS, 'results': rows}, indent=1))
    progress['status'] = 'done'
    progress['final'] = rows
    write_live()
    print(f'saved {out}')


if __name__ == '__main__':
    main()
