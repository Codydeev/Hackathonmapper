"""Export a trained run for the phone and the web.

    python ml/export.py [run_dir]     # default ml/runs/latest

Writes to ml/export/:
  movement-model.json   weights + constants, read by the JS and Swift code
  golden.json           test cases with the expected output, for checking ports
"""

import json
import sys
from pathlib import Path

import numpy as np
import torch

import model as M
from train import DATA, TEST_AREA

HERE = Path(__file__).parent
OUT = HERE / 'export'


def spec(net):
    layers = [m for m in net.net if isinstance(m, torch.nn.Linear)]
    r = lambda a: np.round(a.detach().numpy().astype(float), 6).tolist()
    return {
        'version': 1,
        'K': M.K, 'histN': M.HIST_N, 'histStep': M.HIST_STEP, 'hMin': M.H_MIN, 'hMax': M.H_MAX,
        'headingLookback': list(M.HEADING_LOOKBACK), 'headingMin': M.HEADING_MIN,
        'posScale': M.POS_SCALE, 'accScale': 20.0, 'stdFloor': M.STD_FLOOR,
        'horizonScale': [2.0, 1.3], 'activation': 'silu',
        'layers': [{'w': r(l.weight), 'b': r(l.bias)} for l in layers],
    }


@torch.no_grad()
def predict_world(net, hist, acc, h):
    """Mixture in the same frame as `hist`: weights, means (absolute), covariances."""
    x, th = M.features(hist, acc, h)
    logw, mean, std, rho = net(torch.as_tensor(x), torch.as_tensor(h, dtype=torch.float32))
    w = logw.exp().numpy()
    mean, std, rho = mean.numpy(), std.numpy(), rho.numpy()
    c, s = np.cos(th)[:, None], np.sin(th)[:, None]
    mw = np.stack([c * mean[..., 0] - s * mean[..., 1], s * mean[..., 0] + c * mean[..., 1]], -1) + hist[:, -1:, :]
    sxx, syy, sxy = std[..., 0] ** 2, std[..., 1] ** 2, rho * std[..., 0] * std[..., 1]
    cov = np.stack([c * c * sxx - 2 * c * s * sxy + s * s * syy,
                    c * s * (sxx - syy) + (c * c - s * s) * sxy,
                    s * s * sxx + 2 * c * s * sxy + c * c * syy], -1)   # xx, xy, yy
    return w, mw, cov


def main():
    run = Path(sys.argv[1]) if len(sys.argv) > 1 else HERE / 'runs' / 'latest'
    net = M.MovementModel()
    net.load_state_dict(torch.load(run / 'model.pt'))
    net.eval()
    OUT.mkdir(exist_ok=True)
    (OUT / 'movement-model.json').write_text(json.dumps(spec(net), separators=(',', ':')))

    # Golden cases: real test-area histories, moved somewhere arbitrary, with
    # some still, some short (padded) and a spread of accuracies and horizons.
    rng = np.random.default_rng(7)
    z = np.load(DATA / f'{TEST_AREA}.npz')
    hist = z['hist'][rng.choice(len(z['hist']), 24, replace=False)].astype(float)
    hist += rng.uniform(-500, 500, (len(hist), 1, 2))
    hist[0] = hist[0, -1]                     # standing still: no heading
    hist[1, :20] = hist[1, 20]                # short history, padded
    acc = rng.choice([4.0, 8.0, 15.0, 25.0], len(hist))
    h = rng.choice([2.0, 10.0, 30.0, 60.0, 120.0, 180.0, 45.5], len(hist))
    hist = np.round(hist, 4)   # what the ports read back from JSON
    w, m, cov = predict_world(net, hist, acc, h)
    cases = [{'hist': hist[i].tolist(), 'acc': float(acc[i]), 'h': float(h[i]),
              'weights': w[i].tolist(), 'means': m[i].tolist(), 'covs': cov[i].tolist()}
             for i in range(len(hist))]
    (OUT / 'golden.json').write_text(json.dumps(cases))
    kb = (OUT / 'movement-model.json').stat().st_size / 1024
    params = sum(p.numel() for p in net.parameters())
    print(f'exported {run.resolve().name}: {params} parameters, movement-model.json {kb:.0f} kB, {len(cases)} golden cases')


if __name__ == '__main__':
    main()
